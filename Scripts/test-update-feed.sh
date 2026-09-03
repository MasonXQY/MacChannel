#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repo_root"
source Scripts/update-test-paths.sh

if [[ ! -x Scripts/build-update-feed.sh ]]; then
    echo "Scripts/build-update-feed.sh is missing or not executable" >&2
    exit 1
fi
grep -F '/usr/bin/codesign "$@"' Scripts/build-update-feed.sh >/dev/null
grep -F '/usr/bin/xcrun stapler validate "$dmg_path"' \
    Scripts/build-update-feed.sh >/dev/null
grep -F '/usr/sbin/spctl --assess --type open' Scripts/build-update-feed.sh >/dev/null

version=1.2.4
build_number=17
account=com.mason.macchannel.updates
generate_appcast="$repo_root/.build/tools/Sparkle-2.9.6/bin/generate_appcast"
signing_home="${HOME:?}"
signing_tmp="${TMPDIR:-/tmp}"

test_root="$(macchannel_create_test_root macchannel-update-feed-test)"
macchannel_require_canonical_test_root "$test_root"
fixture_root="$test_root/fixture"
test_dist="$test_root/dist"
fixture_dmg="$fixture_root/DropMesh.dmg"
fixture_manifest="$fixture_root/DropMesh.manifest.json"
release_notes="$repo_root/Distribution/ReleaseNotes/v1.2.4.md"
security_shim="$test_root/security-missing-key"
fake_login_keychain="$test_root/fake-login.keychain-db"
codesign_shim="$test_root/codesign-update-fixture"
stapler_shim="$test_root/stapler-update-fixture"
spctl_shim="$test_root/spctl-update-fixture"
validator_marker="$test_root/dmg-validation.marker"
key_access_marker="$test_root/private-key-access.marker"
test_private_pem="$test_root/sparkle-private.pem"
test_private_key="$test_root/sparkle-private.key"
test_public_key="$test_root/sparkle-public.key"
fixture_team_id=XKAZ67HN45
fixture_requirement='identifier "com.mason.macchannel" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = XKAZ67HN45'
primary_identity='Developer ID Application: ZENSYS TECHNOLOGIES - FZCO (XKAZ67HN45)'

snapshot_dist() {
    local root="$1"
    if [[ ! -e "$root" && ! -L "$root" ]]; then
        printf 'absent\n'
        return
    fi
    find "$root" -mindepth 0 -maxdepth 1 -print0 | LC_ALL=C sort -z | \
        while IFS= read -r -d '' entry; do
            if [[ -L "$entry" ]]; then
                printf 'link\t%s\t%s\n' "$(basename "$entry")" "$(readlink "$entry")"
            elif [[ -f "$entry" ]]; then
                printf 'file\t%s\t%s\n' "$(basename "$entry")" \
                    "$(shasum -a 256 "$entry" | awk '{print $1}')"
            elif [[ -d "$entry" ]]; then
                printf 'dir\t%s\n' "$(basename "$entry")"
            else
                printf 'other\t%s\n' "$(basename "$entry")"
            fi
        done
}

formal_dist_before="$(snapshot_dist "$repo_root/dist")"

cleanup() {
    local status=$?
    trap - EXIT
    if [[ "$(snapshot_dist "$repo_root/dist")" != "$formal_dist_before" ]]; then
        echo "formal repository dist changed during update fixture test" >&2
        status=1
    fi
    if [[ "${MACCHANNEL_TEST_KEEP_TEMP:-0}" != 1 ]]; then
        if macchannel_require_canonical_test_root "$test_root"; then
            rm -rf "$test_root"
        else
            echo "refusing cleanup of a non-canonical update-feed test root" >&2
            status=1
        fi
    fi
    exit "$status"
}
trap cleanup EXIT

mkdir -p "$fixture_root/app" "$test_dist" "$test_root/home"
chmod 700 "$test_root" "$fixture_root" "$test_dist"
clean_fixture_tool() {
    env -i PATH="$PATH" HOME="$test_root/home" TMPDIR="$test_root/" LANG=C LC_ALL=C "$@"
}
clean_signing_tool() {
    env -i PATH="$PATH" HOME="$signing_home" TMPDIR="$signing_tmp" LANG=C LC_ALL=C "$@"
}

# Characterize the shared resolver against a synthetic repository that already
# contains uploadable-looking formal assets. Test output must resolve elsewhere.
sentinel_repo="$test_root/sentinel-repo"
mkdir -p "$sentinel_repo/dist"
chmod 700 "$sentinel_repo" "$sentinel_repo/dist"
printf 'formal-dmg-sentinel\n' >"$sentinel_repo/dist/DropMesh.dmg"
printf 'formal-manifest-sentinel\n' >"$sentinel_repo/dist/DropMesh.manifest.json"
printf 'formal-feed-sentinel\n' >"$sentinel_repo/dist/appcast.xml"
synthetic_dist_before="$(snapshot_dist "$sentinel_repo/dist")"
resolved_test_dist="$(MACCHANNEL_UPDATE_TESTING=1 \
    MACCHANNEL_UPDATE_TEST_ROOT="$test_root" \
    MACCHANNEL_UPDATE_TEST_DIST_ROOT="$test_dist" \
    macchannel_resolve_dist_root "$sentinel_repo")"
[[ "$resolved_test_dist" == "$test_dist" ]]
[[ "$(snapshot_dist "$sentinel_repo/dist")" == "$synthetic_dist_before" ]]

# Canonical-containment attacks must be rejected without touching a sentinel
# outside the requested direct-child target.
attack_root="$test_root/containment"
outside_root="$test_root/outside"
mkdir -p "$attack_root" "$outside_root"
chmod 700 "$attack_root" "$outside_root"
printf 'outside-sentinel\n' >"$outside_root/sentinel"
outside_sha="$(shasum -a 256 "$outside_root/sentinel" | awk '{print $1}')"
! macchannel_require_direct_child_path "$attack_root" \
    "$attack_root/../outside/MacChannel.app" MacChannel.app
