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

# It must still reject a sensitive value logged from a production source directory.
mutation_path="$(mktemp "$repository_root/App/SensitiveLoggingMutation.XXXXXX.swift")"
printf '%s\n' 'func sensitiveLoggingMutation(path: String) {' \
    '    print("path=\\(path)")' \
    '}' > "$mutation_path"
if bash "$repository_root/Scripts/check-sensitive-logging.sh" >/dev/null 2>&1; then
    echo "sensitive logging scan accepted a production path logging mutation" >&2
    exit 1
fi

echo "sensitive logging default-scan contract PASS"
