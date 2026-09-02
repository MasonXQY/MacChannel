#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repo_root"

build_configuration="${MACCHANNEL_BUILD_CONFIGURATION:-debug}"
codesign_identity="${MACCHANNEL_CODESIGN_IDENTITY:-}"
app_version="${MACCHANNEL_VERSION:-1.2.2}"
build_number="${MACCHANNEL_BUILD_NUMBER:-15}"
update_testing="${MACCHANNEL_UPDATE_TESTING:-0}"
update_test_bundle_id="${MACCHANNEL_UPDATE_TEST_BUNDLE_ID:-}"
update_test_feed_url="${MACCHANNEL_UPDATE_TEST_FEED_URL:-}"
update_test_public_key_path="${MACCHANNEL_UPDATE_TEST_PUBLIC_KEY_PATH:-}"
update_test_codesign_keychain="${MACCHANNEL_UPDATE_TEST_CODESIGN_KEYCHAIN:-}"
update_test_embed_harness="${MACCHANNEL_UPDATE_TEST_EMBED_HARNESS:-0}"
update_test_signer_variant="${MACCHANNEL_UPDATE_TEST_SIGNER_VARIANT:-}"
update_test_root="${MACCHANNEL_UPDATE_TEST_ROOT:-}"
signing_home="${HOME:?}"
signing_tmp="${TMPDIR:-/tmp}"

source "$repo_root/Scripts/update-test-paths.sh"

clean_build_tool() {
    env -i PATH="$PATH" HOME="$signing_home" TMPDIR="$signing_tmp" LANG=C LC_ALL=C "$@"
}
clean_codesign() {
    env -i PATH="$PATH" HOME="$signing_home" TMPDIR="$signing_tmp" LANG=C LC_ALL=C \
        /usr/bin/codesign "$@"
}

case "$update_testing" in
    0|1) ;;
    *)
        echo "MACCHANNEL_UPDATE_TESTING must be 0 or 1" >&2
        exit 2
        ;;
esac

update_override_names=(
    MACCHANNEL_UPDATE_TEST_BUNDLE_ID
    MACCHANNEL_UPDATE_TEST_FEED_URL
    MACCHANNEL_UPDATE_TEST_PUBLIC_KEY_PATH
    MACCHANNEL_UPDATE_TEST_CODESIGN_KEYCHAIN
    MACCHANNEL_UPDATE_TEST_EMBED_HARNESS
    MACCHANNEL_UPDATE_TEST_SIGNER_VARIANT
    MACCHANNEL_UPDATE_TEST_ROOT
    MACCHANNEL_UPDATE_TEST_DIST_ROOT
)
if [[ "$update_testing" != 1 ]]; then
    for override_name in "${update_override_names[@]}"; do
        if [[ -n "${!override_name:-}" ]]; then
            echo "update test overrides require MACCHANNEL_UPDATE_TESTING=1" >&2
            exit 2
        fi
    done
fi

case "$build_configuration" in
    debug|release) ;;
    *)
        echo "MACCHANNEL_BUILD_CONFIGURATION must be debug or release" >&2
        exit 2
        ;;
esac

