#!/usr/bin/env bash
set -euo pipefail

identity="${MACCHANNEL_CODESIGN_IDENTITY:-}"
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
MACCHANNEL_APP_OUTPUT="$app_path" \
    bash Scripts/build-app.sh

codesign --verify --deep --strict --verbose=2 "$app_path"

details="$(codesign -dvvv "$app_path" 2>&1)"
grep -F "Authority=$identity" <<<"$details" >/dev/null
grep -E 'flags=.*runtime' <<<"$details" >/dev/null

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
