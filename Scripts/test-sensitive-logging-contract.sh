#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mutation_path=""

cleanup() {
    if [[ -n "$mutation_path" ]]; then
        rm -f "$mutation_path"
    fi
}
trap cleanup EXIT INT TERM

# The no-argument production scan is the documented acceptance invocation.
bash "$repository_root/Scripts/check-sensitive-logging.sh" >/dev/null

# It must reject sensitive output from Swift, Go, and a test-named shell script.
for mutation_root in App Services/rendezvous Scripts; do
    temporary_path="$(mktemp "$repository_root/$mutation_root/SensitiveLoggingMutation.XXXXXX")"
    case "$mutation_root" in
        App)
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

echo "sensitive logging default-scan contract PASS"
