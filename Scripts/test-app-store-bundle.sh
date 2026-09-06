#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
source "$repo_root/Scripts/app-store-validation.sh"

app="${1:-}"
[[ -d "$app" && ! -L "$app" ]] || { echo "usage: $0 /path/to/DropMesh.app" >&2; exit 2; }
plist="$app/Contents/Info.plist"
executable="$app/Contents/MacOS/DropMeshAppStore"
[[ -f "$plist" && -f "$executable" && ! -L "$executable" ]] || { echo "incomplete App Store bundle" >&2; exit 1; }

while IFS= read -r -d '' candidate; do
    [[ -f "$candidate" && ! -L "$candidate" ]] || continue
    xml="$(plutil -convert xml1 -o - "$candidate" 2>/dev/null || true)"
    [[ -n "$xml" ]] || continue
    su_key="$(printf '%s\n' "$xml" | sed -nE 's@.*<key>(SU[^<]*)</key>.*@\1@p' | head -1)"
    if [[ -n "$su_key" ]]; then
        echo "forbidden SU metadata key: $su_key" >&2
        exit 1
    fi
done < <(find "$app" -type f -print0)

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
macchannel_validate_signed_app_entitlements "$signed_entitlements" XKAZ67HN45.com.zensystech.dropmesh XKAZ67HN45 XKAZ67HN45.com.zensystech.dropmesh || { echo "signed app entitlement allowlist mismatch" >&2; exit 1; }

archs="$(lipo -archs "$executable")"
[[ " $archs " == *' arm64 '* && " $archs " == *' x86_64 '* ]] || { echo "universal architectures are required" >&2; exit 1; }
profile_plist="$(mktemp "${TMPDIR:-/tmp}/dropmesh-profile.XXXXXX")"
trap 'rm -f "$signed_entitlements" "$profile_plist"' EXIT
xcrun swift "$repo_root/Scripts/verify-apple-provisioning-profile.swift" "$app/Contents/embedded.provisionprofile" "$profile_plist" >/dev/null 2>&1
macchannel_validate_macos_profile "$profile_plist" distribution XKAZ67HN45.com.zensystech.dropmesh XKAZ67HN45 XKAZ67HN45.com.zensystech.dropmesh

echo "app store bundle PASS"
