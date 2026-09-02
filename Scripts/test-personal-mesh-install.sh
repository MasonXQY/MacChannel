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
[[ "${MACCHANNEL_INSTALL_VALIDATOR_FAIL:-}" != stapler ]] || exit 71
printf 'stapler\t%s\t%s\n' "$1" "$2" >>"$MACCHANNEL_INSTALL_TEST_MARKER"
SH
cat >"$spctl_shim" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" -ge 4 && "$1" == --assess && "$2" == --type ]]
case "$3" in
    open)
        [[ -f "${@: -1}" ]]
        [[ "${MACCHANNEL_INSTALL_VALIDATOR_FAIL:-}" != open ]] || exit 72
        ;;
    execute)
        [[ -d "${@: -1}" ]]
        [[ "${MACCHANNEL_INSTALL_VALIDATOR_FAIL:-}" != execute ]] || exit 73
        ;;
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

prepare_old_app() {
    local label="$1"
    rm -rf "$applications/MacChannel.app" "$test_root/expected-old.app"
    mkdir -p "$applications/MacChannel.app/Contents/Resources"
    printf 'old executable %s\n' "$label" >"$applications/MacChannel.app/Contents/MacChannelApp"
    printf 'old resource %s\n' "$label" >"$applications/MacChannel.app/Contents/Resources/state.bin"
    cp -R "$applications/MacChannel.app" "$test_root/expected-old.app"
}

assert_old_app_unchanged() {
    [[ -d "$applications/MacChannel.app" && ! -L "$applications/MacChannel.app" ]]
    diff -rq "$test_root/expected-old.app" "$applications/MacChannel.app" >/dev/null
}

assert_installed_app_valid() {
    [[ -d "$applications/MacChannel.app" && ! -L "$applications/MacChannel.app" ]]
    /usr/bin/codesign --verify --deep --strict "$applications/MacChannel.app"
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

# Every notarization and Gatekeeper failure is fail-closed and preserves the
# exact old application bytes.
for validator_failure in stapler open execute; do
    prepare_old_app "validator-$validator_failure"
    case "$validator_failure" in
        stapler) expected_status=71 ;;
        open) expected_status=72 ;;
        execute) expected_status=73 ;;
    esac
    expect_failure "$expected_status" "${installer_test_environment[@]}" \
        MACCHANNEL_INSTALL_VALIDATOR_FAIL="$validator_failure" \
        bash Scripts/install-personal-mesh.sh \
        --dmg "$primary_dmg" \
        --manifest "$primary_manifest" \
        --applications-dir "$applications" \
        --expected-commit "$(git rev-parse HEAD)"
    assert_old_app_unchanged
done

# A hostile process may pre-create the installer's former predictable PID-based
# file names. Files, directories, and symlinks at those names must remain
# byte-for-byte untouched and must never redirect a copy or cleanup operation.
run_hostile_collision_case() {
    local kind="$1"
    local pid_file="$test_root/collision-$kind.pid"
    local continue_file="$test_root/collision-$kind.continue"
    local outside="$test_root/collision-$kind-outside"
    local installer_pid install_collision backup_collision result

    rm -f "$pid_file" "$continue_file"
    mkdir -p "$outside"
    printf 'outside-%s\n' "$kind" >"$outside/sentinel"

    "${installer_test_environment[@]}" bash -c '
        pid_file="$1"
        continue_file="$2"
        shift 2
        printf "%s\n" "$$" >"$pid_file"
        while [[ ! -e "$continue_file" ]]; do /bin/sleep 0.01; done
        exec "$@"
    ' bash "$pid_file" "$continue_file" \
        bash Scripts/install-personal-mesh.sh \
        --dmg "$primary_dmg" \
        --manifest "$primary_manifest" \
        --applications-dir "$applications" \
        --expected-commit "$(git rev-parse HEAD)" &
    installer_pid=$!

    for _ in {1..500}; do
        [[ -s "$pid_file" ]] && break
        /bin/sleep 0.01
    done
    [[ -s "$pid_file" ]] || { echo "installer PID synchronization failed" >&2; exit 1; }
    installer_pid="$(cat "$pid_file")"
    install_collision="$applications/.DropMesh.install.$installer_pid"
    backup_collision="$applications/.DropMesh.backup.$installer_pid"

    case "$kind" in
        file)
            printf 'hostile-install-file\n' >"$install_collision"
            printf 'hostile-backup-file\n' >"$backup_collision"
            ;;
        directory)
            mkdir "$install_collision" "$backup_collision"
            printf 'hostile-install-directory\n' >"$install_collision/sentinel"
            printf 'hostile-backup-directory\n' >"$backup_collision/sentinel"
            ;;
        symlink)
            ln -s "$outside" "$install_collision"
            ln -s "$outside" "$backup_collision"
            ;;
        *) exit 64 ;;
    esac
    : >"$continue_file"
    set +e
    wait "$installer_pid"
    result=$?
    set -e
    [[ "$result" -eq 0 ]] || { echo "collision install failed with $result" >&2; exit 1; }
    assert_installed_app_valid
    case "$kind" in
        file)
            grep -qx 'hostile-install-file' "$install_collision"
            grep -qx 'hostile-backup-file' "$backup_collision"
            ;;
        directory)
            grep -qx 'hostile-install-directory' "$install_collision/sentinel"
            grep -qx 'hostile-backup-directory' "$backup_collision/sentinel"
            ;;
        symlink)
            [[ -L "$install_collision" && "$(readlink "$install_collision")" == "$outside" ]]
            [[ -L "$backup_collision" && "$(readlink "$backup_collision")" == "$outside" ]]
            ;;
    esac
    grep -qx "outside-$kind" "$outside/sentinel"
}

