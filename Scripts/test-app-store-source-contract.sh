#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repo_root"

required=(
    Scripts/app-store-build-defaults.sh
    Distribution/AppStore.entitlements
    Distribution/AppStoreSigningAnchor.plist
    Scripts/build-app-store-app.sh
    Scripts/app-store-validation.sh
    Scripts/test-app-store-bundle.sh
    Scripts/test-app-store-validation.sh
    Tests/Fixtures/app-store-profile-summary.plist
    Tests/Fixtures/app-store-development-profile-summary.plist
)
for path in "${required[@]}"; do
    test -f "$path" || { echo "missing App Store contract file: $path" >&2; exit 1; }
done

source Scripts/app-store-build-defaults.sh
test "$macchannel_app_store_default_version" = 1.3.0
test "$macchannel_app_store_default_build_number" = 1
test "$macchannel_app_store_bundle_identifier" = com.zensystech.dropmesh
test "$macchannel_app_store_executable" = DropMeshAppStore
test "$macchannel_app_store_team_identifier" = XKAZ67HN45

entitlements=Distribution/AppStore.entitlements
plutil -lint "$entitlements" >/dev/null
keys="$(/usr/libexec/PlistBuddy -c Print "$entitlements" | sed -nE 's/^    ([^ ]+) = .*/\1/p' | sort)"
expected=$'com.apple.application-identifier\ncom.apple.developer.team-identifier\ncom.apple.security.app-sandbox\ncom.apple.security.files.downloads.read-write\ncom.apple.security.files.user-selected.read-write\ncom.apple.security.network.client\ncom.apple.security.network.server\nkeychain-access-groups'
test "$keys" = "$expected" || { echo "App Store entitlement allowlist mismatch" >&2; exit 1; }
if grep -q '<key>com\.apple\.security\.temporary-exception' "$entitlements"; then
    echo "temporary exception entitlement is forbidden" >&2
    exit 1
fi
test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "$entitlements")" = XKAZ67HN45.com.zensystech.dropmesh
test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "$entitlements")" = XKAZ67HN45
test "$(/usr/libexec/PlistBuddy -c 'Print :keychain-access-groups:0' "$entitlements")" = XKAZ67HN45.com.zensystech.dropmesh
for key in com.apple.security.app-sandbox com.apple.security.network.client com.apple.security.network.server com.apple.security.files.downloads.read-write com.apple.security.files.user-selected.read-write; do
    test "$(/usr/libexec/PlistBuddy -c "Print :$key" "$entitlements")" = true
done

grep -F 'swift build -c release --product "$macchannel_app_store_executable" --arch arm64 --arch x86_64' Scripts/build-app-store-app.sh >/dev/null
grep -F 'dist-app-store/DropMesh.app' Scripts/app-store-build-defaults.sh >/dev/null
if grep -Eq 'Sparkle|SUFeedURL|SUPublicEDKey' Scripts/build-app-store-app.sh; then
    echo "Store assembly contains Direct update metadata" >&2
    exit 1
fi
grep -F 'docs/security/app-store-export-compliance.md' Scripts/build-app-store-app.sh >/dev/null
grep -F 'ITSAppUsesNonExemptEncryption' Scripts/build-app-store-app.sh >/dev/null
grep -F '_macchannel._tcp' Scripts/build-app-store-app.sh >/dev/null
grep -F 'MACCHANNEL_APP_STORE_PROFILE' Scripts/build-app-store-app.sh >/dev/null
grep -F 'MACCHANNEL_APP_STORE_SIGNING_IDENTITY' Scripts/build-app-store-app.sh >/dev/null
grep -F 'MACCHANNEL_APP_STORE_APP_ID' Scripts/build-app-store-app.sh >/dev/null
grep -F 'MACCHANNEL_APP_STORE_APP_OUTPUT' Scripts/build-app-store-app.sh >/dev/null
grep -F 'macchannel_resolve_store_identity "$identity" "$identity_listing"' Scripts/build-app-store-app.sh >/dev/null
grep -F 'macchannel_require_profile_certificate "$profile_plist" "$identity_fingerprint" "$identity"' Scripts/build-app-store-app.sh >/dev/null
grep -F 'macchannel_validate_store_output_path "$repo_root" "$app_output"' Scripts/build-app-store-app.sh >/dev/null

anchor=Distribution/AppStoreSigningAnchor.plist
plutil -lint "$anchor" >/dev/null
test "$(plutil -extract bundleIdentifier raw -o - "$anchor")" = com.zensystech.dropmesh
test "$(plutil -extract bundleExecutable raw -o - "$anchor")" = DropMeshAppStore
test "$(plutil -extract teamID raw -o - "$anchor")" = XKAZ67HN45

test "$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' Tests/Fixtures/app-store-profile-summary.plist)" = XKAZ67HN45.com.zensystech.dropmesh
test "$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:keychain-access-groups:0' Tests/Fixtures/app-store-profile-summary.plist)" = 'XKAZ67HN45.*'
if /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.security.app-sandbox' Tests/Fixtures/app-store-profile-summary.plist >/dev/null 2>&1; then
    echo "sanitized macOS profile fixture incorrectly requires signed-app sandbox entitlements" >&2
    exit 1
fi
grep -F 'verify-apple-provisioning-profile.swift' Scripts/build-app-store-app.sh >/dev/null

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/dropmesh-store-negative.XXXXXX")"
fixture_root="$(cd "$fixture_root" && pwd -P)"
trap 'rm -rf "$fixture_root"' EXIT
fixture_app="$fixture_root/DropMesh.app"
mkdir -p "$fixture_app/Contents/MacOS"
cp /bin/echo "$fixture_app/Contents/MacOS/DropMeshAppStore"
cp Tests/Fixtures/app-store-profile-summary.plist "$fixture_app/Contents/Info.plist"
touch "$fixture_app/Contents/Sparkle.framework"
set +e
bash Scripts/test-app-store-bundle.sh "$fixture_app" >"$fixture_root/result.log" 2>&1
fixture_status=$?
set -e
test "$fixture_status" -ne 0
grep -F 'forbidden Direct update material: Sparkle.framework' "$fixture_root/result.log" >/dev/null

set +e
MACCHANNEL_APP_STORE_SIGNING_IDENTITY='Apple Distribution: fixture (XKAZ67HN45)' \
MACCHANNEL_APP_STORE_PROFILE=Tests/Fixtures/app-store-profile-summary.plist \
MACCHANNEL_APP_STORE_APP_ID=123456789 \
MACCHANNEL_APP_STORE_APP_OUTPUT=dist/DropMesh.app \
bash Scripts/build-app-store-app.sh >"$fixture_root/dist.log" 2>&1
dist_status=$?
set -e
test "$dist_status" -eq 2
grep -F 'App Store output path is unsafe, existing, symlinked, or under dist/' "$fixture_root/dist.log" >/dev/null
test ! -e dist/DropMesh.app

echo "app store source contract PASS"
