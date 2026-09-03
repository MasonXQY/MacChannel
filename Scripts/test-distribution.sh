#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repo_root"

if [[ ! -x Scripts/build-distribution.sh ]]; then
    echo "Scripts/build-distribution.sh is missing or not executable" >&2
    exit 1
fi

grep -F 'spctl --assess --type open --context context:primary-signature' \
    Scripts/build-distribution.sh >/dev/null
grep -F 'MACCHANNEL_RELEASE_NOTES' Scripts/build-distribution.sh >/dev/null
grep -F 'bash Scripts/build-update-feed.sh' Scripts/build-distribution.sh >/dev/null

# Public branding must not leak the legacy product name. Swift string literals
# are allowed only for these byte-for-byte storage/protocol compatibility IDs.
while IFS=: read -r source_file source_line source_text; do
    allowed=0
    case "$source_file" in
        App/ClipboardTransferSource.swift)
            [[ "$source_text" == *'appendingPathComponent("MacChannel", isDirectory: true)'* ]] \
                && allowed=1
            ;;
        App/ProductionAppRuntime.swift)
            [[ "$source_text" == *'appendingPathComponent("MacChannel", isDirectory: true)'* ]] \
                && allowed=1
            ;;
        Sources/MacChannelCore/Storage/DownloadDirectory.swift)
            [[ "$source_text" == *'appendingPathComponent("Mac 通道", isDirectory: true)'* ]] \
                && allowed=1
            ;;
        Sources/MacChannelCore/Storage/ReceiveStore.swift)
            [[ "$source_text" == *'appendingPathComponent("MacChannel", isDirectory: true)'* || \
               "$source_text" == *'appendingPathComponent("MacChannel/Incoming", isDirectory: true)'* ]] \
                && allowed=1
            ;;
        Sources/MacChannelCore/Orchestration/OutgoingTransferPackage.swift)
            [[ "$source_text" == *'appendingPathComponent("MacChannel/Outgoing", isDirectory: true)'* ]] \
                && allowed=1
            ;;
        Sources/MacChannelCore/Pairing/PairingCoordinator.swift)
            [[ "$source_text" == *'Data("MacChannel pairing v1".utf8)'* ]] && allowed=1
            ;;
    esac
    if [[ "$allowed" -ne 1 ]]; then
        echo "legacy product literal outside compatibility allowlist: $source_file:$source_line" >&2
        exit 1
    fi
done < <(rg -n --no-heading '"[^"\n]*(Mac 通道|MacChannel)' App Sources || true)

# Current documentation permits the old name only where it identifies a real
# transition path/repository or explains the v1.2.2 rename. Historical release
# notes have their own immutable contract and are intentionally excluded.
while IFS=: read -r source_file source_line source_text; do
    allowed=0
    case "$source_file:$source_text" in
        'README.md:open .build/MacChannel.app'|\
        'README.md:MACCHANNEL_APP_OUTPUT="/tmp/MacChannel.app" \'|\
        'README.md:[官方 GitHub Releases](https://github.com/MasonXQY/MacChannel/releases) 下载本次'|\
        'Distribution/ReleaseNotes/v1.2.2.md:MacChannel 现在更名为 DropMesh，同时换上了全新的应用图标。这次更名不会改变你的设备身份、配对关系、设置、传输历史或接收目录，升级后无需重新配对。')
            allowed=1
            ;;
    esac
    if [[ "$allowed" -ne 1 ]]; then
        echo "legacy product copy outside documentation compatibility allowlist: $source_file:$source_line" >&2
        exit 1
    fi
done < <(rg -n --no-heading 'Mac 通道|MacChannel' \
    README.md Distribution/README.txt Distribution/ReleaseNotes/v1.2.2.md || true)

