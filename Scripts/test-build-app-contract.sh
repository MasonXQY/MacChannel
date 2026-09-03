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

# Acceptance builds must use the trusted root itself and the one allowed direct
# child output. A nested directory may archive a completed app, but it can never
# become MACCHANNEL_UPDATE_TEST_ROOT.
acceptance_output="$test_root/MacChannel.app"
macchannel_require_isolated_test_root "$repo_root" "$test_root"
macchannel_require_direct_child_path "$test_root" "$acceptance_output" MacChannel.app
nested_test_root="$test_root/build-nested"
mkdir "$nested_test_root"
chmod 700 "$nested_test_root"
if macchannel_require_isolated_test_root "$repo_root" "$nested_test_root"; then
    echo "nested acceptance test root unexpectedly passed validation" >&2
    exit 1
fi

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

env -i PATH="$PATH" HOME="$test_root/home" TMPDIR="$signing_tmp" \
    MACCHANNEL_BUILD_CONFIGURATION=debug \
    MACCHANNEL_APP_OUTPUT="$output_app" \
    bash Scripts/build-app.sh

plist="$output_app/Contents/Info.plist"
bundle_executable="$(plutil -extract CFBundleExecutable raw -o - "$plist")"
if [[ "$bundle_executable" != MacChannelApp ]]; then
    echo "CFBundleExecutable changed: expected MacChannelApp, got $bundle_executable" >&2
    exit 1
fi
bundle_identifier="$(plutil -extract CFBundleIdentifier raw -o - "$plist")"
if [[ "$bundle_identifier" != com.mason.macchannel ]]; then
    echo "CFBundleIdentifier changed: expected com.mason.macchannel, got $bundle_identifier" >&2
    exit 1
fi
test "$(plutil -extract CFBundleName raw -o - "$plist")" = DropMesh
test "$(plutil -extract CFBundleDisplayName raw -o - "$plist")" = MacChannel
test "$(plutil -extract LSHasLocalizedDisplayName raw -o - "$plist")" = true
test "$(plutil -extract CFBundleIconFile raw -o - "$plist")" = DropMesh
test "$(plutil -extract CFBundleShortVersionString raw -o - "$plist")" = 1.2.3
test "$(plutil -extract CFBundleVersion raw -o - "$plist")" = 16
test -s "$output_app/Contents/Resources/DropMesh.icns"
localized_info="$output_app/Contents/Resources/en.lproj/InfoPlist.strings"
test -f "$localized_info" && test ! -L "$localized_info"
test "$(plutil -extract CFBundleDisplayName raw -o - "$localized_info")" = DropMesh
test "$(plutil -extract CFBundleName raw -o - "$localized_info")" = DropMesh
test "$(basename "$output_app")" = MacChannel.app
display_probe="$test_root/display-probe/MacChannel.app"
mkdir -p "$(dirname "$display_probe")"
ditto "$output_app" "$display_probe"
plutil -replace CFBundleIdentifier \
    -string "com.mason.macchannel.display-probe.$(basename "$test_root")" \
    "$display_probe/Contents/Info.plist"
display_name="$(/usr/bin/swift -e 'import Foundation; print(FileManager.default.displayName(atPath: CommandLine.arguments[1]))' "$display_probe")"
test "$display_name" = DropMesh

iconset="$test_root/DropMesh.iconset"
iconutil -c iconset "$output_app/Contents/Resources/DropMesh.icns" -o "$iconset"
for required in \
    icon_16x16.png \
    icon_16x16@2x.png \
    icon_128x128.png \
    icon_128x128@2x.png \
    icon_256x256.png \
    icon_256x256@2x.png \
    icon_512x512.png \
    icon_512x512@2x.png; do
    test -s "$iconset/$required"
done

if rg -n -i 'paperplane|#?(0088cc|229ed9)|telegram blue' \
    Scripts/build-app.sh Scripts/generate-dropmesh-icon.swift; then
    echo "DropMesh icon source contains a forbidden paper-plane or Telegram-blue design" >&2
    exit 1
fi
if rg -n 'generate-dropmesh-icon\.swift.*(\|\|[[:space:]]*true|2>/dev/null)|if .*generate-dropmesh-icon\.swift' \
    Scripts/build-app.sh; then
    echo "DropMesh icon integration contains a fallback path" >&2
    exit 1
fi
grep -F 'clean_build_tool xcrun swift \' Scripts/build-app.sh >/dev/null
grep -F '"$repo_root/Scripts/generate-dropmesh-icon.swift" \' Scripts/build-app.sh >/dev/null
grep -F 'if [[ ! -s "$dropmesh_icon_path" ]]; then' Scripts/build-app.sh >/dev/null

echo "build app contract PASS"
