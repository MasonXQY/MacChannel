#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
source "$repo_root/Scripts/update-test-paths.sh"
raw_root="$(mktemp -d "${TMPDIR:-/tmp}/macchannel-tls-contract.XXXXXX")"
chmod 700 "$raw_root"
test_root="$(cd "$raw_root" && pwd -P)"
temp_parent="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
cleanup() {
    local status=$?
    trap - EXIT
    case "$test_root" in
        "$temp_parent"/macchannel-tls-contract.*)
            macchannel_require_canonical_test_root "$test_root" && rm -rf "$test_root" || status=70
            ;;
        *) status=70 ;;
    esac
    exit "$status"
}
trap cleanup EXIT

xcrun clang -fobjc-arc -fmodules -framework Foundation -framework Security \
    "$repo_root/Tests/Fixtures/UpdateAcceptanceTLSProtocol.m" \
    "$repo_root/Tests/Fixtures/UpdateAcceptanceTLSProtocolContract.m" \
    -o "$test_root/tls-contract"
env -i PATH="$PATH" HOME="$test_root" TMPDIR="$test_root/" \
    "$test_root/tls-contract"