ln -s "$attack_root" "$test_root/containment-link"
! macchannel_require_direct_child_path "$test_root/containment-link" \
    "$test_root/containment-link/MacChannel.app" MacChannel.app
ln -s "$outside_root" "$attack_root/MacChannel.app"
! macchannel_require_direct_child_path "$attack_root" \
    "$attack_root/MacChannel.app" MacChannel.app
rm "$attack_root/MacChannel.app"
! macchannel_require_direct_child_path "$attack_root" \
    "$attack_root/NotMacChannel.app" MacChannel.app
ln -s /Applications "$test_root/applications-alias"
! macchannel_require_canonical_test_root "$test_root/applications-alias"
test "$outside_sha" = "$(shasum -a 256 "$outside_root/sentinel" | awk '{print $1}')"
cp Tests/Fixtures/security-missing-key.sh "$security_shim"
cp Tests/Fixtures/codesign-update-fixture.sh "$codesign_shim"
cat >"$stapler_shim" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" -eq 2 && "$1" == validate && -f "$2" ]]
printf 'stapler\t%s\n' "$2" >>"$MACCHANNEL_UPDATE_VALIDATOR_MARKER"
[[ "${MACCHANNEL_UPDATE_VALIDATOR_FAIL:-}" != stapler ]]
SH
cat >"$spctl_shim" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" -ge 7 && "$1" == --assess && "$2" == --type && "$3" == open ]]
[[ "$4" == --context && "$5" == context:primary-signature && "$6" == --verbose=2 ]]
[[ -f "${@: -1}" ]]
printf 'spctl-open\t%s\n' "${@: -1}" >>"$MACCHANNEL_UPDATE_VALIDATOR_MARKER"
[[ "${MACCHANNEL_UPDATE_VALIDATOR_FAIL:-}" != gatekeeper ]]
SH
chmod 700 "$security_shim" "$codesign_shim" "$stapler_shim" "$spctl_shim"
: >"$fake_login_keychain"
chmod 600 "$fake_login_keychain"
if ! /usr/bin/security find-identity -v -p codesigning | \
    grep -F "\"$primary_identity\"" >/dev/null; then
    echo "update-feed adversarial test requires the production identity" >&2
    exit 2
fi
clean_fixture_tool openssl genpkey -algorithm Ed25519 -out "$test_private_pem" >/dev/null 2>&1
clean_fixture_tool openssl pkey -in "$test_private_pem" -outform DER 2>/dev/null | tail -c 32 | \
    base64 >"$test_private_key"
clean_fixture_tool openssl pkey -in "$test_private_pem" -pubout -outform DER 2>/dev/null | tail -c 32 | \
    base64 >"$test_public_key"
chmod 600 "$test_private_pem" "$test_private_key" "$test_public_key"
public_key="$(tr -d '\r\n' <"$test_public_key")"
ditto ".build/tools/Sparkle-2.9.6/Sparkle Test App.app" \
    "$fixture_root/app/MacChannel.app"
fixture_plist="$fixture_root/app/MacChannel.app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string com.mason.macchannel "$fixture_plist"
plutil -replace CFBundleShortVersionString -string "$version" "$fixture_plist"
plutil -replace CFBundleVersion -string "$build_number" "$fixture_plist"
plutil -replace CFBundleExecutable -string MacChannelApp "$fixture_plist"
plutil -replace CFBundleName -string DropMesh "$fixture_plist"
plutil -replace CFBundleDisplayName -string MacChannel "$fixture_plist"
plutil -replace LSHasLocalizedDisplayName -bool true "$fixture_plist"
mkdir -p "$fixture_root/app/MacChannel.app/Contents/Resources/en.lproj"
fixture_localized_info="$fixture_root/app/MacChannel.app/Contents/Resources/en.lproj/InfoPlist.strings"
plutil -create binary1 "$fixture_localized_info"
plutil -insert CFBundleDisplayName -string DropMesh "$fixture_localized_info"
plutil -insert CFBundleName -string DropMesh "$fixture_localized_info"
plutil -replace SUPublicEDKey -string "$public_key" "$fixture_plist"
plutil -replace SURequireSignedFeed -bool true "$fixture_plist"
/bin/mv "$fixture_root/app/MacChannel.app/Contents/MacOS/Sparkle Test App" \
    "$fixture_root/app/MacChannel.app/Contents/MacOS/MacChannelApp"
clean_fixture_tool xattr -cr "$fixture_root/app/MacChannel.app"
clean_signing_tool /usr/bin/codesign --force --deep --options runtime --timestamp=none \
    --sign "$primary_identity" "$fixture_root/app/MacChannel.app" >/dev/null 2>&1
clean_signing_tool /usr/bin/codesign --verify --deep --strict \
    --test-requirement "=$fixture_requirement" "$fixture_root/app/MacChannel.app"
clean_fixture_tool hdiutil create \
    -srcfolder "$fixture_root/app" \
    -volname "DropMesh" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$fixture_dmg" >/dev/null
clean_signing_tool /usr/bin/codesign --force --sign "$primary_identity" --timestamp=none \
    "$fixture_dmg" >/dev/null 2>&1

if [[ ! -s "$release_notes" ]]; then
    echo "tracked Chinese release notes are missing" >&2
    exit 1
fi
release_notes_sha_before="$(shasum -a 256 "$release_notes" | awk '{print $1}')"

dmg_sha="$(shasum -a 256 "$fixture_dmg" | awk '{print $1}')"
plutil -create xml1 "$fixture_manifest"
plutil -insert product -string DropMesh "$fixture_manifest"
plutil -insert bundleIdentifier -string com.mason.macchannel "$fixture_manifest"
plutil -insert version -string "$version" "$fixture_manifest"
plutil -insert build -string "$build_number" "$fixture_manifest"
plutil -insert releaseState -string notarized "$fixture_manifest"
plutil -insert dmgSHA256 -string "$dmg_sha" "$fixture_manifest"
plutil -insert teamID -string "$fixture_team_id" "$fixture_manifest"
plutil -insert designatedRequirement -string "$fixture_requirement" "$fixture_manifest"
plutil -convert json "$fixture_manifest"

