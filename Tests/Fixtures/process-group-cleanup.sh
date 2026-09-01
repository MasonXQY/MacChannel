#!/usr/bin/env bash

macchannel_process_group_alive() {
    local process_group=${1:-}
    [[ "$process_group" =~ ^[1-9][0-9]*$ ]] || return 2
    kill -0 "-$process_group" 2>/dev/null
}

macchannel_stop_process_group() {
    local process_group=${1:-}
    local leader_pid=${2:-}
    local attempts=${3:-40}
    local wait_status=0

    [[ "$process_group" =~ ^[1-9][0-9]*$ && "$leader_pid" =~ ^[1-9][0-9]*$ && \
        "$attempts" =~ ^[1-9][0-9]*$ ]] || return 2
    if macchannel_process_group_alive "$process_group"; then
        kill -TERM "-$process_group" 2>/dev/null || true
        for ((index = 0; index < attempts; index++)); do
            macchannel_process_group_alive "$process_group" || break
            sleep 0.05
        done
    fi
    if macchannel_process_group_alive "$process_group"; then
        kill -KILL "-$process_group" 2>/dev/null || true
        for ((index = 0; index < attempts; index++)); do
            macchannel_process_group_alive "$process_group" || break
            sleep 0.05
        done
    fi
    macchannel_process_group_alive "$process_group" && return 70

    # The bounded group checks above prove wait cannot block on a live leader.
    set +e
    wait "$leader_pid" 2>/dev/null
    wait_status=$?
    set -e
    MACCHANNEL_PROCESS_GROUP_WAIT_STATUS=$wait_status
    return 0
}
