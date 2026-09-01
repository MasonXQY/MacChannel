#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
source "$repo_root/Scripts/update-test-paths.sh"
raw_root="$(mktemp -d "${TMPDIR:-/tmp}/macchannel-update-paths-contract.XXXXXX")"
chmod 700 "$raw_root"
test_root="$(cd "$raw_root" && pwd -P)"
temp_parent="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
cleanup() {
    local status=$?
    trap - EXIT
    case "$test_root" in
        "$temp_parent"/macchannel-update-paths-contract.*)
            macchannel_require_canonical_test_root "$test_root" && rm -rf "$test_root" || status=70
            ;;
        *) status=70 ;;
    esac
    exit "$status"
}
trap cleanup EXIT

expect_resolver_failure() {
    if "$@" >/dev/null 2>&1; then
        printf 'resolver unexpectedly accepted hostile path\n' >&2
        exit 1
    fi
}

checkout="$test_root/checkout"
mkdir -p "$checkout/dist"
chmod 700 "$checkout" "$checkout/dist"
printf 'formal sentinel\n' >"$checkout/dist/MacChannel.dmg"
sentinel_sha="$(shasum -a 256 "$checkout/dist/MacChannel.dmg" | awk '{print $1}')"

test "$(MACCHANNEL_UPDATE_TESTING=0 macchannel_resolve_dist_root "$checkout")" = "$checkout/dist"
expect_resolver_failure env MACCHANNEL_UPDATE_TESTING=1 \
    MACCHANNEL_UPDATE_TEST_ROOT="$checkout" \
    MACCHANNEL_UPDATE_TEST_DIST_ROOT="$checkout/dist" \
    bash -c 'source "$1"; macchannel_resolve_dist_root "$2"' _ \
    "$repo_root/Scripts/update-test-paths.sh" "$checkout"

alternate_dist="$checkout/test-dist"
mkdir "$alternate_dist"
chmod 700 "$alternate_dist"
expect_resolver_failure env MACCHANNEL_UPDATE_TESTING=1 \
    MACCHANNEL_UPDATE_TEST_ROOT="$checkout" \
    MACCHANNEL_UPDATE_TEST_DIST_ROOT="$alternate_dist" \
    bash -c 'source "$1"; macchannel_resolve_dist_root "$2"' _ \
    "$repo_root/Scripts/update-test-paths.sh" "$checkout"

alias="$test_root/checkout-alias"
ln -s "$checkout" "$alias"
expect_resolver_failure env MACCHANNEL_UPDATE_TESTING=0 \
    bash -c 'source "$1"; macchannel_resolve_dist_root "$2"' _ \
    "$repo_root/Scripts/update-test-paths.sh" "$alias"

symlink_repo="$test_root/symlink-repo"
outside="$test_root/outside"
mkdir "$symlink_repo" "$outside"
chmod 700 "$symlink_repo" "$outside"
ln -s "$outside" "$symlink_repo/dist"
expect_resolver_failure env MACCHANNEL_UPDATE_TESTING=0 \
    bash -c 'source "$1"; macchannel_resolve_dist_root "$2"' _ \
    "$repo_root/Scripts/update-test-paths.sh" "$symlink_repo"

test "$sentinel_sha" = "$(shasum -a 256 "$checkout/dist/MacChannel.dmg" | awk '{print $1}')"

expected_requirement='anchor apple generic and identifier "com.mason.macchannel" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "XKAZ67HN45"'
test "$(plutil -extract designatedRequirement raw -o - \
    "$repo_root/Distribution/ProductionSigningAnchor.plist")" = "$expected_requirement"

if rg -n '(^|[[:space:]])(mkdir -p|find)[[:space:]]+dist([/[:space:]]|$)' \
    "$repo_root/Scripts/test-distribution.sh" >/dev/null; then
    printf 'distribution fixture still references formal dist directly\n' >&2
    exit 1
fi
grep -F 'macchannel_require_isolated_test_root "$repo_root" "$update_test_root"' \
    "$repo_root/Scripts/build-app.sh" >/dev/null

printf 'update path and anchor contract PASS\n'