prepare_fixture() {
    cp "$fixture_dmg" "$test_dist/DropMesh.dmg"
    cp "$fixture_manifest" "$test_dist/DropMesh.manifest.json"
    rm -f "$test_dist/appcast.xml" "$test_dist/.appcast.xml.new"
}

run_feed_builder() {
    local testing="${MACCHANNEL_TESTING:-1}"
    local use_disposable_key="${MACCHANNEL_TEST_USE_DISPOSABLE_KEY:-1}"
    local ed_key_file=""
    local public_key_path=""
    local test_root_value=""
    local test_dist_value=""
    if [[ "$use_disposable_key" == 1 ]]; then
        ed_key_file="$test_private_key"
        public_key_path="$test_public_key"
    fi
    if [[ -n "${MACCHANNEL_TEST_ED_KEY_FILE_OVERRIDE+x}" ]]; then
        ed_key_file="$MACCHANNEL_TEST_ED_KEY_FILE_OVERRIDE"
    fi
    if [[ -n "${MACCHANNEL_TEST_PUBLIC_KEY_PATH_OVERRIDE+x}" ]]; then
        public_key_path="$MACCHANNEL_TEST_PUBLIC_KEY_PATH_OVERRIDE"
    fi
    if [[ "$testing" == 1 ]]; then
        test_root_value="$test_root"
        test_dist_value="$test_dist"
    fi
    env -i PATH="$PATH" HOME="$test_root/home" TMPDIR="$test_root/" LANG=C LC_ALL=C \
        MACCHANNEL_VERSION="${MACCHANNEL_TEST_VERSION:-$version}" \
        MACCHANNEL_BUILD_NUMBER="${MACCHANNEL_TEST_BUILD_NUMBER:-$build_number}" \
        MACCHANNEL_RELEASE_NOTES="${MACCHANNEL_TEST_RELEASE_NOTES:-$release_notes}" \
        MACCHANNEL_SPARKLE_ACCOUNT="${MACCHANNEL_TEST_SPARKLE_ACCOUNT:-$account}" \
        MACCHANNEL_SPARKLE_GENERATE_APPCAST="${MACCHANNEL_TEST_GENERATE_APPCAST:-$generate_appcast}" \
        MACCHANNEL_UPDATE_TESTING="$testing" \
        MACCHANNEL_UPDATE_TEST_ROOT="$test_root_value" \
        MACCHANNEL_UPDATE_TEST_DIST_ROOT="$test_dist_value" \
        MACCHANNEL_UPDATE_TEST_FAIL_STAGE="${MACCHANNEL_TEST_FAIL_STAGE:-}" \
        MACCHANNEL_UPDATE_TEST_MUTATION="${MACCHANNEL_TEST_MUTATION:-}" \
        MACCHANNEL_UPDATE_SECURITY_COMMAND="${MACCHANNEL_TEST_SECURITY_COMMAND:-$security_shim}" \
        MACCHANNEL_UPDATE_CODESIGN_COMMAND="${MACCHANNEL_TEST_CODESIGN_COMMAND:-}" \
        MACCHANNEL_UPDATE_STAPLER_COMMAND="${MACCHANNEL_TEST_STAPLER_COMMAND:-$stapler_shim}" \
        MACCHANNEL_UPDATE_SPCTL_COMMAND="${MACCHANNEL_TEST_SPCTL_COMMAND:-$spctl_shim}" \
        MACCHANNEL_UPDATE_TEST_ED_KEY_FILE="$ed_key_file" \
        MACCHANNEL_UPDATE_TEST_PUBLIC_KEY_PATH="$public_key_path" \
        MACCHANNEL_UPDATE_TEST_KEY_ACCESS_MARKER="${MACCHANNEL_TEST_KEY_ACCESS_MARKER:-$key_access_marker}" \
        MACCHANNEL_UPDATE_VALIDATOR_MARKER="$validator_marker" \
        MACCHANNEL_UPDATE_VALIDATOR_FAIL="${MACCHANNEL_TEST_VALIDATOR_FAIL:-}" \
        MACCHANNEL_SECURITY_SHIM_MARKER="${MACCHANNEL_TEST_SECURITY_MARKER:-}" \
        MACCHANNEL_SECURITY_SHIM_NOISE="${MACCHANNEL_TEST_SECURITY_NOISE:-}" \
        MACCHANNEL_SECURITY_SHIM_LOGIN_KEYCHAIN="$fake_login_keychain" \
        MACCHANNEL_CODESIGN_FIXTURE_VERIFY="${MACCHANNEL_TEST_CODESIGN_VERIFY:-pass}" \
        MACCHANNEL_CODESIGN_FIXTURE_ANCHOR_MATCH="${MACCHANNEL_TEST_CODESIGN_ANCHOR_MATCH:-pass}" \
        MACCHANNEL_CODESIGN_FIXTURE_CERT_CLASS="${MACCHANNEL_TEST_CODESIGN_CERT_CLASS:-developer-id-application}" \
        MACCHANNEL_CODESIGN_FIXTURE_ANCHOR_MARKER="${MACCHANNEL_TEST_ANCHOR_MARKER:-}" \
        MACCHANNEL_CODESIGN_FIXTURE_POST_MOUNT_MARKER="${MACCHANNEL_TEST_POST_MOUNT_MARKER:-}" \
        MACCHANNEL_CODESIGN_FIXTURE_BUNDLE_ID="${MACCHANNEL_TEST_CODESIGN_BUNDLE_ID:-com.mason.macchannel}" \
        MACCHANNEL_CODESIGN_FIXTURE_TEAM_ID="${MACCHANNEL_TEST_CODESIGN_TEAM_ID:-$fixture_team_id}" \
        MACCHANNEL_CODESIGN_FIXTURE_REQUIREMENT="${MACCHANNEL_TEST_CODESIGN_REQUIREMENT:-$fixture_requirement}" \
        bash Scripts/build-update-feed.sh
}

