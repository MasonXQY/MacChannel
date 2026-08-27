#!/usr/bin/env bash
set -euo pipefail

bash Scripts/build-app.sh

marker_path="$(mktemp -t macchannel-launch.XXXXXX)"
rm -f "$marker_path"
opener_pid=""

cleanup() {
    if [[ -n "$opener_pid" ]] && kill -0 "$opener_pid" 2>/dev/null; then
        kill "$opener_pid" 2>/dev/null || true
    fi
    rm -f "$marker_path"
}
trap cleanup EXIT

test "$(plutil -extract LSUIElement raw .build/MacChannel.app/Contents/Info.plist)" = "true"

/usr/bin/open -n -W .build/MacChannel.app --args --smoke-test "$marker_path" &
opener_pid=$!

for _ in {1..50}; do
    [[ -f "$marker_path" ]] && break
    sleep 0.1
done

test -f "$marker_path"
grep -qx "ready accessory" "$marker_path"
wait "$opener_pid"
opener_pid=""