# Production scripts may refer to frozen executable, bundle, environment,
# repository, and artifact migration identifiers. Removing those exact tokens
# must leave no ordinary legacy brand prose behind.
normalize_script_compatibility_anchors() {
    perl -pe '
        s/(?<![A-Za-z0-9_])MacChannel_MacChannelAppKit(?![A-Za-z0-9_])//g;
        s/(?<![A-Za-z0-9_])MacChannelUpdateAcceptance(?![A-Za-z0-9_])//g;
        s/(?<![A-Za-z0-9_])MacChannelUpdateLoadProbe(?![A-Za-z0-9_])//g;
        s/(?<![A-Za-z0-9_])MacChannelUpdateTestSigner(?![A-Za-z0-9_])//g;
        s/(?<![A-Za-z0-9_])MacChannelApp(?![A-Za-z0-9_])//g;
        s/(?<![A-Za-z0-9_])MacChannel\.(?:app|dmg|manifest\.json)(?![A-Za-z0-9_])//g;
        s#MasonXQY/MacChannel(?![A-Za-z0-9_])##g;
    '
}
script_audit_probe='MacChannelBogus must remain visible to the audit'
script_audit_probe_normalized="$(normalize_script_compatibility_anchors \
    <<<"$script_audit_probe")"
test "$script_audit_probe_normalized" = "$script_audit_probe"
while IFS=: read -r source_file source_line source_text; do
    case "$source_file:$source_text" in
        'Scripts/build-app.sh:    <string>MacChannel</string>'|\
        'Scripts/build-distribution.sh:    MacChannel'|\
        'Scripts/build-update-feed.sh:    "$actual_display_name" == MacChannel && \'|\
        "Scripts/verify-personal-mesh.sh:if pgrep -f '/MacChannel\\.app/Contents/MacOS/MacChannelApp' >/dev/null; then")
            continue
            ;;
    esac
    normalized="$(normalize_script_compatibility_anchors <<<"$source_text")"
    if [[ "$normalized" == *MacChannel* || "$normalized" == *"Mac 通道"* ]]; then
        echo "legacy product copy in production script: $source_file:$source_line" >&2
        exit 1
    fi
done < <(find Scripts -maxdepth 1 -type f ! -name 'test-*' -print0 | \
    xargs -0 rg -n --no-heading 'Mac 通道|MacChannel' || true)

legacy_cleanup_refs="$(rg --no-heading -o 'MacChannel\.(dmg|manifest\.json)' \
    Scripts/build-distribution.sh || true)"
test "$legacy_cleanup_refs" = $'MacChannel.dmg\nMacChannel.manifest.json'
if rg -n 'MacChannel\.(dmg|manifest\.json)|Mac 通道' \
    Scripts/build-update-feed.sh Distribution/README.txt; then
    echo "current public distribution branding still contains the legacy product name" >&2
    exit 1
fi
grep -F 'MacChannel.app' Scripts/build-distribution.sh >/dev/null
grep -F 'MacChannelApp' Scripts/build-app.sh >/dev/null
grep -F 'https://github.com/MasonXQY/MacChannel/releases/latest/download/appcast.xml' \
    Scripts/build-app.sh >/dev/null
grep -F 'com.mason.macchannel' Distribution/ProductionSigningAnchor.plist >/dev/null
test "$(plutil -extract product raw -o - Distribution/ProductionSigningAnchor.plist)" = DropMesh
test "$(plutil -extract bundleExecutable raw -o - \
    Distribution/ProductionSigningAnchor.plist)" = MacChannelApp

identity="${MACCHANNEL_CODESIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
    echo "MACCHANNEL_CODESIGN_IDENTITY is required for distribution tests" >&2
    exit 2
fi
expected_team_id="$(sed -E 's/^.*\(([A-Z0-9]{10})\)$/\1/' <<<"$identity")"
[[ "$expected_team_id" == XKAZ67HN45 ]] || {
    echo "distribution tests require the anchored production Team identity" >&2
    exit 2
}
signing_home="${HOME:?}"
unset MACCHANNEL_NOTARY_PROFILE MACCHANNEL_RELEASE_NOTES MACCHANNEL_VERSION \
    MACCHANNEL_BUILD_NUMBER MACCHANNEL_DISTRIBUTION_TESTING \
    MACCHANNEL_DISTRIBUTION_FAIL_AT MACCHANNEL_UPDATE_TEST_FIXTURE_ROOT \
    MACCHANNEL_UPDATE_SECURITY_COMMAND MACCHANNEL_UPDATE_CODESIGN_COMMAND \
    MACCHANNEL_UPDATE_STAPLER_COMMAND MACCHANNEL_UPDATE_SPCTL_COMMAND \
    MACCHANNEL_UPDATE_TEST_ED_KEY_FILE MACCHANNEL_UPDATE_TEST_PUBLIC_KEY_PATH \
    MACCHANNEL_UPDATE_TEST_KEY_ACCESS_MARKER MACCHANNEL_UPDATE_VALIDATOR_MARKER \
    MACCHANNEL_UPDATE_VALIDATOR_FAIL \
    MACCHANNEL_SPARKLE_GENERATE_APPCAST MACCHANNEL_SPARKLE_ACCOUNT

