#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repo_root"
source Scripts/app-store-build-defaults.sh
source Scripts/app-store-validation.sh
source Scripts/app-store-export-fragment.sh

build_mode=release
case "$#:${1:-}" in
    0:) ;;
    1:--review-candidate) build_mode=review-candidate ;;
    *) echo 'usage: build-app-store-app.sh [--review-candidate]' >&2; exit 2 ;;
esac

identity="${MACCHANNEL_APP_STORE_SIGNING_IDENTITY:-}"
profile="${MACCHANNEL_APP_STORE_PROFILE:-}"
store_id="${MACCHANNEL_APP_STORE_APP_ID:-}"
app_output="${MACCHANNEL_APP_STORE_APP_OUTPUT:-}"
app_version="${MACCHANNEL_APP_STORE_VERSION:-$macchannel_app_store_default_version}"
build_number="${MACCHANNEL_APP_STORE_BUILD_NUMBER:-$macchannel_app_store_default_build_number}"
export_record="$repo_root/docs/security/app-store-export-compliance.md"
entitlements="$repo_root/Distribution/AppStore.entitlements"

fail() { echo "$*" >&2; exit 2; }
[[ -n "$identity" ]] || fail "MACCHANNEL_APP_STORE_SIGNING_IDENTITY is required"
[[ -f "$profile" && ! -L "$profile" ]] || fail "MACCHANNEL_APP_STORE_PROFILE must be a regular provisioning profile"
[[ "$store_id" =~ ^[1-9][0-9]*$ ]] || fail "MACCHANNEL_APP_STORE_APP_ID must be the numeric App Store Connect ID"
[[ -n "$app_output" ]] || fail "MACCHANNEL_APP_STORE_APP_OUTPUT is required"
[[ "$app_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail "MACCHANNEL_APP_STORE_VERSION must be release SemVer"
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || fail "MACCHANNEL_APP_STORE_BUILD_NUMBER must be a positive integer"

output_abs="$(macchannel_validate_store_output_path "$repo_root" "$app_output")" || fail "App Store output path is unsafe, existing, symlinked, or under dist/"
output_parent="$(dirname "$output_abs")"
mkdir -p "$output_parent"
[[ "$(macchannel_validate_store_output_path "$repo_root" "$output_abs")" == "$output_abs" ]] || fail "App Store output ancestry changed during preparation"

# ITSAppUsesNonExemptEncryption is omitted for an explicitly marked review candidate.
export_fragment="$(macchannel_store_export_fragment "$build_mode" "$export_record")" || fail "export-compliance record is not approved or has no supported encryption decision"
source_commit="$(git rev-parse HEAD)"
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || fail "Store candidate requires a clean committed worktree"

work_root="$(bash "$repo_root/Scripts/create-store-staging.sh")"
chmod 700 "$work_root"
cleanup() { rm -rf "$work_root"; }
trap cleanup EXIT
profile_plist="$work_root/profile.plist"
xcrun swift "$repo_root/Scripts/verify-apple-provisioning-profile.swift" "$profile" "$profile_plist" >/dev/null 2>&1 || fail "provisioning profile CMS signature or Apple signer trust is invalid"
plutil -lint "$profile_plist" >/dev/null || fail "provisioning profile payload is invalid"

profile_name="$(plutil -extract Name raw -o - "$profile_plist" 2>/dev/null || true)"
[[ "$profile_name" != *Mi2* ]] || fail "Mi2 provisioning profiles are forbidden"
macchannel_validate_macos_profile "$profile_plist" distribution "$macchannel_app_store_application_identifier" "$macchannel_app_store_team_identifier" "$macchannel_app_store_keychain_group" || fail "profile is not an exact, unexpired macOS App Store distribution profile for DropMesh"

identity_listing="$work_root/identities.txt"
security find-identity -v -p codesigning >"$identity_listing" 2>/dev/null || fail "unable to query signing identities"
macchannel_resolve_store_identity "$identity" "$identity_listing" || fail "exactly one approved Store application identity for Team XKAZ67HN45 is required"
identity_fingerprint="$macchannel_resolved_store_identity_fingerprint"
macchannel_require_profile_certificate "$profile_plist" "$identity_fingerprint" "$identity" || fail "selected Store signing certificate is not included in the provisioning profile or has inconsistent certificate identity"

HOME_VALUE="${HOME:?}"
TMP_VALUE="${TMPDIR:-/tmp}"
clean_tool() { env -i PATH="$PATH" HOME="$HOME_VALUE" TMPDIR="$TMP_VALUE" LANG=C LC_ALL=C "$@"; }
clean_tool swift build -c release --product "$macchannel_app_store_executable" --arch arm64 --arch x86_64
product_path="$(clean_tool swift build -c release --product "$macchannel_app_store_executable" --arch arm64 --arch x86_64 --show-bin-path)"

app="$work_root/DropMesh.app"
contents="$app/Contents"
mkdir -p "$contents/MacOS" "$contents/Frameworks" "$contents/Resources/en.lproj" "$contents/Resources/zh-Hans.lproj"
cp -X "$product_path/$macchannel_app_store_executable" "$contents/MacOS/$macchannel_app_store_executable"
bash "$repo_root/Scripts/fix-store-rpath.sh" "$contents/MacOS/$macchannel_app_store_executable"
cp -X -R "$product_path/WebRTC.framework" "$contents/Frameworks/WebRTC.framework"
cp -X -R "$product_path/MacChannel_MacChannelAppKit.bundle" "$contents/Resources/MacChannel_MacChannelAppKit.bundle"
bash "$repo_root/Scripts/normalize-store-resource-bundle.sh" "$contents/Resources/MacChannel_MacChannelAppKit.bundle"
clean_tool xcrun swift "$repo_root/Scripts/package-app-store-icon.swift" \
    "$repo_root/Distribution/AppStoreBrand/app-icon-1024.png" \
    "$contents/Resources/DropMesh.icns"
[[ -s "$repo_root/App/Resources/PrivacyInfo.xcprivacy" ]] || fail "app-level privacy manifest is required"
cp -X "$repo_root/App/Resources/PrivacyInfo.xcprivacy" "$contents/Resources/PrivacyInfo.xcprivacy"
cp -X "$profile" "$contents/embedded.provisionprofile"

cat >"$contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$macchannel_app_store_executable</string>
<key>CFBundleIdentifier</key><string>$macchannel_app_store_bundle_identifier</string>
<key>CFBundleName</key><string>DropMesh</string><key>CFBundleDisplayName</key><string>DropMesh</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
<key>CFBundlePackageType</key><string>APPL</string><key>CFBundleIconFile</key><string>DropMesh</string>
<key>CFBundleShortVersionString</key><string>$app_version</string><key>CFBundleVersion</key><string>$build_number</string>
<key>LSMinimumSystemVersion</key><string>14.0</string><key>LSUIElement</key><true/>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSBonjourServices</key><array><string>_macchannel._tcp</string></array>
<key>NSLocalNetworkUsageDescription</key><string>Find paired Macs nearby and transfer files securely over your local network.</string>
<key>NSDownloadsFolderUsageDescription</key><string>Save files received from your paired Macs to Downloads.</string>
<key>NSDocumentsFolderUsageDescription</key><string>Save received files to a folder you choose.</string>
<key>DropMeshDistributionChannel</key><string>app-store</string>
<key>DropMeshAppStoreID</key><string>$store_id</string>
<key>DropMeshPrivacyURL</key><string>https://masonxqy.github.io/MacChannel/privacy/</string>
<key>DropMeshSupportURL</key><string>https://masonxqy.github.io/MacChannel/support/</string>
$export_fragment
<key>DropMeshSourceCommit</key><string>$source_commit</string>
</dict></plist>
PLIST
plutil -lint "$contents/Info.plist" >/dev/null

for localization in en zh-Hans; do
    cp -X "$repo_root/App/Resources/$localization.lproj/InfoPlist.strings" \
        "$contents/Resources/$localization.lproj/InfoPlist.strings"
done
plutil -lint "$contents/Resources/en.lproj/InfoPlist.strings" "$contents/Resources/zh-Hans.lproj/InfoPlist.strings" >/dev/null

xattr -cr "$app"
sign=(--force --sign "$identity" --timestamp)
/usr/bin/codesign "${sign[@]}" "$contents/Frameworks/WebRTC.framework"
/usr/bin/codesign "${sign[@]}" --entitlements "$entitlements" "$contents/MacOS/$macchannel_app_store_executable"
/usr/bin/codesign "${sign[@]}" --entitlements "$entitlements" "$app"
bash "$repo_root/Scripts/test-app-store-bundle.sh" "$app"
[[ "$(macchannel_validate_store_output_path "$repo_root" "$output_abs")" == "$output_abs" ]] || fail "App Store output ancestry changed before publication"
mv "$app" "$output_abs"
trap - EXIT
rm -rf "$work_root"
echo "App Store app assembled ($build_mode; not installed or uploaded): $output_abs"
