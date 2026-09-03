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

run_guarded_fixture() {
    local fixture_name="$1"
    local marker="$fixture_root/$fixture_name.marker"
    local descendant_file="$fixture_root/$fixture_name.descendant"
    local watchdog_marker="$fixture_root/$fixture_name.watchdog"
    "fixture_$fixture_name" "$marker" "$descendant_file" &
    local process_id=$!
    launch_wait_for_marker "$marker" "$process_id" 20
    (
        sleep 3
        printf timeout > "$watchdog_marker"
        kill -KILL "$process_id" 2>/dev/null || true
        if [[ -f "$descendant_file" ]]; then
            kill -KILL "$(<"$descendant_file")" 2>/dev/null || true
        fi
    ) &
    local watchdog_id=$!
    if launch_require_process_exit "$process_id" 2; then
        echo "launch fixture unexpectedly completed without bounded cleanup: $fixture_name" >&2
        exit 1
    fi
    if kill -0 "$watchdog_id" 2>/dev/null; then
        kill -TERM "$watchdog_id" 2>/dev/null || true
    fi
    if launch_wait_for_exit "$watchdog_id" 20; then
        :
    else
        watchdog_status=$?
        [[ "$watchdog_status" -ne 124 ]] || {
            echo "launch cleanup watchdog did not exit within its deadline: $fixture_name" >&2
            exit 1
        }
    fi
    [[ ! -f "$watchdog_marker" ]] || {
        echo "launch cleanup exceeded its bounded deadline: $fixture_name" >&2
        exit 1
    }
    local descendant_id=""
    [[ ! -f "$descendant_file" ]] || descendant_id="$(<"$descendant_file")"
    assert_stopped "$process_id" "$descendant_id"
}

wait_for_file() {
    local file_path="$1"
    local tenths="$2"
    local attempt
    for ((attempt = 0; attempt < tenths; attempt += 1)); do
        [[ -f "$file_path" ]] && return 0
        sleep 0.1
    done
    [[ -f "$file_path" ]]
}

snapshot_for_process() {
    local process_id="$1"
    shift
    local snapshot
    for snapshot in "$@"; do
        [[ "$(launch_snapshot_process_id "$snapshot")" == "$process_id" ]] && {
            printf '%s\n' "$snapshot"
            return 0
        }
    done
    return 1
}

run_exec_identity_fixture() {
    local fixture_name="$1"
    local marker="$fixture_root/$fixture_name.marker"
    local descendant_file="$fixture_root/$fixture_name.descendant"
    "fixture_$fixture_name" "$marker" "$descendant_file" &
    local process_id=$!
    launch_wait_for_marker "$marker" "$process_id" 20
    local snapshots=()
    local snapshot
    while IFS= read -r snapshot; do
        [[ -n "$snapshot" ]] && snapshots+=("$snapshot")
    done < <(launch_capture_process_tree "$process_id")
    local root_snapshot
    root_snapshot="$(snapshot_for_process "$process_id" "${snapshots[@]}")"
    launch_signal_snapshots TERM "${snapshots[@]}"
    if [[ "$fixture_name" == root-execs-term-ignoring ]]; then
        wait_for_file "$marker.exec" 20
    fi
    if ! launch_snapshot_matches "$root_snapshot"; then
        echo "exec changed the root command but not its process identity: $fixture_name" >&2
        exit 1
    fi
    local descendant_id=""
    if [[ -f "$descendant_file" ]]; then
        descendant_id="$(<"$descendant_file")"
        [[ "$fixture_name" == descendant-execs-term-ignoring ]] && \
            wait_for_file "$marker.descendant-exec" 20
        local descendant_snapshot
        descendant_snapshot="$(snapshot_for_process "$descendant_id" "${snapshots[@]}")"
        if ! launch_snapshot_matches "$descendant_snapshot"; then
            echo "exec changed the descendant command but not its process identity: $fixture_name" >&2
            exit 1
        fi
    fi
    launch_signal_snapshots KILL "${snapshots[@]}"
    launch_wait_for_snapshots_exit 20 "${snapshots[@]}"
    launch_reap_process "$process_id" || true
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

exec_term_ignoring_perl() {
    printf exec > "$1"
    exec /usr/bin/perl -e '$SIG{TERM} = "IGNORE"; while (1) { sleep 1; }'
}

fixture_root-execs-term-ignoring() {
    printf ready > "$1"
    trap '' TERM
    sleep 1
    exec_term_ignoring_perl "$1.exec"
}

fixture_descendant-execs-term-ignoring() {
    (
        trap '' TERM
        printf ready > "$2.ready"
        sleep 1
        exec_term_ignoring_perl "$1.descendant-exec"
    ) &
    local descendant_id=$!
    while [[ ! -f "$2.ready" ]]; do sleep 0.01; done
    printf '%s' "$descendant_id" > "$2"
    printf ready > "$1"
    trap '' TERM
    while :; do sleep 1; done
}

run_fixture marker-then-hang
run_fixture term-ignoring
run_fixture root-exits-term-descendant-ignores
run_guarded_fixture root-execs-term-ignoring
run_fixture descendant-execs-term-ignoring
run_exec_identity_fixture root-execs-term-ignoring
run_exec_identity_fixture descendant-execs-term-ignoring
run_nonzero_exit_fixture

echo "app launch bounded-process contract PASS"
