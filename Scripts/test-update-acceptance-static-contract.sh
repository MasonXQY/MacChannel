#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repo_root"
source Scripts/update-test-paths.sh

signing_home="${HOME:?}"
[[ "$signing_home" == /* && -d "$signing_home" && ! -L "$signing_home" ]]
contract_root="$(macchannel_create_test_root macchannel-update-acceptance-static-contract)"
log="$contract_root/static-acceptance.log"

cleanup() {
    local exit_code=$?
    trap - EXIT
    if macchannel_require_canonical_test_root "$contract_root"; then
        rm -rf "$contract_root"
    else
        exit_code=70
    fi
    exit "$exit_code"
}
trap cleanup EXIT

set +e
env -i PATH="$PATH" HOME="$signing_home" TMPDIR="$contract_root/" LANG=C LC_ALL=C \
    MACCHANNEL_UPDATE_TEST_STATIC_ONLY=1 \
    bash Scripts/test-update-acceptance.sh >"$log" 2>&1
acceptance_status=$?
set -e
if [[ "$acceptance_status" -ne 0 ]]; then
    sed -n '1,160p' "$log" >&2
    exit "$acceptance_status"
fi

test "$(grep -Fxc 'update-acceptance static-fixtures-complete count=4' "$log")" = 1
grep -Fx 'update-acceptance static signing PASS' "$log" >/dev/null
printf 'update acceptance static contract PASS\n'