run_hostile_collision_case file
run_hostile_collision_case directory
run_hostile_collision_case symlink

# Unrecognized transaction orphans belong to another/terminated process. A new
# run must not scan, adopt, or delete them.
orphan_root="$applications/.DropMesh.transaction.orphan42"
mkdir -m 700 "$orphan_root"
printf 'do-not-adopt\n' >"$orphan_root/sentinel"
"${installer_test_environment[@]}" \
    bash Scripts/install-personal-mesh.sh \
    --dmg "$primary_dmg" \
    --manifest "$primary_manifest" \
    --applications-dir "$applications" \
    --expected-commit "$(git rev-parse HEAD)"
grep -qx 'do-not-adopt' "$orphan_root/sentinel"

# Ordinary failures before the commit boundary restore the exact old app. A
# post-commit failure keeps the complete newly installed signed app.
for failure_point in before-backup after-backup after-install; do
    prepare_old_app "failure-$failure_point"
    expect_failure 70 "${installer_test_environment[@]}" \
        MACCHANNEL_INSTALL_FAIL_AT="$failure_point" \
        bash Scripts/install-personal-mesh.sh \
        --dmg "$primary_dmg" \
        --manifest "$primary_manifest" \
        --applications-dir "$applications" \
        --expected-commit "$(git rev-parse HEAD)"
    assert_old_app_unchanged
done
prepare_old_app failure-after-success
expect_failure 70 "${installer_test_environment[@]}" \
    MACCHANNEL_INSTALL_FAIL_AT=after-success \
    bash Scripts/install-personal-mesh.sh \
    --dmg "$primary_dmg" \
    --manifest "$primary_manifest" \
    --applications-dir "$applications" \
    --expected-commit "$(git rev-parse HEAD)"
assert_installed_app_valid

# INT, TERM, and HUP received at either rename point are deferred until the
# tiny commit section reaches a complete old-or-new state. The same signals at
# the success boundary also leave a complete signed app.
for signal_name in INT TERM HUP; do
    case "$signal_name" in
        INT) expected_status=130 ;;
        TERM) expected_status=143 ;;
        HUP) expected_status=129 ;;
    esac
    for signal_point in after-backup after-install after-success; do
        prepare_old_app "signal-$signal_name-$signal_point"
        expect_failure "$expected_status" "${installer_test_environment[@]}" \
            MACCHANNEL_INSTALL_SIGNAL_AT="$signal_point:$signal_name" \
            bash Scripts/install-personal-mesh.sh \
            --dmg "$primary_dmg" \
            --manifest "$primary_manifest" \
            --applications-dir "$applications" \
            --expected-commit "$(git rev-parse HEAD)"
        assert_installed_app_valid
    done
done

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