source Scripts/update-test-paths.sh
test_root="$(macchannel_create_test_root macchannel-distribution-test)"
test_dist="$test_root/dist"
signing_tmp="$test_root/signing-tmp"
mkdir -p "$test_dist" "$signing_tmp"
chmod 700 "$test_dist" "$signing_tmp"
macchannel_require_canonical_test_root "$test_root"
test "$(MACCHANNEL_UPDATE_TESTING=1 MACCHANNEL_UPDATE_TEST_ROOT="$test_root" \
    MACCHANNEL_UPDATE_TEST_DIST_ROOT="$test_dist" \
    macchannel_resolve_dist_root "$repo_root")" = "$test_dist"

snapshot_dist() {
    local root=$1
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
clean_test_environment=(env -i PATH="$PATH" HOME="$signing_home" TMPDIR="$signing_tmp" \
    LANG=C LC_ALL=C MACCHANNEL_UPDATE_TESTING=1 \
    MACCHANNEL_UPDATE_TEST_ROOT="$test_root" MACCHANNEL_UPDATE_TEST_DIST_ROOT="$test_dist")
clean_codesign() {
    env -i PATH="$PATH" HOME="$signing_home" TMPDIR="$signing_tmp" LANG=C LC_ALL=C \
        /usr/bin/codesign "$@"
}
mounted_path=""
cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n "$mounted_path" ]] && mount | grep -F " on $mounted_path " >/dev/null; then
        hdiutil detach "$mounted_path" -quiet || true
    fi
    if [[ "$(snapshot_dist "$repo_root/dist")" != "$formal_dist_before" ]]; then
        echo "formal repository dist changed during distribution fixture test" >&2
        status=1
    fi
    if macchannel_require_canonical_test_root "$test_root"; then
        rm -rf "$test_root"
    else
        echo "refusing cleanup of a non-canonical distribution test root" >&2
        status=1
    fi
    exit "$status"
}
trap cleanup EXIT

expect_failure() {
    local expected_status="$1"
    shift
    set +e
    "$@" >"$test_root/expected-failure.log" 2>&1
    local actual_status=$?
    set -e
    if [[ "$actual_status" -ne "$expected_status" ]]; then
        echo "expected status $expected_status, got $actual_status" >&2
        sed -n '1,120p' "$test_root/expected-failure.log" >&2
        exit 1
    fi
    test ! -e $test_dist/DropMesh.dmg
    test ! -e $test_dist/DropMesh.manifest.json
}

expect_distribution_failure() {
    printf '%s\n' stale-feed >"$test_dist/appcast.xml"
    printf '%s\n' stale-pending >"$test_dist/.appcast.xml.new"
    expect_failure "$@"
    test ! -e $test_dist/appcast.xml
    test ! -e $test_dist/.appcast.xml.new
}

expect_distribution_failure 2 "${clean_test_environment[@]}" bash Scripts/build-distribution.sh
expect_distribution_failure 2 "${clean_test_environment[@]}" \
    MACCHANNEL_CODESIGN_IDENTITY="Developer ID Application: Missing (AAAAAAAAAA)" \
    bash Scripts/build-distribution.sh
expect_failure 2 env -i PATH="$PATH" HOME="$signing_home" TMPDIR="$signing_tmp" LANG=C LC_ALL=C \
    MACCHANNEL_UPDATE_TESTING=0 MACCHANNEL_VERSION=1.0 bash Scripts/build-app.sh
expect_failure 2 env -i PATH="$PATH" HOME="$signing_home" TMPDIR="$signing_tmp" LANG=C LC_ALL=C \
    MACCHANNEL_UPDATE_TESTING=0 MACCHANNEL_BUILD_NUMBER=0 bash Scripts/build-app.sh

dirty_marker="distribution-contract-dirty-marker"
trap 'rm -f "$dirty_marker"; cleanup' EXIT
: >"$dirty_marker"
expect_distribution_failure 2 "${clean_test_environment[@]}" MACCHANNEL_CODESIGN_IDENTITY="$identity" \
    bash Scripts/build-distribution.sh
