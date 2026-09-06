#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repo_root"
source Scripts/app-store-build-defaults.sh

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
[[ "$identity" != *"Developer ID Application"* ]] || fail "Developer ID identities cannot sign the App Store bundle"
[[ -f "$profile" && ! -L "$profile" ]] || fail "MACCHANNEL_APP_STORE_PROFILE must be a regular provisioning profile"
[[ "$store_id" =~ ^[1-9][0-9]*$ ]] || fail "MACCHANNEL_APP_STORE_APP_ID must be the numeric App Store Connect ID"
[[ -n "$app_output" && "$app_output" == */DropMesh.app ]] || fail "MACCHANNEL_APP_STORE_APP_OUTPUT must end in DropMesh.app"
[[ "$app_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail "MACCHANNEL_APP_STORE_VERSION must be release SemVer"
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || fail "MACCHANNEL_APP_STORE_BUILD_NUMBER must be a positive integer"

case "$app_output" in
    /*) output_abs="$app_output" ;;
    *) output_abs="$repo_root/$app_output" ;;
esac
case "$output_abs" in
    "$repo_root/dist/"*) fail "App Store output must not be written under dist/" ;;
esac
[[ ! -e "$output_abs" && ! -L "$output_abs" ]] || fail "refusing to replace an existing App Store output"
output_parent="$(dirname "$output_abs")"
mkdir -p "$output_parent"
[[ ! -L "$output_parent" ]] || fail "App Store output parent must not be a symlink"

[[ -f "$export_record" && ! -L "$export_record" ]] || fail "approved export-compliance record is required: docs/security/app-store-export-compliance.md"
grep -Eiq '^Status:[[:space:]]*approved[[:space:]]*$' "$export_record" || fail "export-compliance record is not approved"
encryption_value="$(sed -nE 's/^Decision:[[:space:]]*ITSAppUsesNonExemptEncryption[[:space:]]*=[[:space:]]*(true|false)[[:space:]]*$/\1/p' "$export_record")"
[[ "$encryption_value" == true || "$encryption_value" == false ]] || fail "export-compliance record has no supported encryption decision"

work_root="$(mktemp -d "$output_parent/.dropmesh-store.XXXXXX")"
chmod 700 "$work_root"
cleanup() { rm -rf "$work_root"; }
trap cleanup EXIT
profile_plist="$work_root/profile.plist"
security cms -D -i "$profile" >"$profile_plist" 2>/dev/null || fail "provisioning profile is not a valid signed CMS profile"
plutil -lint "$profile_plist" >/dev/null || fail "provisioning profile payload is invalid"

profile_name="$(plutil -extract Name raw -o - "$profile_plist" 2>/dev/null || true)"
[[ "$profile_name" != *Mi2* ]] || fail "Mi2 provisioning profiles are forbidden"
profile_app_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$profile_plist" 2>/dev/null || true)"
[[ "$profile_app_id" == "$macchannel_app_store_application_identifier" ]] || fail "profile application identifier mismatch or wildcard profile"
[[ "$profile_app_id" != *'*'* ]] || fail "wildcard provisioning profiles are forbidden"
[[ "$(plutil -extract TeamIdentifier.0 raw -o - "$profile_plist" 2>/dev/null || true)" == "$macchannel_app_store_team_identifier" ]] || fail "profile Team ID mismatch"
profile_expiry="$(plutil -extract ExpirationDate raw -o - "$profile_plist" 2>/dev/null || true)"
expiry_epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$profile_expiry" '+%s' 2>/dev/null || true)"
[[ "$expiry_epoch" =~ ^[0-9]+$ && "$expiry_epoch" -gt "$(date -u +%s)" ]] || fail "provisioning profile is expired or has an invalid expiration"

for key in com.apple.security.app-sandbox com.apple.security.network.client com.apple.security.network.server com.apple.security.files.downloads.read-write com.apple.security.files.user-selected.read-write; do
    [[ "$(/usr/libexec/PlistBuddy -c "Print :Entitlements:$key" "$profile_plist" 2>/dev/null || true)" == "$(/usr/libexec/PlistBuddy -c "Print :$key" "$entitlements")" ]] || fail "profile entitlement mismatch: $key"
done
[[ "$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' "$profile_plist" 2>/dev/null || true)" == "$macchannel_app_store_team_identifier" ]] || fail "profile team entitlement mismatch"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:keychain-access-groups:0' "$profile_plist" 2>/dev/null || true)" == "$macchannel_app_store_keychain_group" ]] || fail "profile keychain group mismatch"
if plutil -convert xml1 -o - "$profile_plist" | grep -q '<key>com\.apple\.security\.temporary-exception'; then
    fail "profile contains a temporary exception entitlement"
fi

identity_line="$(security find-identity -v -p codesigning | grep -F \"$identity\" | head -1 || true)"
[[ -n "$identity_line" ]] || fail "Store signing identity with private key is unavailable"

HOME_VALUE="${HOME:?}"
TMP_VALUE="${TMPDIR:-/tmp}"
clean_tool() { env -i PATH="$PATH" HOME="$HOME_VALUE" TMPDIR="$TMP_VALUE" LANG=C LC_ALL=C "$@"; }
clean_tool swift build -c release --product "$macchannel_app_store_executable" --arch arm64 --arch x86_64
product_path="$(clean_tool swift build -c release --product "$macchannel_app_store_executable" --arch arm64 --arch x86_64 --show-bin-path)"

app="$work_root/DropMesh.app"
contents="$app/Contents"
mkdir -p "$contents/MacOS" "$contents/Frameworks" "$contents/Resources/en.lproj" "$contents/Resources/zh-Hans.lproj"
cp -X "$product_path/$macchannel_app_store_executable" "$contents/MacOS/$macchannel_app_store_executable"
cp -X -R "$product_path/WebRTC.framework" "$contents/Frameworks/WebRTC.framework"
cp -X -R "$product_path/MacChannel_MacChannelAppKit.bundle" "$contents/Resources/MacChannel_MacChannelAppKit.bundle"
clean_tool xcrun swift "$repo_root/Scripts/generate-dropmesh-icon.swift" "$contents/Resources/DropMesh.icns"
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
<key>CFBundlePackageType</key><string>APPL</string><key>CFBundleIconFile</key><string>DropMesh</string>
<key>CFBundleShortVersionString</key><string>$app_version</string><key>CFBundleVersion</key><string>$build_number</string>
<key>LSMinimumSystemVersion</key><string>14.0</string><key>LSUIElement</key><true/>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSBonjourServices</key><array><string>_macchannel._tcp</string></array>
<key>NSDownloadsFolderUsageDescription</key><string>Save files received from your paired Macs to Downloads.</string>
<key>NSDocumentsFolderUsageDescription</key><string>Save received files to a folder you choose.</string>
<key>DropMeshDistributionChannel</key><string>app-store</string>
<key>DropMeshAppStoreID</key><string>$store_id</string>
<key>DropMeshPrivacyURL</key><string>https://masonxqy.github.io/MacChannel/privacy/</string>
<key>DropMeshSupportURL</key><string>https://masonxqy.github.io/MacChannel/support/</string>
<key>ITSAppUsesNonExemptEncryption</key><$encryption_value/>
</dict></plist>
PLIST
plutil -lint "$contents/Info.plist" >/dev/null

cat >"$contents/Resources/en.lproj/InfoPlist.strings" <<'STRINGS'
"CFBundleDisplayName" = "DropMesh";
"CFBundleName" = "DropMesh";
"NSDownloadsFolderUsageDescription" = "Save files received from your paired Macs to Downloads.";
"NSDocumentsFolderUsageDescription" = "Save received files to a folder you choose.";
STRINGS
cat >"$contents/Resources/zh-Hans.lproj/InfoPlist.strings" <<'STRINGS'
"CFBundleDisplayName" = "DropMesh";
"CFBundleName" = "DropMesh";
"NSDownloadsFolderUsageDescription" = "将从已配对 Mac 收到的文件保存到“下载”文件夹。";
"NSDocumentsFolderUsageDescription" = "将收到的文件保存到您选择的文件夹。";
STRINGS
plutil -lint "$contents/Resources/en.lproj/InfoPlist.strings" "$contents/Resources/zh-Hans.lproj/InfoPlist.strings" >/dev/null

xattr -cr "$app"
sign=(--force --sign "$identity" --timestamp)
/usr/bin/codesign "${sign[@]}" "$contents/Frameworks/WebRTC.framework"
/usr/bin/codesign "${sign[@]}" --entitlements "$entitlements" "$contents/MacOS/$macchannel_app_store_executable"
/usr/bin/codesign "${sign[@]}" --entitlements "$entitlements" "$app"
bash "$repo_root/Scripts/test-app-store-bundle.sh" "$app"
mv "$app" "$output_abs"
trap - EXIT
rm -rf "$work_root"
echo "App Store app published: $output_abs"
