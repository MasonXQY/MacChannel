#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f Scripts/normalize-store-resource-bundle.sh ]] || { echo 'resource bundle FAIL: normalizer missing'; exit 1; }
test_root="$(mktemp -d /private/tmp/store-resource-test.XXXXXX)"
trap 'rm -rf "$test_root"' EXIT
bundle="$test_root/MacChannel_MacChannelAppKit.bundle"
mkdir -p "$bundle/Contents/Resources"
cp Tests/Fixtures/store-resource-bundle.plist "$bundle/Contents/Info.plist"
cp Tests/Fixtures/store-resource-bundle.plist "$bundle/Contents/Resources/sentinel.plist"
bash Scripts/normalize-store-resource-bundle.sh "$bundle"
if plutil -extract CFBundleExecutable raw -o - "$bundle/Contents/Info.plist" >/dev/null 2>&1; then exit 1; fi
[[ "$(plutil -extract CFBundleDevelopmentRegion raw -o - "$bundle/Contents/Info.plist")" == en ]]
cmp Tests/Fixtures/store-resource-bundle.plist "$bundle/Contents/Resources/sentinel.plist"
bash Scripts/normalize-store-resource-bundle.sh "$bundle"
mkdir "$bundle/Contents/MacOS"
if bash Scripts/normalize-store-resource-bundle.sh "$bundle" >/dev/null 2>&1; then exit 1; fi
echo 'Store resource bundle contract PASS'
