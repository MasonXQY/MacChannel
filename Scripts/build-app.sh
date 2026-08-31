#!/usr/bin/env bash
set -euo pipefail

build_configuration="${MACCHANNEL_BUILD_CONFIGURATION:-debug}"
codesign_identity="${MACCHANNEL_CODESIGN_IDENTITY:-}"
app_version="${MACCHANNEL_VERSION:-1.1.6}"
build_number="${MACCHANNEL_BUILD_NUMBER:-8}"

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
mkdir -p "$contents_path/MacOS" "$contents_path/Resources"
cp -X "$product_path/MacChannelApp" "$contents_path/MacOS/MacChannelApp"
cp -X -R "$product_path/WebRTC.framework" "$contents_path/MacOS/WebRTC.framework"
if [[ "$build_configuration" == release ]]; then
    install_name_tool -add_rpath @executable_path "$contents_path/MacOS/MacChannelApp"
fi
if [[ -n "$codesign_identity" ]]; then
    cp -X -R "$product_path/MacChannel_MacChannelAppKit.bundle" "$contents_path/Resources/MacChannel_MacChannelAppKit.bundle"
else
    cp -X -R "$product_path/MacChannel_MacChannelAppKit.bundle" "$working_app/MacChannel_MacChannelAppKit.bundle"
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
</dict>
</plist>
PLIST
plutil -lint "$contents_path/Info.plist" >/dev/null

if [[ -n "$codesign_identity" ]]; then
    signing_args=(
        --force
        --sign "$codesign_identity"
        --options runtime
        --timestamp
    )

    codesign "${signing_args[@]}" "$working_app/Contents/MacOS/WebRTC.framework"
    codesign "${signing_args[@]}" "$working_app/Contents/MacOS/MacChannelApp"
    codesign "${signing_args[@]}" "$working_app"

    mv "$working_app" "$app_path"
    xattr -cr "$app_path"
    signing_root=""
    trap - EXIT
else
    xattr -cr "$app_path"
fi
