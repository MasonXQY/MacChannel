#!/bin/bash
# Read-only artifact gate. Does not replace signature or live-device validation.
set -euo pipefail
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
[[ $# -eq 3 ]] || fail 'usage: verify-mobile-account-configuration.sh APP_PATH EXPECTED_HTTPS_ORIGIN EXPECTED_BUNDLE_ID'
plist="$1/Info.plist"
expected_origin="$2"
expected_bundle="$3"
# Deliberately require a canonical DNS HTTPS origin; no path/query/user info.
[[ "$expected_origin" =~ ^https://[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?(:[0-9]+)?$ ]] || fail 'expected origin must be a canonical HTTPS DNS origin'
[[ -n "$expected_bundle" ]] || fail 'expected bundle ID is empty'
[[ -f "$plist" ]] || fail 'built Info.plist missing'
read_string() {
  [[ "$(/usr/bin/plutil -type "$1" "$plist" 2>/dev/null)" == string ]] || fail 'required string configuration missing or mistyped'
  /usr/bin/plutil -extract "$1" raw -o - "$plist"
}
[[ "$(read_string CFBundleIdentifier)" == "$expected_bundle" ]] || fail 'account audience does not match expected bundle'
[[ "$(read_string DropMeshAccountServiceOrigin)" == "$expected_origin" ]] || fail 'account origin does not match expected candidate'
[[ "$(read_string DropMeshAccountTransportOrigin)" == "$expected_origin" ]] || fail 'account transport origin does not match expected candidate'
[[ "$(/usr/bin/plutil -type DropMeshAccountGroupsEnabled "$plist" 2>/dev/null)" == bool ]] || fail 'account groups flag must be a plist Boolean'
[[ "$(/usr/bin/plutil -extract DropMeshAccountGroupsEnabled raw -o - "$plist")" == true ]] || fail 'account groups are not enabled in this artifact'
[[ "$(/usr/bin/plutil -type DropMeshAccountDeletionEnabled "$plist" 2>/dev/null)" == bool ]] || fail 'account deletion flag must be a plist Boolean'
[[ "$(/usr/bin/plutil -extract DropMeshAccountDeletionEnabled raw -o - "$plist")" == true ]] || fail 'account deletion is not enabled in this artifact'
printf 'PASS: built account configuration matches expected origin and audience; groups and deletion enabled (signature and live service not checked)\n'
