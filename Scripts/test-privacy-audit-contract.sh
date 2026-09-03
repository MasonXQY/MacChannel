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
