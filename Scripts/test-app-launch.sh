#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"
source "$repository_root/Scripts/app-build-defaults.sh"
source "$repository_root/Scripts/launch-process-support.sh"

bash "$repository_root/Scripts/build-app.sh"
app_path="$repository_root/.build/MacChannel.app"
app_executable="$app_path/Contents/MacOS/MacChannelApp"
if [[ "${MACCHANNEL_LAUNCH_TESTING:-0}" == "1" ]]; then
    app_executable="${MACCHANNEL_LAUNCH_TEST_EXECUTABLE:-}"
    if [[ ! -n "$app_executable" || ! -x "$app_executable" ]]; then
        echo "MACCHANNEL_LAUNCH_TEST_EXECUTABLE must name an executable test fixture" >&2
        exit 1
    fi
fi
expected_version="${MACCHANNEL_EXPECTED_VERSION:-$macchannel_default_version}"
expected_build_number="${MACCHANNEL_EXPECTED_BUILD_NUMBER:-$macchannel_default_build_number}"
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
    if [[ -n "$opener_pid" ]]; then
        launch_terminate_process_tree "$opener_pid" 20 || true
        opener_pid=""
    fi
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
    "$repository_root/App/SettingsView.swift" "$repository_root/App/PairingView.swift"; then
    echo "旧的网络配置仍然出现在普通用户界面" >&2
    exit 1
fi

"$app_executable" \
    -SUEnableAutomaticChecks NO \
    --smoke-test "$marker_path" &
opener_pid=$!

launch_wait_for_marker "$marker_path" "$opener_pid" 300

test -f "$marker_path"
grep -qx "ready accessory" "$marker_path"
launch_require_process_exit "$opener_pid" 150
opener_pid=""
! pgrep -f "$app_executable" >/dev/null

env -u MACCHANNEL_RENDEZVOUS_URL -u MACCHANNEL_RUNTIME \
    "$app_executable" \
    -SUEnableAutomaticChecks NO \
    --production-launch-test "$production_marker_path" &
opener_pid=$!

launch_wait_for_marker "$production_marker_path" "$opener_pid" 150

test -f "$production_marker_path"
jq -e '
    (.runtimeStatus == "offline" or .runtimeStatus == "ready") and
    (has("connectivityMode") | not) and
    (.identityID | type == "string" and length > 0) and
    .settingsAvailable == true and
    .statusInstalled == true and
    .shutdownComplete == true
' "$production_marker_path" >/dev/null
launch_require_process_exit "$opener_pid" 150
opener_pid=""
! pgrep -f "$app_executable" >/dev/null
