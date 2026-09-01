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

# Reserve the caller's stderr for stable status records; raw tool diagnostics are
# intentionally suppressed or captured below.
exec 3>&2
exec 2>/dev/null

mkdir -p "$dist_root"
chmod 700 "$dist_root"
rm -f "$feed_path" "$pending_feed"
updates_root=""
published=0
release_identity_validated=0
cleanup() {
    local status=$?
    [[ -z "$updates_root" ]] || rm -rf "$updates_root"
    [[ "$published" -eq 1 ]] || rm -f "$feed_path" "$pending_feed"
    exit "$status"
}
trap cleanup EXIT INT TERM HUP
fail_feed() {
    local output_version=unvalidated
    local output_build=unvalidated
    if [[ "$release_identity_validated" -eq 1 ]]; then
        output_version="$version"
        output_build="$build_number"
    fi
    printf 'update-feed failure stage=%s version=%s build=%s\n' \
        "$1" "$output_version" "$output_build" >&3
    exit "${2:-1}"
}

if [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ || \
    ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
    fail_feed input 2
fi
release_identity_validated=1
[[ -n "$release_notes" && "$release_notes" == *.md ]] || fail_feed input 2
[[ "$account" == com.mason.macchannel.updates ]] || fail_feed account 2

security_command=/usr/bin/security
requested_security_command="${MACCHANNEL_UPDATE_SECURITY_COMMAND:-}"
if [[ -n "$requested_security_command" ]]; then
    [[ "${MACCHANNEL_UPDATE_TESTING:-0}" == 1 ]] || fail_feed test 2
    [[ "$requested_security_command" == /* && -f "$requested_security_command" && \
        ! -L "$requested_security_command" && -x "$requested_security_command" ]] || \
        fail_feed test 2
    security_command="$requested_security_command"
fi
[[ -f "$dmg_path" && ! -L "$dmg_path" ]] || fail_feed assets
[[ -f "$manifest_path" && ! -L "$manifest_path" ]] || fail_feed assets
[[ -f "$release_notes" && ! -L "$release_notes" && -s "$release_notes" ]] || fail_feed input
while IFS= read -r release_entry; do
    case "$(basename "$release_entry")" in
        MacChannel.dmg|MacChannel.manifest.json) ;;
        *) fail_feed assets ;;
    esac
done < <(find "$dist_root" -mindepth 1 -maxdepth 1 -print)

manifest_version="$(plutil -extract version raw -o - "$manifest_path" 2>/dev/null)" || fail_feed manifest
manifest_build="$(plutil -extract build raw -o - "$manifest_path" 2>/dev/null)" || fail_feed manifest
release_state="$(plutil -extract releaseState raw -o - "$manifest_path" 2>/dev/null)" || fail_feed manifest
manifest_dmg_sha="$(plutil -extract dmgSHA256 raw -o - "$manifest_path" 2>/dev/null)" || fail_feed manifest
[[ "$manifest_version" == "$version" && "$manifest_build" == "$build_number" && \
    "$release_state" == notarized && "$manifest_dmg_sha" =~ ^[0-9a-f]{64}$ ]] || fail_feed manifest
actual_dmg_sha="$(shasum -a 256 "$dmg_path" | awk '{print $1}')"
[[ "$actual_dmg_sha" == "$manifest_dmg_sha" ]] || fail_feed manifest

[[ -x "$generate_appcast" ]] || fail_feed tool
actual_generator_sha="$(shasum -a 256 "$generate_appcast" | awk '{print $1}')"
[[ "$actual_generator_sha" == "$expected_generate_appcast_sha256" ]] || fail_feed tool
sign_update="$(dirname "$generate_appcast")/sign_update"
[[ -x "$sign_update" ]] || fail_feed tool
actual_sign_update_sha="$(shasum -a 256 "$sign_update" | awk '{print $1}')"
[[ "$actual_sign_update_sha" == "$expected_sign_update_sha256" ]] || fail_feed tool

public_key="$(tr -d '\r\n' <Distribution/SparklePublicKey.txt)"
[[ "$public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || fail_feed key
public_key_length="$(printf '%s' "$public_key" | base64 -D 2>/dev/null | wc -c | tr -d ' ')"
[[ "$public_key_length" == 32 ]] || fail_feed key
login_keychain="$("$security_command" login-keychain 2>/dev/null | \
    sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')"
[[ -f "$login_keychain" ]] || fail_feed key
if ! keychain_metadata="$("$security_command" find-generic-password -a "$account" \
    -s https://sparkle-project.org "$login_keychain" 2>/dev/null)"; then
    fail_feed key
fi
grep -F "$public_key" <<<"$keychain_metadata" >/dev/null || fail_feed key
unset keychain_metadata

updates_root="$(mktemp -d "${TMPDIR:-/tmp}/macchannel-update-feed.XXXXXX")"
chmod 700 "$updates_root"
cp -p "$dmg_path" "$updates_root/MacChannel.dmg"
cp -p "$release_notes" "$updates_root/MacChannel.md"
chmod 600 "$updates_root/MacChannel.dmg" "$updates_root/MacChannel.md"
tool_log="$updates_root/tool.log"
if ! (
    cd "$updates_root"
    "$generate_appcast" --account "$account" \
        --download-url-prefix "https://github.com/MasonXQY/MacChannel/releases/download/v$version/" \
        --embed-release-notes --maximum-versions 1 --maximum-deltas 0 \
        -o appcast.xml "$updates_root"
) >"$tool_log" 2>&1; then
    fail_feed generate
fi
[[ "${MACCHANNEL_UPDATE_TESTING:-0}" != 1 || \
    "${MACCHANNEL_UPDATE_TEST_FAIL_STAGE:-}" != after-generate ]] || fail_feed generate
generated_feed="$updates_root/appcast.xml"
[[ -f "$generated_feed" && ! -L "$generated_feed" ]] || fail_feed generate

if [[ "${MACCHANNEL_UPDATE_TESTING:-0}" == 1 && -n "${MACCHANNEL_UPDATE_TEST_MUTATION:-}" ]]; then
    case "$MACCHANNEL_UPDATE_TEST_MUTATION" in
        repo-path) mutation_value="$repo_root" ;;
        updates-path) mutation_value="$updates_root" ;;
        release-notes-path) mutation_value="$release_notes" ;;
        account) mutation_value="$account" ;;
        developer-id) mutation_value='Developer ID Application:' ;;
        file-url) mutation_value='file://' ;;
        *) fail_feed test 2 ;;
    esac
    MUTATION_VALUE="$mutation_value" perl -0pi -e \
        's#<channel>#<channel><test-sensitive>$ENV{MUTATION_VALUE}</test-sensitive>#' \
        "$generated_feed" 2>>"$tool_log" || fail_feed test
fi
for forbidden_metadata in "$repo_root" "$updates_root" "$release_notes" "$account" \
    'Developer ID Application:' 'file://'; do
    grep -F "$forbidden_metadata" "$generated_feed" >/dev/null && fail_feed metadata
done

xmllint --noout "$generated_feed" >>"$tool_log" 2>&1 || fail_feed verify
item_count="$(xmllint --xpath 'count(//*[local-name()="item"])' "$generated_feed" 2>>"$tool_log")" || fail_feed verify
feed_build="$(xmllint --xpath 'string(//*[local-name()="item"][1]/*[local-name()="version"])' "$generated_feed" 2>>"$tool_log")" || fail_feed verify
feed_version="$(xmllint --xpath 'string(//*[local-name()="item"][1]/*[local-name()="shortVersionString"])' "$generated_feed" 2>>"$tool_log")" || fail_feed verify
enclosure_url="$(xmllint --xpath 'string(//*[local-name()="item"][1]/*[local-name()="enclosure"]/@url)' "$generated_feed" 2>>"$tool_log")" || fail_feed verify
enclosure_length="$(xmllint --xpath 'string(//*[local-name()="item"][1]/*[local-name()="enclosure"]/@length)' "$generated_feed" 2>>"$tool_log")" || fail_feed verify
enclosure_signature="$(xmllint --xpath 'string(//*[local-name()="item"][1]/*[local-name()="enclosure"]/@*[local-name()="edSignature"])' "$generated_feed" 2>>"$tool_log")" || fail_feed verify
embedded_release_notes="$(xmllint --xpath 'string(//*[local-name()="item"][1]/*[local-name()="description"])' "$generated_feed" 2>>"$tool_log")" || fail_feed verify
[[ "$item_count" == 1 && "$feed_build" == "$build_number" && "$feed_version" == "$version" ]] || fail_feed verify
expected_url="https://github.com/MasonXQY/MacChannel/releases/download/v$version/MacChannel.dmg"
[[ "$enclosure_url" == "$expected_url" ]] || fail_feed verify
[[ "$enclosure_length" == "$(stat -f %z "$dmg_path")" ]] || fail_feed verify
[[ -n "$enclosure_signature" && -n "$embedded_release_notes" ]] || fail_feed verify
grep -F '<!-- sparkle-signatures:' "$generated_feed" >/dev/null || fail_feed verify
grep -F 'edSignature: ' "$generated_feed" >/dev/null || fail_feed verify
"$sign_update" --account "$account" --verify "$dmg_path" "$enclosure_signature" >>"$tool_log" 2>&1 || fail_feed verify
"$sign_update" --account "$account" --verify "$generated_feed" >>"$tool_log" 2>&1 || fail_feed verify
[[ "${MACCHANNEL_UPDATE_TESTING:-0}" != 1 || \
    "${MACCHANNEL_UPDATE_TEST_FAIL_STAGE:-}" != after-verify ]] || fail_feed test

mv "$generated_feed" "$pending_feed" || fail_feed publish
chmod 644 "$pending_feed" || fail_feed publish
mv "$pending_feed" "$feed_path" || fail_feed publish
published=1
printf 'update-feed success version=%s build=%s\n' "$version" "$build_number"