if [[ ! "$app_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "MACCHANNEL_VERSION must be a release SemVer such as 1.2.3" >&2
    exit 2
fi
if [[ ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
    echo "MACCHANNEL_BUILD_NUMBER must be a positive integer" >&2
    exit 2
fi

bundle_identifier=com.mason.macchannel
feed_url=https://github.com/MasonXQY/MacChannel/releases/latest/download/appcast.xml
sparkle_public_key_path="$repo_root/Distribution/SparklePublicKey.txt"
if [[ "$update_testing" == 1 ]]; then
    if [[ ! "$update_test_bundle_id" =~ ^com\.mason\.macchannel\.update-acceptance\.[A-Za-z0-9-]+$ ]]; then
        echo "MACCHANNEL_UPDATE_TEST_BUNDLE_ID must be an isolated acceptance identifier" >&2
        exit 2
    fi
    if [[ ! "$update_test_feed_url" =~ ^https://localhost:[1-9][0-9]*/appcast\.xml$ ]]; then
        echo "MACCHANNEL_UPDATE_TEST_FEED_URL must be a local HTTPS appcast URL" >&2
        exit 2
    fi
    if [[ "$update_test_public_key_path" != /* || ! -f "$update_test_public_key_path" || \
        -L "$update_test_public_key_path" ]]; then
        echo "MACCHANNEL_UPDATE_TEST_PUBLIC_KEY_PATH must be an absolute regular file" >&2
        exit 2
    fi
    if [[ -n "$update_test_codesign_keychain" && \
        ( "$update_test_codesign_keychain" != /* || ! -f "$update_test_codesign_keychain" || \
        -L "$update_test_codesign_keychain" ) ]]; then
        echo "MACCHANNEL_UPDATE_TEST_CODESIGN_KEYCHAIN must be an absolute regular file when provided" >&2
        exit 2
    fi
    primary_test_identity='Developer ID Application: ZENSYS TECHNOLOGIES - FZCO (XKAZ67HN45)'
    alternate_test_identity='Apple Development: Qianyao Xu (H33N6G5622)'
    expected_test_identity=""
    case "$update_test_signer_variant" in
        primary) expected_test_identity="$primary_test_identity" ;;
        alternate) expected_test_identity="$alternate_test_identity" ;;
    esac
    if [[ "$update_test_embed_harness" != 1 || \
        "$codesign_identity" != "$expected_test_identity" ]]; then
        echo "update acceptance builds require the signed packaged updater harness" >&2
        exit 2
    fi
    case "$update_test_signer_variant" in
        primary|alternate) ;;
        *)
            echo "MACCHANNEL_UPDATE_TEST_SIGNER_VARIANT must be primary or alternate" >&2
            exit 2
            ;;
    esac
    bundle_identifier="$update_test_bundle_id"
    feed_url="$update_test_feed_url"
    sparkle_public_key_path="$update_test_public_key_path"
fi
if [[ ! -f "$sparkle_public_key_path" ]]; then
    echo "Sparkle public key file is required" >&2
    exit 2
fi
if [[ "$(awk 'END { print NR }' "$sparkle_public_key_path")" -ne 1 ]]; then
    echo "Sparkle public key file must contain exactly one line" >&2
    exit 2
fi
IFS= read -r sparkle_public_key < "$sparkle_public_key_path"
if [[ ! "$sparkle_public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
    echo "Sparkle public key file must contain a Sparkle public key" >&2
    exit 2
fi

app_path="${MACCHANNEL_APP_OUTPUT:-.build/MacChannel.app}"
case "$app_path" in
    */MacChannel.app|MacChannel.app) ;;
    *)
        echo "MACCHANNEL_APP_OUTPUT must end in MacChannel.app" >&2
        exit 2
        ;;
esac
if [[ "$update_testing" == 1 ]]; then
    if ! macchannel_require_isolated_test_root "$repo_root" "$update_test_root"; then
        echo "update acceptance root must be canonical, owner-only, and outside the repository" >&2
        exit 2
    fi
    if ! macchannel_require_direct_child_path "$update_test_root" "$app_path" MacChannel.app; then
        echo "update acceptance output must be the canonical direct child of its owner-only test root" >&2
        exit 2
    fi
fi

if [[ "$build_configuration" == release ]]; then
    build_arguments=(-c release --arch arm64 --arch x86_64)
else
    build_arguments=(-c debug)
fi
clean_build_tool swift build "${build_arguments[@]}"
product_path="$(clean_build_tool swift build "${build_arguments[@]}" --show-bin-path)"

mkdir -p "$(dirname "$app_path")"
rm -rf "$app_path"

signing_root=""
working_app="$app_path"
cleanup_signing_root() {
    if [[ -n "$signing_root" ]]; then
        rm -rf "$signing_root"
    fi
}

if [[ -n "$codesign_identity" ]]; then
    signing_root="$(mktemp -d "${TMPDIR:-/tmp}/macchannel-sign.XXXXXX")"
    working_app="$signing_root/MacChannel.app"
    trap cleanup_signing_root EXIT
fi

contents_path="$working_app/Contents"
mkdir -p "$contents_path/MacOS" "$contents_path/Resources" "$contents_path/Frameworks"
dropmesh_icon_path="$contents_path/Resources/DropMesh.icns"
clean_build_tool xcrun swift \
    "$repo_root/Scripts/generate-dropmesh-icon.swift" \
    "$dropmesh_icon_path"
if [[ ! -s "$dropmesh_icon_path" ]]; then
    echo "DropMesh application icon is required" >&2
    exit 2
fi
cp -X "$product_path/MacChannelApp" "$contents_path/MacOS/MacChannelApp"
cp -X -R "$product_path/WebRTC.framework" "$contents_path/MacOS/WebRTC.framework"
cp -X -R "$product_path/Sparkle.framework" "$contents_path/Frameworks/Sparkle.framework"
if [[ "$build_configuration" == release ]]; then
    install_name_tool -add_rpath @executable_path/../Frameworks "$contents_path/MacOS/MacChannelApp"
    install_name_tool -add_rpath @executable_path "$contents_path/MacOS/MacChannelApp"
    cp -X -R "$product_path/MacChannel_MacChannelAppKit.bundle" \
        "$contents_path/Resources/MacChannel_MacChannelAppKit.bundle"
else
    cp -X -R "$product_path/Sparkle.framework" "$contents_path/MacOS/Sparkle.framework"
    cp -X -R "$product_path/MacChannel_MacChannelAppKit.bundle" \
        "$working_app/MacChannel_MacChannelAppKit.bundle"
fi

if [[ "$update_testing" == 1 ]]; then
    sparkle_cli_source="$repo_root/.build/checkouts/Sparkle/sparkle-cli"
    sparkle_private_headers="$contents_path/Frameworks/Sparkle.framework/Versions/Current/PrivateHeaders"
    [[ -f "$sparkle_cli_source/main.m" && -f "$sparkle_private_headers/SUInstallerLauncher+Private.h" ]] || {
        echo "pinned Sparkle acceptance harness sources are unavailable" >&2
        exit 2
    }
    harness_source="$signing_root/SPUCommandLineUserDriver.m"
    harness_driver_source="$signing_root/SPUCommandLineDriver.m"
    cp -p "$sparkle_cli_source/SPUCommandLineUserDriver.m" "$harness_source"
    cp -p "$sparkle_cli_source/SPUCommandLineDriver.m" "$harness_driver_source"
    perl -0pi -e \
        's/installUpdateHandler\(SPUUserUpdateChoiceDismiss\);/fprintf(stdout, "macchannel-update-acceptance state=validated\\n"); fflush(stdout); installUpdateHandler(SPUUserUpdateChoiceSkip);/' \
        "$harness_source"
    perl -0pi -e \
        's/fprintf\(stderr, "Error: Unable to download release notes: %s\\n", error\.localizedDescription\.UTF8String\);/for (NSError *cursor = error; cursor != nil; cursor = cursor.userInfo[NSUnderlyingErrorKey]) { fprintf(stderr, "macchannel-update-acceptance state=release-notes-failed domain=%s code=%ld\\n", cursor.domain.UTF8String, (long)cursor.code); }/' \
        "$harness_source"
    perl -0pi -e \
        's/if \(_probingForUpdates\) \{/if (_probingForUpdates) { fprintf(stdout, "macchannel-update-acceptance state=available build=%s\\n", item.versionString.UTF8String); fflush(stdout);/' \
        "$harness_driver_source"
    perl -0pi -e \
        's/fprintf\(stderr, "Error: Update has failed due to error %ld \(%s\)\. %s\\n", \(long\)error\.code, error\.domain\.UTF8String, error\.localizedDescription\.UTF8String\);/for (NSError *cursor = error; cursor != nil; cursor = cursor.userInfo[NSUnderlyingErrorKey]) { fprintf(stderr, "macchannel-update-acceptance state=failed domain=%s code=%ld\\n", cursor.domain.UTF8String, (long)cursor.code); }/' \
        "$harness_driver_source"
    clean_build_tool xcrun clang \
        -fobjc-arc \
        -fmodules \
        -DSPU_OBJC_DIRECT_MEMBERS= \
        -DSPU_OBJC_DIRECT= \
        -framework AppKit \
        -framework Foundation \
        -framework Security \
        -framework Sparkle \
        -F "$contents_path/Frameworks" \
        -I "$sparkle_cli_source" \
        -I "$sparkle_private_headers" \
        "$sparkle_cli_source/main.m" \
        "$harness_driver_source" \
        "$harness_source" \
        "$repo_root/Tests/Fixtures/UpdateAcceptanceTLSProtocol.m" \
        -Wl,-rpath,@executable_path/../Frameworks \
        -o "$contents_path/MacOS/MacChannelUpdateAcceptance"
    clean_build_tool xcrun clang \
        -fobjc-arc \
        -fmodules \
        -framework Foundation \
        -framework Sparkle \
        -F "$contents_path/Frameworks" \
        "$repo_root/Tests/Fixtures/UpdateAcceptanceLoadProbe.m" \
        -Wl,-rpath,@executable_path/../Frameworks \
        -o "$contents_path/MacOS/MacChannelUpdateLoadProbe"
fi

update_test_plist_fragment=""
if [[ "$update_testing" == 1 ]]; then
    update_test_plist_fragment="    <key>MacChannelUpdateTestSigner</key>
    <string>$update_test_signer_variant</string>"
fi

cat > "$contents_path/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MacChannelApp</string>
    <key>CFBundleIdentifier</key>
    <string>$bundle_identifier</string>
    <key>CFBundleName</key>
    <string>DropMesh</string>
    <key>CFBundleDisplayName</key>
    <string>MacChannel</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>LSHasLocalizedDisplayName</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>DropMesh</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$app_version</string>
    <key>CFBundleVersion</key>
    <string>$build_number</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>用于将来自已配对 Mac 的文件自动保存到“下载”文件夹。</string>
    <key>SUFeedURL</key>
    <string>$feed_url</string>
    <key>SUPublicEDKey</key>
    <string>$sparkle_public_key</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUScheduledCheckInterval</key>
    <real>86400</real>
    <key>SUAutomaticallyUpdate</key>
    <false/>
    <key>SUAllowsAutomaticUpdates</key>
    <false/>
    <key>SUVerifyUpdateBeforeExtraction</key>
    <true/>
    <key>SURequireSignedFeed</key>
    <true/>
$update_test_plist_fragment
</dict>
</plist>
PLIST
plutil -lint "$contents_path/Info.plist" >/dev/null

localized_info_root="$contents_path/Resources/en.lproj"
mkdir -p "$localized_info_root"
localized_info="$localized_info_root/InfoPlist.strings"
plutil -create binary1 "$localized_info"
plutil -insert CFBundleDisplayName -string DropMesh "$localized_info"
plutil -insert CFBundleName -string DropMesh "$localized_info"
for localization in Base zh-Hans; do
    mkdir -p "$contents_path/Resources/$localization.lproj"
    cp -X "$localized_info" "$contents_path/Resources/$localization.lproj/InfoPlist.strings"
done

if [[ -n "$codesign_identity" ]]; then
    xattr -cr "$working_app"
    signing_args=(
        --force
        --sign "$codesign_identity"
        --options runtime
    )
    if [[ "$update_testing" == 1 ]]; then
        [[ -z "$update_test_codesign_keychain" ]] || \
            signing_args+=(--keychain "$update_test_codesign_keychain")
        signing_args+=(--timestamp=none)
    else
        signing_args+=(--timestamp)
    fi

    sparkle_path="$working_app/Contents/Frameworks/Sparkle.framework"
    for nested_sparkle_code in \
        "$sparkle_path/Versions/Current/XPCServices/Downloader.xpc" \
        "$sparkle_path/Versions/Current/XPCServices/Installer.xpc" \
        "$sparkle_path/Versions/Current/Updater.app" \
        "$sparkle_path/Versions/Current/Autoupdate"; do
        if [[ -e "$nested_sparkle_code" ]]; then
            clean_codesign "${signing_args[@]}" "$nested_sparkle_code"
        fi
    done

    clean_codesign "${signing_args[@]}" "$sparkle_path"
    clean_codesign "${signing_args[@]}" "$working_app/Contents/MacOS/WebRTC.framework"
    if [[ "$update_testing" == 1 ]]; then
        clean_codesign "${signing_args[@]}" \
            --entitlements "$repo_root/Tests/Fixtures/UpdateAcceptance.entitlements" \
            "$working_app/Contents/MacOS/MacChannelUpdateAcceptance"
        clean_codesign "${signing_args[@]}" \
            --entitlements "$repo_root/Tests/Fixtures/UpdateAcceptance.entitlements" \
            "$working_app/Contents/MacOS/MacChannelUpdateLoadProbe"
    fi
    clean_codesign "${signing_args[@]}" "$working_app/Contents/MacOS/MacChannelApp"
    if [[ "$update_testing" == 1 ]]; then
        acceptance_requirement="=designated => identifier \"$bundle_identifier\" and info[MacChannelUpdateTestSigner] = \"$update_test_signer_variant\""
        clean_codesign "${signing_args[@]}" --requirements "$acceptance_requirement" "$working_app"
    else
        clean_codesign "${signing_args[@]}" "$working_app"
    fi

    mv "$working_app" "$app_path"
    rm -rf "$signing_root"
    signing_root=""
    trap - EXIT
else
    xattr -cr "$app_path"
fi
