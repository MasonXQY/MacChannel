#!/usr/bin/env bash
set -euo pipefail

bash Scripts/build-app.sh
app_executable="$(pwd)/.build/MacChannel.app/Contents/MacOS/MacChannelApp"
if pgrep -f -x "$app_executable" >/dev/null; then
    echo "MacChannelApp is already running; refusing an ambiguous launch test" >&2
    exit 1
fi

marker_path="$(mktemp -t macchannel-launch.XXXXXX)"
production_launch_dir="$(mktemp -d -t macchannel-production-launch.XXXXXX)"
personal_marker_path="$production_launch_dir/personal.json"
public_marker_path="$production_launch_dir/public.json"
rm -f "$marker_path"
opener_pid=""

cleanup() {
    if [[ -n "$opener_pid" ]] && kill -0 "$opener_pid" 2>/dev/null; then
        kill "$opener_pid" 2>/dev/null || true
    fi
    pkill -TERM -f -x "$app_executable" 2>/dev/null || true
    rm -f "$marker_path"
    rm -f "$personal_marker_path" "$public_marker_path"
    rmdir "$production_launch_dir" 2>/dev/null || true
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
! pgrep -f -x "$app_executable" >/dev/null

env -u MACCHANNEL_RENDEZVOUS_URL -u MACCHANNEL_RUNTIME \
    MACCHANNEL_LAUNCH_TEST_CONNECTIVITY_MODE=personalMesh \
    /usr/bin/open -n -W .build/MacChannel.app --args --production-launch-test "$personal_marker_path" &
opener_pid=$!

for _ in {1..150}; do
    [[ -f "$personal_marker_path" ]] && break
    sleep 0.1
done

test -f "$personal_marker_path"
jq -e '
    (.runtimeStatus == "offline" or .runtimeStatus == "ready") and
    .connectivityMode == "personalMesh" and
    (.identityID | type == "string" and length > 0) and
    .settingsAvailable == true and
    .statusInstalled == true and
    .shutdownComplete == true
' "$personal_marker_path" >/dev/null
wait "$opener_pid"
opener_pid=""
! pgrep -f -x "$app_executable" >/dev/null

env -u MACCHANNEL_RENDEZVOUS_URL -u MACCHANNEL_RUNTIME \
    MACCHANNEL_LAUNCH_TEST_CONNECTIVITY_MODE=publicService \
    /usr/bin/open -n -W .build/MacChannel.app --args --production-launch-test "$public_marker_path" &
opener_pid=$!

for _ in {1..200}; do
    [[ -f "$public_marker_path" ]] && break
    sleep 0.1
done

test -f "$public_marker_path"
jq -e '
    (.runtimeStatus == "offline" or .runtimeStatus == "ready") and
    .connectivityMode == "publicService" and
    (.identityID | type == "string" and length > 0) and
    .settingsAvailable == true and
    .statusInstalled == true and
    .shutdownComplete == true
' "$public_marker_path" >/dev/null
wait "$opener_pid"
opener_pid=""
! pgrep -f -x "$app_executable" >/dev/null