expect_unvalidated_input_failure() {
    local input_name="$1"
    local hostile_value="$2"
    prepare_fixture
    printf '%s\n' stale-feed >"$test_dist/appcast.xml"
    printf '%s\n' stale-pending >"$test_dist/.appcast.xml.new"
    set +e
    if [[ "$input_name" == version ]]; then
        MACCHANNEL_TEST_VERSION="$hostile_value" run_feed_builder \
            >"$test_root/hostile-$input_name.log" 2>&1
    else
        MACCHANNEL_TEST_BUILD_NUMBER="$hostile_value" run_feed_builder \
            >"$test_root/hostile-$input_name.log" 2>&1
    fi
    local actual_status=$?
    set -e
    [[ "$actual_status" -eq 2 ]]
    grep -Fx 'update-feed failure stage=input version=unvalidated build=unvalidated' \
        "$test_root/hostile-$input_name.log" >/dev/null
    test "$(wc -l <"$test_root/hostile-$input_name.log" | tr -d ' ')" = 1
    if grep -F "$hostile_value" "$test_root/hostile-$input_name.log" >/dev/null; then
        echo "unvalidated release identity leaked into failure output" >&2
        exit 1
    fi
    assert_redacted_output "$test_root/hostile-$input_name.log"
    [[ ! -e "$test_dist/appcast.xml" && ! -L "$test_dist/appcast.xml" ]]
    [[ ! -e "$test_dist/.appcast.xml.new" && ! -L "$test_dist/.appcast.xml.new" ]]
}

assert_redacted_output() {
    local output_path="$1"
    local release_note_text='此版本包含安全更新与稳定性改进。'
    for forbidden in "$repo_root" "$test_root" "$release_note_text" \
        DropMesh.dmg DropMesh.manifest.json appcast.xml .appcast.xml.new; do
        if grep -F "$forbidden" "$output_path" >/dev/null; then
            echo "release output exposed prohibited metadata" >&2
            exit 1
        fi
    done
}

expect_failure() {
    local expected_stage="$1"
    shift
    printf '%s\n' stale-feed >"$test_dist/appcast.xml"
    printf '%s\n' stale-pending >"$test_dist/.appcast.xml.new"
    set +e
    "$@" >"$test_root/expected-failure.log" 2>&1
    local actual_status=$?
    set -e
    if [[ "$actual_status" -eq 0 ]]; then
        echo "expected feed build to fail at stage $expected_stage case=${MACCHANNEL_EXPECT_LABEL:-unspecified}" >&2
        exit 1
    fi
    if [[ -e "$test_dist/appcast.xml" || -L "$test_dist/appcast.xml" || \
        -e "$test_dist/.appcast.xml.new" || -L "$test_dist/.appcast.xml.new" ]]; then
        echo "failed feed build left a published appcast" >&2
        exit 1
    fi
    local expected_version="${MACCHANNEL_TEST_VERSION:-$version}"
    local expected_build="${MACCHANNEL_TEST_BUILD_NUMBER:-$build_number}"
    grep -Fx "update-feed failure stage=$expected_stage version=$expected_version build=$expected_build" \
        "$test_root/expected-failure.log" >/dev/null
    test "$(wc -l <"$test_root/expected-failure.log" | tr -d ' ')" = 1
    assert_redacted_output "$test_root/expected-failure.log"
}

assert_pre_key_identity_failure() {
    local label="$1"
    rm -f "$key_access_marker" "$validator_marker"
    MACCHANNEL_EXPECT_LABEL="$label" expect_failure identity run_feed_builder
    [[ ! -e "$key_access_marker" ]]
    [[ ! -e "$test_dist/appcast.xml" && ! -e "$test_dist/.appcast.xml.new" ]]
    test -z "$(find "$test_root" -maxdepth 1 -type d \
        -name 'macchannel-update-identity.*' -print -quit)"
}

prepare_fixture
mv "$test_dist/DropMesh.dmg" "$test_root/missing.dmg"
expect_failure assets run_feed_builder

hostile_payload="$repo_root/DropMesh.dmg"$'\n''此版本包含安全更新与稳定性改进。'$'\033[31m$(touch /tmp/never-run)\001'
expect_unvalidated_input_failure version "$hostile_payload"
expect_unvalidated_input_failure build_number "$hostile_payload"

prepare_fixture
plutil -replace releaseState -string internalSignedNotNotarized \
    "$test_dist/DropMesh.manifest.json"
expect_failure manifest run_feed_builder

prepare_fixture
MACCHANNEL_TEST_VERSION=1.2.3 expect_failure manifest run_feed_builder
prepare_fixture
MACCHANNEL_TEST_BUILD_NUMBER=16 expect_failure manifest run_feed_builder

prepare_fixture
plutil -replace dmgSHA256 -string \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    "$test_dist/DropMesh.manifest.json"
expect_failure manifest run_feed_builder

# RED on the vulnerable standalone feed builder: releaseState was only unsigned
# metadata, so a repackaged container around the genuine production-anchored App
# reached the Sparkle private-key boundary when its forged manifest hash agreed.
prepare_fixture
unsigned_stage="$test_root/repackaged-unsigned-stage"
mkdir -p "$unsigned_stage"
ditto "$fixture_root/app/MacChannel.app" "$unsigned_stage/MacChannel.app"
clean_fixture_tool hdiutil create -srcfolder "$unsigned_stage" -volname DropMesh -fs HFS+ \
    -format UDZO -ov "$test_dist/DropMesh.dmg" >/dev/null
