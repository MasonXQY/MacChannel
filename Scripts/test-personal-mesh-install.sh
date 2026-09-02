#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repo_root"
source "$repo_root/Scripts/update-test-paths.sh"

for required in Scripts/install-personal-mesh.sh Scripts/accept-personal-mesh.sh; do
    if [[ ! -x "$required" ]]; then
        echo "$required is missing or not executable" >&2
        exit 1
    fi
done

if rg -n -i 'tailscale|个人网络通道|个人网络（推荐）|--tailscale-cli' \
    Scripts/install-personal-mesh.sh Scripts/accept-personal-mesh.sh; then
    echo "installer still depends on obsolete auxiliary networking" >&2
    exit 1
fi
grep -F '内置安全服务' Scripts/install-personal-mesh.sh >/dev/null

identity="${MACCHANNEL_CODESIGN_IDENTITY:-}"
[[ -n "$identity" ]] || { echo "MACCHANNEL_CODESIGN_IDENTITY is required" >&2; exit 2; }
expected_team_id="$(sed -E 's/^.*\(([A-Z0-9]{10})\)$/\1/' <<<"$identity")"
[[ "$expected_team_id" == XKAZ67HN45 ]] || {
    echo "installer tests require the anchored production Team identity" >&2
    exit 2
}
alternate_identity='Apple Development: Qianyao Xu (H33N6G5622)'
if ! /usr/bin/security find-identity -v -p codesigning | \
    grep -F "\"$alternate_identity\"" >/dev/null; then
    echo "installer adversarial test requires the alternate Apple Development identity" >&2
    exit 2
fi

test_root="$(macchannel_create_test_root macchannel-install-contract)"
applications="$test_root/Applications"
mkdir -p "$applications"
mount_path=""
cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n "$mount_path" ]] && mount | grep -F " on $mount_path " >/dev/null; then
        hdiutil detach "$mount_path" -quiet || status=70
    fi
    if macchannel_require_canonical_test_root "$test_root"; then
        rm -rf "$test_root"
    else
        status=70
    fi
    exit "$status"
}
trap cleanup EXIT INT TERM

make_fixture() {
    local fixture_name="$1"
    local fixture_identity="$2"
    local fixture_root="$test_root/$fixture_name"
    local stage="$fixture_root/stage"
    local app="$stage/MacChannel.app"
    local dmg="$fixture_root/DropMesh.dmg"
    local manifest="$fixture_root/DropMesh.manifest.json"
    mkdir -p "$stage"

    MACCHANNEL_BUILD_CONFIGURATION=release \
    MACCHANNEL_CODESIGN_IDENTITY="$fixture_identity" \
    MACCHANNEL_VERSION=1.2.2 \
    MACCHANNEL_BUILD_NUMBER=15 \
    MACCHANNEL_APP_OUTPUT="$app" \
        bash Scripts/build-app.sh >/dev/null
    ln -s /Applications "$stage/Applications"
    hdiutil create -srcfolder "$stage" -volname DropMesh -fs HFS+ -format UDZO -ov \
        "$dmg" >/dev/null
    /usr/bin/codesign --force --sign "$fixture_identity" --timestamp=none "$dmg"

    local team requirement dmg_sha version build product bundle_identifier
    team="$(/usr/bin/codesign -dvvv "$app" 2>&1 | \
        sed -n 's/^TeamIdentifier=//p' | tail -n 1)"
    requirement="$(/usr/bin/codesign -d -r- "$app" 2>&1 | \
        sed -n 's/^designated => //p' | tail -n 1)"
    dmg_sha="$(shasum -a 256 "$dmg" | awk '{print $1}')"
    version="$(plutil -extract CFBundleShortVersionString raw -o - \
        "$app/Contents/Info.plist")"
    build="$(plutil -extract CFBundleVersion raw -o - "$app/Contents/Info.plist")"
    product="$(plutil -extract CFBundleName raw -o - "$app/Contents/Info.plist")"
    bundle_identifier="$(plutil -extract CFBundleIdentifier raw -o - \
        "$app/Contents/Info.plist")"

    plutil -create xml1 "$manifest"
    plutil -insert product -string "$product" "$manifest"
    plutil -insert bundleIdentifier -string "$bundle_identifier" "$manifest"
    plutil -insert version -string "$version" "$manifest"
    plutil -insert build -string "$build" "$manifest"
    plutil -insert gitCommit -string "$(git rev-parse HEAD)" "$manifest"
    plutil -insert teamID -string "$team" "$manifest"
    plutil -insert designatedRequirement -string "$requirement" "$manifest"
    # The command shims below stand in only for Apple's online notarization and
    # Gatekeeper services. Identity, designated requirement, metadata, and hash
    # validation always use the real signed fixture.
    plutil -insert releaseState -string notarized "$manifest"
    plutil -insert dmgSHA256 -string "$dmg_sha" "$manifest"
    plutil -convert json "$manifest"
}

