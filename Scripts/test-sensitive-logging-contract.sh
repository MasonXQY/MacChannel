#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mutation_path=""
mutation_directory=""
test_root="$(mktemp -d "${TMPDIR:-/tmp}/dropmesh-sensitive-logging-contract.XXXXXX")"

cleanup() {
    if [[ -n "$mutation_path" ]]; then
        rm -f "$mutation_path"
    fi
    if [[ -n "$mutation_directory" ]]; then
        rmdir "$mutation_directory"
    fi
    case "$test_root" in
        "${TMPDIR:-/tmp}"/dropmesh-sensitive-logging-contract.*) rm -rf "$test_root" ;;
        *) echo "refusing unexpected cleanup target: $test_root" >&2; exit 1 ;;
    esac
}
trap cleanup EXIT INT TERM

# The no-argument production scan is the documented acceptance invocation.
bash "$repository_root/Scripts/check-sensitive-logging.sh" >/dev/null

# Public certificate fingerprint helpers return their value to a command-substitution
# caller, and the forged plist is test input written to a file. Their exemptions must
# survive line-number drift while remaining bound to the exact helper/fixture writes.
mkdir -p "$test_root/Scripts"
for source_name in app-store-validation.sh audit-app-store-prerequisites.sh test-app-store-prerequisites-contract.sh; do
    cp "$repository_root/Scripts/$source_name" "$test_root/Scripts/$source_name"
    sed -i '' '2i\
# line-number drift must not change scanner behavior
' "$test_root/Scripts/$source_name"
    bash "$repository_root/Scripts/check-sensitive-logging.sh" "$test_root/Scripts/$source_name" >/dev/null
done

assert_rejected_copy() {
    local source_name="$1" mutation="$2"
    mutation_path="$test_root/Scripts/$source_name"
    cp "$repository_root/Scripts/$source_name" "$mutation_path"
    printf '\n%s\n' "$mutation" >>"$mutation_path"
    if bash "$repository_root/Scripts/check-sensitive-logging.sh" "$mutation_path" >/dev/null 2>&1; then
        echo "sensitive logging scan accepted unsafe mutation in $source_name" >&2
        exit 1
    fi
    mutation_path=""
}

assert_adjacent_helper_leak_rejected() {
    local source_name="$1"
    local leak_line=$'    printf \'%s\\n\' "$private_key"'
    mutation_path="$test_root/Scripts/$source_name"
    cp "$repository_root/Scripts/$source_name" "$mutation_path"
    sed -i '' '/^[[:space:]]*[[:alnum:]_]*fingerprint[[:alnum:]_]*="$fingerprint"/a\
'"$leak_line"'
' "$mutation_path"
    if bash "$repository_root/Scripts/check-sensitive-logging.sh" "$mutation_path" >/dev/null 2>&1; then
        echo "sensitive logging scan accepted a leak adjacent to the allowed helper return in $source_name" >&2
        exit 1
    fi
    mutation_path=""
}

assert_parser_confusion_rejected() {
    local source_name="$1"
    mutation_path="$test_root/Scripts/$source_name"
    cp "$repository_root/Scripts/$source_name" "$mutation_path"
    printf '\n%s\n' \
        "cat <<'FAKE_FUNCTION_HEADER'" \
        'macchannel_resolve_store_identity() {' \
        'FAKE_FUNCTION_HEADER' \
        'printf '\''%s\n'\'' "$fingerprint"' >>"$mutation_path"
    if bash "$repository_root/Scripts/check-sensitive-logging.sh" "$mutation_path" >/dev/null 2>&1; then
        echo "sensitive logging scan accepted output after a heredoc-spoofed helper boundary" >&2
        exit 1
    fi
    mutation_path=""
}

assert_rejected_copy app-store-validation.sh \
    $'unrelated_fingerprint_output() {\n    local fingerprint="$1"\n    printf \'%s\\n\' "$fingerprint"\n}'
assert_adjacent_helper_leak_rejected app-store-validation.sh
assert_parser_confusion_rejected app-store-validation.sh
assert_rejected_copy audit-app-store-prerequisites.sh \
    $'unrelated_fingerprint_output() {\n    local fingerprint="$1"\n    printf \'%s\\n\' "$fingerprint"\n}'
assert_adjacent_helper_leak_rejected audit-app-store-prerequisites.sh
assert_rejected_copy test-app-store-prerequisites-contract.sh \
    $'payload="private fixture payload"\nprintf \'%s\\n\' "$payload"'