plutil -replace dmgSHA256 -string \
    "$(shasum -a 256 "$test_dist/DropMesh.dmg" | awk '{print $1}')" \
    "$test_dist/DropMesh.manifest.json"
assert_pre_key_identity_failure repackaged-unsigned-dmg

prepare_fixture
clean_signing_tool /usr/bin/codesign --force --sign - \
    "$test_dist/DropMesh.dmg" >/dev/null 2>&1
plutil -replace dmgSHA256 -string \
    "$(shasum -a 256 "$test_dist/DropMesh.dmg" | awk '{print $1}')" \
    "$test_dist/DropMesh.manifest.json"
assert_pre_key_identity_failure non-production-team-dmg

for validator_failure in stapler gatekeeper; do
    prepare_fixture
    rm -f "$key_access_marker" "$validator_marker"
    MACCHANNEL_TEST_VALIDATOR_FAIL="$validator_failure" \
    MACCHANNEL_EXPECT_LABEL="$validator_failure" \
        expect_failure identity run_feed_builder
    [[ ! -e "$key_access_marker" ]]
    test -f "$validator_marker"
    test -z "$(find "$test_root" -maxdepth 1 -type d \
        -name 'macchannel-update-identity.*' -print -quit)"
done

prepare_fixture
MACCHANNEL_TEST_RELEASE_NOTES="$test_root/missing.md" expect_failure input run_feed_builder
prepare_fixture
MACCHANNEL_TEST_SPARKLE_ACCOUNT=com.mason.macchannel.missing \
    expect_failure account run_feed_builder

prepare_fixture
set +e
MACCHANNEL_TEST_SECURITY_COMMAND="$security_shim" MACCHANNEL_TESTING=0 \
    run_feed_builder >"$test_root/unguarded-feed-seam.log" 2>&1
unguarded_feed_status=$?
set -e
[[ "$unguarded_feed_status" -eq 2 ]]
grep -Fx "update-feed failure stage=test version=$version build=$build_number" \
    "$test_root/unguarded-feed-seam.log" >/dev/null
[[ ! -e "$repo_root/dist/DropMesh.dmg" || "$formal_dist_before" != absent ]]

prepare_fixture
security_marker="$test_root/security-shim-called"
security_noise="$repo_root/DropMesh.dmg 此版本包含安全更新与稳定性改进。"
MACCHANNEL_TESTING=1 \
MACCHANNEL_TEST_USE_DISPOSABLE_KEY=0 \
MACCHANNEL_TEST_SECURITY_COMMAND="$security_shim" \
MACCHANNEL_TEST_SECURITY_MARKER="$security_marker" \
MACCHANNEL_TEST_SECURITY_NOISE="$security_noise" \
MACCHANNEL_EXPECT_LABEL=missing-test-key \
    expect_failure test run_feed_builder
[[ ! -e "$security_marker" ]]

prepare_fixture
MACCHANNEL_TEST_ED_KEY_FILE_OVERRIDE="$repo_root/Distribution/SparklePublicKey.txt" \
MACCHANNEL_TEST_PUBLIC_KEY_PATH_OVERRIDE="$repo_root/Distribution/SparklePublicKey.txt" \
MACCHANNEL_EXPECT_LABEL=external-test-key \
    expect_failure test run_feed_builder

prepare_fixture
MACCHANNEL_TEST_SECURITY_COMMAND="$repo_root/Tests/Fixtures/security-missing-key.sh" \
MACCHANNEL_EXPECT_LABEL=external-security-shim \
    expect_failure test run_feed_builder

for external_validator in stapler spctl; do
    prepare_fixture
    if [[ "$external_validator" == stapler ]]; then
        MACCHANNEL_TEST_STAPLER_COMMAND=/usr/bin/xcrun \
        MACCHANNEL_EXPECT_LABEL=external-stapler-shim \
            expect_failure test run_feed_builder
    else
        MACCHANNEL_TEST_SPCTL_COMMAND=/usr/sbin/spctl \
        MACCHANNEL_EXPECT_LABEL=external-spctl-shim \
            expect_failure test run_feed_builder
    fi
done

prepare_fixture
MACCHANNEL_TEST_KEY_ACCESS_MARKER="$repo_root/private-key-access.marker" \
MACCHANNEL_EXPECT_LABEL=external-key-access-marker \
    expect_failure test run_feed_builder
[[ ! -e "$repo_root/private-key-access.marker" ]]

prepare_fixture
wrong_team=WRONGTEAM2
wrong_requirement='identifier "com.mason.macchannel" and anchor apple generic and certificate leaf[subject.OU] = "WRONGTEAM2"'
plutil -replace teamID -string "$wrong_team" "$test_dist/DropMesh.manifest.json"
plutil -replace designatedRequirement -string "$wrong_requirement" \
    "$test_dist/DropMesh.manifest.json"
pre_key_marker="$test_root/wrong-team-key-accessed"
MACCHANNEL_TEST_SECURITY_COMMAND="$security_shim" \
MACCHANNEL_TEST_SECURITY_MARKER="$pre_key_marker" \
MACCHANNEL_TEST_CODESIGN_TEAM_ID="$wrong_team" \
MACCHANNEL_TEST_CODESIGN_REQUIREMENT="$wrong_requirement" \
MACCHANNEL_TEST_CODESIGN_ANCHOR_MATCH=fail \
    expect_failure manifest run_feed_builder
[[ ! -e "$pre_key_marker" ]]
prepare_fixture
MACCHANNEL_TEST_CODESIGN_COMMAND="$codesign_shim" \
MACCHANNEL_TEST_CODESIGN_REQUIREMENT='identifier "com.mason.macchannel" and anchor apple generic and certificate leaf[subject.OU] = "TESTTEAM01" and true' \
MACCHANNEL_TEST_CODESIGN_ANCHOR_MATCH=fail \
    expect_failure identity run_feed_builder

