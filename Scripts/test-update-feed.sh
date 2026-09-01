#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repo_root"

if [[ ! -x Scripts/build-update-feed.sh ]]; then
    echo "Scripts/build-update-feed.sh is missing or not executable" >&2
    exit 1
fi

version=1.2.0
build_number=13
account=com.mason.macchannel.updates
generate_appcast="$repo_root/.build/tools/Sparkle-2.9.6/bin/generate_appcast"
public_key="$(tr -d '\r\n' <Distribution/SparklePublicKey.txt)"

test_root="$(mktemp -d "${TMPDIR:-/tmp}/macchannel-update-feed-test.XXXXXX")"
fixture_root="$test_root/fixture"
fixture_dmg="$fixture_root/MacChannel.dmg"
fixture_manifest="$fixture_root/MacChannel.manifest.json"
release_notes="$repo_root/Distribution/ReleaseNotes/v1.2.0.md"
security_shim="$test_root/security-missing-key"

cleanup() {
    [[ "${MACCHANNEL_TEST_KEEP_TEMP:-0}" == 1 ]] || rm -rf "$test_root"
    rm -f dist/MacChannel.dmg dist/MacChannel.manifest.json dist/appcast.xml \
        dist/.appcast.xml.new
}
trap cleanup EXIT

mkdir -p "$fixture_root/app"
chmod 700 "$test_root" "$fixture_root"
cp Tests/Fixtures/security-missing-key.sh "$security_shim"
chmod 700 "$security_shim"
ditto ".build/tools/Sparkle-2.9.6/Sparkle Test App.app" \
    "$fixture_root/app/MacChannel.app"
fixture_plist="$fixture_root/app/MacChannel.app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string com.mason.macchannel "$fixture_plist"
plutil -replace CFBundleShortVersionString -string "$version" "$fixture_plist"
plutil -replace CFBundleVersion -string "$build_number" "$fixture_plist"
plutil -replace SUPublicEDKey -string "$public_key" "$fixture_plist"
plutil -replace SURequireSignedFeed -bool true "$fixture_plist"
codesign --remove-signature "$fixture_root/app/MacChannel.app" >/dev/null 2>&1 || true
hdiutil create \
    -srcfolder "$fixture_root/app" \
    -volname "Mac 通道" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$fixture_dmg" >/dev/null

if [[ ! -s "$release_notes" ]]; then
    echo "tracked Chinese release notes are missing" >&2
    exit 1
fi
release_notes_sha_before="$(shasum -a 256 "$release_notes" | awk '{print $1}')"

dmg_sha="$(shasum -a 256 "$fixture_dmg" | awk '{print $1}')"
plutil -create xml1 "$fixture_manifest"
plutil -insert product -string MacChannel "$fixture_manifest"
plutil -insert version -string "$version" "$fixture_manifest"
plutil -insert build -string "$build_number" "$fixture_manifest"
plutil -insert releaseState -string notarized "$fixture_manifest"
plutil -insert dmgSHA256 -string "$dmg_sha" "$fixture_manifest"
plutil -convert json "$fixture_manifest"

prepare_fixture() {
    mkdir -p dist
    chmod 700 dist
    cp "$fixture_dmg" dist/MacChannel.dmg
    cp "$fixture_manifest" dist/MacChannel.manifest.json
    rm -f dist/appcast.xml dist/.appcast.xml.new
}