make_fixture primary "$identity"
make_fixture alternate "$alternate_identity"

stapler_shim="$test_root/stapler-shim"
spctl_shim="$test_root/spctl-shim"
validation_marker="$test_root/validation.log"
cat >"$stapler_shim" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" -eq 2 && "$1" == validate && -f "$2" ]]
printf 'stapler\t%s\t%s\n' "$1" "$2" >>"$MACCHANNEL_INSTALL_TEST_MARKER"
SH
cat >"$spctl_shim" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" -ge 4 && "$1" == --assess && "$2" == --type ]]
case "$3" in
    open) [[ -f "${@: -1}" ]] ;;
    execute) [[ -d "${@: -1}" ]] ;;
    *) exit 64 ;;
esac
printf 'spctl\t%s\t%s\n' "$3" "${@: -1}" >>"$MACCHANNEL_INSTALL_TEST_MARKER"
SH
chmod 700 "$stapler_shim" "$spctl_shim"

installer_test_environment=(
    env
    MACCHANNEL_INSTALL_TESTING=1
    MACCHANNEL_INSTALL_TEST_ROOT="$test_root"
    MACCHANNEL_INSTALL_STAPLER_COMMAND="$stapler_shim"
    MACCHANNEL_INSTALL_SPCTL_COMMAND="$spctl_shim"
    MACCHANNEL_INSTALL_TEST_MARKER="$validation_marker"
    MACCHANNEL_INSTALL_SKIP_LAUNCH=1
)

expect_failure() {
    local expected="$1"
    shift
    set +e
    "$@" >"$test_root/failure.log" 2>&1
    local actual=$?
    set -e
    if [[ "$actual" -ne "$expected" ]]; then
        echo "expected installer status $expected, got $actual" >&2
        sed -n '1,120p' "$test_root/failure.log" >&2
        exit 1
    fi
}

primary_dmg="$test_root/primary/DropMesh.dmg"
primary_manifest="$test_root/primary/DropMesh.manifest.json"
alternate_dmg="$test_root/alternate/DropMesh.dmg"
alternate_manifest="$test_root/alternate/DropMesh.manifest.json"

data_root="$test_root/Application Support/MacChannel"
mkdir -p "$data_root"
printf 'preserve-me\n' >"$data_root/settings.json"

"${installer_test_environment[@]}" \
    bash Scripts/install-personal-mesh.sh \
    --dmg "$primary_dmg" \
    --manifest "$primary_manifest" \
    --applications-dir "$applications" \
    --expected-commit "$(git rev-parse HEAD)"
/usr/bin/codesign --verify --deep --strict "$applications/MacChannel.app"
grep -qx 'preserve-me' "$data_root/settings.json"

# RED on the vulnerable installer: a second valid Apple signer and a matching
# unsigned manifest used to be accepted because neither was checked against the
# repository's production signing anchor.
expect_failure 1 "${installer_test_environment[@]}" \
    bash Scripts/install-personal-mesh.sh \
    --dmg "$alternate_dmg" \
    --manifest "$alternate_manifest" \
    --applications-dir "$applications" \
    --expected-commit "$(git rev-parse HEAD)"
test "$(grep -c '^stapler' "$validation_marker")" -eq 1
test "$(grep -c $'^spctl\topen\t' "$validation_marker")" -eq 1
test "$(grep -c $'^spctl\texecute\t' "$validation_marker")" -eq 1

assert_manifest_rejected() {
    local key="$1"
    local value="$2"
    local mutated_manifest="$test_root/mutated-$key.json"
    cp "$primary_manifest" "$mutated_manifest"
    plutil -replace "$key" -string "$value" "$mutated_manifest"
    expect_failure 1 "${installer_test_environment[@]}" \
        bash Scripts/install-personal-mesh.sh \
        --dmg "$primary_dmg" \
        --manifest "$mutated_manifest" \
        --applications-dir "$applications" \
        --expected-commit "$(git rev-parse HEAD)"
}

