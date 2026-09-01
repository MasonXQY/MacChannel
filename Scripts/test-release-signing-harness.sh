#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repo_root"
harness=Scripts/test-release-signing.sh

if grep -F '/usr/bin/open' "$harness" >/dev/null; then
    echo "release signing smoke harness still delegates launch to open" >&2
    exit 1
fi
grep -F 'app_executable' "$harness" >/dev/null
grep -F 'smoke_pid=$!' "$harness" >/dev/null
grep -F 'wait "$smoke_pid"' "$harness" >/dev/null
test "$(grep -c '^run_smoke_test ' "$harness")" -eq 2

echo "release signing harness contract PASS"
