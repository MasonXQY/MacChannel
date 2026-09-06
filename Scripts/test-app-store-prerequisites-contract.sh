#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repo_root"

audit=Scripts/audit-app-store-prerequisites.sh
cms_verifier=Scripts/verify-apple-provisioning-profile.swift
anchor=Distribution/AppStoreProfileAnchor.plist
ops=docs/operations/app-store-connect-setup.md

test -x "$audit"
test -f "$cms_verifier"
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

if grep -F 'security cms -D' "$audit" >/dev/null; then
    echo "audit must not treat security cms decoding as signature verification" >&2
    exit 1
fi
grep -F 'verify-apple-provisioning-profile.swift' "$audit" >/dev/null
grep -F 'find-identity -v -p codesigning' "$audit" >/dev/null
grep -F 'altool --list-apps' "$audit" >/dev/null
grep -F 'com.apple.security.app-sandbox' "$audit" >/dev/null
grep -F 'get-task-allow' "$audit" >/dev/null
grep -F 'XKAZ67HN45.com.zensystech.dropmesh' "$audit" >/dev/null
grep -F 'development identity with a private key is required' "$audit" >/dev/null

test "$(plutil -extract bundleIdentifier raw -o - "$anchor")" = com.zensystech.dropmesh
test "$(plutil -extract teamID raw -o - "$anchor")" = XKAZ67HN45
test "$(plutil -extract sku raw -o - "$anchor")" = dropmesh-macos-130
test "$(plutil -extract appStoreID raw -o - "$anchor")" = 6809209993

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

apple_profile="$(find "${HOME:?}/Library/Developer/Xcode/UserData/Provisioning Profiles" -type f -name '*.provisionprofile' 2>/dev/null | head -1 || true)"
test -n "$apple_profile"
verified_payload="$(mktemp "${TMPDIR:-/tmp}/dropmesh-verified-profile.XXXXXX")"
selfsigned_root="$(mktemp -d "${TMPDIR:-/tmp}/dropmesh-selfsigned-profile.XXXXXX")"
trap 'rm -f "$fake_key" "$verified_payload"; rm -rf "$selfsigned_root"' EXIT
xcrun swift "$cms_verifier" "$apple_profile" "$verified_payload"
plutil -lint "$verified_payload" >/dev/null
cp "$apple_profile" "$selfsigned_root/tampered.provisionprofile"
printf '\000' | dd of="$selfsigned_root/tampered.provisionprofile" bs=1 seek=32 conv=notrunc 2>/dev/null
! xcrun swift "$cms_verifier" "$selfsigned_root/tampered.provisionprofile" "$selfsigned_root/tampered.plist" >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -subj '/CN=Apple iPhone OS Provisioning Profile Signing/O=Apple Inc./OU=Apple Certification Authority' \
    -keyout "$selfsigned_root/key.pem" -out "$selfsigned_root/cert.pem" -days 1 >/dev/null 2>&1
printf '%s\n' '<?xml version="1.0"?><plist version="1.0"><dict><key>Name</key><string>forged</string></dict></plist>' >"$selfsigned_root/payload.plist"
openssl cms -sign -binary -nodetach -in "$selfsigned_root/payload.plist" -signer "$selfsigned_root/cert.pem" \
    -inkey "$selfsigned_root/key.pem" -outform DER -out "$selfsigned_root/selfsigned.provisionprofile" >/dev/null 2>&1
! xcrun swift "$cms_verifier" "$selfsigned_root/selfsigned.provisionprofile" "$selfsigned_root/selfsigned.plist" >/dev/null 2>&1

acl_key="$selfsigned_root/acl-key.p8"
printf 'dummy' >"$acl_key"
chmod 600 "$acl_key"
chmod +a 'everyone allow read' "$acl_key"
set +e
acl_output="$(MACCHANNEL_APP_STORE_API_KEY_ID='ABC123' \
    MACCHANNEL_APP_STORE_API_ISSUER_ID='12345678-1234-1234-1234-1234567890ab' \
    MACCHANNEL_APP_STORE_API_PRIVATE_KEY="$acl_key" bash "$audit" 2>&1)"
acl_status=$?
set -e
test "$acl_status" -eq 2
grep -F 'private key has ACL entries' <<<"$acl_output" >/dev/null

grep -F "stat -f '%u'" "$audit" >/dev/null
grep -F 'id -u' "$audit" >/dev/null

development_subject='Apple Development: Qianyao Xu (H33N6G5622)'
set +e
development_output="$(MACCHANNEL_APP_STORE_DEVELOPMENT_IDENTITY="$development_subject" bash "$audit" 2>&1)"
development_status=$?
set -e
test "$development_status" -eq 2
if grep -F 'development identity with a private key is required' <<<"$development_output" >/dev/null; then
    echo "valid development identity was rejected because its personal identifier differs from Team ID" >&2
    exit 1
fi

root_owned_key=/private/etc/ssh/ssh_host_ed25519_key
if [[ -f "$root_owned_key" ]]; then
    set +e
    owner_output="$(MACCHANNEL_APP_STORE_API_KEY_ID='ABC123' \
        MACCHANNEL_APP_STORE_API_ISSUER_ID='12345678-1234-1234-1234-1234567890ab' \
        MACCHANNEL_APP_STORE_API_PRIVATE_KEY="$root_owned_key" bash "$audit" 2>&1)"
    owner_status=$?
    set -e
    test "$owner_status" -eq 2
    grep -F 'private key is not owned by the current user' <<<"$owner_output" >/dev/null
fi

echo "app-store prerequisites contract PASS"