# It must reject sensitive output from app/tool Swift, service/tool Go and shell.
for mutation_root in App Services/rendezvous Scripts Tools/PrivacyEvidenceVerifier Tools/AuditOwnerPreflight; do
    temporary_path="$(mktemp "$repository_root/$mutation_root/SensitiveLoggingMutation.XXXXXX")"
    case "$mutation_root" in
        App|Tools/AuditOwnerPreflight)
            mutation_path="$temporary_path.swift"
            mv "$temporary_path" "$mutation_path"
            mutation_source=$'func sensitiveLoggingMutation(path: String) {\n    print("path=\\(path)")\n}'
            printf '%s\n' "$mutation_source" > "$mutation_path"
            ;;
        Services/rendezvous)
            mutation_path="$temporary_path.go"
            mv "$temporary_path" "$mutation_path"
            mutation_source=$'package main\nfunc sensitiveLoggingMutation(content string) {\n    log.Printf("content=%s", content)\n}'
            printf '%s\n' "$mutation_source" > "$mutation_path"
            ;;
        Scripts)
            mutation_path="$repository_root/Scripts/test-sensitive-console-${temporary_path##*.}.sh"
            mv "$temporary_path" "$mutation_path"
            mutation_source=$'#!/usr/bin/env bash\nprintf "filename=%s\\n" "$filename"'
            printf '%s\n' "$mutation_source" > "$mutation_path"
            ;;
        Tools/PrivacyEvidenceVerifier)
            mutation_path="$temporary_path.go"
            mv "$temporary_path" "$mutation_path"
            mutation_source=$'package verifiermutation\nimport "fmt"\nfunc sensitiveLoggingMutation(payload string) {\n    fmt.Printf("payload=%s", payload)\n}'
            printf '%s\n' "$mutation_source" > "$mutation_path"
            ;;
    esac
    if bash "$repository_root/Scripts/check-sensitive-logging.sh" >/dev/null 2>&1; then
        echo "sensitive logging scan accepted a $mutation_root mutation" >&2
        exit 1
    fi
    if bash "$repository_root/Scripts/audit-privacy.sh" --static-only >/dev/null 2>&1; then
        echo "privacy audit accepted a $mutation_root mutation" >&2
        exit 1
    fi
    rm -f "$mutation_path"
    mutation_path=""
done

# Native iPhone app, extension, and shared sources are production code. A nearby
# production directory containing "Tests" must remain covered, while only the
# exact iPhone/Tests subtree is excluded from the no-argument production scan.
for mutation_root in iPhone/App iPhone/ShareExtension iPhone/Shared; do
    temporary_path="$(mktemp "$repository_root/$mutation_root/SensitiveLoggingMutation.XXXXXX")"
    mutation_path="$temporary_path.swift"
    mv "$temporary_path" "$mutation_path"
    printf '%s\n' $'func sensitiveLoggingMutation(path: String) {\n    print("path=\\(path)")\n}' > "$mutation_path"
    if bash "$repository_root/Scripts/check-sensitive-logging.sh" >/dev/null 2>&1; then
        echo "sensitive logging scan accepted a $mutation_root mutation" >&2
        exit 1
    fi
    rm -f "$mutation_path"
    mutation_path=""
done

mutation_directory="$(mktemp -d "$repository_root/iPhone/TestsNearbyProduction.XXXXXX")"
mutation_path="$mutation_directory/SensitiveLoggingMutation.swift"
printf '%s\n' $'func sensitiveLoggingMutation(path: String) {\n    print("path=\\(path)")\n}' > "$mutation_path"
if bash "$repository_root/Scripts/check-sensitive-logging.sh" >/dev/null 2>&1; then
    echo "sensitive logging scan excluded a production path merely because its name contains Tests" >&2
    exit 1
fi
rm -f "$mutation_path"
mutation_path=""
rmdir "$mutation_directory"
mutation_directory=""

temporary_path="$(mktemp "$repository_root/iPhone/Tests/SensitiveLoggingFixture.XXXXXX")"
mutation_path="$temporary_path.swift"
mv "$temporary_path" "$mutation_path"
printf '%s\n' $'func sensitiveLoggingFixture(path: String) {\n    print("path=\\(path)")\n}' > "$mutation_path"
if ! bash "$repository_root/Scripts/check-sensitive-logging.sh" >/dev/null 2>&1; then
    echo "sensitive logging scan included the exact iPhone/Tests fixture subtree" >&2
    exit 1
fi
rm -f "$mutation_path"
mutation_path=""

echo "sensitive logging default-scan contract PASS"
