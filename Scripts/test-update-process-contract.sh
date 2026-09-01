#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
source "$repo_root/Scripts/update-test-paths.sh"
runner="$repo_root/Tests/Fixtures/run-bounded-process.py"
fixture="$repo_root/Tests/Fixtures/update-acceptance-hang.py"
group_cleanup="$repo_root/Tests/Fixtures/process-group-cleanup.sh"
raw_root="$(mktemp -d "${TMPDIR:-/tmp}/macchannel-process-contract.XXXXXX")"
chmod 700 "$raw_root"
test_root="$(cd "$raw_root" && pwd -P)"
temp_parent="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
marker="LeaderExitChild${RANDOM}$$"
ready="$test_root/child.ready"
cleanup() {
    local status=$?
    trap - EXIT
    pkill -f "$marker" >/dev/null 2>&1 || true
    case "$test_root" in
        "$temp_parent"/macchannel-process-contract.*)
            macchannel_require_canonical_test_root "$test_root" && rm -rf "$test_root" || status=70
            ;;
        *) status=70 ;;
    esac
    exit "$status"
}
trap cleanup EXIT

/usr/bin/python3 "$runner" --timeout 2 --log "$test_root/leader-exit.log" \
    env -i PATH="$PATH" HOME="$test_root" TMPDIR="$test_root/" \
    /usr/bin/python3 "$fixture" --leader-exits "$marker" "$ready"
test -f "$ready"
sleep 0.1
if pgrep -f "$marker" >/dev/null 2>&1; then
    printf 'bounded process left leader-exit descendant alive\n' >&2
    exit 1
fi

printf 'bounded process contract PASS\n'

if [[ ! -f "$group_cleanup" ]]; then
    printf 'missing process-group cleanup helper\n' >&2
    exit 1
fi
source "$group_cleanup"
server_marker="ServerGroupChild${RANDOM}$$"
server_ready="$test_root/server.ready"
env -i PATH="$PATH" HOME="$test_root" TMPDIR="$test_root/" \
    /usr/bin/python3 "$fixture" --group-server "$server_ready" "$server_marker" &
server_pid=$!
for _ in {1..100}; do
    [[ -f "$server_ready" ]] && break
    kill -0 "$server_pid" 2>/dev/null || break
    sleep 0.02
done
test -f "$server_ready"
macchannel_stop_process_group "$server_pid" "$server_pid"
if pgrep -f "$server_marker" >/dev/null 2>&1; then
    printf 'server process-group cleanup left a descendant alive\n' >&2
    exit 1
fi
printf 'server process-group contract PASS\n'