rm -f "$dirty_marker"
trap cleanup EXIT

for fail_at in app-built app-verified stage-ready image-created image-verified manifest-ready; do
    expect_distribution_failure 70 "${clean_test_environment[@]}" \
        MACCHANNEL_CODESIGN_IDENTITY="$identity" \
        MACCHANNEL_DISTRIBUTION_TESTING=1 \
        MACCHANNEL_DISTRIBUTION_FAIL_AT="$fail_at" \
        bash Scripts/build-distribution.sh
done

"${clean_test_environment[@]}" MACCHANNEL_CODESIGN_IDENTITY="$identity" \
MACCHANNEL_RELEASE_NOTES="$repo_root/Distribution/ReleaseNotes/v1.2.6.md" \
    bash Scripts/build-distribution.sh

test -f "$test_dist/DropMesh.dmg"
test -f "$test_dist/DropMesh.manifest.json"
test ! -e "$test_dist/appcast.xml"
clean_codesign --verify --strict --verbose=2 "$test_dist/DropMesh.dmg"

cp $test_dist/DropMesh.manifest.json "$test_root/first-manifest.json"
first_dmg_sha="$(shasum -a 256 $test_dist/DropMesh.dmg | awk '{print $1}')"
"${clean_test_environment[@]}" MACCHANNEL_CODESIGN_IDENTITY="$identity" \
MACCHANNEL_RELEASE_NOTES="$repo_root/Distribution/ReleaseNotes/v1.2.6.md" \
    bash Scripts/build-distribution.sh

for manifest_key in \
    product bundleIdentifier version build gitCommit teamID designatedRequirement releaseState volumeName \
    stagedFilesystemSHA256 sourceDateEpoch createdAt; do
    first_value="$(plutil -extract "$manifest_key" raw -o - "$test_root/first-manifest.json")"
    second_value="$(plutil -extract "$manifest_key" raw -o - $test_dist/DropMesh.manifest.json)"
    test "$first_value" = "$second_value"
done
second_dmg_sha="$(shasum -a 256 $test_dist/DropMesh.dmg | awk '{print $1}')"
if [[ "$first_dmg_sha" != "$second_dmg_sha" ]]; then
    grep -F "Developer ID timestamps and UDIF metadata may change raw DMG bytes" \
        $test_dist/DropMesh.manifest.json >/dev/null
fi
test -z "$(find "$test_dist" -mindepth 1 -maxdepth 1 ! -name DropMesh.dmg \
    ! -name DropMesh.manifest.json -print -quit)"

mounted_path="$test_root/mounted"
mkdir -p "$mounted_path"
hdiutil attach $test_dist/DropMesh.dmg -nobrowse -readonly -mountpoint "$mounted_path" -quiet

mapfile_path="$test_root/entries.txt"
find "$mounted_path" -mindepth 1 -maxdepth 1 -exec basename {} \; | LC_ALL=C sort >"$mapfile_path"
printf '%s\n' Applications MacChannel.app README.txt | LC_ALL=C sort >"$test_root/expected-entries.txt"
cmp "$test_root/expected-entries.txt" "$mapfile_path"
test -L "$mounted_path/Applications"
test "$(readlink "$mounted_path/Applications")" = /Applications
grep -F "版本 1.2.6 (19)" "$mounted_path/README.txt" >/dev/null
clean_codesign --verify --deep --strict --verbose=2 "$mounted_path/MacChannel.app"

