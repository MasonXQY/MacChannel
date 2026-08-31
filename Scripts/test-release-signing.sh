#!/usr/bin/env bash
set -euo pipefail

identity="${MACCHANNEL_CODESIGN_IDENTITY:-}"
version="${MACCHANNEL_VERSION:-1.1.3}"
build_number="${MACCHANNEL_BUILD_NUMBER:-5}"
if [[ -z "$identity" ]]; then
    echo "MACCHANNEL_CODESIGN_IDENTITY is required" >&2
    exit 2
fi

release_root="$(mktemp -d "${TMPDIR:-/tmp}/macchannel-release-test.XXXXXX")"
app_path="$release_root/MacChannel.app"
launch_marker="$release_root/launch.marker"
opener_pid=""

cleanup() {
    if [[ -n "$opener_pid" ]] && kill -0 "$opener_pid" 2>/dev/null; then
        kill "$opener_pid" 2>/dev/null || true
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

/usr/bin/open -n -W "$app_path" --args --smoke-test "$launch_marker" &
opener_pid=$!
for _ in {1..100}; do
    [[ -f "$launch_marker" ]] && break
    sleep 0.1
done
test -f "$launch_marker"
grep -qx "ready accessory" "$launch_marker"
wait "$opener_pid"
opener_pid=""

echo "release signing PASS"
