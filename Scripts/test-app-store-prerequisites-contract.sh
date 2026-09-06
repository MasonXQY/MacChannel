#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repo_root"

audit=Scripts/audit-app-store-prerequisites.sh
anchor=Distribution/AppStoreProfileAnchor.plist
ops=docs/operations/app-store-connect-setup.md

test -x "$audit"
test -f "$anchor"
test -f "$ops"

for required in \
    MACCHANNEL_APP_STORE_DEVELOPMENT_PROFILE \
    MACCHANNEL_APP_STORE_DISTRIBUTION_PROFILE \
    MACCHANNEL_APP_STORE_DEVELOPMENT_IDENTITY \
    MACCHANNEL_APP_STORE_APPLICATION_IDENTITY \
    MACCHANNEL_APP_STORE_INSTALLER_IDENTITY \
    MACCHANNEL_APP_STORE_APP_ID \
    MACCHANNEL_APP_STORE_API_KEY_ID \
    MACCHANNEL_APP_STORE_API_ISSUER_ID; do
    grep -F "$required" "$audit" >/dev/null
done

grep -F 'security cms -D' "$audit" >/dev/null
grep -F 'find-identity -v -p codesigning' "$audit" >/dev/null
grep -F 'altool --list-apps' "$audit" >/dev/null
grep -F 'com.apple.security.app-sandbox' "$audit" >/dev/null
grep -F 'get-task-allow' "$audit" >/dev/null
grep -F 'XKAZ67HN45.com.zensystech.dropmesh' "$audit" >/dev/null
grep -F 'development identity with a private key is required' "$audit" >/dev/null

test "$(plutil -extract bundleIdentifier raw -o - "$anchor")" = com.zensystech.dropmesh
test "$(plutil -extract teamID raw -o - "$anchor")" = XKAZ67HN45
test "$(plutil -extract sku raw -o - "$anchor")" = dropmesh-macos-130
test "$(plutil -extract appStoreID raw -o - "$anchor")" = BLOCKED_PENDING_APP_STORE_CONNECT

set +e
blocked_output="$(env -i PATH="$PATH" HOME="${HOME:?}" TMPDIR="${TMPDIR:-/tmp}" bash "$audit" 2>&1)"
blocked_status=$?
set -e
test "$blocked_status" -eq 2
grep -F 'app-store-prerequisites BLOCKED' <<<"$blocked_output" >/dev/null
grep -F 'development profile' <<<"$blocked_output" >/dev/null
grep -F 'distribution profile' <<<"$blocked_output" >/dev/null
grep -F 'numeric App Store ID' <<<"$blocked_output" >/dev/null
grep -F 'upload authentication' <<<"$blocked_output" >/dev/null
if grep -E 'API key ID:|issuer ID:|\.p8' <<<"$blocked_output" >/dev/null; then
    echo "audit output exposed upload credential metadata" >&2
    exit 1
fi

fake_key="$(mktemp "${TMPDIR:-/tmp}/dropmesh-fake-key.XXXXXX")"
trap 'rm -f "$fake_key"' EXIT
chmod 600 "$fake_key"
set +e
malformed_output="$(MACCHANNEL_APP_STORE_API_KEY_ID='../escape' \
    MACCHANNEL_APP_STORE_API_ISSUER_ID='not-an-issuer' \
    MACCHANNEL_APP_STORE_API_PRIVATE_KEY="$fake_key" bash "$audit" 2>&1)"
malformed_status=$?
set -e
test "$malformed_status" -eq 2
grep -F 'upload authentication identifiers are malformed' <<<"$malformed_output" >/dev/null
test ! -e "${TMPDIR:-/tmp}/escape.p8"

echo "app-store prerequisites contract PASS"