plist="$mounted_path/MacChannel.app/Contents/Info.plist"
sparkle="$mounted_path/MacChannel.app/Contents/Frameworks/Sparkle.framework"
test -d "$sparkle"
test -x "$sparkle/Versions/Current/Sparkle"
test "$(plutil -extract CFBundleShortVersionString raw -o - "$plist")" = 1.2.6
test -n "$(plutil -extract NSDownloadsFolderUsageDescription raw -o - "$plist")"
test "$(plutil -extract CFBundleVersion raw -o - "$plist")" = 19
test "$(plutil -extract CFBundlePackageType raw -o - "$plist")" = APPL
test "$(plutil -extract CFBundleIdentifier raw -o - "$plist")" = com.mason.macchannel
test "$(plutil -extract CFBundleExecutable raw -o - "$plist")" = MacChannelApp
test "$(plutil -extract CFBundleName raw -o - "$plist")" = DropMesh
test "$(plutil -extract CFBundleDisplayName raw -o - "$plist")" = MacChannel
test "$(plutil -extract LSHasLocalizedDisplayName raw -o - "$plist")" = true
localized_info="$mounted_path/MacChannel.app/Contents/Resources/en.lproj/InfoPlist.strings"
test "$(plutil -extract CFBundleDisplayName raw -o - "$localized_info")" = DropMesh
display_name="$(/usr/bin/swift -e 'import Foundation; print(FileManager.default.displayName(atPath: CommandLine.arguments[1]))' "$mounted_path/MacChannel.app")"
test "$display_name" = DropMesh
test "$(plutil -extract SUFeedURL raw -o - "$plist")" = \
    "https://github.com/MasonXQY/MacChannel/releases/latest/download/appcast.xml"
test "$(plutil -extract SUEnableAutomaticChecks raw -o - "$plist")" = true
test "$(plutil -extract SUScheduledCheckInterval raw -o - "$plist")" = 86400.000000
test "$(plutil -extract SUAutomaticallyUpdate raw -o - "$plist")" = false
test "$(plutil -extract SUAllowsAutomaticUpdates raw -o - "$plist")" = false
test "$(plutil -extract SUVerifyUpdateBeforeExtraction raw -o - "$plist")" = true
test "$(plutil -extract SURequireSignedFeed raw -o - "$plist")" = true
test -n "$(plutil -extract SUPublicEDKey raw -o - "$plist")"

mutated_app="$test_root/Mutated.app"
ditto "$mounted_path/MacChannel.app" "$mutated_app"
printf '\nmutation\n' >>"$mutated_app/Contents/Info.plist"
if clean_codesign --verify --deep --strict "$mutated_app" >/dev/null 2>&1; then
    echo "mutated application unexpectedly verified" >&2
    exit 1
fi

manifest_sha="$(plutil -extract dmgSHA256 raw -o - $test_dist/DropMesh.manifest.json)"
actual_sha="$(shasum -a 256 $test_dist/DropMesh.dmg | awk '{print $1}')"
test "$manifest_sha" = "$actual_sha"
test "$(plutil -extract gitCommit raw -o - $test_dist/DropMesh.manifest.json)" = "$(git rev-parse HEAD)"
test "$(plutil -extract version raw -o - $test_dist/DropMesh.manifest.json)" = 1.2.6
test "$(plutil -extract build raw -o - $test_dist/DropMesh.manifest.json)" = 19
test "$(plutil -extract releaseState raw -o - $test_dist/DropMesh.manifest.json)" = internalSignedNotNotarized
test "$(plutil -extract product raw -o - $test_dist/DropMesh.manifest.json)" = DropMesh
test "$(plutil -extract bundleIdentifier raw -o - \
    $test_dist/DropMesh.manifest.json)" = com.mason.macchannel
test "$(plutil -extract volumeName raw -o - $test_dist/DropMesh.manifest.json)" = DropMesh
test "$(plutil -extract teamID raw -o - $test_dist/DropMesh.manifest.json)" = "$expected_team_id"
actual_requirement="$(clean_codesign -d -r- "$mounted_path/MacChannel.app" 2>&1 | \
    sed -n 's/^designated => //p')"
test "$(plutil -extract designatedRequirement raw -o - $test_dist/DropMesh.manifest.json)" = \
    "$actual_requirement"
test "$actual_requirement" = "$(plutil -extract designatedRequirement raw -o - \
    Distribution/ProductionSigningAnchor.plist)"

hdiutil detach "$mounted_path" -quiet
mounted_path=""

install_root="$test_root/Applications"
mkdir -p "$install_root"
mounted_path="$test_root/install-source"
mkdir -p "$mounted_path"
hdiutil attach $test_dist/DropMesh.dmg -nobrowse -readonly -mountpoint "$mounted_path" -quiet
ditto "$mounted_path/MacChannel.app" "$install_root/MacChannel.app"
hdiutil detach "$mounted_path" -quiet
mounted_path=""
launch_marker="$test_root/launch.marker"
/usr/bin/open -n -W "$install_root/MacChannel.app" --args --smoke-test "$launch_marker"
grep -qx "ready accessory" "$launch_marker"

echo "distribution PASS"
