#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mutation_path=""

store_audit="$repository_root/docs/security/app-store-privacy-audit.md"
store_answers="$repository_root/docs/security/app-store-connect-privacy.md"
export_record="$repository_root/docs/security/app-store-export-compliance.md"
for required_file in "$store_audit" "$store_answers" "$export_record"; do
    [[ -f "$required_file" ]] || {
        echo "privacy audit contract FAIL: missing ${required_file#$repository_root/}" >&2
        exit 1
    }
done

for component in 'App client' 'WebRTC framework' 'rendezvous' 'nginx' 'PostgreSQL' 'coturn' 'host/system logs' 'backups' 'monitoring'; do
    grep -F "| $component |" "$store_audit" >/dev/null || {
        echo "privacy audit contract FAIL: missing inventory row: $component" >&2
        exit 1
    }
done
grep -F 'PRODUCTION PRIVACY EVIDENCE: BLOCKED' "$store_audit" >/dev/null
grep -F 'APP STORE CONNECT ANSWERS: DRAFT / BLOCKED' "$store_answers" >/dev/null
grep -F 'EXPORT COMPLIANCE DECISION: BLOCKED' "$export_record" >/dev/null

set +e
store_output="$(bash "$repository_root/Scripts/audit-app-store-privacy.sh" 2>&1)"
store_status=$?
set -e
[[ $store_status -eq 2 ]] || {
    echo "privacy audit contract FAIL: unresolved Store audit must exit 2" >&2
    exit 1
}
grep -F 'App Store privacy audit BLOCKED' <<<"$store_output" >/dev/null

cleanup() {
    if [[ -n "$mutation_path" ]]; then
        rm -f "$mutation_path"
    fi
}
trap cleanup EXIT INT TERM

# A clean production scan must accept test-fixture scripts as test-only input.
bash "$repository_root/Scripts/audit-privacy.sh" --static-only >/dev/null

# The same scan must still reject a sensitive value written to a production source file.
temporary_path="$(mktemp "$repository_root/App/PrivacyLoggingMutation.XXXXXX")"
mutation_path="$temporary_path.swift"
mv "$temporary_path" "$mutation_path"
mutation_source=$'func privacyLoggingMutation(filename: String) {\n    print("filename=\\(filename)")\n}'
printf '%s\n' "$mutation_source" > "$mutation_path"
if bash "$repository_root/Scripts/audit-privacy.sh" --static-only >/dev/null 2>&1; then
    echo "privacy audit accepted a production filename logging mutation" >&2
    exit 1
fi

echo "privacy audit source-scope contract PASS"
