#!/usr/bin/env bash

launch_process_running() {
    local process_id="$1"
    kill -0 "$process_id" 2>/dev/null || return 1
    ! ps -o stat= -p "$process_id" 2>/dev/null | rg -q '^[[:space:]]*Z'
}

launch_process_start_identity() {
    ps -o lstart= -p "$1" 2>/dev/null
}

launch_process_command_identity() {
    ps -o command= -p "$1" 2>/dev/null
}

launch_capture_process_tree() {
    local process_id="$1"
    local child_id
    local start_identity
    local command_identity
    while IFS= read -r child_id; do
        [[ -n "$child_id" ]] || continue
        launch_capture_process_tree "$child_id"
    done < <(pgrep -P "$process_id" 2>/dev/null || true)

    launch_process_running "$process_id" || return 0
    start_identity="$(launch_process_start_identity "$process_id")"
    command_identity="$(launch_process_command_identity "$process_id")"
    [[ -n "$start_identity" && -n "$command_identity" ]] || return 0
    printf '%s\t%s\t%s\n' "$process_id" "$start_identity" "$command_identity"
}

launch_snapshot_process_id() {
    printf '%s\n' "${1%%$'\t'*}"
}

launch_snapshot_matches() {
    local snapshot="$1"
    local process_id
    local expected_start
    local diagnostic_command
    IFS=$'\t' read -r process_id expected_start diagnostic_command <<< "$snapshot"
    launch_process_running "$process_id" || return 1
    [[ "$(launch_process_start_identity "$process_id")" == "$expected_start" ]]
}

launch_signal_snapshots() {
    local signal="$1"
    shift
    local snapshot
    local process_id
    for snapshot in "$@"; do
        launch_snapshot_matches "$snapshot" || continue
        process_id="$(launch_snapshot_process_id "$snapshot")"
        kill "-$signal" "$process_id" 2>/dev/null || true
    done
}

launch_wait_for_snapshots_exit() {
    local tenths="$1"
    shift
    local attempt
    local snapshot
    local still_running
    for ((attempt = 0; attempt < tenths; attempt += 1)); do
        still_running=0
        for snapshot in "$@"; do
            if launch_snapshot_matches "$snapshot"; then
                still_running=1
                break
            fi
        done
        [[ "$still_running" -eq 0 ]] && return 0
        sleep 0.1
    done
    return 124
}

launch_wait_for_marker() {
    local marker_path="$1"
    local process_id="$2"
    local tenths="$3"
    local attempt
    for ((attempt = 0; attempt < tenths; attempt += 1)); do
        [[ -f "$marker_path" ]] && return 0
        launch_process_running "$process_id" || return 1
        sleep 0.1
    done
    [[ -f "$marker_path" ]]
}

launch_wait_for_exit() {
    local process_id="$1"
    local tenths="$2"
    local attempt
    for ((attempt = 0; attempt < tenths; attempt += 1)); do
        if ! launch_process_running "$process_id"; then
            if wait "$process_id" 2>/dev/null; then
                return 0
            else
                return $?
            fi
        fi
        sleep 0.1
    done
    return 124
}

launch_reap_process() {
    local process_id="$1"
    # wait is only safe after polling established that the child exited or is a zombie.
    launch_process_running "$process_id" && return 124
    if wait "$process_id" 2>/dev/null; then
        return 0
    else
        return $?
    fi
}

launch_terminate_process_tree() {
    local process_id="$1"
    local tenths="$2"
    local snapshots=()
    local snapshot
    while IFS= read -r snapshot; do
        [[ -n "$snapshot" ]] && snapshots+=("$snapshot")
    done < <(launch_capture_process_tree "$process_id")
    ((${#snapshots[@]})) || return 0

    launch_signal_snapshots TERM "${snapshots[@]}"
    if launch_wait_for_snapshots_exit "$tenths" "${snapshots[@]}"; then
        launch_reap_process "$process_id" || true
        return 0
    fi

    launch_signal_snapshots KILL "${snapshots[@]}"
    if launch_wait_for_snapshots_exit "$tenths" "${snapshots[@]}"; then
        launch_reap_process "$process_id" || true
        return 0
    fi

    launch_reap_process "$process_id" || true
    return 1
}

launch_require_process_exit() {
    local process_id="$1"
    local tenths="$2"
    local exit_status
    if launch_wait_for_exit "$process_id" "$tenths"; then
        return 0
    else
        exit_status=$?
    fi
    [[ "$exit_status" -eq 124 ]] || return "$exit_status"
    launch_terminate_process_tree "$process_id" "$tenths" || {
        echo "launch process did not exit after TERM/KILL deadlines: $process_id" >&2
        return 1
    }
    echo "launch process exceeded completion deadline: $process_id" >&2
    return 124
}
