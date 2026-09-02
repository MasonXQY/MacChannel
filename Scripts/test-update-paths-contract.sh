#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
source "$repo_root/Scripts/update-test-paths.sh"
test_root="$(macchannel_create_test_root macchannel-update-paths-contract)"
trusted_parent="$(macchannel_trusted_user_temp_parent)"
repo_attack=""
ambient_root=""
invalid_prefix_root=""
cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n "$repo_attack" && -e "$repo_attack" ]]; then
        case "$repo_attack" in
            "$repo_root"/macchannel-repo-attack.*)
                if [[ ! -L "$repo_attack" &&
                    "$(cd "$(dirname "$repo_attack")" && pwd -P)" == "$repo_root" ]]; then
                    /bin/rmdir "$repo_attack"
                else
                    status=70
                fi
                ;;
            *) status=70 ;;
        esac
    fi
    if [[ -n "$ambient_root" && -e "$ambient_root" ]]; then
        if macchannel_require_canonical_test_root "$ambient_root"; then
            rm -rf "$ambient_root"
        else
            status=70
        fi
    fi
    if [[ -n "$invalid_prefix_root" && -e "$invalid_prefix_root" ]]; then
        case "$invalid_prefix_root" in
            "$trusted_parent"/not-macchannel.*)
                [[ ! -L "$invalid_prefix_root" ]] && /bin/rmdir "$invalid_prefix_root" || status=70
                ;;
            *) status=70 ;;
        esac
    fi
    case "$test_root" in
        "$trusted_parent"/macchannel-update-paths-contract.*)
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

root_attack_failures=0
expect_isolated_root_rejection() {
    local label="$1"
    local repository="$2"
    local candidate="$3"
    if macchannel_require_isolated_test_root "$repository" "$candidate"; then
        printf 'trusted-root contract accepted %s\n' "$label" >&2
        root_attack_failures=$((root_attack_failures + 1))
    fi
}

checkout="$test_root/checkout"
mkdir -p "$checkout/dist"
chmod 700 "$checkout" "$checkout/dist"
printf 'formal sentinel\n' >"$checkout/dist/MacChannel.dmg"
sentinel_sha="$(shasum -a 256 "$checkout/dist/MacChannel.dmg" | awk '{print $1}')"

# A test root must never be accepted merely because it is canonical, owner-only,
# and isolated from the exact repository root or exact formal dist path.
repo_attack="$(mktemp -d "$repo_root/macchannel-repo-attack.XXXXXX")"
chmod 700 "$repo_attack"
expect_isolated_root_rejection 'repository descendant' "$repo_root" "$repo_attack"

mode700_checkout="$test_root/mode700-checkout"
mode700_checkout_child="$mode700_checkout/macchannel-checkout-child.attack"
mkdir -p "$mode700_checkout_child"
chmod 700 "$mode700_checkout" "$mode700_checkout_child"
expect_isolated_root_rejection 'mode-700 checkout descendant' \
    "$mode700_checkout" "$mode700_checkout_child"

dist_nested="$checkout/dist/nested/macchannel-dist-attack.ABC123"
mkdir -p "$dist_nested"
chmod 700 "$checkout/dist/nested" "$dist_nested"
expect_isolated_root_rejection 'repository dist descendant' "$checkout" "$dist_nested"

home_like="$test_root/simulated-home/Documents/macchannel-home-attack.ABC123"
mkdir -p "$home_like"
chmod 700 "$test_root/simulated-home" "$test_root/simulated-home/Documents" "$home_like"
expect_isolated_root_rejection 'home-like Documents descendant' "$checkout" "$home_like"

if ! declare -F macchannel_create_test_root >/dev/null; then
    printf 'trusted-root contract is missing ambient-independent root creation\n' >&2
    root_attack_failures=$((root_attack_failures + 1))
fi

ambient_root="$(TMPDIR="$repo_root" \
    macchannel_create_test_root macchannel-update-paths-ambient)"
[[ "${ambient_root%/*}" == "$trusted_parent" ]]
case "$ambient_root/" in
    "$repo_root/"*)
        printf 'ambient TMPDIR redirected the test root into the repository\n' >&2
        root_attack_failures=$((root_attack_failures + 1))
        ;;
esac

trusted_parent_alias="$test_root/trusted-parent-alias"
ln -s "$trusted_parent" "$trusted_parent_alias"
if macchannel_require_canonical_test_root \
    "$trusted_parent_alias/${ambient_root##*/}"; then
    printf 'trusted-root contract accepted a symlink alias\n' >&2
    root_attack_failures=$((root_attack_failures + 1))
fi

if macchannel_require_canonical_test_root /Users/mason/Documents; then
    printf 'trusted-root contract accepted a Documents root\n' >&2
    root_attack_failures=$((root_attack_failures + 1))
fi

invalid_prefix_root="$(/usr/bin/mktemp -d "$trusted_parent/not-macchannel.XXXXXX")"
/bin/chmod 700 "$invalid_prefix_root"
if macchannel_require_canonical_test_root "$invalid_prefix_root"; then
    printf 'trusted-root contract accepted an invalid prefix\n' >&2
    root_attack_failures=$((root_attack_failures + 1))
fi
/bin/rmdir "$invalid_prefix_root"
invalid_prefix_root=""

if macchannel_create_test_root '../macchannel-traversal' >/dev/null 2>&1; then
    printf 'trusted-root creator accepted a traversal prefix\n' >&2
    root_attack_failures=$((root_attack_failures + 1))
fi

if [[ "$root_attack_failures" -ne 0 ]]; then
    exit 1
fi

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

expected_requirement='identifier "com.mason.macchannel" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = XKAZ67HN45'
test "$(plutil -extract designatedRequirement raw -o - \
    "$repo_root/Distribution/ProductionSigningAnchor.plist")" = "$expected_requirement"

if rg -n '(^|[[:space:]])(mkdir -p|find)[[:space:]]+dist([/[:space:]]|$)' \
    "$repo_root/Scripts/test-distribution.sh" >/dev/null; then
    printf 'distribution fixture still references formal dist directly\n' >&2
    exit 1
fi
grep -F 'macchannel_require_isolated_test_root "$repo_root" "$update_test_root"' \
    "$repo_root/Scripts/build-app.sh" >/dev/null

for fixture_script in \
    test-build-app-contract.sh \
    test-distribution.sh \
    test-update-acceptance.sh \
    test-update-acceptance-static-contract.sh \
    test-update-feed.sh \
    test-update-process-contract.sh \
    test-update-tls-contract.sh \
    test-verify-e2e-contract.sh; do
    grep -F 'macchannel_create_test_root macchannel-' \
        "$repo_root/Scripts/$fixture_script" >/dev/null
done

printf 'update path and anchor contract PASS\n'
