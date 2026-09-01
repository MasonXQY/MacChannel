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

cleanup() {
    rm -rf "$test_root"
    rm -f dist/MacChannel.dmg dist/MacChannel.manifest.json dist/appcast.xml \
        dist/.appcast.xml.new
}
trap cleanup EXIT

mkdir -p "$fixture_root/app"
chmod 700 "$test_root" "$fixture_root"
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
        bash Scripts/build-update-feed.sh
}

expect_failure() {
    printf '%s\n' stale-feed >dist/appcast.xml
    set +e
    "$@" >"$test_root/expected-failure.log" 2>&1
    local actual_status=$?
    set -e
    if [[ "$actual_status" -eq 0 ]]; then
        echo "expected feed build to fail" >&2
        exit 1
    fi
    if [[ -e dist/appcast.xml || -e dist/.appcast.xml.new ]]; then
        echo "failed feed build left a published appcast" >&2
        exit 1
    fi
}

prepare_fixture
mv dist/MacChannel.dmg "$test_root/missing.dmg"
expect_failure run_feed_builder
grep -F 'dist/MacChannel.dmg is required' "$test_root/expected-failure.log" >/dev/null

prepare_fixture
plutil -replace releaseState -string internalSignedNotNotarized \
    dist/MacChannel.manifest.json
expect_failure run_feed_builder
grep -F 'only notarized releases may have an appcast' \
    "$test_root/expected-failure.log" >/dev/null

prepare_fixture
MACCHANNEL_TEST_VERSION=1.2.1 expect_failure run_feed_builder
grep -F 'manifest version does not match release version' \
    "$test_root/expected-failure.log" >/dev/null
prepare_fixture
MACCHANNEL_TEST_BUILD_NUMBER=14 expect_failure run_feed_builder
grep -F 'manifest build does not match release build' \
    "$test_root/expected-failure.log" >/dev/null

prepare_fixture
plutil -replace dmgSHA256 -string \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    dist/MacChannel.manifest.json
expect_failure run_feed_builder
grep -F 'manifest DMG digest does not match the DMG' \
    "$test_root/expected-failure.log" >/dev/null

prepare_fixture
MACCHANNEL_TEST_RELEASE_NOTES="$test_root/missing.md" expect_failure run_feed_builder
grep -F 'release notes Markdown is missing or empty' \
    "$test_root/expected-failure.log" >/dev/null
prepare_fixture
MACCHANNEL_TEST_SPARKLE_ACCOUNT=com.mason.macchannel.missing \
    expect_failure run_feed_builder
grep -F 'Sparkle private key account is missing from the login Keychain' \
    "$test_root/expected-failure.log" >/dev/null
prepare_fixture
MACCHANNEL_TEST_GENERATE_APPCAST="$repo_root/.build/tools/Sparkle-2.9.6/bin/sign_update" \
    expect_failure run_feed_builder
grep -F 'must be the pinned Sparkle 2.9.6 generator' \
    "$test_root/expected-failure.log" >/dev/null

prepare_fixture
run_feed_builder

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

test -z "$(find dist -mindepth 1 -maxdepth 1 -type f \
    ! -name MacChannel.dmg \
    ! -name MacChannel.manifest.json \
    ! -name appcast.xml \
    -print -quit)"

cp dist/appcast.xml "$test_root/first-appcast.xml"
run_feed_builder
cmp "$test_root/first-appcast.xml" dist/appcast.xml
test "$(shasum -a 256 "$release_notes" | awk '{print $1}')" = \
    "$release_notes_sha_before"

echo "update feed PASS"
