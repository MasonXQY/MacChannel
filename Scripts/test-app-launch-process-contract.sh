#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repository_root/Scripts/launch-process-support.sh"

fixture_root="$(mktemp -d -t macchannel-launch-process-contract.XXXXXX)"
cleanup() {
    rm -rf "$fixture_root"
}
trap cleanup EXIT INT TERM

assert_stopped() {
    local process_id="$1"
    local descendant_id="${2:-}"
    ! kill -0 "$process_id" 2>/dev/null
    [[ -z "$descendant_id" ]] || ! kill -0 "$descendant_id" 2>/dev/null
    ! pgrep -P "$process_id" >/dev/null 2>&1
}

run_fixture() {
    local fixture_name="$1"
    local marker="$fixture_root/$fixture_name.marker"
    local descendant_file="$fixture_root/$fixture_name.descendant"
    "fixture_$fixture_name" "$marker" "$descendant_file" &
    local process_id=$!
    launch_wait_for_marker "$marker" "$process_id" 20
    if launch_require_process_exit "$process_id" 2; then
        echo "launch fixture unexpectedly completed without bounded cleanup: $fixture_name" >&2
        exit 1
    fi
    local descendant_id=""
    [[ ! -f "$descendant_file" ]] || descendant_id="$(<"$descendant_file")"
    assert_stopped "$process_id" "$descendant_id"
}

fixture_marker-then-hang() {
    printf ready > "$1"
    trap 'exit 0' TERM
    while :; do sleep 1; done
}

fixture_term-ignoring() {
    (trap '' TERM; while :; do sleep 1; done) &
    printf '%s' "$!" > "$2"
    printf ready > "$1"
    trap '' TERM
    while :; do sleep 1; done
}

run_fixture marker-then-hang
run_fixture term-ignoring

echo "app launch bounded-process contract PASS"
