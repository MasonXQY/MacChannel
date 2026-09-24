#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repo_root"
source Scripts/app-store-validation.sh

test_root="$(mktemp -d "${TMPDIR:-/tmp}/dropmesh-store-validation.XXXXXX")"
test_root="$(cd "$test_root" && pwd -P)"
trap 'rm -rf "$test_root"' EXIT
store_profile=Tests/Fixtures/app-store-profile-summary.plist
development_profile=Tests/Fixtures/app-store-development-profile-summary.plist
macchannel_validate_macos_profile "$store_profile" distribution XKAZ67HN45.com.zensystech.dropmesh XKAZ67HN45 XKAZ67HN45.com.zensystech.dropmesh
macchannel_validate_macos_profile "$development_profile" development XKAZ67HN45.com.zensystech.dropmesh XKAZ67HN45 XKAZ67HN45.com.zensystech.dropmesh

mutate_profile() {
    local name="$1" source="$2" target
    target="$test_root/$name.plist"
    cp "$source" "$target"
    printf '%s\n' "$target"
}
wildcard_profile="$(mutate_profile wildcard "$store_profile")"
/usr/libexec/PlistBuddy -c 'Set :Entitlements:com.apple.application-identifier XKAZ67HN45.*' "$wildcard_profile"
wrong_team_profile="$(mutate_profile wrong-team "$store_profile")"
plutil -replace TeamIdentifier.0 -string AAAAAAAAAA "$wrong_team_profile"
wrong_type_profile="$(mutate_profile wrong-type "$store_profile")"
plutil -insert ProvisionedDevices -array "$wrong_type_profile"
plutil -insert ProvisionedDevices.0 -string SANITIZED-MAC "$wrong_type_profile"
all_devices_profile="$(mutate_profile all-devices "$development_profile")"
plutil -insert ProvisionsAllDevices -bool true "$all_devices_profile"
false_all_devices_profile="$(mutate_profile false-all-devices "$store_profile")"
plutil -insert ProvisionsAllDevices -bool false "$false_all_devices_profile"
wrong_platform_profile="$(mutate_profile wrong-platform "$store_profile")"
plutil -replace Platform.0 -string iOS "$wrong_platform_profile"
dictionary_platform_profile="$(mutate_profile dictionary-platform "$store_profile")"
plutil -replace Platform -json '{"0":"OSX"}' "$dictionary_platform_profile"
extra_platform_profile="$(mutate_profile extra-platform "$store_profile")"
plutil -insert Platform.1 -string '' "$extra_platform_profile"
wrong_group_profile="$(mutate_profile wrong-group "$store_profile")"
plutil -replace Entitlements.keychain-access-groups.0 -string 'AAAAAAAAAA.*' "$wrong_group_profile"
for rejected in "$wildcard_profile" "$wrong_team_profile" "$wrong_type_profile" "$all_devices_profile" "$false_all_devices_profile" "$wrong_platform_profile" "$dictionary_platform_profile" "$extra_platform_profile" "$wrong_group_profile"; do
    if macchannel_validate_macos_profile "$rejected" distribution XKAZ67HN45.com.zensystech.dropmesh XKAZ67HN45 XKAZ67HN45.com.zensystech.dropmesh >/dev/null 2>&1; then
        echo "invalid macOS profile unexpectedly accepted: $(basename "$rejected")" >&2; exit 1
    fi
done

signed_entitlements="$test_root/signed-entitlements.plist"
cp Distribution/AppStore.entitlements "$signed_entitlements"
macchannel_validate_signed_app_entitlements "$signed_entitlements" XKAZ67HN45.com.zensystech.dropmesh XKAZ67HN45 XKAZ67HN45.com.zensystech.dropmesh
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.cs.allow-jit bool true' "$signed_entitlements"
if macchannel_validate_signed_app_entitlements "$signed_entitlements" XKAZ67HN45.com.zensystech.dropmesh XKAZ67HN45 XKAZ67HN45.com.zensystech.dropmesh >/dev/null 2>&1; then
    echo "extra signed app entitlement unexpectedly accepted" >&2; exit 1
fi
cp Distribution/AppStore.entitlements "$signed_entitlements"
plutil -insert 'unexpected entitlement' -bool true "$signed_entitlements"
if macchannel_validate_signed_app_entitlements "$signed_entitlements" XKAZ67HN45.com.zensystech.dropmesh XKAZ67HN45 XKAZ67HN45.com.zensystech.dropmesh >/dev/null 2>&1; then
    echo "spaced extra signed app entitlement unexpectedly accepted" >&2; exit 1
fi
cp Distribution/AppStore.entitlements "$signed_entitlements"
/usr/libexec/PlistBuddy -c 'Add :keychain-access-groups:1 string ' "$signed_entitlements"
if macchannel_validate_signed_app_entitlements "$signed_entitlements" XKAZ67HN45.com.zensystech.dropmesh XKAZ67HN45 XKAZ67HN45.com.zensystech.dropmesh >/dev/null 2>&1; then
    echo "extra empty signed app group unexpectedly accepted" >&2; exit 1
fi
security_output="$test_root/identities.txt"
cat >"$security_output" <<'EOF'
  1) AAAABBBBCCCCDDDDEEEEFFFF0000111122223333 "Apple Distribution: ZENSYS TECHNOLOGIES - FZCO (XKAZ67HN45)"
     1 valid identities found
EOF
identity_stdout="$test_root/identity-stdout.txt"
macchannel_resolve_store_identity 'Apple Distribution: ZENSYS TECHNOLOGIES - FZCO (XKAZ67HN45)' "$security_output" >"$identity_stdout"
test ! -s "$identity_stdout"
test "$macchannel_resolved_store_identity_fingerprint" = AAAABBBBCCCCDDDDEEEEFFFF0000111122223333

for rejected in \
    'Apple Development: Qianyao Xu (XKAZ67HN45)' \
    'Apple Distribution: Other Team (AAAAAAAAAA)'; do
    printf '  1) AAAABBBBCCCCDDDDEEEEFFFF0000111122223333 "%s"\n' "$rejected" >"$security_output"
    if macchannel_resolve_store_identity "$rejected" "$security_output" >/dev/null 2>&1; then
        echo "invalid Store identity unexpectedly accepted: $rejected" >&2; exit 1
    fi
    test -z "$macchannel_resolved_store_identity_fingerprint"
done
cat >"$security_output" <<'EOF'
  1) AAAABBBBCCCCDDDDEEEEFFFF0000111122223333 "Apple Distribution: ZENSYS TECHNOLOGIES - FZCO (XKAZ67HN45)"
  2) 444455556666777788889999AAAABBBBCCCCDDDD "Apple Distribution: ZENSYS TECHNOLOGIES - FZCO (XKAZ67HN45)"
EOF
if macchannel_resolve_store_identity 'Apple Distribution: ZENSYS TECHNOLOGIES - FZCO (XKAZ67HN45)' "$security_output" >/dev/null 2>&1; then
    echo "ambiguous Store identity unexpectedly accepted" >&2; exit 1
fi
test -z "$macchannel_resolved_store_identity_fingerprint"

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
