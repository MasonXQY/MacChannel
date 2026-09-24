#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
info="${1:-$root/iPhone/App/Info.plist}"
# The bundled WebRTC binary contains camera APIs even though our data-channel
# client never starts capture. Apple scans SDK references during processing.
value=$(/usr/libexec/PlistBuddy -c 'Print :NSCameraUsageDescription' "$info" 2>/dev/null) || {
  echo 'FAIL: WebRTC-linked app is missing NSCameraUsageDescription' >&2
  exit 1
}
test -n "$value"
echo 'PASS: camera purpose string exists'
