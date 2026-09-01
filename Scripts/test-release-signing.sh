#!/usr/bin/env bash
set -euo pipefail

identity="${MACCHANNEL_CODESIGN_IDENTITY:-}"
version="${MACCHANNEL_VERSION:-1.2.0}"
build_number="${MACCHANNEL_BUILD_NUMBER:-13}"
if [[ -z "$identity" ]]; then
    echo "MACCHANNEL_CODESIGN_IDENTITY is required" >&2
    exit 2
fi

release_root="$(mktemp -d "${TMPDIR:-/tmp}/macchannel-release-test.XXXXXX")"
app_path="$release_root/MacChannel.app"
app_executable="$app_path/Contents/MacOS/MacChannelApp"
smoke_pid=""

cleanup() {
    if [[ -n "$smoke_pid" ]]; then
        if kill -0 "$smoke_pid" 2>/dev/null; then
            kill -TERM "$smoke_pid" 2>/dev/null || true
            for _ in {1..20}; do
                kill -0 "$smoke_pid" 2>/dev/null || break
                sleep 0.1
            done
            kill -KILL "$smoke_pid" 2>/dev/null || true
        fi
        wait "$smoke_pid" 2>/dev/null || true
    fi
    rm -rf "$release_root"
}
trap cleanup EXIT

MACCHANNEL_BUILD_CONFIGURATION=release \
MACCHANNEL_CODESIGN_IDENTITY="$identity" \
MACCHANNEL_VERSION="$version" \
MACCHANNEL_BUILD_NUMBER="$build_number" \
MACCHANNEL_APP_OUTPUT="$app_path" \
    bash Scripts/build-app.sh

codesign --verify --deep --strict --verbose=2 "$app_path"

sparkle="$app_path/Contents/Frameworks/Sparkle.framework"
plist="$app_path/Contents/Info.plist"
test -d "$sparkle"
test -x "$sparkle/Versions/Current/Sparkle"
test "$(plutil -extract SUFeedURL raw -o - "$plist")" = \
    "https://github.com/MasonXQY/MacChannel/releases/latest/download/appcast.xml"
test "$(plutil -extract SUEnableAutomaticChecks raw -o - "$plist")" = true
test "$(plutil -extract SUScheduledCheckInterval raw -o - "$plist")" = 86400.000000
test "$(plutil -extract SUAutomaticallyUpdate raw -o - "$plist")" = false
test "$(plutil -extract SUAllowsAutomaticUpdates raw -o - "$plist")" = false
test "$(plutil -extract SUVerifyUpdateBeforeExtraction raw -o - "$plist")" = true
test "$(plutil -extract SURequireSignedFeed raw -o - "$plist")" = true
test -n "$(plutil -extract SUPublicEDKey raw -o - "$plist")"

details="$(codesign -dvvv "$app_path" 2>&1)"
grep -F "Authority=$identity" <<<"$details" >/dev/null
grep -E 'flags=.*runtime' <<<"$details" >/dev/null
team_id="$(sed -E 's/^.*\(([A-Z0-9]{10})\)$/\1/' <<<"$identity")"
grep -F "TeamIdentifier=$team_id" <<<"$details" >/dev/null
test "$(plutil -extract CFBundleShortVersionString raw -o - "$app_path/Contents/Info.plist")" = \
    "$version"
test "$(plutil -extract CFBundleVersion raw -o - "$app_path/Contents/Info.plist")" = \
    "$build_number"

app_architectures="$(lipo -archs "$app_path/Contents/MacOS/MacChannelApp")"
for required_architecture in arm64 x86_64; do
    if [[ " $app_architectures " != *" $required_architecture "* ]]; then
        echo "signed app is missing required architecture: $required_architecture" >&2
        exit 1
    fi
done

if find "$app_path" -name CodeResources -o -name _CodeSignature | grep -q .; then
    :
else
    echo "signed bundle has no sealed resource metadata" >&2
    exit 1
fi

run_smoke_test() {
    local run_number="$1"
    local runtime_root
    runtime_root="$(mktemp -d "$release_root/smoke-$run_number.XXXXXX")"
    local launch_marker="$runtime_root/launch.marker"
    mkdir -p "$runtime_root/tmp"
    chmod 700 "$runtime_root" "$runtime_root/tmp"

    TMPDIR="$runtime_root/tmp" \
    MACCHANNEL_SIGNING_SMOKE_RUN="$run_number" \
        "$app_executable" --smoke-test "$launch_marker" &
    smoke_pid=$!
    for _ in {1..150}; do
        [[ -f "$launch_marker" ]] && break
        kill -0 "$smoke_pid" 2>/dev/null || break
        sleep 0.1
    done
    test -f "$launch_marker"
    grep -qx "ready accessory" "$launch_marker"
    wait "$smoke_pid"
    smoke_pid=""
    ! pgrep -f "$app_executable --smoke-test $runtime_root" >/dev/null
}

run_smoke_test 1
run_smoke_test 2

echo "release signing PASS"
