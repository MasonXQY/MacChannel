#!/usr/bin/env bash

launch_process_running() {
    local process_id="$1"
    kill -0 "$process_id" 2>/dev/null || return 1
    ! ps -o stat= -p "$process_id" 2>/dev/null | rg -q '^[[:space:]]*Z'
}

launch_process_tree() {
    local process_id="$1"
    local child_id
    while IFS= read -r child_id; do
        [[ -n "$child_id" ]] || continue
        launch_process_tree "$child_id"
    done < <(pgrep -P "$process_id" 2>/dev/null || true)
    printf '%s\n' "$process_id"
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
        launch_process_running "$process_id" || {
            wait "$process_id" 2>/dev/null || true
            return 0
        }
        sleep 0.1
    done
    return 1
}

launch_terminate_process_tree() {
    local process_id="$1"
    local tenths="$2"
    local process_ids=()
    local candidate
    while IFS= read -r candidate; do process_ids+=("$candidate"); done < <(
        launch_process_tree "$process_id"
    )
    ((${#process_ids[@]})) || return 0
    kill -TERM "${process_ids[@]}" 2>/dev/null || true
    launch_wait_for_exit "$process_id" "$tenths" && return 0

    process_ids=()
    while IFS= read -r candidate; do process_ids+=("$candidate"); done < <(
        launch_process_tree "$process_id"
    )
    ((${#process_ids[@]})) || return 0
    kill -KILL "${process_ids[@]}" 2>/dev/null || true
    launch_wait_for_exit "$process_id" "$tenths"
}

launch_require_process_exit() {
    local process_id="$1"
    local tenths="$2"
    launch_wait_for_exit "$process_id" "$tenths" && return 0
    launch_terminate_process_tree "$process_id" "$tenths" || {
        echo "launch process did not exit after TERM/KILL deadlines: $process_id" >&2
        return 1
    }
    echo "launch process exceeded completion deadline: $process_id" >&2
    return 1
}
