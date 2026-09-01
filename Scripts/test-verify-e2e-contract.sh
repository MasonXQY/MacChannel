#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
source "$repo_root/Scripts/update-test-paths.sh"
test_root="$(macchannel_create_test_root macchannel-verify-e2e-contract)"
temp_parent="$(macchannel_trusted_user_temp_parent)"
cleanup() {
    local status=$?
    trap - EXIT
    case "$test_root" in
        "$temp_parent"/macchannel-verify-e2e-contract.*)
            macchannel_require_canonical_test_root "$test_root" && rm -rf "$test_root" || status=70
            ;;
        *) status=70 ;;
    esac
    exit "$status"
}
trap cleanup EXIT

mkdir -p "$test_root/bin"
cat >"$test_root/bin/swift" <<'SHIM'
#!/bin/bash
printf 'direct-lan PASS\n'
SHIM
cat >"$test_root/bin/bash" <<'SHIM'
#!/bin/bash
if [[ "${1:-}" == Scripts/test-update-acceptance.sh ]]; then
    if [[ -n "${MACCHANNEL_UPDATE_TEST_STATIC_ONLY+x}" ]]; then
        printf 'verify-e2e fixture failure ambient-static-only-leaked\n' >&2
        exit 61
    fi
    case "${VERIFY_E2E_SHIM_MODE:?}" in
        full)
            printf 'update-acceptance full-matrix-complete cases=17\n'
            ;;
        missing)
            printf 'update acceptance static PASS\n'
            ;;
        duplicate)
            printf 'update-acceptance full-matrix-complete cases=17\n'
            printf 'update-acceptance full-matrix-complete cases=17\n'
            ;;
        *) exit 64 ;;
    esac
    exit 0
fi
exec /bin/bash "$@"
SHIM
chmod 700 "$test_root/bin/swift" "$test_root/bin/bash"

run_verify() {
    local mode=$1
    env -i PATH="$test_root/bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$test_root" \
        TMPDIR="$test_root/" LANG=C LC_ALL=C VERIFY_E2E_SHIM_MODE="$mode" \
        MACCHANNEL_UPDATE_TEST_STATIC_ONLY=1 \
        /bin/bash "$repo_root/Scripts/verify-e2e.sh" --local-only
}

set +e
run_verify full >"$test_root/full.log" 2>&1
full_status=$?
set -e
if [[ "$full_status" -ne 0 ]]; then
    sed -n '1,120p' "$test_root/full.log" >&2
    exit "$full_status"
fi
test "$(grep -Fxc 'update-acceptance full-matrix-complete cases=17' "$test_root/full.log")" = 1

for mode in missing duplicate; do
    set +e
    run_verify "$mode" >"$test_root/$mode.log" 2>&1
    status=$?
    set -e
    [[ "$status" -ne 0 ]]
done

printf 'verify-e2e contract PASS\n'
