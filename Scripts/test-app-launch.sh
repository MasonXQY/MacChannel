#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repository_root/Scripts/app-build-defaults.sh"

bash Scripts/build-app.sh
app_path="$(pwd)/.build/MacChannel.app"
app_executable="$app_path/Contents/MacOS/MacChannelApp"
expected_version="${MACCHANNEL_EXPECTED_VERSION:-${MACCHANNEL_VERSION:-$macchannel_default_version}}"
expected_build_number="${MACCHANNEL_EXPECTED_BUILD_NUMBER:-${MACCHANNEL_BUILD_NUMBER:-$macchannel_default_build_number}}"
if pgrep -f "$app_executable" >/dev/null; then
    echo "MacChannelApp is already running; refusing an ambiguous launch test" >&2
    exit 1
fi

smoke_launch_dir="$(mktemp -d -t macchannel-launch.XXXXXX)"
marker_path="$smoke_launch_dir/launch.marker"
production_launch_dir="$(mktemp -d -t macchannel-production-launch.XXXXXX)"
production_marker_path="$production_launch_dir/production.json"
opener_pid=""

cleanup() {
    if [[ -n "$opener_pid" ]] && kill -0 "$opener_pid" 2>/dev/null; then
        kill "$opener_pid" 2>/dev/null || true
    fi
    pkill -TERM -f "$app_executable" 2>/dev/null || true
    rm -f "$marker_path"
    rmdir "$smoke_launch_dir" 2>/dev/null || true
    rm -f "$production_marker_path"
    rmdir "$production_launch_dir" 2>/dev/null || true
}
trap cleanup EXIT

plist="$app_path/Contents/Info.plist"
sparkle="$app_path/Contents/Frameworks/Sparkle.framework"
test -d "$sparkle"
test -x "$sparkle/Versions/Current/Sparkle"
test "$(plutil -extract LSUIElement raw -o - "$plist")" = "true"
test "$(plutil -extract CFBundlePackageType raw -o - "$plist")" = "APPL"
test "$(plutil -extract CFBundleShortVersionString raw -o - "$plist")" = "$expected_version"
test "$(plutil -extract CFBundleVersion raw -o - "$plist")" = "$expected_build_number"
test -n "$(plutil -extract NSDownloadsFolderUsageDescription raw -o - "$plist")"
test "$(plutil -extract SUFeedURL raw -o - "$plist")" = \
    "https://github.com/MasonXQY/MacChannel/releases/latest/download/appcast.xml"
test "$(plutil -extract SUEnableAutomaticChecks raw -o - "$plist")" = true
test "$(plutil -extract SUScheduledCheckInterval raw -o - "$plist")" = 86400.000000
test "$(plutil -extract SUAutomaticallyUpdate raw -o - "$plist")" = false
test "$(plutil -extract SUAllowsAutomaticUpdates raw -o - "$plist")" = false
test "$(plutil -extract SUVerifyUpdateBeforeExtraction raw -o - "$plist")" = true
test "$(plutil -extract SURequireSignedFeed raw -o - "$plist")" = true
test -n "$(plutil -extract SUPublicEDKey raw -o - "$plist")"

if rg -n 'Tailscale|个人网络|连接方式|安全中继地址|rendezvousURL' \
    App/SettingsView.swift App/PairingView.swift; then
    echo "旧的网络配置仍然出现在普通用户界面" >&2
    exit 1
fi

"$app_executable" \
    -SUEnableAutomaticChecks NO \
    --smoke-test "$marker_path" &
opener_pid=$!

# Startup also initializes the packaged update controller; allow the same bounded
# launch window as the production-runtime smoke below.
for _ in {1..150}; do
    [[ -f "$marker_path" ]] && break
    sleep 0.1
done

test -f "$marker_path"
grep -qx "ready accessory" "$marker_path"
wait "$opener_pid"
opener_pid=""
! pgrep -f "$app_executable" >/dev/null

env -u MACCHANNEL_RENDEZVOUS_URL -u MACCHANNEL_RUNTIME \
    "$app_executable" \
    -SUEnableAutomaticChecks NO \
    --production-launch-test "$production_marker_path" &
opener_pid=$!

for _ in {1..150}; do
    [[ -f "$production_marker_path" ]] && break
    sleep 0.1
done

test -f "$production_marker_path"
jq -e '
    (.runtimeStatus == "offline" or .runtimeStatus == "ready") and
    (has("connectivityMode") | not) and
    (.identityID | type == "string" and length > 0) and
    .settingsAvailable == true and
    .statusInstalled == true and
    .shutdownComplete == true
' "$production_marker_path" >/dev/null
wait "$opener_pid"
opener_pid=""
! pgrep -f "$app_executable" >/dev/null
