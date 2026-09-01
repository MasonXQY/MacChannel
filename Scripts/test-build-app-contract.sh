#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repo_root"
source Scripts/update-test-paths.sh
test_root="$(macchannel_create_test_root macchannel-build-contract)"
macchannel_require_canonical_test_root "$test_root"
output_app="$test_root/output/MacChannel.app"
signing_tmp="$test_root/signing-tmp"
mkdir -p "$(dirname "$output_app")" "$signing_tmp" "$test_root/home"

cleanup() {
    if macchannel_require_canonical_test_root "$test_root"; then
        rm -rf "$test_root"
    else
        echo "refusing cleanup of a non-canonical build-contract root" >&2
        return 1
    fi
}
trap cleanup EXIT

for override_name in \
    MACCHANNEL_UPDATE_TEST_BUNDLE_ID \
    MACCHANNEL_UPDATE_TEST_FEED_URL \
    MACCHANNEL_UPDATE_TEST_PUBLIC_KEY_PATH \
    MACCHANNEL_UPDATE_TEST_CODESIGN_KEYCHAIN \
    MACCHANNEL_UPDATE_TEST_EMBED_HARNESS \
    MACCHANNEL_UPDATE_TEST_SIGNER_VARIANT \
    MACCHANNEL_UPDATE_TEST_ROOT \
    MACCHANNEL_UPDATE_TEST_DIST_ROOT; do
    guarded_output="$test_root/$override_name/MacChannel.app"
    set +e
    env -i PATH="$PATH" HOME="$test_root/home" TMPDIR="$test_root/" \
        MACCHANNEL_UPDATE_TESTING=0 "$override_name=hostile-override" \
        MACCHANNEL_APP_OUTPUT="$guarded_output" \
        bash Scripts/build-app.sh >"$test_root/$override_name.log" 2>&1
    override_status=$?
    set -e
    [[ "$override_status" -eq 2 ]]
    grep -Fx 'update test overrides require MACCHANNEL_UPDATE_TESTING=1' \
        "$test_root/$override_name.log" >/dev/null
    [[ ! -e "$guarded_output" && ! -L "$guarded_output" ]]
done

set +e
env -i PATH="$PATH" HOME="$test_root/home" TMPDIR="$signing_tmp" \
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