prepare_fixture
development_anchor_marker="$test_root/apple-development-anchor-checked"
development_key_marker="$test_root/apple-development-key-accessed"
MACCHANNEL_TEST_CODESIGN_COMMAND="$codesign_shim" \
MACCHANNEL_TEST_CODESIGN_CERT_CLASS=apple-development \
MACCHANNEL_TEST_ANCHOR_MARKER="$development_anchor_marker" \
MACCHANNEL_TEST_SECURITY_MARKER="$development_key_marker" \
    expect_failure identity run_feed_builder
test -f "$development_anchor_marker"
[[ ! -e "$development_key_marker" ]]

rebuild_fixture_dmg() {
    local field=${1:-} value=${2:-}
    local variant_root="$test_root/post-mount-variant"
    if [[ -d "$variant_root" ]]; then
        find "$variant_root" -depth -delete
    fi
    mkdir -p "$variant_root/app"
    ditto "$fixture_root/app/MacChannel.app" "$variant_root/app/MacChannel.app"
    local variant_plist="$variant_root/app/MacChannel.app/Contents/Info.plist"
    case "$field" in
        '') ;;
        bundle) plutil -replace CFBundleIdentifier -string "$value" "$variant_plist" ;;
        version) plutil -replace CFBundleShortVersionString -string "$value" "$variant_plist" ;;
        build) plutil -replace CFBundleVersion -string "$value" "$variant_plist" ;;
        *) return 64 ;;
    esac
    clean_fixture_tool hdiutil create -srcfolder "$variant_root/app" -volname "DropMesh" -fs HFS+ \
        -format UDZO -ov "$fixture_dmg" >/dev/null
    clean_signing_tool /usr/bin/codesign --force --sign "$primary_identity" --timestamp=none \
        "$fixture_dmg" >/dev/null 2>&1
    plutil -replace dmgSHA256 -string \
        "$(shasum -a 256 "$fixture_dmg" | awk '{print $1}')" "$fixture_manifest"
}

expect_post_mount_identity_failure() {
    local name=$1 field=$2 value=$3 actual_bundle=$4 actual_team=$5 actual_requirement=$6
    rebuild_fixture_dmg "$field" "$value"
    prepare_fixture
    local post_mount_marker="$test_root/post-mount-$name-reached"
    local key_marker="$test_root/post-mount-$name-key-accessed"
    MACCHANNEL_TEST_POST_MOUNT_MARKER="$post_mount_marker" \
    MACCHANNEL_TEST_SECURITY_MARKER="$key_marker" \
    MACCHANNEL_TEST_CODESIGN_COMMAND="$codesign_shim" \
    MACCHANNEL_TEST_CODESIGN_BUNDLE_ID="$actual_bundle" \
    MACCHANNEL_TEST_CODESIGN_TEAM_ID="$actual_team" \
    MACCHANNEL_TEST_CODESIGN_REQUIREMENT="$actual_requirement" \
        expect_failure identity run_feed_builder
    test -f "$post_mount_marker"
    [[ ! -e "$key_marker" ]]
    test -z "$(find "$test_root" -maxdepth 1 -type d -name 'macchannel-update-identity.*' -print -quit)"
}

expect_post_mount_identity_failure bundle bundle com.mason.macchannel.wrong \
    com.mason.macchannel.wrong "$fixture_team_id" "$fixture_requirement"
expect_post_mount_identity_failure version version 9.9.9 \
    com.mason.macchannel "$fixture_team_id" "$fixture_requirement"
expect_post_mount_identity_failure build build 999 \
    com.mason.macchannel "$fixture_team_id" "$fixture_requirement"
expect_post_mount_identity_failure team '' '' \
    com.mason.macchannel WRONGTEAM2 "$fixture_requirement"
expect_post_mount_identity_failure requirement '' '' \
    com.mason.macchannel "$fixture_team_id" "$fixture_requirement and true"
rebuild_fixture_dmg

prepare_fixture
MACCHANNEL_TEST_CODESIGN_TEAM_ID="$fixture_team_id" \
MACCHANNEL_TEST_CODESIGN_REQUIREMENT="$fixture_requirement" \
    run_feed_builder >"$test_root/same-team-success.log" 2>&1
grep -Fx "update-feed success version=$version build=$build_number" \
    "$test_root/same-team-success.log" >/dev/null
assert_redacted_output "$test_root/same-team-success.log"
prepare_fixture
MACCHANNEL_TEST_GENERATE_APPCAST="$repo_root/.build/tools/Sparkle-2.9.6/bin/sign_update" \
    expect_failure tool run_feed_builder

prepare_fixture
MACCHANNEL_TESTING=1 MACCHANNEL_TEST_FAIL_STAGE=after-generate \
    expect_failure generate run_feed_builder

for mutation in repo-path updates-path release-notes-path account developer-id file-url; do
    prepare_fixture
    MACCHANNEL_TESTING=1 MACCHANNEL_TEST_MUTATION="$mutation" \
        expect_failure metadata run_feed_builder
done

prepare_fixture
run_feed_builder >"$test_root/success.log" 2>&1
grep -Fx "update-feed success version=$version build=$build_number" \
    "$test_root/success.log" >/dev/null
assert_redacted_output "$test_root/success.log"

test -f "$test_dist/appcast.xml"
xmllint --noout "$test_dist/appcast.xml"

version_value="$(xmllint --xpath \
    'string(//*[local-name()="item"][1]/*[local-name()="version"])' \
    "$test_dist/appcast.xml")"
short_value="$(xmllint --xpath \
    'string(//*[local-name()="item"][1]/*[local-name()="shortVersionString"])' \
    "$test_dist/appcast.xml")"
enclosure_url="$(xmllint --xpath \
    'string(//*[local-name()="item"][1]/*[local-name()="enclosure"]/@url)' \
    "$test_dist/appcast.xml")"
enclosure_length="$(xmllint --xpath \
    'string(//*[local-name()="item"][1]/*[local-name()="enclosure"]/@length)' \
    "$test_dist/appcast.xml")"
