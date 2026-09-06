#!/usr/bin/env bash
set -euo pipefail

app="${1:-}"
[[ -d "$app" && ! -L "$app" ]] || { echo "usage: $0 /path/to/DropMesh.app" >&2; exit 2; }
plist="$app/Contents/Info.plist"
executable="$app/Contents/MacOS/DropMeshAppStore"
[[ -f "$plist" && -f "$executable" && ! -L "$executable" ]] || { echo "incomplete App Store bundle" >&2; exit 1; }

for forbidden in Sparkle.framework Downloader.xpc Installer.xpc Updater.app Autoupdate SUFeedURL SUPublicEDKey SUEnableAutomaticChecks appcast.xml SparklePublicKey github.com/MasonXQY/MacChannel/releases/latest/download; do
    if find "$app" -name "*$forbidden*" -print -quit | grep -q . || /usr/bin/grep -R -a -F -q "$forbidden" "$app" 2>/dev/null; then
        echo "forbidden Direct update material: $forbidden" >&2
        exit 1
    fi
done
if otool -L "$executable" | grep -Fq Sparkle; then
    echo "App Store executable links Sparkle" >&2
    exit 1
fi

test "$(plutil -extract CFBundleIdentifier raw -o - "$plist")" = com.zensystech.dropmesh
test "$(plutil -extract CFBundleExecutable raw -o - "$plist")" = DropMeshAppStore
test "$(plutil -extract LSUIElement raw -o - "$plist")" = true
test "$(plutil -extract NSBonjourServices.0 raw -o - "$plist")" = _macchannel._tcp
test "$(plutil -extract DropMeshDistributionChannel raw -o - "$plist")" = app-store
test -d "$app/Contents/Resources/en.lproj"
test -d "$app/Contents/Resources/zh-Hans.lproj"
test -s "$app/Contents/Resources/PrivacyInfo.xcprivacy"
test -s "$app/Contents/embedded.provisionprofile"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"
/usr/bin/codesign --verify --strict --verbose=2 "$executable"
/usr/bin/codesign -R='identifier "com.zensystech.dropmesh" and anchor apple generic and certificate leaf[subject.OU] = "XKAZ67HN45"' --verify "$app"
signed_entitlements="$(mktemp "${TMPDIR:-/tmp}/dropmesh-entitlements.XXXXXX")"
trap 'rm -f "$signed_entitlements"' EXIT
/usr/bin/codesign -d --entitlements :- "$app" >"$signed_entitlements" 2>/dev/null
for key in com.apple.security.app-sandbox com.apple.security.network.client com.apple.security.network.server com.apple.security.files.downloads.read-write com.apple.security.files.user-selected.read-write; do
    test "$(/usr/libexec/PlistBuddy -c "Print :$key" "$signed_entitlements")" = true
done
test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "$signed_entitlements")" = XKAZ67HN45.com.zensystech.dropmesh
test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "$signed_entitlements")" = XKAZ67HN45
test "$(/usr/libexec/PlistBuddy -c 'Print :keychain-access-groups:0' "$signed_entitlements")" = XKAZ67HN45.com.zensystech.dropmesh
if grep -q '<key>com\.apple\.security\.temporary-exception' "$signed_entitlements"; then
    echo "signed app contains a temporary exception entitlement" >&2; exit 1
fi

archs="$(lipo -archs "$executable")"
[[ " $archs " == *' arm64 '* && " $archs " == *' x86_64 '* ]] || { echo "universal architectures are required" >&2; exit 1; }
profile_plist="$(mktemp "${TMPDIR:-/tmp}/dropmesh-profile.XXXXXX")"
trap 'rm -f "$signed_entitlements" "$profile_plist"' EXIT
security cms -D -i "$app/Contents/embedded.provisionprofile" >"$profile_plist" 2>/dev/null
test "$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$profile_plist")" = XKAZ67HN45.com.zensystech.dropmesh
expiry="$(plutil -extract ExpirationDate raw -o - "$profile_plist")"
expiry_epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$expiry" '+%s')"
test "$expiry_epoch" -gt "$(date -u +%s)"

echo "app store bundle PASS"
