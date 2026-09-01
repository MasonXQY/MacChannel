#!/usr/bin/env bash

# Shared fail-closed path validation for destructive update-test operations.
# Test roots are created only as unique direct children of the macOS user temp
# directory returned by an ambient-independent getconf invocation.

macchannel_trusted_user_temp_parent() {
    local reported_parent physical_parent parent_mode parent_uid source=getconf

    if ! reported_parent="$(/usr/bin/env -i \
        PATH=/usr/bin:/bin:/usr/sbin:/sbin LANG=C LC_ALL=C \
        /usr/bin/getconf DARWIN_USER_TEMP_DIR 2>/dev/null)"; then
        reported_parent=/private/tmp
        source=fallback
    fi
    reported_parent="${reported_parent%/}"
    [[ -n "$reported_parent" && "$reported_parent" == /* ]] || return 1
    case "$reported_parent" in
        *$'\n'*|*//*|*/./*|*/../*|*/.|*/..) return 1 ;;
    esac
    [[ -d "$reported_parent" && ! -L "$reported_parent" ]] || return 1
    physical_parent="$(cd "$reported_parent" 2>/dev/null && /bin/pwd -P)" || return 1
    [[ -n "$physical_parent" && "$physical_parent" != / && ! -L "$physical_parent" ]] || return 1
    parent_mode="$(/usr/bin/stat -f %Lp "$physical_parent" 2>/dev/null)" || return 1
    parent_uid="$(/usr/bin/stat -f %u "$physical_parent" 2>/dev/null)" || return 1
    if [[ "$source" == getconf ]]; then
        [[ "$parent_mode" == 700 && "$parent_uid" == "$(/usr/bin/id -u)" ]] || return 1
    else
        [[ "$physical_parent" == /private/tmp && "$parent_mode" == 1777 && "$parent_uid" == 0 ]] || return 1
    fi
    printf '%s\n' "$physical_parent"
}

macchannel_create_test_root() {
    local prefix="${1:-}"
    local trusted_parent created_root

    [[ "$prefix" =~ ^macchannel-[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || return 1
    trusted_parent="$(macchannel_trusted_user_temp_parent)" || return 1
    created_root="$(umask 077; /usr/bin/mktemp -d "$trusted_parent/$prefix.XXXXXX")" || return 1
    if ! /bin/chmod 700 "$created_root" || ! macchannel_require_canonical_test_root "$created_root"; then
        /bin/rmdir "$created_root" 2>/dev/null || true
        return 1
    fi
    printf '%s\n' "$created_root"
}

macchannel_require_canonical_test_root() {
    local root="${1:-}"
    local physical_root root_mode root_uid trusted_parent root_parent root_name

    [[ -n "$root" && "$root" == /* ]] || return 1
    case "$root" in
        *//*|*/./*|*/../*|*/.|*/..) return 1 ;;
    esac
    [[ -d "$root" && ! -L "$root" ]] || return 1
    physical_root="$(cd "$root" 2>/dev/null && /bin/pwd -P)" || return 1
    [[ "$physical_root" == "$root" ]] || return 1
    case "$physical_root" in
        /|/Applications|/Applications/*|/System/Applications|/System/Applications/*) return 1 ;;
    esac
    root_mode="$(/usr/bin/stat -f %Lp "$root" 2>/dev/null)" || return 1
    root_uid="$(/usr/bin/stat -f %u "$root" 2>/dev/null)" || return 1
    [[ "$root_mode" == 700 && "$root_uid" == "$(/usr/bin/id -u)" ]] || return 1
    trusted_parent="$(macchannel_trusted_user_temp_parent)" || return 1
    root_parent="${root%/*}"
    root_name="${root##*/}"
    [[ "$root_parent" == "$trusted_parent" ]] || return 1
    [[ "$root_name" =~ ^macchannel-[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[A-Za-z0-9]{6}$ ]] || return 1
}

macchannel_require_canonical_repository_root() {
    local root="${1:-}"
    local physical_root

    [[ -n "$root" && "$root" == /* ]] || return 1
    case "$root" in
        *//*|*/./*|*/../*|*/.|*/..) return 1 ;;
    esac
    [[ -d "$root" && ! -L "$root" ]] || return 1
    physical_root="$(cd "$root" 2>/dev/null && /bin/pwd -P)" || return 1
    [[ "$physical_root" == "$root" ]] || return 1
    case "$physical_root" in
        /|/Applications|/Applications/*|/System/Applications|/System/Applications/*) return 1 ;;
    esac
}

macchannel_require_isolated_test_root() {
    local repo_root="${1:-}"
    local test_root="${2:-}"

    macchannel_require_canonical_repository_root "$repo_root" || return 1
    macchannel_require_canonical_test_root "$test_root" || return 1
    [[ "$test_root" != "$repo_root" && "$test_root" != "$repo_root/dist" ]] || return 1
    case "$test_root/" in
        "$repo_root/"*) return 1 ;;
    esac
}

macchannel_require_direct_child_path() {
    local root="${1:-}"
    local path="${2:-}"
    local basename_required="${3:-}"

    macchannel_require_canonical_test_root "$root" || return 1
    [[ -n "$basename_required" && "$basename_required" != */* ]] || return 1
    [[ "$path" == "$root/$basename_required" ]] || return 1
    [[ ! -L "$path" ]] || return 1
    if [[ -e "$path" ]]; then
        [[ "$(cd "$(dirname "$path")" 2>/dev/null && pwd -P)/$(basename "$path")" == "$path" ]] || return 1
    fi
}

macchannel_require_contained_regular_file() {
    local root="${1:-}"
    local path="${2:-}"
    local parent physical_parent

    macchannel_require_canonical_test_root "$root" || return 1
    [[ -n "$path" && "$path" == "$root/"* ]] || return 1
    case "$path" in
        *//*|*/./*|*/../*|*/.|*/..) return 1 ;;
    esac
    [[ -f "$path" && ! -L "$path" ]] || return 1
    parent="$(dirname "$path")"
    physical_parent="$(cd "$parent" 2>/dev/null && pwd -P)" || return 1
    [[ "$physical_parent" == "$parent" ]] || return 1
    [[ "$(stat -f %u "$path" 2>/dev/null)" == "$(id -u)" ]] || return 1
}

macchannel_resolve_dist_root() {
    local repo_root="$1"
    local testing="${MACCHANNEL_UPDATE_TESTING:-0}"
    local requested_root="${MACCHANNEL_UPDATE_TEST_ROOT:-}"
    local requested_dist="${MACCHANNEL_UPDATE_TEST_DIST_ROOT:-}"

    local production_dist="$repo_root/dist"

    macchannel_require_canonical_repository_root "$repo_root" || return 1
    if [[ "$testing" == 1 ]]; then
        macchannel_require_isolated_test_root "$repo_root" "$requested_root" || return 1
        [[ "$requested_dist" != "$production_dist" ]] || return 1
        macchannel_require_direct_child_path "$requested_root" "$requested_dist" dist || return 1
        printf '%s\n' "$requested_dist"
        return 0
    fi
    [[ -z "$requested_root" && -z "$requested_dist" ]] || return 1
    [[ ! -L "$production_dist" ]] || return 1
    if [[ -e "$production_dist" ]]; then
        [[ -d "$production_dist" ]] || return 1
        [[ "$(cd "$production_dist" 2>/dev/null && pwd -P)" == "$production_dist" ]] || return 1
    fi
    printf '%s\n' "$production_dist"
}
