#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repo_root"
version="${MACCHANNEL_VERSION:-1.2.2}"
build_number="${MACCHANNEL_BUILD_NUMBER:-15}"
release_notes="${MACCHANNEL_RELEASE_NOTES:-}"
account="${MACCHANNEL_SPARKLE_ACCOUNT:-com.mason.macchannel.updates}"
generate_appcast="${MACCHANNEL_SPARKLE_GENERATE_APPCAST:-$repo_root/.build/tools/Sparkle-2.9.6/bin/generate_appcast}"
update_testing="${MACCHANNEL_UPDATE_TESTING:-0}"
signing_home="${HOME:?}"
signing_tmp="${TMPDIR:-/tmp}"
[[ "$signing_home" == /* && -d "$signing_home" && ! -L "$signing_home" ]]
case "$update_testing" in
    0|1) ;;
    *)
        printf 'update-feed failure stage=test version=unvalidated build=unvalidated\n' >&2
        exit 2
        ;;
esac
if [[ "$update_testing" != 1 && \
    ( -n "${MACCHANNEL_UPDATE_TEST_ROOT:-}" || \
      -n "${MACCHANNEL_UPDATE_TEST_DIST_ROOT:-}" || \
      -n "${MACCHANNEL_UPDATE_TEST_FAIL_STAGE:-}" || \
      -n "${MACCHANNEL_UPDATE_TEST_MUTATION:-}" || \
      -n "${MACCHANNEL_UPDATE_SECURITY_COMMAND:-}" || \
      -n "${MACCHANNEL_UPDATE_CODESIGN_COMMAND:-}" || \
      -n "${MACCHANNEL_UPDATE_TEST_ED_KEY_FILE:-}" || \
      -n "${MACCHANNEL_UPDATE_TEST_PUBLIC_KEY_PATH:-}" ) ]]; then
    printf 'update-feed failure stage=test version=%s build=%s\n' \
        "$version" "$build_number" >&2
    exit 2
fi
source "$repo_root/Scripts/update-test-paths.sh"
if ! dist_root="$(macchannel_resolve_dist_root "$repo_root")"; then
    echo "update-feed failure stage=test version=unvalidated build=unvalidated" >&2
    exit 2
fi
dmg_path="$dist_root/DropMesh.dmg"
manifest_path="$dist_root/DropMesh.manifest.json"
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
identity_mount_root=""
identity_mounted=0
cleanup() {
    local status=$?
    if [[ "$identity_mounted" -eq 1 ]]; then
        hdiutil detach "$identity_mount_root" -quiet >/dev/null 2>&1 || true
    fi
    [[ -z "$identity_mount_root" ]] || rm -rf "$identity_mount_root"
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

clean_security_tool() {
    env -i PATH="$PATH" HOME="$signing_home" TMPDIR="$signing_tmp" LANG=C LC_ALL=C \
        MACCHANNEL_SECURITY_SHIM_MARKER="${MACCHANNEL_SECURITY_SHIM_MARKER:-}" \
        MACCHANNEL_SECURITY_SHIM_NOISE="${MACCHANNEL_SECURITY_SHIM_NOISE:-}" \
        MACCHANNEL_SECURITY_SHIM_LOGIN_KEYCHAIN="${MACCHANNEL_SECURITY_SHIM_LOGIN_KEYCHAIN:-}" \
        "$@"
}
clean_codesign_tool() {
    env -i PATH="$PATH" HOME="$signing_home" TMPDIR="$signing_tmp" LANG=C LC_ALL=C \
        MACCHANNEL_CODESIGN_FIXTURE_VERIFY="${MACCHANNEL_CODESIGN_FIXTURE_VERIFY:-}" \
        MACCHANNEL_CODESIGN_FIXTURE_ANCHOR_MATCH="${MACCHANNEL_CODESIGN_FIXTURE_ANCHOR_MATCH:-}" \
        MACCHANNEL_CODESIGN_FIXTURE_CERT_CLASS="${MACCHANNEL_CODESIGN_FIXTURE_CERT_CLASS:-}" \
        MACCHANNEL_CODESIGN_FIXTURE_ANCHOR_MARKER="${MACCHANNEL_CODESIGN_FIXTURE_ANCHOR_MARKER:-}" \
        MACCHANNEL_CODESIGN_FIXTURE_POST_MOUNT_MARKER="${MACCHANNEL_CODESIGN_FIXTURE_POST_MOUNT_MARKER:-}" \
        MACCHANNEL_CODESIGN_FIXTURE_BUNDLE_ID="${MACCHANNEL_CODESIGN_FIXTURE_BUNDLE_ID:-}" \
        MACCHANNEL_CODESIGN_FIXTURE_TEAM_ID="${MACCHANNEL_CODESIGN_FIXTURE_TEAM_ID:-}" \
        MACCHANNEL_CODESIGN_FIXTURE_REQUIREMENT="${MACCHANNEL_CODESIGN_FIXTURE_REQUIREMENT:-}" \
        "$@"
}
clean_update_tool() {
    env -i PATH="$PATH" HOME="$signing_home" TMPDIR="$signing_tmp" LANG=C LC_ALL=C "$@"
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
    [[ "$update_testing" == 1 ]] || fail_feed test 2
    [[ "$requested_security_command" == /* && -f "$requested_security_command" && \
        ! -L "$requested_security_command" && -x "$requested_security_command" ]] || \
        fail_feed test 2
    security_command="$requested_security_command"
fi
codesign_command=/usr/bin/codesign
requested_codesign_command="${MACCHANNEL_UPDATE_CODESIGN_COMMAND:-}"
if [[ -n "$requested_codesign_command" ]]; then
    [[ "$update_testing" == 1 ]] || fail_feed test 2
    [[ "$requested_codesign_command" == /* && -f "$requested_codesign_command" && \
        ! -L "$requested_codesign_command" && -x "$requested_codesign_command" ]] || \
        fail_feed test 2
    codesign_command="$requested_codesign_command"
fi
test_ed_key_file="${MACCHANNEL_UPDATE_TEST_ED_KEY_FILE:-}"
test_public_key_path="${MACCHANNEL_UPDATE_TEST_PUBLIC_KEY_PATH:-}"
if [[ "$update_testing" == 1 ]]; then
    [[ -n "$requested_security_command" && -n "$test_ed_key_file" && \
        -n "$test_public_key_path" ]] || fail_feed test 2
    macchannel_require_contained_regular_file "${MACCHANNEL_UPDATE_TEST_ROOT:-}" \
        "$requested_security_command" || fail_feed test 2
    macchannel_require_contained_regular_file "${MACCHANNEL_UPDATE_TEST_ROOT:-}" \
        "$test_ed_key_file" || fail_feed test 2
    macchannel_require_contained_regular_file "${MACCHANNEL_UPDATE_TEST_ROOT:-}" \
        "$test_public_key_path" || fail_feed test 2
    [[ -z "$requested_codesign_command" ]] || \
        macchannel_require_contained_regular_file "${MACCHANNEL_UPDATE_TEST_ROOT:-}" \
            "$requested_codesign_command" || fail_feed test 2
elif [[ -n "$test_ed_key_file" || -n "$test_public_key_path" ]]; then
    fail_feed test 2
fi
[[ -f "$dmg_path" && ! -L "$dmg_path" ]] || fail_feed assets
[[ -f "$manifest_path" && ! -L "$manifest_path" ]] || fail_feed assets
[[ -f "$release_notes" && ! -L "$release_notes" && -s "$release_notes" ]] || fail_feed input
while IFS= read -r release_entry; do
    case "$(basename "$release_entry")" in
        DropMesh.dmg|DropMesh.manifest.json) ;;
        *) fail_feed assets ;;
    esac
done < <(find "$dist_root" -mindepth 1 -maxdepth 1 -print)

manifest_version="$(plutil -extract version raw -o - "$manifest_path" 2>/dev/null)" || fail_feed manifest
manifest_build="$(plutil -extract build raw -o - "$manifest_path" 2>/dev/null)" || fail_feed manifest
manifest_product="$(plutil -extract product raw -o - "$manifest_path" 2>/dev/null)" || fail_feed manifest
release_state="$(plutil -extract releaseState raw -o - "$manifest_path" 2>/dev/null)" || fail_feed manifest
manifest_dmg_sha="$(plutil -extract dmgSHA256 raw -o - "$manifest_path" 2>/dev/null)" || fail_feed manifest
manifest_team_id="$(plutil -extract teamID raw -o - "$manifest_path" 2>/dev/null)" || fail_feed manifest
manifest_requirement="$(plutil -extract designatedRequirement raw -o - "$manifest_path" 2>/dev/null)" || fail_feed manifest
anchor_path="$repo_root/Distribution/ProductionSigningAnchor.plist"
[[ -f "$anchor_path" && ! -L "$anchor_path" ]] || fail_feed identity
anchor_team_id="$(plutil -extract teamID raw -o - "$anchor_path" 2>/dev/null)" || fail_feed identity
anchor_bundle_id="$(plutil -extract bundleIdentifier raw -o - "$anchor_path" 2>/dev/null)" || fail_feed identity
anchor_requirement="$(plutil -extract designatedRequirement raw -o - "$anchor_path" 2>/dev/null)" || fail_feed identity
expected_anchor_requirement='anchor apple generic and identifier "com.mason.macchannel" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "XKAZ67HN45"'
[[ "$anchor_team_id" == XKAZ67HN45 && "$anchor_bundle_id" == com.mason.macchannel && \
    "$anchor_requirement" == "$expected_anchor_requirement" ]] || fail_feed identity
[[ "$manifest_product" == DropMesh && "$manifest_version" == "$version" && \
    "$manifest_build" == "$build_number" && \
    "$release_state" == notarized && "$manifest_dmg_sha" =~ ^[0-9a-f]{64}$ && \
    "$manifest_team_id" =~ ^[A-Z0-9]{10}$ && -n "$manifest_requirement" ]] || fail_feed manifest
actual_dmg_sha="$(shasum -a 256 "$dmg_path" | awk '{print $1}')"
[[ "$actual_dmg_sha" == "$manifest_dmg_sha" ]] || fail_feed manifest

identity_mount_root="$(mktemp -d "${TMPDIR:-/tmp}/macchannel-update-identity.XXXXXX")"
chmod 700 "$identity_mount_root"
cleanup_identity_mount() {
    if [[ "$identity_mounted" -eq 1 ]]; then
        hdiutil detach "$identity_mount_root" -quiet >/dev/null 2>&1 || true
        identity_mounted=0
    fi
    rm -rf "$identity_mount_root"
    identity_mount_root=""
}
if ! hdiutil attach "$dmg_path" -nobrowse -readonly -mountpoint "$identity_mount_root" -quiet; then
    cleanup_identity_mount
    fail_feed identity
fi
identity_mounted=1
mounted_app="$identity_mount_root/MacChannel.app"
if [[ ! -d "$mounted_app" || -L "$mounted_app" ]] || \
    ! clean_codesign_tool "$codesign_command" --verify --deep --strict --verbose=2 "$mounted_app" || \
    ! clean_codesign_tool "$codesign_command" --verify --deep --strict \
        --test-requirement "=$anchor_requirement" "$mounted_app"; then
    cleanup_identity_mount
    fail_feed identity
fi
if ! app_identity="$(clean_codesign_tool "$codesign_command" -d --verbose=4 --requirements - "$mounted_app" 2>&1)"; then
    cleanup_identity_mount
    fail_feed identity
fi
actual_team_id="$(sed -n 's/^TeamIdentifier=//p' <<<"$app_identity" | tail -n 1)"
actual_requirement="$(sed -n 's/^designated => //p' <<<"$app_identity" | tail -n 1)"
actual_bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$mounted_app/Contents/Info.plist" 2>/dev/null || true)"
actual_executable="$(plutil -extract CFBundleExecutable raw -o - "$mounted_app/Contents/Info.plist" 2>/dev/null || true)"
actual_bundle_name="$(plutil -extract CFBundleName raw -o - "$mounted_app/Contents/Info.plist" 2>/dev/null || true)"
actual_display_name="$(plutil -extract CFBundleDisplayName raw -o - "$mounted_app/Contents/Info.plist" 2>/dev/null || true)"
actual_version="$(plutil -extract CFBundleShortVersionString raw -o - "$mounted_app/Contents/Info.plist" 2>/dev/null || true)"
actual_build="$(plutil -extract CFBundleVersion raw -o - "$mounted_app/Contents/Info.plist" 2>/dev/null || true)"
unset app_identity
cleanup_identity_mount
[[ "$actual_team_id" == "$anchor_team_id" && \
    "$actual_requirement" == "$manifest_requirement" && \
    "$manifest_team_id" == "$actual_team_id" && \
    "$actual_bundle_id" == "$anchor_bundle_id" && \
    "$actual_executable" == MacChannelApp && "$actual_bundle_name" == DropMesh && \
    "$actual_display_name" == DropMesh && \
    "$actual_version" == "$version" && "$actual_build" == "$build_number" ]] || \
    fail_feed identity

[[ -x "$generate_appcast" ]] || fail_feed tool
actual_generator_sha="$(shasum -a 256 "$generate_appcast" | awk '{print $1}')"
[[ "$actual_generator_sha" == "$expected_generate_appcast_sha256" ]] || fail_feed tool
sign_update="$(dirname "$generate_appcast")/sign_update"
[[ -x "$sign_update" ]] || fail_feed tool
actual_sign_update_sha="$(shasum -a 256 "$sign_update" | awk '{print $1}')"
[[ "$actual_sign_update_sha" == "$expected_sign_update_sha256" ]] || fail_feed tool

public_key_source=Distribution/SparklePublicKey.txt
[[ -z "$test_public_key_path" ]] || public_key_source="$test_public_key_path"
public_key="$(tr -d '\r\n' <"$public_key_source")"
[[ "$public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || fail_feed key
public_key_length="$(printf '%s' "$public_key" | base64 -D 2>/dev/null | wc -c | tr -d ' ')"
[[ "$public_key_length" == 32 ]] || fail_feed key
if [[ "$update_testing" == 1 ]]; then
    [[ "$(stat -f %Lp "$test_ed_key_file")" =~ ^[0-7]*00$ ]] || fail_feed key
    signing_key_arguments=(--ed-key-file "$test_ed_key_file")
else
    signing_key_arguments=(--account "$account")
    login_keychain="$(clean_security_tool "$security_command" login-keychain 2>/dev/null | \
        sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')"
    [[ -f "$login_keychain" ]] || fail_feed key
    if ! keychain_metadata="$(clean_security_tool "$security_command" find-generic-password -a "$account" \
        -s https://sparkle-project.org "$login_keychain" 2>/dev/null)"; then
        fail_feed key
    fi
    grep -F "$public_key" <<<"$keychain_metadata" >/dev/null || fail_feed key
    unset keychain_metadata
fi

updates_root="$(mktemp -d "${TMPDIR:-/tmp}/macchannel-update-feed.XXXXXX")"
chmod 700 "$updates_root"
cp -p "$dmg_path" "$updates_root/DropMesh.dmg"
cp -p "$release_notes" "$updates_root/DropMesh.md"
chmod 600 "$updates_root/DropMesh.dmg" "$updates_root/DropMesh.md"
tool_log="$updates_root/tool.log"
if ! (
    cd "$updates_root"
    clean_update_tool "$generate_appcast" "${signing_key_arguments[@]}" \
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
expected_url="https://github.com/MasonXQY/MacChannel/releases/download/v$version/DropMesh.dmg"
[[ "$enclosure_url" == "$expected_url" ]] || fail_feed verify
[[ "$enclosure_length" == "$(stat -f %z "$dmg_path")" ]] || fail_feed verify
[[ -n "$enclosure_signature" && -n "$embedded_release_notes" ]] || fail_feed verify
grep -F '<!-- sparkle-signatures:' "$generated_feed" >/dev/null || fail_feed verify
grep -F 'edSignature: ' "$generated_feed" >/dev/null || fail_feed verify
clean_update_tool "$sign_update" "${signing_key_arguments[@]}" --verify "$dmg_path" "$enclosure_signature" >>"$tool_log" 2>&1 || fail_feed verify
clean_update_tool "$sign_update" "${signing_key_arguments[@]}" --verify "$generated_feed" >>"$tool_log" 2>&1 || fail_feed verify
[[ "${MACCHANNEL_UPDATE_TESTING:-0}" != 1 || \
    "${MACCHANNEL_UPDATE_TEST_FAIL_STAGE:-}" != after-verify ]] || fail_feed test

mv "$generated_feed" "$pending_feed" || fail_feed publish
chmod 644 "$pending_feed" || fail_feed publish
mv "$pending_feed" "$feed_path" || fail_feed publish
published=1
printf 'update-feed success version=%s build=%s\n' "$version" "$build_number"
