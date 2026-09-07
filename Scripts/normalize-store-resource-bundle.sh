#!/usr/bin/env bash
set -euo pipefail
# Only the copied SwiftPM resource bundle, before application signing.
fail() { echo 'unexpected Store resource bundle layout' >&2; exit 2; }
[[ "$#" == 1 ]] || fail
bundle="$1"
plist="$bundle/Contents/Info.plist"
[[ -d "$bundle" && ! -L "$bundle" && ! -L "$bundle/Contents" && -f "$plist" && ! -L "$plist" ]] || fail
[[ ! -e "$bundle/Contents/MacOS" && ! -L "$bundle/Contents/MacOS" ]] || fail
[[ "$(plutil -extract CFBundleIdentifier raw -o - "$plist")" == MacChannel.MacChannelAppKit.resources ]] || fail
[[ "$(plutil -extract CFBundlePackageType raw -o - "$plist")" == BNDL ]] || fail
if executable="$(plutil -extract CFBundleExecutable raw -o - "$plist" 2>/dev/null)"; then
    [[ "$executable" == MacChannel_MacChannelAppKit ]] || fail
    plutil -remove CFBundleExecutable "$plist"
fi
plutil -lint "$plist" >/dev/null
