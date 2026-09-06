#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repo_root"
source Scripts/app-store-validation.sh

test_root="$(mktemp -d "${TMPDIR:-/tmp}/dropmesh-store-validation.XXXXXX")"
test_root="$(cd "$test_root" && pwd -P)"
trap 'rm -rf "$test_root"' EXIT
security_output="$test_root/identities.txt"
cat >"$security_output" <<'EOF'
  1) AAAABBBBCCCCDDDDEEEEFFFF0000111122223333 "Apple Distribution: ZENSYS TECHNOLOGIES - FZCO (XKAZ67HN45)"
     1 valid identities found
EOF
test "$(macchannel_resolve_store_identity 'Apple Distribution: ZENSYS TECHNOLOGIES - FZCO (XKAZ67HN45)' "$security_output")" = AAAABBBBCCCCDDDDEEEEFFFF0000111122223333

for rejected in \
    'Apple Development: Qianyao Xu (XKAZ67HN45)' \
    'Apple Distribution: Other Team (AAAAAAAAAA)'; do
    printf '  1) AAAABBBBCCCCDDDDEEEEFFFF0000111122223333 "%s"\n' "$rejected" >"$security_output"
    if macchannel_resolve_store_identity "$rejected" "$security_output" >/dev/null 2>&1; then
        echo "invalid Store identity unexpectedly accepted: $rejected" >&2; exit 1
    fi
done
cat >"$security_output" <<'EOF'
  1) AAAABBBBCCCCDDDDEEEEFFFF0000111122223333 "Apple Distribution: ZENSYS TECHNOLOGIES - FZCO (XKAZ67HN45)"
  2) 444455556666777788889999AAAABBBBCCCCDDDD "Apple Distribution: ZENSYS TECHNOLOGIES - FZCO (XKAZ67HN45)"
EOF
if macchannel_resolve_store_identity 'Apple Distribution: ZENSYS TECHNOLOGIES - FZCO (XKAZ67HN45)' "$security_output" >/dev/null 2>&1; then
    echo "ambiguous Store identity unexpectedly accepted" >&2; exit 1
fi

store_identity='Apple Distribution: ZENSYS TECHNOLOGIES - FZCO (XKAZ67HN45)'
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -subj "/OU=XKAZ67HN45/CN=$store_identity" -days 1 \
    -keyout "$test_root/key.pem" -out "$test_root/cert.pem" >/dev/null 2>&1
/usr/bin/openssl x509 -in "$test_root/cert.pem" -outform der -out "$test_root/cert.der"
fingerprint="$(/usr/bin/openssl x509 -in "$test_root/cert.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"
profile="$test_root/profile.plist"
cp Tests/Fixtures/app-store-profile-summary.plist "$profile"
plutil -insert DeveloperCertificates -array "$profile"
plutil -insert DeveloperCertificates.0 -data "$(base64 <"$test_root/cert.der")" "$profile"
macchannel_require_profile_certificate "$profile" "$fingerprint" "$store_identity"
if macchannel_require_profile_certificate "$profile" FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF "$store_identity" >/dev/null 2>&1; then
    echo "mismatched profile certificate unexpectedly accepted" >&2; exit 1
fi
if macchannel_require_profile_certificate "$profile" "$fingerprint" 'Apple Distribution: Impostor (XKAZ67HN45)' >/dev/null 2>&1; then
    echo "profile certificate with mismatched subject unexpectedly accepted" >&2; exit 1
fi

mkdir -p "$test_root/repo/dist" "$test_root/outside"
touch "$test_root/repo/dist/existing-direct-artifact"
dist_before="$(find "$test_root/repo/dist" -mindepth 1 -print | sort)"
ln -s "$test_root/repo/dist" "$test_root/repo/store-link"
for unsafe in \
    "$test_root/repo/other/../dist/DropMesh.app" \
    "$test_root/repo/store-link/new/DropMesh.app"; do
    if macchannel_validate_store_output_path "$test_root/repo" "$unsafe" >/dev/null 2>&1; then
        echo "unsafe Store output unexpectedly accepted: $unsafe" >&2; exit 1
    fi
done
test ! -e "$test_root/repo/other"
test ! -e "$test_root/repo/dist/DropMesh.app"
test ! -e "$test_root/repo/dist/new"
test "$(find "$test_root/repo/dist" -mindepth 1 -print | sort)" = "$dist_before"
safe="$(macchannel_validate_store_output_path "$test_root/repo" "$test_root/outside/new/DropMesh.app")"
test "$safe" = "$test_root/outside/new/DropMesh.app"
test ! -e "$test_root/outside/new"

fixture_app="$test_root/SUFixture/DropMesh.app"
mkdir -p "$fixture_app/Contents/MacOS" "$fixture_app/Contents/Resources/Nested"
cp /bin/echo "$fixture_app/Contents/MacOS/DropMeshAppStore"
cp Tests/Fixtures/app-store-profile-summary.plist "$fixture_app/Contents/Info.plist"
nested="$fixture_app/Contents/Resources/Nested/settings.plist"
plutil -create binary1 "$nested"
plutil -insert SUScheduledCheckInterval -integer 3600 "$nested"
set +e
bash Scripts/test-app-store-bundle.sh "$fixture_app" >"$test_root/su.log" 2>&1
su_status=$?
set -e
test "$su_status" -ne 0
grep -F 'forbidden SU metadata key: SUScheduledCheckInterval' "$test_root/su.log" >/dev/null

echo "app store validation contract PASS"
