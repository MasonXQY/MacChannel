#!/usr/bin/env bash
set -euo pipefail

swift build -c debug

app_path=".build/MacChannel.app"
contents_path="$app_path/Contents"
mkdir -p "$contents_path/MacOS" "$contents_path/Resources"
cp ".build/debug/MacChannelApp" "$contents_path/MacOS/MacChannelApp"

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
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST
