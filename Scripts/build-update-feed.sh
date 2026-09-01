#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repo_root"

version="${MACCHANNEL_VERSION:-1.2.0}"
build_number="${MACCHANNEL_BUILD_NUMBER:-13}"
release_notes="${MACCHANNEL_RELEASE_NOTES:-}"
account="${MACCHANNEL_SPARKLE_ACCOUNT:-com.mason.macchannel.updates}"
generate_appcast="${MACCHANNEL_SPARKLE_GENERATE_APPCAST:-$repo_root/.build/tools/Sparkle-2.9.6/bin/generate_appcast}"
dist_root="$repo_root/dist"
dmg_path="$dist_root/MacChannel.dmg"
manifest_path="$dist_root/MacChannel.manifest.json"
feed_path="$dist_root/appcast.xml"
pending_feed="$dist_root/.appcast.xml.new"
expected_generate_appcast_sha256=b3b54ba3fb85ef1f25eb2f5a9ad90c32ba6e71af777b181c50ffb5d860bac6b7
expected_sign_update_sha256=bfb52400c3da18bb4c251ac4818c2c2e1e31c2e649a45b31c11109b6e57b34ad

mkdir -p "$dist_root"
chmod 700 "$dist_root"
rm -f "$feed_path" "$pending_feed"

updates_root=""
published=0
cleanup() {
    local status=$?
    if [[ -n "$updates_root" ]]; then
        rm -rf "$updates_root"
    fi
    if [[ "$published" -ne 1 ]]; then
        rm -f "$feed_path" "$pending_feed"
    fi
    exit "$status"
}
trap cleanup EXIT INT TERM HUP

fail_usage() {
    echo "$1" >&2
    exit 2
}

fail_feed() {
    echo "$1" >&2
    exit 1
}

[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || \
    fail_usage "MACCHANNEL_VERSION must be a release SemVer such as 1.2.3"
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || \
    fail_usage "MACCHANNEL_BUILD_NUMBER must be a positive integer"
[[ -n "$release_notes" ]] || fail_usage "MACCHANNEL_RELEASE_NOTES is required"
[[ -n "$account" ]] || fail_usage "MACCHANNEL_SPARKLE_ACCOUNT is required"

[[ -f "$dmg_path" ]] || fail_feed "dist/MacChannel.dmg is required"
[[ -f "$manifest_path" ]] || fail_feed "dist/MacChannel.manifest.json is required"
[[ -f "$release_notes" && -s "$release_notes" ]] || \
    fail_feed "release notes Markdown is missing or empty"
[[ "$release_notes" == *.md ]] || fail_usage "MACCHANNEL_RELEASE_NOTES must reference Markdown"

manifest_version="$(plutil -extract version raw -o - "$manifest_path" 2>/dev/null)" || \
    fail_feed "distribution manifest has no version"
manifest_build="$(plutil -extract build raw -o - "$manifest_path" 2>/dev/null)" || \
    fail_feed "distribution manifest has no build"
release_state="$(plutil -extract releaseState raw -o - "$manifest_path" 2>/dev/null)" || \
    fail_feed "distribution manifest has no releaseState"
manifest_dmg_sha="$(plutil -extract dmgSHA256 raw -o - "$manifest_path" 2>/dev/null)" || \
    fail_feed "distribution manifest has no dmgSHA256"

[[ "$manifest_version" == "$version" ]] || fail_feed "manifest version does not match release version"
[[ "$manifest_build" == "$build_number" ]] || fail_feed "manifest build does not match release build"
[[ "$release_state" == notarized ]] || fail_feed "only notarized releases may have an appcast"
[[ "$manifest_dmg_sha" =~ ^[0-9a-f]{64}$ ]] || fail_feed "manifest DMG digest is invalid"
actual_dmg_sha="$(shasum -a 256 "$dmg_path" | awk '{print $1}')"
[[ "$actual_dmg_sha" == "$manifest_dmg_sha" ]] || fail_feed "manifest DMG digest does not match the DMG"

[[ -x "$generate_appcast" ]] || fail_feed "Sparkle generate_appcast is missing or not executable"
actual_generator_sha="$(shasum -a 256 "$generate_appcast" | awk '{print $1}')"
[[ "$actual_generator_sha" == "$expected_generate_appcast_sha256" ]] || \
    fail_feed "MACCHANNEL_SPARKLE_GENERATE_APPCAST must be the pinned Sparkle 2.9.6 generator"
sign_update="$(dirname "$generate_appcast")/sign_update"
[[ -x "$sign_update" ]] || fail_feed "Sparkle 2.9.6 sign_update is missing or not executable"
actual_sign_update_sha="$(shasum -a 256 "$sign_update" | awk '{print $1}')"
[[ "$actual_sign_update_sha" == "$expected_sign_update_sha256" ]] || \
    fail_feed "Sparkle sign_update does not match the pinned 2.9.6 tool"

public_key="$(tr -d '\r\n' <Distribution/SparklePublicKey.txt)"
[[ "$public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || fail_feed "Sparkle public key is invalid"
public_key_length="$(printf '%s' "$public_key" | base64 -D 2>/dev/null | wc -c | tr -d ' ')"
[[ "$public_key_length" == 32 ]] || fail_feed "Sparkle public key must decode to 32 bytes"

login_keychain="$(security login-keychain | \
    sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')"
[[ -f "$login_keychain" ]] || fail_feed "the user login Keychain is unavailable"
if ! keychain_metadata="$(security find-generic-password \
    -a "$account" \
    -s https://sparkle-project.org \
    "$login_keychain" 2>&1)"; then
    fail_feed "Sparkle private key account is missing from the login Keychain"
fi
grep -F "$public_key" <<<"$keychain_metadata" >/dev/null || \
    fail_feed "Sparkle Keychain account does not match Distribution/SparklePublicKey.txt"
unset keychain_metadata

updates_root="$(mktemp -d "${TMPDIR:-/tmp}/macchannel-update-feed.XXXXXX")"
chmod 700 "$updates_root"
cp -p "$dmg_path" "$updates_root/MacChannel.dmg"
cp -p "$release_notes" "$updates_root/MacChannel.md"
chmod 600 "$updates_root/MacChannel.dmg" "$updates_root/MacChannel.md"

(
    cd "$updates_root"
    "$generate_appcast" \
        --account "$account" \
        --download-url-prefix "https://github.com/MasonXQY/MacChannel/releases/download/v$version/" \
        --embed-release-notes \
        --maximum-versions 1 \
        --maximum-deltas 0 \
        -o appcast.xml \
        "$updates_root"
)

generated_feed="$updates_root/appcast.xml"
[[ -f "$generated_feed" ]] || fail_feed "Sparkle did not generate appcast.xml"
xmllint --noout "$generated_feed" || fail_feed "generated appcast is not valid XML"

item_count="$(xmllint --xpath 'count(//*[local-name()="item"])' "$generated_feed")"
feed_build="$(xmllint --xpath \
    'string(//*[local-name()="item"][1]/*[local-name()="version"])' \
    "$generated_feed")"
feed_version="$(xmllint --xpath \
    'string(//*[local-name()="item"][1]/*[local-name()="shortVersionString"])' \
    "$generated_feed")"
enclosure_url="$(xmllint --xpath \
    'string(//*[local-name()="item"][1]/*[local-name()="enclosure"]/@url)' \
    "$generated_feed")"
enclosure_length="$(xmllint --xpath \
    'string(//*[local-name()="item"][1]/*[local-name()="enclosure"]/@length)' \
    "$generated_feed")"
enclosure_signature="$(xmllint --xpath \
    'string(//*[local-name()="item"][1]/*[local-name()="enclosure"]/@*[local-name()="edSignature"])' \
    "$generated_feed")"
embedded_release_notes="$(xmllint --xpath \
    'string(//*[local-name()="item"][1]/*[local-name()="description"])' \
    "$generated_feed")"

[[ "$item_count" == 1 ]] || fail_feed "appcast must contain exactly one release"
[[ "$feed_build" == "$build_number" ]] || fail_feed "appcast build does not match the manifest"
[[ "$feed_version" == "$version" ]] || fail_feed "appcast version does not match the manifest"
expected_url="https://github.com/MasonXQY/MacChannel/releases/download/v$version/MacChannel.dmg"
[[ "$enclosure_url" == "$expected_url" ]] || fail_feed "appcast enclosure URL is incorrect"
[[ "$enclosure_length" == "$(stat -f %z "$dmg_path")" ]] || \
    fail_feed "appcast enclosure length does not match the DMG"
[[ -n "$enclosure_signature" ]] || fail_feed "appcast enclosure has no EdDSA signature"
[[ -n "$embedded_release_notes" ]] || fail_feed "release notes were not embedded in the appcast"
grep -F '<!-- sparkle-signatures:' "$generated_feed" >/dev/null || \
    fail_feed "appcast has no embedded feed signature"
grep -F 'edSignature: ' "$generated_feed" >/dev/null || \
    fail_feed "appcast feed signature is empty"

"$sign_update" --account "$account" --verify "$dmg_path" "$enclosure_signature" >/dev/null
"$sign_update" --account "$account" --verify "$generated_feed" >/dev/null

for forbidden_metadata in \
    "$repo_root" \
    "$updates_root" \
    "$release_notes" \
    "$account" \
    'Developer ID Application:' \
    'file://'; do
    if grep -F "$forbidden_metadata" "$generated_feed" >/dev/null; then
        fail_feed "generated appcast contains sensitive local metadata"
    fi
done

mv "$generated_feed" "$pending_feed"
chmod 644 "$pending_feed"
mv "$pending_feed" "$feed_path"
published=1

echo "created $feed_path (signed Sparkle feed for $version ($build_number))"
