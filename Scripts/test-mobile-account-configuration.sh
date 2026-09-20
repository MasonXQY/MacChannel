#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/dropmesh-account-config.XXXXXX")
trap 'rm -f "$fixture/Info.plist"; rmdir "$fixture"' EXIT
check="$repo_root/scripts/verify-mobile-account-configuration.sh"
plist="$fixture/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.example.candidate' "$plist" >/dev/null
reject() {
  if bash "$check" "$fixture" 'https://candidate.example.com' com.example.candidate >/dev/null 2>&1; then
    printf 'FAIL: accepted %s\n' "$1" >&2; exit 1
  fi
}
reject 'missing account origin and activation'
/usr/libexec/PlistBuddy -c 'Add :DropMeshAccountServiceOrigin string https://candidate.example.com' "$plist"
reject 'missing activation'
/usr/libexec/PlistBuddy -c 'Add :DropMeshAccountGroupsEnabled string true' "$plist"
reject 'string instead of Boolean activation'
/usr/libexec/PlistBuddy -c 'Delete :DropMeshAccountGroupsEnabled' -c 'Add :DropMeshAccountGroupsEnabled bool false' "$plist"
reject 'disabled activation'
/usr/libexec/PlistBuddy -c 'Set :DropMeshAccountGroupsEnabled true' "$plist"
reject 'missing candidate transport origin'
/usr/libexec/PlistBuddy -c 'Add :DropMeshAccountTransportOrigin string https://old.example.com' "$plist"
reject 'mismatched candidate transport origin'
/usr/libexec/PlistBuddy -c 'Set :DropMeshAccountTransportOrigin https://candidate.example.com' "$plist"
reject 'missing account deletion capability'
/usr/libexec/PlistBuddy -c 'Add :DropMeshAccountDeletionEnabled string true' "$plist"
reject 'mistyped account deletion capability'
/usr/libexec/PlistBuddy -c 'Delete :DropMeshAccountDeletionEnabled' -c 'Add :DropMeshAccountDeletionEnabled bool false' "$plist"
reject 'disabled account deletion capability'
/usr/libexec/PlistBuddy -c 'Set :DropMeshAccountDeletionEnabled true' "$plist"
bash "$check" "$fixture" 'https://candidate.example.com' com.example.candidate
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.example.other' "$plist"
reject 'wrong account audience'
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.example.candidate' -c 'Set :DropMeshAccountServiceOrigin https://old.example.com' "$plist"
reject 'wrong account origin'
/usr/libexec/PlistBuddy -c 'Set :DropMeshAccountServiceOrigin http://candidate.example.com' "$plist"
if bash "$check" "$fixture" 'http://candidate.example.com' com.example.candidate >/dev/null 2>&1; then
  printf 'FAIL: accepted insecure expected origin\n' >&2; exit 1
fi
printf 'PASS: candidate bundle configuration regression checks\n'
