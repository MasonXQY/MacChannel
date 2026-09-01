#!/usr/bin/env bash

# Shared fail-closed path validation for destructive update-test operations.
# Callers must create an owner-only root first, resolve it with pwd -P, and pass
# only direct children of that root to the mutation helpers below.

macchannel_require_canonical_test_root() {
    local root="${1:-}"
    local physical_root root_mode root_uid

    [[ -n "$root" && "$root" == /* ]] || return 1
    case "$root" in
        *//*|*/./*|*/../*|*/.|*/..) return 1 ;;
    esac
    [[ -d "$root" && ! -L "$root" ]] || return 1
    physical_root="$(cd "$root" 2>/dev/null && pwd -P)" || return 1
    [[ "$physical_root" == "$root" ]] || return 1
    case "$physical_root" in
        /|/Applications|/Applications/*|/System/Applications|/System/Applications/*) return 1 ;;
    esac
    root_mode="$(stat -f %Lp "$root" 2>/dev/null)" || return 1
    root_uid="$(stat -f %u "$root" 2>/dev/null)" || return 1
    [[ "$root_mode" == 700 && "$root_uid" == "$(id -u)" ]] || return 1
}

macchannel_require_canonical_repository_root() {
    local root="${1:-}"
    local physical_root

    [[ -n "$root" && "$root" == /* ]] || return 1
    case "$root" in
        *//*|*/./*|*/../*|*/.|*/..) return 1 ;;
    esac
    [[ -d "$root" && ! -L "$root" ]] || return 1
    physical_root="$(cd "$root" 2>/dev/null && pwd -P)" || return 1
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