run_feed_builder() {
    env \
        MACCHANNEL_VERSION="${MACCHANNEL_TEST_VERSION:-$version}" \
        MACCHANNEL_BUILD_NUMBER="${MACCHANNEL_TEST_BUILD_NUMBER:-$build_number}" \
        MACCHANNEL_RELEASE_NOTES="${MACCHANNEL_TEST_RELEASE_NOTES:-$release_notes}" \
        MACCHANNEL_SPARKLE_ACCOUNT="${MACCHANNEL_TEST_SPARKLE_ACCOUNT:-$account}" \
        MACCHANNEL_SPARKLE_GENERATE_APPCAST="${MACCHANNEL_TEST_GENERATE_APPCAST:-$generate_appcast}" \
        MACCHANNEL_UPDATE_TESTING="${MACCHANNEL_TESTING:-0}" \
        MACCHANNEL_UPDATE_TEST_FAIL_STAGE="${MACCHANNEL_TEST_FAIL_STAGE:-}" \
        MACCHANNEL_UPDATE_TEST_MUTATION="${MACCHANNEL_TEST_MUTATION:-}" \
        MACCHANNEL_UPDATE_SECURITY_COMMAND="${MACCHANNEL_TEST_SECURITY_COMMAND:-}" \
        MACCHANNEL_SECURITY_SHIM_MARKER="${MACCHANNEL_TEST_SECURITY_MARKER:-}" \
        MACCHANNEL_SECURITY_SHIM_NOISE="${MACCHANNEL_TEST_SECURITY_NOISE:-}" \
        bash Scripts/build-update-feed.sh
}

expect_unvalidated_input_failure() {
    local input_name="$1"
    local hostile_value="$2"
    prepare_fixture
    printf '%s\n' stale-feed >dist/appcast.xml
    printf '%s\n' stale-pending >dist/.appcast.xml.new
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
    [[ ! -e dist/appcast.xml && ! -L dist/appcast.xml ]]
    [[ ! -e dist/.appcast.xml.new && ! -L dist/.appcast.xml.new ]]
}

assert_redacted_output() {
    local output_path="$1"
    local release_note_text='此版本包含安全更新与稳定性改进。'
    for forbidden in "$repo_root" "$test_root" "$release_note_text" \
        MacChannel.dmg MacChannel.manifest.json appcast.xml .appcast.xml.new; do
        if grep -F "$forbidden" "$output_path" >/dev/null; then
            echo "release output exposed prohibited metadata" >&2
            exit 1
        fi
    done
}