enclosure_signature="$(xmllint --xpath \
    'string(//*[local-name()="item"][1]/*[local-name()="enclosure"]/@*[local-name()="edSignature"])' \
    "$test_dist/appcast.xml")"
description_value="$(xmllint --xpath \
    'string(//*[local-name()="item"][1]/*[local-name()="description"])' \
    "$test_dist/appcast.xml")"
channel_title="$(xmllint --xpath \
    'string(//*[local-name()="channel"]/*[local-name()="title"])' \
    "$test_dist/appcast.xml")"

test "$version_value" = "$build_number"
test "$short_value" = "$version"
test "$channel_title" = DropMesh
test "$enclosure_url" = \
    "https://github.com/MasonXQY/MacChannel/releases/download/v$version/DropMesh.dmg"
test "$enclosure_length" = "$(stat -f %z "$test_dist/DropMesh.dmg")"
test -n "$enclosure_signature"
grep -F "重新配对时出现单边成功" <<<"$description_value" >/dev/null
grep -F "releases/download/v$version/DropMesh.dmg" "$test_dist/appcast.xml" >/dev/null
grep -F 'sparkle:edSignature=' "$test_dist/appcast.xml" >/dev/null
grep -F '<!-- sparkle-signatures:' "$test_dist/appcast.xml" >/dev/null
grep -F 'edSignature: ' "$test_dist/appcast.xml" >/dev/null

test "$(shasum -a 256 "$test_dist/DropMesh.dmg" | awk '{print $1}')" = \
    "$(plutil -extract dmgSHA256 raw -o - "$test_dist/DropMesh.manifest.json")"
test "$(plutil -extract version raw -o - "$test_dist/DropMesh.manifest.json")" = "$version"
test "$(plutil -extract build raw -o - "$test_dist/DropMesh.manifest.json")" = "$build_number"
test "$(plutil -extract releaseState raw -o - "$test_dist/DropMesh.manifest.json")" = notarized
test "$(plutil -extract product raw -o - "$test_dist/DropMesh.manifest.json")" = DropMesh

for forbidden_metadata in \
    "$repo_root" \
    "$test_root" \
    "$account" \
    'Developer ID Application:' \
    'file://'; do
    if grep -F "$forbidden_metadata" "$test_dist/appcast.xml" >/dev/null; then
        echo "appcast contains sensitive metadata: $forbidden_metadata" >&2
        exit 1
    fi
done

assert_exact_release_assets() {
    for required in DropMesh.dmg DropMesh.manifest.json appcast.xml; do
        [[ -f "$test_dist/$required" && ! -L "$test_dist/$required" ]] || return 1
    done
    local actual
    actual="$(find "$test_dist" -mindepth 1 -maxdepth 1 -exec basename {} \; | LC_ALL=C sort)"
    [[ "$actual" == $'DropMesh.dmg\nDropMesh.manifest.json\nappcast.xml' ]]
}
assert_exact_release_assets

expect_asset_contract_failure() {
    if assert_exact_release_assets; then
        echo "asset contract accepted an extra or non-regular entry" >&2
        exit 1
    fi
}
mkdir "$test_dist/extra-directory"
expect_asset_contract_failure
rmdir "$test_dist/extra-directory"
ln -s DropMesh.dmg "$test_dist/extra-link"
expect_asset_contract_failure
rm "$test_dist/extra-link"
mkfifo "$test_dist/extra-fifo"
expect_asset_contract_failure
rm "$test_dist/extra-fifo"
mv "$test_dist/appcast.xml" "$test_root/regular-appcast.xml"
ln -s "$test_root/regular-appcast.xml" "$test_dist/appcast.xml"
expect_asset_contract_failure
rm "$test_dist/appcast.xml"
mv "$test_root/regular-appcast.xml" "$test_dist/appcast.xml"
assert_exact_release_assets

# Exercise build-distribution.sh's guarded notarized-assets handoff into the real
# feed builder without invoking Apple's live notary service.
rm -f "$test_dist/DropMesh.dmg" "$test_dist/DropMesh.manifest.json" \
    "$test_dist/appcast.xml" "$test_dist/.appcast.xml.new"
printf '%s\n' legacy-dmg >"$test_dist/MacChannel.dmg"
printf '%s\n' legacy-manifest >"$test_dist/MacChannel.manifest.json"
env -i PATH="$PATH" HOME="$test_root/home" TMPDIR="$test_root/" LANG=C LC_ALL=C \
    MACCHANNEL_UPDATE_TESTING=1 \
    MACCHANNEL_UPDATE_TEST_ROOT="$test_root" \
    MACCHANNEL_UPDATE_TEST_DIST_ROOT="$test_dist" \
    MACCHANNEL_UPDATE_TEST_FIXTURE_ROOT="$fixture_root" \
    MACCHANNEL_UPDATE_SECURITY_COMMAND="$security_shim" \
    MACCHANNEL_UPDATE_CODESIGN_COMMAND="$codesign_shim" \
    MACCHANNEL_UPDATE_STAPLER_COMMAND="$stapler_shim" \
    MACCHANNEL_UPDATE_SPCTL_COMMAND="$spctl_shim" \
    MACCHANNEL_UPDATE_TEST_ED_KEY_FILE="$test_private_key" \
    MACCHANNEL_UPDATE_TEST_PUBLIC_KEY_PATH="$test_public_key" \
    MACCHANNEL_UPDATE_TEST_KEY_ACCESS_MARKER="$key_access_marker" \
    MACCHANNEL_UPDATE_VALIDATOR_MARKER="$validator_marker" \
    MACCHANNEL_CODESIGN_FIXTURE_VERIFY=pass \
    MACCHANNEL_CODESIGN_FIXTURE_ANCHOR_MATCH=pass \
    MACCHANNEL_CODESIGN_FIXTURE_BUNDLE_ID=com.mason.macchannel \
    MACCHANNEL_CODESIGN_FIXTURE_TEAM_ID="$fixture_team_id" \
    MACCHANNEL_CODESIGN_FIXTURE_REQUIREMENT="$fixture_requirement" \
    MACCHANNEL_RELEASE_NOTES="$release_notes" \
    MACCHANNEL_VERSION="$version" \
    MACCHANNEL_BUILD_NUMBER="$build_number" \
    bash Scripts/build-distribution.sh >"$test_root/handoff-success.log" 2>&1
