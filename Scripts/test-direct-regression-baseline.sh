#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 1 ]]; then
    echo "usage: $0 APP_PATH" >&2
    exit 2
fi

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
baseline="$repository_root/Distribution/DirectBaseline-v1.2.6.plist"
sparkle_public_key="$repository_root/Distribution/SparklePublicKey.txt"
app_path="$1"
plist="$app_path/Contents/Info.plist"
executable="$app_path/Contents/MacOS/MacChannelApp"
sparkle="$app_path/Contents/Frameworks/Sparkle.framework"

[[ -d "$app_path" && -f "$plist" && -x "$executable" ]]
[[ -f "$baseline" && -f "$sparkle_public_key" ]]

baseline_value() {
    plutil -extract "$1" raw -o - "$baseline"
}

require_plist_value() {
    local key="$1"
    local expected="$2"
    local actual
    actual="$(plutil -extract "$key" raw -o - "$plist")"
    if [[ "$actual" != "$expected" ]]; then
        echo "$key changed: expected $expected, got $actual" >&2
        exit 1
    fi
}

require_executable_path() {
    local path="$1"
    if [[ ! -x "$path" ]]; then
        echo "required Direct Sparkle component is missing or not executable: $path" >&2
        exit 1
    fi
}

require_plist_value CFBundleName "$(baseline_value product)"
require_plist_value CFBundleIdentifier "$(baseline_value bundleIdentifier)"
require_plist_value CFBundleExecutable "$(baseline_value bundleExecutable)"
require_plist_value CFBundleShortVersionString "$(baseline_value version)"
require_plist_value CFBundleVersion "$(baseline_value build)"
require_plist_value LSUIElement true

expected_su_keys=$'SUAllowsAutomaticUpdates\nSUAutomaticallyUpdate\nSUEnableAutomaticChecks\nSUFeedURL\nSUPublicEDKey\nSURequireSignedFeed\nSUScheduledCheckInterval\nSUVerifyUpdateBeforeExtraction'
actual_su_keys="$(plutil -convert xml1 -o - "$plist" | \
    sed -n 's|^[[:space:]]*<key>\(SU[^<]*\)</key>[[:space:]]*$|\1|p' | LC_ALL=C sort -u)"
if [[ "$actual_su_keys" != "$expected_su_keys" ]]; then
    echo "Sparkle Info.plist keys changed" >&2
    exit 1
fi

require_plist_value SUFeedURL "$(baseline_value feedURL)"
require_plist_value SUPublicEDKey "$(<"$sparkle_public_key")"
require_plist_value SUEnableAutomaticChecks true
require_plist_value SUScheduledCheckInterval 86400.000000
require_plist_value SUAutomaticallyUpdate false
require_plist_value SUAllowsAutomaticUpdates false
require_plist_value SUVerifyUpdateBeforeExtraction true
require_plist_value SURequireSignedFeed true

actual_key_hash="$(shasum -a 256 "$sparkle_public_key" | awk '{print $1}')"
if [[ "$actual_key_hash" != "$(baseline_value sparklePublicKeySHA256)" ]]; then
    echo "Sparkle public key fingerprint changed" >&2
    exit 1
fi

[[ -d "$sparkle" ]]
sparkle_version_directory="$sparkle/Versions/B"
[[ -d "$sparkle_version_directory" ]]
if [[ ! -L "$sparkle/Versions/Current" || \
    "$(readlink "$sparkle/Versions/Current")" != B ]]; then
    echo "Sparkle Current version must point to B" >&2
    exit 1
fi
require_executable_path "$sparkle_version_directory/Sparkle"
require_executable_path "$sparkle_version_directory/Autoupdate"
require_executable_path "$sparkle_version_directory/Updater.app/Contents/MacOS/Updater"
require_executable_path "$sparkle_version_directory/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
require_executable_path "$sparkle_version_directory/XPCServices/Installer.xpc/Contents/MacOS/Installer"
sparkle_linkage="$(otool -L "$executable" | rg -F '@rpath/Sparkle.framework/Versions/B/Sparkle')"
if [[ "$sparkle_linkage" != *"current version $(baseline_value sparkleVersion)"* ]]; then
    echo "Sparkle linkage version changed" >&2
    exit 1
fi

if /usr/bin/codesign -d --entitlements - "$executable" 2>&1 | \
    rg -q -F 'com.apple.security.app-sandbox'; then
    echo "Direct app unexpectedly contains an App Sandbox entitlement" >&2
    exit 1
fi

rg -a -q -F 'MacChannel' "$executable"
rg -a -q -F 'com.mason.macchannel.identity' "$executable"
if rg -a -q -F 'com.zensystech.dropmesh' "$app_path"; then
    echo "Store identity leaked into Direct bundle" >&2
    exit 1
fi

echo "direct-regression PASS version=$(baseline_value version) build=$(baseline_value build)"