expect_failure() {
    local expected_stage="$1"
    shift
    printf '%s\n' stale-feed >dist/appcast.xml
    printf '%s\n' stale-pending >dist/.appcast.xml.new
    set +e
    "$@" >"$test_root/expected-failure.log" 2>&1
    local actual_status=$?
    set -e
    if [[ "$actual_status" -eq 0 ]]; then
        echo "expected feed build to fail" >&2
        exit 1
    fi
    if [[ -e dist/appcast.xml || -L dist/appcast.xml || \
        -e dist/.appcast.xml.new || -L dist/.appcast.xml.new ]]; then
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

prepare_fixture
mv dist/MacChannel.dmg "$test_root/missing.dmg"
expect_failure assets run_feed_builder

hostile_payload="$repo_root/MacChannel.dmg"$'\n''此版本包含安全更新与稳定性改进。'$'\033[31m$(touch /tmp/never-run)\001'
expect_unvalidated_input_failure version "$hostile_payload"
expect_unvalidated_input_failure build_number "$hostile_payload"

prepare_fixture
plutil -replace releaseState -string internalSignedNotNotarized \
    dist/MacChannel.manifest.json
expect_failure manifest run_feed_builder

prepare_fixture
MACCHANNEL_TEST_VERSION=1.2.1 expect_failure manifest run_feed_builder
prepare_fixture
MACCHANNEL_TEST_BUILD_NUMBER=14 expect_failure manifest run_feed_builder

prepare_fixture
plutil -replace dmgSHA256 -string \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    dist/MacChannel.manifest.json
expect_failure manifest run_feed_builder

prepare_fixture
MACCHANNEL_TEST_RELEASE_NOTES="$test_root/missing.md" expect_failure input run_feed_builder
prepare_fixture
MACCHANNEL_TEST_SPARKLE_ACCOUNT=com.mason.macchannel.missing \
    expect_failure account run_feed_builder

prepare_fixture
MACCHANNEL_TEST_SECURITY_COMMAND="$security_shim" \
    expect_failure test run_feed_builder

prepare_fixture
security_marker="$test_root/security-shim-called"
security_noise="$repo_root/MacChannel.dmg 此版本包含安全更新与稳定性改进。"
MACCHANNEL_TESTING=1 \
MACCHANNEL_TEST_SECURITY_COMMAND="$security_shim" \
MACCHANNEL_TEST_SECURITY_MARKER="$security_marker" \
MACCHANNEL_TEST_SECURITY_NOISE="$security_noise" \
    expect_failure key run_feed_builder
test -f "$security_marker"
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

test -f dist/appcast.xml
xmllint --noout dist/appcast.xml

version_value="$(xmllint --xpath \
    'string(//*[local-name()="item"][1]/*[local-name()="version"])' \
    dist/appcast.xml)"
short_value="$(xmllint --xpath \
    'string(//*[local-name()="item"][1]/*[local-name()="shortVersionString"])' \
    dist/appcast.xml)"
enclosure_url="$(xmllint --xpath \
    'string(//*[local-name()="item"][1]/*[local-name()="enclosure"]/@url)' \
    dist/appcast.xml)"
enclosure_length="$(xmllint --xpath \
    'string(//*[local-name()="item"][1]/*[local-name()="enclosure"]/@length)' \
    dist/appcast.xml)"
enclosure_signature="$(xmllint --xpath \
    'string(//*[local-name()="item"][1]/*[local-name()="enclosure"]/@*[local-name()="edSignature"])' \
    dist/appcast.xml)"
description_value="$(xmllint --xpath \
    'string(//*[local-name()="item"][1]/*[local-name()="description"])' \
    dist/appcast.xml)"

test "$version_value" = "$build_number"
test "$short_value" = "$version"
test "$enclosure_url" = \
    "https://github.com/MasonXQY/MacChannel/releases/download/v$version/MacChannel.dmg"
test "$enclosure_length" = "$(stat -f %z dist/MacChannel.dmg)"
test -n "$enclosure_signature"
grep -F "此版本包含安全更新与稳定性改进。" <<<"$description_value" >/dev/null
grep -F "releases/download/v$version/MacChannel.dmg" dist/appcast.xml >/dev/null
grep -F 'sparkle:edSignature=' dist/appcast.xml >/dev/null
grep -F '<!-- sparkle-signatures:' dist/appcast.xml >/dev/null
grep -F 'edSignature: ' dist/appcast.xml >/dev/null

test "$(shasum -a 256 dist/MacChannel.dmg | awk '{print $1}')" = \
    "$(plutil -extract dmgSHA256 raw -o - dist/MacChannel.manifest.json)"
test "$(plutil -extract version raw -o - dist/MacChannel.manifest.json)" = "$version"
test "$(plutil -extract build raw -o - dist/MacChannel.manifest.json)" = "$build_number"
test "$(plutil -extract releaseState raw -o - dist/MacChannel.manifest.json)" = notarized

for forbidden_metadata in \
    "$repo_root" \
    "$test_root" \
    "$account" \
    'Developer ID Application:' \
    'file://'; do
    if grep -F "$forbidden_metadata" dist/appcast.xml >/dev/null; then
        echo "appcast contains sensitive metadata: $forbidden_metadata" >&2
        exit 1
    fi
done

assert_exact_release_assets() {
    for required in MacChannel.dmg MacChannel.manifest.json appcast.xml; do
        [[ -f "dist/$required" && ! -L "dist/$required" ]] || return 1
    done
    local actual
    actual="$(find dist -mindepth 1 -maxdepth 1 -exec basename {} \; | LC_ALL=C sort)"
    [[ "$actual" == $'MacChannel.dmg\nMacChannel.manifest.json\nappcast.xml' ]]
}
assert_exact_release_assets

expect_asset_contract_failure() {
    if assert_exact_release_assets; then
        echo "asset contract accepted an extra or non-regular entry" >&2
        exit 1
    fi
}
mkdir dist/extra-directory
expect_asset_contract_failure
rmdir dist/extra-directory
ln -s MacChannel.dmg dist/extra-link
expect_asset_contract_failure
rm dist/extra-link
mkfifo dist/extra-fifo
expect_asset_contract_failure
rm dist/extra-fifo
mv dist/appcast.xml "$test_root/regular-appcast.xml"
ln -s "$test_root/regular-appcast.xml" dist/appcast.xml
expect_asset_contract_failure
rm dist/appcast.xml
mv "$test_root/regular-appcast.xml" dist/appcast.xml
assert_exact_release_assets

# Exercise build-distribution.sh's guarded notarized-assets handoff into the real
# feed builder without invoking Apple's live notary service.
rm -f dist/MacChannel.dmg dist/MacChannel.manifest.json dist/appcast.xml \
    dist/.appcast.xml.new
env MACCHANNEL_UPDATE_TESTING=1 \
    MACCHANNEL_UPDATE_TEST_FIXTURE_ROOT="$fixture_root" \
    MACCHANNEL_RELEASE_NOTES="$release_notes" \
    MACCHANNEL_VERSION="$version" \
    MACCHANNEL_BUILD_NUMBER="$build_number" \
    bash Scripts/build-distribution.sh >"$test_root/handoff-success.log" 2>&1
assert_redacted_output "$test_root/handoff-success.log"
grep -Fx "update-feed success version=$version build=$build_number" \
    "$test_root/handoff-success.log" >/dev/null
grep -Fx "distribution success state=notarized version=$version build=$build_number" \
    "$test_root/handoff-success.log" >/dev/null
assert_exact_release_assets

handoff_dmg_sha="$(shasum -a 256 dist/MacChannel.dmg | awk '{print $1}')"
handoff_manifest_sha="$(shasum -a 256 dist/MacChannel.manifest.json | awk '{print $1}')"
printf '%s\n' stale-feed >dist/appcast.xml
printf '%s\n' stale-pending >dist/.appcast.xml.new
set +e
env MACCHANNEL_UPDATE_TESTING=1 \
    MACCHANNEL_UPDATE_TEST_FIXTURE_ROOT="$fixture_root" \
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
[[ -f dist/MacChannel.dmg && ! -L dist/MacChannel.dmg ]]
[[ -f dist/MacChannel.manifest.json && ! -L dist/MacChannel.manifest.json ]]
test "$handoff_dmg_sha" = "$(shasum -a 256 dist/MacChannel.dmg | awk '{print $1}')"
test "$handoff_manifest_sha" = \
    "$(shasum -a 256 dist/MacChannel.manifest.json | awk '{print $1}')"
[[ ! -e dist/appcast.xml && ! -L dist/appcast.xml ]]
[[ ! -e dist/.appcast.xml.new && ! -L dist/.appcast.xml.new ]]

set +e
env MACCHANNEL_UPDATE_TEST_FIXTURE_ROOT="$fixture_root" \
    MACCHANNEL_RELEASE_NOTES="$release_notes" \
    bash Scripts/build-distribution.sh >"$test_root/unguarded-seam.log" 2>&1
unguarded_status=$?
set -e
[[ "$unguarded_status" -ne 0 ]]
grep -F 'update fixture seam requires MACCHANNEL_UPDATE_TESTING=1' \
    "$test_root/unguarded-seam.log" >/dev/null

prepare_fixture
run_feed_builder >"$test_root/post-handoff-success.log" 2>&1
assert_redacted_output "$test_root/post-handoff-success.log"
assert_exact_release_assets

cp dist/appcast.xml "$test_root/first-appcast.xml"
run_feed_builder >"$test_root/repeat-success.log" 2>&1
assert_redacted_output "$test_root/repeat-success.log"
cmp "$test_root/first-appcast.xml" dist/appcast.xml
test "$(shasum -a 256 "$release_notes" | awk '{print $1}')" = \
    "$release_notes_sha_before"

echo "update feed PASS"
