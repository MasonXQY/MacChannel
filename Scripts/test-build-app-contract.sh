#!/usr/bin/env bash
set -euo pipefail

test_root="$(mktemp -d "${TMPDIR:-/tmp}/macchannel-build-contract.XXXXXX")"
output_app="$test_root/output/MacChannel.app"
signing_tmp="$test_root/signing-tmp"
mkdir -p "$(dirname "$output_app")" "$signing_tmp"

cleanup() {
    rm -rf "$test_root"
}
trap cleanup EXIT

set +e
TMPDIR="$signing_tmp" \
MACCHANNEL_BUILD_CONFIGURATION=release \
MACCHANNEL_CODESIGN_IDENTITY="Developer ID Application: deliberately missing" \
MACCHANNEL_APP_OUTPUT="$output_app" \
    bash Scripts/build-app.sh >/dev/null 2>&1
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
    echo "invalid signing identity unexpectedly succeeded" >&2
    exit 1
fi

if [[ -e "$output_app" ]]; then
    echo "failed signing left a distributable-looking app" >&2
    exit 1
fi

if find "$signing_tmp" -maxdepth 1 -name 'macchannel-sign.*' -print -quit | grep -q .; then
    echo "failed signing left temporary material" >&2
    exit 1
fi

echo "build app failure contract PASS"
