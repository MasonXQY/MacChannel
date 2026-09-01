#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repo_root"

build_configuration="${MACCHANNEL_BUILD_CONFIGURATION:-debug}"
codesign_identity="${MACCHANNEL_CODESIGN_IDENTITY:-}"
app_version="${MACCHANNEL_VERSION:-1.2.0}"
build_number="${MACCHANNEL_BUILD_NUMBER:-13}"

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

sparkle_public_key_path="$repo_root/Distribution/SparklePublicKey.txt"
if [[ ! -f "$sparkle_public_key_path" ]]; then
    echo "Distribution/SparklePublicKey.txt is required" >&2
    exit 2
fi
if [[ "$(awk 'END { print NR }' "$sparkle_public_key_path")" -ne 1 ]]; then
    echo "Distribution/SparklePublicKey.txt must contain exactly one line" >&2
    exit 2
fi
IFS= read -r sparkle_public_key < "$sparkle_public_key_path"
if [[ ! "$sparkle_public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
    echo "Distribution/SparklePublicKey.txt must contain a Sparkle public key" >&2
    exit 2
fi

if [[ "$build_configuration" == release ]]; then
    build_arguments=(-c release --arch arm64 --arch x86_64)
else
    build_arguments=(-c debug)
fi
swift build "${build_arguments[@]}"
product_path="$(swift build "${build_arguments[@]}" --show-bin-path)"

app_path="${MACCHANNEL_APP_OUTPUT:-.build/MacChannel.app}"
case "$app_path" in
    */MacChannel.app|MacChannel.app) ;;
    *)
        echo "MACCHANNEL_APP_OUTPUT must end in MacChannel.app" >&2
        exit 2
        ;;
esac
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

cat > "$contents_path/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MacChannelApp</string>
    <key>CFBundleIdentifier</key>
    <string>com.mason.macchannel</string>
    <key>CFBundleName</key>
    <string>MacChannel</string>
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
    <string>https://github.com/MasonXQY/MacChannel/releases/latest/download/appcast.xml</string>
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
</dict>
</plist>
PLIST
plutil -lint "$contents_path/Info.plist" >/dev/null

if [[ -n "$codesign_identity" ]]; then
    xattr -cr "$working_app"
    signing_args=(
        --force
        --sign "$codesign_identity"
        --options runtime
        --timestamp
    )

    sparkle_path="$working_app/Contents/Frameworks/Sparkle.framework"
    for nested_sparkle_code in \
        "$sparkle_path/Versions/Current/XPCServices/Downloader.xpc" \
        "$sparkle_path/Versions/Current/XPCServices/Installer.xpc" \
        "$sparkle_path/Versions/Current/Updater.app" \
        "$sparkle_path/Versions/Current/Autoupdate"; do
        if [[ -e "$nested_sparkle_code" ]]; then
            codesign "${signing_args[@]}" "$nested_sparkle_code"
        fi
    done

    codesign "${signing_args[@]}" "$sparkle_path"
    codesign "${signing_args[@]}" "$working_app/Contents/MacOS/WebRTC.framework"
    codesign "${signing_args[@]}" "$working_app/Contents/MacOS/MacChannelApp"
    codesign "${signing_args[@]}" "$working_app"

    mv "$working_app" "$app_path"
    signing_root=""
    trap - EXIT
else
    xattr -cr "$app_path"
fi