assert_redacted_output "$test_root/handoff-success.log"
grep -Fx "update-feed success version=$version build=$build_number" \
    "$test_root/handoff-success.log" >/dev/null
grep -Fx "distribution success state=notarized version=$version build=$build_number" \
    "$test_root/handoff-success.log" >/dev/null
[[ ! -e "$test_dist/MacChannel.dmg" && ! -L "$test_dist/MacChannel.dmg" ]]
[[ ! -e "$test_dist/MacChannel.manifest.json" && \
    ! -L "$test_dist/MacChannel.manifest.json" ]]
assert_exact_release_assets

handoff_dmg_sha="$(shasum -a 256 "$test_dist/DropMesh.dmg" | awk '{print $1}')"
handoff_manifest_sha="$(shasum -a 256 "$test_dist/DropMesh.manifest.json" | awk '{print $1}')"
printf '%s\n' stale-feed >"$test_dist/appcast.xml"
printf '%s\n' stale-pending >"$test_dist/.appcast.xml.new"
set +e
env -i PATH="$PATH" HOME="$test_root/home" TMPDIR="$test_root/" LANG=C LC_ALL=C \
    MACCHANNEL_UPDATE_TESTING=1 \
    MACCHANNEL_UPDATE_TEST_ROOT="$test_root" \
    MACCHANNEL_UPDATE_TEST_DIST_ROOT="$test_dist" \
    MACCHANNEL_UPDATE_TEST_FIXTURE_ROOT="$fixture_root" \
    MACCHANNEL_UPDATE_SECURITY_COMMAND="$security_shim" \
    MACCHANNEL_UPDATE_CODESIGN_COMMAND="$codesign_shim" \
    MACCHANNEL_UPDATE_STAPLER_COMMAND="$stapler_shim" \
    MACCHANNEL_UPDATE_SPCTL_COMMAND="$spctl_shim" \
    MACCHANNEL_UPDATE_TEST_ED_KEY_FILE="$test_private_key" \
    MACCHANNEL_UPDATE_TEST_PUBLIC_KEY_PATH="$test_public_key" \
    MACCHANNEL_UPDATE_TEST_KEY_ACCESS_MARKER="$key_access_marker" \
    MACCHANNEL_UPDATE_VALIDATOR_MARKER="$validator_marker" \
    MACCHANNEL_CODESIGN_FIXTURE_VERIFY=pass \
    MACCHANNEL_CODESIGN_FIXTURE_ANCHOR_MATCH=pass \
    MACCHANNEL_CODESIGN_FIXTURE_BUNDLE_ID=com.mason.macchannel \
    MACCHANNEL_CODESIGN_FIXTURE_TEAM_ID="$fixture_team_id" \
    MACCHANNEL_CODESIGN_FIXTURE_REQUIREMENT="$fixture_requirement" \
    MACCHANNEL_UPDATE_TEST_FAIL_STAGE=after-verify \
    MACCHANNEL_RELEASE_NOTES="$release_notes" \
    MACCHANNEL_VERSION="$version" \
    MACCHANNEL_BUILD_NUMBER="$build_number" \
    bash Scripts/build-distribution.sh >"$test_root/handoff-failure.log" 2>&1
handoff_status=$?
set -e
[[ "$handoff_status" -ne 0 ]]
assert_redacted_output "$test_root/handoff-failure.log"
grep -Fx "update-feed failure stage=test version=$version build=$build_number" \
    "$test_root/handoff-failure.log" >/dev/null
[[ -f "$test_dist/DropMesh.dmg" && ! -L "$test_dist/DropMesh.dmg" ]]
[[ -f "$test_dist/DropMesh.manifest.json" && ! -L "$test_dist/DropMesh.manifest.json" ]]
test "$handoff_dmg_sha" = "$(shasum -a 256 "$test_dist/DropMesh.dmg" | awk '{print $1}')"
test "$handoff_manifest_sha" = \
    "$(shasum -a 256 "$test_dist/DropMesh.manifest.json" | awk '{print $1}')"
[[ ! -e "$test_dist/appcast.xml" && ! -L "$test_dist/appcast.xml" ]]
[[ ! -e "$test_dist/.appcast.xml.new" && ! -L "$test_dist/.appcast.xml.new" ]]

set +e
env -i PATH="$PATH" HOME="$test_root/home" TMPDIR="$test_root/" LANG=C LC_ALL=C \
    MACCHANNEL_UPDATE_TEST_FIXTURE_ROOT="$fixture_root" \
    MACCHANNEL_RELEASE_NOTES="$release_notes" \
    bash Scripts/build-distribution.sh >"$test_root/unguarded-seam.log" 2>&1
unguarded_status=$?
set -e
[[ "$unguarded_status" -ne 0 ]]
grep -F 'update fixture seams require MACCHANNEL_UPDATE_TESTING=1' \
    "$test_root/unguarded-seam.log" >/dev/null

prepare_fixture
run_feed_builder >"$test_root/post-handoff-success.log" 2>&1
assert_redacted_output "$test_root/post-handoff-success.log"
assert_exact_release_assets

cp "$test_dist/appcast.xml" "$test_root/first-appcast.xml"
run_feed_builder >"$test_root/repeat-success.log" 2>&1
assert_redacted_output "$test_root/repeat-success.log"
cmp "$test_root/first-appcast.xml" "$test_dist/appcast.xml"
test "$(shasum -a 256 "$release_notes" | awk '{print $1}')" = \
    "$release_notes_sha_before"

echo "update feed PASS"
