#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
module_root="$repository_root/Tools/PrivacyEvidenceVerifier"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/dropmesh-privacy-verifier-contract.XXXXXX")"

cleanup() {
    case "$test_root" in
        "${TMPDIR:-/tmp}"/dropmesh-privacy-verifier-contract.*) rm -rf "$test_root" ;;
        *) echo "refusing unexpected cleanup target" >&2; exit 1 ;;
    esac
}
trap cleanup EXIT INT TERM

export GOTOOLCHAIN=local
export GOPROXY=off
export GOSUMDB=off

[[ "$(go env GOOS)" == "darwin" ]] || { echo "privacy verifier requires macOS" >&2; exit 2; }
[[ "$(go env CGO_ENABLED)" == "1" ]] || { echo "privacy verifier requires cgo" >&2; exit 2; }

(
    cd "$module_root"
    go test ./...
    go vet ./...
    go build -o "$test_root/privacy-evidence" ./cmd/privacy-evidence
)

assert_cli() {
    local expected_status="$1" expected_line="$2"
    shift 2
    local result_file="$test_root/cli-result"
    set +e
    "$test_root/privacy-evidence" "$@" >"$result_file" 2>&1
    local actual_status=$?
    set -e
    [[ "$actual_status" -eq "$expected_status" ]] || {
        echo "privacy verifier returned unexpected exit status" >&2
        exit 1
    }
    [[ "$(cat "$result_file")" == "$expected_line" ]] || {
        echo "privacy verifier returned unexpected output" >&2
        exit 1
    }
}

assert_cli 2 'PRIVACY_VERIFIER_BLOCKED:usage' production SENSITIVE_CLI_SENTINEL
assert_cli 2 'PRIVACY_VERIFIER_BLOCKED:usage' verify-fixture --bundle nowhere --test-policy nowhere --now 2026-09-07T12:00:00+00:00
assert_cli 2 'PRIVACY_VERIFIER_BLOCKED:unavailable-input' verify-fixture --bundle "$test_root/missing-bundle" --test-policy "$test_root/missing-policy" --now 2026-09-07T12:00:00Z

invalid_bundle="$test_root/invalid-bundle"
mkdir "$invalid_bundle"
printf 'not-json' >"$invalid_bundle/manifest.json"
dd if=/dev/zero of="$invalid_bundle/manifest.sig" bs=64 count=1 2>/dev/null
for artifact_name in backups.json canaries.json client.log compose.json coturn.log database-after.json database-before.json destination.bin host.log inspect.json metrics.txt monitoring.json mounts.json proxy.log receipt.json rendezvous.log source.bin; do
    printf 'synthetic' >"$invalid_bundle/$artifact_name"
done
printf 'not-json' >"$test_root/invalid-policy.json"
chmod 400 "$invalid_bundle"/* "$test_root/invalid-policy.json"
assert_cli 1 'FIXTURE_REJECTED:schema' verify-fixture --bundle "$invalid_bundle" --test-policy "$test_root/invalid-policy.json" --now 2026-09-07T12:00:00Z

bash "$repository_root/Scripts/test-sensitive-logging-contract.sh"
bash "$repository_root/Scripts/audit-privacy.sh" --static-only
bash "$repository_root/Scripts/test-privacy-audit-contract.sh"
bash "$repository_root/Scripts/test-privacy-runtime-block.sh"

app_store_result="$test_root/app-store-result"
set +e
bash "$repository_root/Scripts/audit-app-store-privacy.sh" >"$app_store_result" 2>&1
app_store_status=$?
set -e
[[ "$app_store_status" -eq 2 ]] || { echo "App Store privacy gate did not preserve exit 2" >&2; exit 1; }
rg -q 'BLOCKED' "$app_store_result" || { echo "App Store privacy gate omitted BLOCKED" >&2; exit 1; }
if rg -q 'RUNTIME PASS' "$app_store_result"; then
    echo "App Store privacy gate emitted RUNTIME PASS" >&2
    exit 1
fi

echo "privacy verifier contract PASS"
