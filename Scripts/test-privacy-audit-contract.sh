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

# A clean production scan must accept test-fixture scripts as test-only input.
bash "$repository_root/Scripts/audit-privacy.sh" --static-only >/dev/null

# The same scan must still reject a sensitive value written to a production source file.
mutation_path="$(mktemp "$repository_root/App/PrivacyLoggingMutation.XXXXXX.swift")"
printf '%s\n' 'func privacyLoggingMutation(filename: String) {' \
    '    print("filename=\\(filename)")' \
    '}' > "$mutation_path"
if bash "$repository_root/Scripts/audit-privacy.sh" --static-only >/dev/null 2>&1; then
    echo "privacy audit accepted a production filename logging mutation" >&2
    exit 1
fi

echo "privacy audit source-scope contract PASS"