assert_manifest_rejected teamID AAAAAAAAAA
assert_manifest_rejected designatedRequirement 'anchor apple and identifier "attacker"'
assert_manifest_rejected bundleIdentifier com.example.attacker
assert_manifest_rejected product AttackerMesh
assert_manifest_rejected version 9.9.9
assert_manifest_rejected build 999
assert_manifest_rejected releaseState internalSignedNotNotarized

expect_failure 2 "${installer_test_environment[@]}" \
    bash Scripts/install-personal-mesh.sh \
    --dmg "$primary_dmg" \
    --manifest "$primary_manifest" \
    --applications-dir "$applications" \
    --expected-commit 0000000000000000000000000000000000000000

cp "$primary_dmg" "$test_root/mutated.dmg"
printf 'mutation' >>"$test_root/mutated.dmg"
expect_failure 1 "${installer_test_environment[@]}" \
    bash Scripts/install-personal-mesh.sh \
    --dmg "$test_root/mutated.dmg" \
    --manifest "$primary_manifest" \
    --applications-dir "$applications" \
    --expected-commit "$(git rev-parse HEAD)"

mkdir -p "$applications/MacChannel.app/Contents"
printf 'old-version\n' >"$applications/MacChannel.app/Contents/old.txt"
expect_failure 70 "${installer_test_environment[@]}" \
    MACCHANNEL_INSTALL_FAIL_AT=after-backup \
    bash Scripts/install-personal-mesh.sh \
    --dmg "$primary_dmg" \
    --manifest "$primary_manifest" \
    --applications-dir "$applications" \
    --expected-commit "$(git rev-parse HEAD)"
test -f "$applications/MacChannel.app/Contents/old.txt"

# Test validators are accepted only inside an owner-only canonical fixture root.
# Merely setting the test flag must never expose them to /Applications.
expect_failure 2 env \
    MACCHANNEL_INSTALL_TESTING=1 \
    MACCHANNEL_INSTALL_TEST_ROOT="$test_root" \
    MACCHANNEL_INSTALL_STAPLER_COMMAND="$stapler_shim" \
    MACCHANNEL_INSTALL_SPCTL_COMMAND="$spctl_shim" \
    MACCHANNEL_INSTALL_SKIP_LAUNCH=1 \
    bash Scripts/install-personal-mesh.sh \
    --dmg "$test_root/missing.dmg" \
    --manifest "$test_root/missing.json"
grep -F 'installer test controls require a non-/Applications controlled root' \
    "$test_root/failure.log" >/dev/null

anchor=Distribution/ProductionSigningAnchor.plist
expected_requirement='identifier "com.mason.macchannel" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = XKAZ67HN45'
test "$(plutil -extract teamID raw -o - "$anchor")" = XKAZ67HN45
test "$(plutil -extract bundleIdentifier raw -o - "$anchor")" = com.mason.macchannel
test "$(plutil -extract bundleExecutable raw -o - "$anchor")" = MacChannelApp
test "$(plutil -extract product raw -o - "$anchor")" = DropMesh
test "$(plutil -extract designatedRequirement raw -o - "$anchor")" = "$expected_requirement"

if rg -n -i 'spctl[^\n]*master-disable|csrutil|xattr[^\n]*quarantine' \
    Scripts/install-personal-mesh.sh Scripts/accept-personal-mesh.sh; then
    echo "installer attempts to weaken macOS security" >&2
    exit 1
fi
grep -F '/usr/bin/codesign --verify --strict --verbose=2 "$dmg"' \
    Scripts/install-personal-mesh.sh >/dev/null
grep -F '/usr/bin/xcrun stapler validate "$dmg"' \
    Scripts/install-personal-mesh.sh >/dev/null
grep -F '/usr/sbin/spctl --assess --type open --context context:primary-signature' \
    Scripts/install-personal-mesh.sh >/dev/null
grep -F '/usr/sbin/spctl --assess --type execute --verbose=2 "$mounted_app"' \
    Scripts/install-personal-mesh.sh >/dev/null

bash Scripts/accept-personal-mesh.sh --validate-only docs/acceptance/personal-mesh-real-mac.md
echo "personal mesh installer contract PASS"
