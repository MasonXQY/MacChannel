#!/usr/bin/env bash
set -euo pipefail

build_configuration="${MACCHANNEL_BUILD_CONFIGURATION:-debug}"
codesign_identity="${MACCHANNEL_CODESIGN_IDENTITY:-}"

case "$build_configuration" in
    debug|release) ;;
    *)
        echo "MACCHANNEL_BUILD_CONFIGURATION must be debug or release" >&2
        exit 2
        ;;
esac

swift build -c "$build_configuration"

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
cp -X ".build/$build_configuration/MacChannelApp" "$contents_path/MacOS/MacChannelApp"
cp -X -R ".build/$build_configuration/WebRTC.framework" "$contents_path/MacOS/WebRTC.framework"
if [[ -n "$codesign_identity" ]]; then
    cp -X -R ".build/$build_configuration/MacChannel_MacChannelAppKit.bundle" "$contents_path/Resources/MacChannel_MacChannelAppKit.bundle"
else
    cp -X -R ".build/$build_configuration/MacChannel_MacChannelAppKit.bundle" "$working_app/MacChannel_MacChannelAppKit.bundle"
fi

cat > "$contents_path/Info.plist" <<'PLIST'
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
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

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
    signing_root=""
    trap - EXIT
fi
