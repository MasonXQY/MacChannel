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
    if kill -0 "$process_id" 2>/dev/null; then
        echo "launch root remains after bounded cleanup: $process_id" >&2
        return 1
    fi
    if [[ -n "$descendant_id" ]] && kill -0 "$descendant_id" 2>/dev/null; then
        echo "launch descendant remains after bounded cleanup: $descendant_id" >&2
        return 1
    fi
    if pgrep -P "$process_id" >/dev/null 2>&1; then
        echo "launch root retains descendants after bounded cleanup: $process_id" >&2
        return 1
    fi
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

run_nonzero_exit_fixture() {
    local marker="$fixture_root/marker-then-crash.marker"
    fixture_marker-then-crash "$marker" &
    local process_id=$!
    launch_wait_for_marker "$marker" "$process_id" 20
    local exit_status=0
    if launch_wait_for_exit "$process_id" 20; then
        echo "launch fixture unexpectedly succeeded after crashing" >&2
        exit 1
    else
        exit_status=$?
    fi
    [[ "$exit_status" -eq 37 ]] || {
        echo "launch fixture exit status was not preserved: $exit_status" >&2
        exit 1
    }
    assert_stopped "$process_id"
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

fixture_root-exits-term-descendant-ignores() {
    /usr/bin/perl -e '
        $SIG{TERM} = "IGNORE";
        $SIG{HUP} = "IGNORE";
        open my $ready, ">", $ARGV[0] or die $!;
        print {$ready} "ready";
        close $ready;
        while (1) { sleep 1; }
    ' "$2.ready" &
    local descendant_id=$!
    while [[ ! -f "$2.ready" ]]; do sleep 0.01; done
    printf '%s' "$descendant_id" > "$2"
    printf ready > "$1"
    trap 'exit 0' TERM
    while :; do sleep 1; done
}

fixture_marker-then-crash() {
    printf ready > "$1"
    return 37
}

run_fixture marker-then-hang
run_fixture term-ignoring
run_fixture root-exits-term-descendant-ignores
run_nonzero_exit_fixture

echo "app launch bounded-process contract PASS"
