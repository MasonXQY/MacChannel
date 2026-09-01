#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repo_root"
signing_home="${HOME:?}"
[[ "$signing_home" == /* && -d "$signing_home" && ! -L "$signing_home" ]]
source Scripts/update-test-paths.sh
source Tests/Fixtures/process-group-cleanup.sh
generate_appcast="$repo_root/.build/tools/Sparkle-2.9.6/bin/generate_appcast"
sign_update="$repo_root/.build/tools/Sparkle-2.9.6/bin/sign_update"
bounded_runner="$repo_root/Tests/Fixtures/run-bounded-process.py"
https_server="$repo_root/Tests/Fixtures/update-acceptance-https-server.py"
hang_fixture="$repo_root/Tests/Fixtures/update-acceptance-hang.py"
static_only="${MACCHANNEL_UPDATE_TEST_STATIC_ONLY:-0}"
[[ "$static_only" == 0 || "$static_only" == 1 ]]
[[ -x "$generate_appcast" && -x "$sign_update" && -f "$bounded_runner" && \
    -f "$https_server" && -f "$hang_fixture" ]]

test_root="$(macchannel_create_test_root macchannel-update-acceptance.matrix)"
macchannel_require_canonical_test_root "$test_root"
clean_codesign() {
    env -i PATH="$PATH" HOME="$signing_home" TMPDIR="$test_root/" LANG=C LC_ALL=C \
        /usr/bin/codesign "$@"
}
clean_security() {
    env -i PATH="$PATH" HOME="$signing_home" TMPDIR="$test_root/" LANG=C LC_ALL=C \
        /usr/bin/security "$@"
}
clean_fixture_tool() {
    env -i PATH="$PATH" HOME="$test_root/tool-home" TMPDIR="$test_root/" LANG=C LC_ALL=C \
        "$@"
}
mkdir -p "$test_root/tool-home"
chmod 700 "$test_root/tool-home"
clean_security list-keychains -d user >"$test_root/keychains.before"
chmod 600 "$test_root/keychains.before"
signing_keychain="$(clean_security login-keychain | \
    sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')"
[[ "$signing_keychain" == /* && -f "$signing_keychain" && ! -L "$signing_keychain" ]]
server_pid="" server_root="" preserve_root=0
current_case=setup current_stage=initializing

fixture_processes() { pgrep -fal "$test_root" 2>/dev/null || true; }
assert_no_fixture_process() {
    local processes="$(fixture_processes)"
    [[ -z "$processes" ]] || {
        printf 'update-acceptance failure residual-process\n%s\n' "$processes" >&2
        preserve_root=1
        return 1
    }
}
stop_server() {
    [[ -n "$server_pid" ]] || return 0
    if ! macchannel_stop_process_group "$server_pid" "$server_pid"; then
        printf 'update-acceptance failure unreaped-server root=%s\n' "$(basename "$server_root")" >&2
        preserve_root=1
        return 70
    fi
    server_pid="" server_root=""
    [[ "$MACCHANNEL_PROCESS_GROUP_WAIT_STATUS" -eq 0 || \
        "$MACCHANNEL_PROCESS_GROUP_WAIT_STATUS" -eq 143 || \
        "$MACCHANNEL_PROCESS_GROUP_WAIT_STATUS" -eq 137 ]]
}
cleanup() {
    local exit_code=$?
    trap - EXIT INT TERM HUP
    set +e
    stop_server || exit_code=70
    assert_no_fixture_process || exit_code=70
    clean_security list-keychains -d user >"$test_root/keychains.after"
    if ! cmp "$test_root/keychains.before" "$test_root/keychains.after"; then
        printf 'update-acceptance failure keychain-search-list-changed\n' >&2
        exit_code=1 preserve_root=1
    fi
    if [[ "$exit_code" -ne 0 ]]; then
        printf 'update-acceptance failure case=%s stage=%s\n' \
            "$current_case" "$current_stage" >&2
    fi
    local keep_requested=0
    if [[ "${MACCHANNEL_TEST_KEEP_TEMP:-0}" == 1 ]]; then
        keep_requested=1 preserve_root=1
    fi
    if [[ "$preserve_root" -eq 0 ]] && macchannel_require_canonical_test_root "$test_root"; then
        rm -rf "$test_root"
    else
        if [[ "$keep_requested" -eq 1 && "$exit_code" -eq 0 ]]; then
            printf 'update-acceptance debug root-retained name=%s\n' "$(basename "$test_root")" >&2
        else
            printf 'update-acceptance failure root-retained name=%s\n' "$(basename "$test_root")" >&2
        fi
    fi
    exit "$exit_code"
}
trap cleanup EXIT INT TERM HUP

run_bounded() {
    local log=$1 timeout=$2
    shift 2
    set +e
    /usr/bin/python3 "$bounded_runner" --timeout "$timeout" --log "$log" "$@"
    bounded_status=$?
    set -e
}

if [[ "$static_only" != 1 ]]; then
    # The bounded wrapper must kill and reap a descendant tree before any updater launch.
    hang_marker="Hang$RANDOM$$"
    run_bounded "$test_root/hang.log" 0.5 env -i PATH="$PATH" HOME="$test_root/tool-home" \
        TMPDIR="$test_root/" /usr/bin/python3 "$hang_fixture" "$hang_marker"
    [[ "$bounded_status" -eq 124 ]]
    ! pgrep -f "$hang_marker" >/dev/null 2>&1
    assert_no_fixture_process
fi

clean_fixture_tool openssl genpkey -algorithm Ed25519 -out "$test_root/sparkle-a.pem" >/dev/null 2>&1
clean_fixture_tool openssl pkey -in "$test_root/sparkle-a.pem" -outform DER 2>/dev/null | tail -c 32 | \
    base64 >"$test_root/sparkle-a.key"
clean_fixture_tool openssl pkey -in "$test_root/sparkle-a.pem" -pubout -outform DER 2>/dev/null | \
    tail -c 32 | base64 >"$test_root/sparkle-a.pub"
clean_fixture_tool openssl genpkey -algorithm Ed25519 -out "$test_root/sparkle-b.pem" >/dev/null 2>&1
clean_fixture_tool openssl pkey -in "$test_root/sparkle-b.pem" -outform DER 2>/dev/null | tail -c 32 | \
    base64 >"$test_root/sparkle-b.key"
chmod 600 "$test_root"/sparkle-*

fixture_token="matrix$(date +%s)$$"
fixture_bundle_id="com.mason.macchannel.update-acceptance.$fixture_token"
fake_identity='Developer ID Application: Hostile Ambient (REALLOOK01)'
fake_keychain="$test_root/hostile-real-looking.keychain-db"
: >"$fake_keychain"; chmod 600 "$fake_keychain"
export MACCHANNEL_CODESIGN_IDENTITY="$fake_identity"
export MACCHANNEL_NOTARY_PROFILE=hostile-ambient-notary
export MACCHANNEL_UPDATE_TEST_CODESIGN_KEYCHAIN="$fake_keychain"
export MACCHANNEL_SPARKLE_ACCOUNT=hostile-ambient-account

primary_identity='Developer ID Application: ZENSYS TECHNOLOGIES - FZCO (XKAZ67HN45)'
alternate_identity='Apple Development: Qianyao Xu (H33N6G5622)'
clean_security find-identity -v -p codesigning "$signing_keychain" | \
    grep -F "\"$primary_identity\"" >/dev/null
clean_security find-identity -v -p codesigning "$signing_keychain" | \
    grep -F "\"$alternate_identity\"" >/dev/null
test_identity_for_signer() {
    case "$1" in
        primary) printf '%s\n' "$primary_identity" ;;
        alternate) printf '%s\n' "$alternate_identity" ;;
        *) return 64 ;;
    esac
}
test_team_for_signer() {
    case "$1" in
        primary) printf 'XKAZ67HN45\n' ;;
        alternate) printf 'H33N6G5622\n' ;;
        *) return 64 ;;
    esac
}

assert_embedded_team() {
    local app=$1 expected_team=$2
    local sparkle="$app/Contents/Frameworks/Sparkle.framework"
    local code details team
    local -a signed_code=(
        "$sparkle/Versions/Current/XPCServices/Downloader.xpc"
        "$sparkle/Versions/Current/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
        "$sparkle/Versions/Current/XPCServices/Installer.xpc"
        "$sparkle/Versions/Current/XPCServices/Installer.xpc/Contents/MacOS/Installer"
        "$sparkle/Versions/Current/Updater.app"
        "$sparkle/Versions/Current/Updater.app/Contents/MacOS/Updater"
        "$sparkle/Versions/Current/Autoupdate"
        "$sparkle"
        "$sparkle/Versions/Current/Sparkle"
        "$app/Contents/MacOS/WebRTC.framework"
        "$app/Contents/MacOS/WebRTC.framework/Versions/Current/WebRTC"
        "$app/Contents/MacOS/MacChannelUpdateAcceptance"
        "$app/Contents/MacOS/MacChannelUpdateLoadProbe"
        "$app/Contents/MacOS/MacChannelApp"
        "$app"
    )
    for code in "${signed_code[@]}"; do
        [[ ! -e "$code" ]] && continue
        clean_codesign --verify --strict "$code"
        details="$(clean_codesign -dvvv "$code" 2>&1)"
        team="$(sed -n 's/^TeamIdentifier=//p' <<<"$details" | tail -1)"
        [[ "$team" == "$expected_team" ]]
        clean_codesign -d -r- "$code" 2>&1 | grep -F 'designated =>' >/dev/null
    done
    clean_codesign --verify --deep --strict "$app"
    if clean_codesign -d --entitlements - "$app/Contents/MacOS/MacChannelApp" 2>&1 | \
        grep -F 'com.apple.security.cs.disable-library-validation' >/dev/null; then
        return 1
    fi
    for code in "$app/Contents/MacOS/MacChannelUpdateAcceptance" \
        "$app/Contents/MacOS/MacChannelUpdateLoadProbe"; do
        clean_codesign -d --entitlements - "$code" 2>&1 | \
            grep -F 'com.apple.security.cs.disable-library-validation' >/dev/null
    done
}

build_fixture_app() {
    local name=$1 version=$2 build=$3 signer=$4
    local build_root="$test_root/build-$name" output="$test_root/build-$name/MacChannel.app"
    local signing_identity expected_team
    signing_identity="$(test_identity_for_signer "$signer")"
    expected_team="$(test_team_for_signer "$signer")"
    mkdir -p "$build_root/home"; chmod 700 "$build_root" "$build_root/home"
    env -i PATH="$PATH" HOME="$signing_home" TMPDIR="$test_root/" LANG=C LC_ALL=C \
        MACCHANNEL_UPDATE_TESTING=1 MACCHANNEL_UPDATE_TEST_ROOT="$build_root" \
        MACCHANNEL_BUILD_CONFIGURATION=release MACCHANNEL_UPDATE_TEST_BUNDLE_ID="$fixture_bundle_id" \
        MACCHANNEL_UPDATE_TEST_FEED_URL=https://localhost:49191/appcast.xml \
        MACCHANNEL_UPDATE_TEST_PUBLIC_KEY_PATH="$test_root/sparkle-a.pub" \
        MACCHANNEL_UPDATE_TEST_EMBED_HARNESS=1 MACCHANNEL_UPDATE_TEST_SIGNER_VARIANT="$signer" \
        MACCHANNEL_UPDATE_TEST_CODESIGN_KEYCHAIN="$signing_keychain" \
        MACCHANNEL_CODESIGN_IDENTITY="$signing_identity" \
        MACCHANNEL_VERSION="$version" MACCHANNEL_BUILD_NUMBER="$build" \
        MACCHANNEL_APP_OUTPUT="$output" bash Scripts/build-app.sh >"$test_root/build-$name.log" 2>&1
    ! grep -F "$fake_identity" "$test_root/build-$name.log" >/dev/null
    ! grep -F "$fake_keychain" "$test_root/build-$name.log" >/dev/null
    assert_embedded_team "$output" "$expected_team"
}
build_fixture_app base 1.2.0 13 primary
build_fixture_app update-primary 1.2.1 14 primary
build_fixture_app update-alternate 1.2.1 14 alternate
build_fixture_app update-downgrade 1.1.0 12 primary

production_root="$test_root/production"
mkdir -p "$production_root/home"; chmod 700 "$production_root" "$production_root/home"
env -i PATH="$PATH" HOME="$production_root/home" TMPDIR="$test_root/" LANG=C LC_ALL=C \
    MACCHANNEL_BUILD_CONFIGURATION=release MACCHANNEL_APP_OUTPUT="$production_root/MacChannel.app" \
    bash Scripts/build-app.sh >"$test_root/build-production.log" 2>&1
! grep -F "$fake_identity" "$test_root/build-production.log" >/dev/null
! grep -F "$fake_keychain" "$test_root/build-production.log" >/dev/null

base_source="$test_root/build-base/MacChannel.app"
primary_source="$test_root/build-update-primary/MacChannel.app"
alternate_source="$test_root/build-update-alternate/MacChannel.app"
downgrade_source="$test_root/build-update-downgrade/MacChannel.app"
harness="$base_source/Contents/MacOS/MacChannelUpdateAcceptance"
load_probe="$base_source/Contents/MacOS/MacChannelUpdateLoadProbe"
for executable in "$harness" "$load_probe"; do
    entitlement_output="$(clean_codesign -d --entitlements - "$executable" 2>&1)"
    grep -F '[Key] com.apple.security.cs.disable-library-validation' <<<"$entitlement_output" >/dev/null
    grep -F '[Bool] true' <<<"$entitlement_output" >/dev/null
    otool -L "$executable" | grep -F '@rpath/Sparkle.framework/Versions/B/Sparkle' >/dev/null
done
production_app="$production_root/MacChannel.app"
[[ ! -e "$production_app/Contents/MacOS/MacChannelUpdateAcceptance" ]]
[[ ! -e "$production_app/Contents/MacOS/MacChannelUpdateLoadProbe" ]]
! plutil -extract MacChannelUpdateTestSigner raw -o - "$production_app/Contents/Info.plist" \
    >/dev/null 2>&1
! clean_codesign -d --entitlements - "$production_app/Contents/MacOS/MacChannelApp" 2>&1 | \
    grep -F 'com.apple.security.cs.disable-library-validation' >/dev/null

if [[ "$static_only" != 1 ]]; then
    # Exactly one minimal load-only probe precedes the full matrix.
    probe_marker="Probe${fixture_token}"
    run_bounded "$test_root/load-probe.log" 5 env -i PATH="$PATH" HOME="$test_root/tool-home" \
        TMPDIR="$test_root/" MACCHANNEL_UPDATE_TEST_PROBE_MARKER="$probe_marker" "$load_probe"
    [[ "$bounded_status" -eq 0 ]]
    grep -Fx "macchannel-update-load-probe marker=$probe_marker sparkle=2.9.6" \
        "$test_root/load-probe.log" >/dev/null
    assert_no_fixture_process
fi

prepare_app() {
    local source=$1 destination=$2 bundle_id=$3 signer=$4 payload=$5
    mkdir -p "$(dirname "$destination")"; chmod 700 "$(dirname "$destination")"
    local signing_log="$(dirname "$destination")/signing.log"
    ditto "$source" "$destination"
    plutil -replace CFBundleIdentifier -string "$bundle_id" "$destination/Contents/Info.plist"
    printf '%s\n' "$payload" >"$destination/Contents/Resources/UpdateAcceptancePayload.txt"
    local signing_identity expected_team
    signing_identity="$(test_identity_for_signer "$signer")"
    expected_team="$(test_team_for_signer "$signer")"
    local -a signing_args=(--force --sign "$signing_identity" --keychain "$signing_keychain" \
        --options runtime --timestamp=none)
    local sparkle="$destination/Contents/Frameworks/Sparkle.framework"
    local nested_code
    for nested_code in \
        "$sparkle/Versions/Current/XPCServices/Downloader.xpc" \
        "$sparkle/Versions/Current/XPCServices/Installer.xpc" \
        "$sparkle/Versions/Current/Updater.app" \
        "$sparkle/Versions/Current/Autoupdate"; do
        [[ ! -e "$nested_code" ]] || \
            clean_codesign "${signing_args[@]}" "$nested_code" >>"$signing_log" 2>&1
    done
    clean_codesign "${signing_args[@]}" "$sparkle" >>"$signing_log" 2>&1
    clean_codesign "${signing_args[@]}" "$destination/Contents/MacOS/WebRTC.framework" \
        >>"$signing_log" 2>&1
    clean_codesign "${signing_args[@]}" \
        --entitlements "$repo_root/Tests/Fixtures/UpdateAcceptance.entitlements" \
        "$destination/Contents/MacOS/MacChannelUpdateAcceptance" >>"$signing_log" 2>&1
    clean_codesign "${signing_args[@]}" \
        --entitlements "$repo_root/Tests/Fixtures/UpdateAcceptance.entitlements" \
        "$destination/Contents/MacOS/MacChannelUpdateLoadProbe" >>"$signing_log" 2>&1
    clean_codesign "${signing_args[@]}" "$destination/Contents/MacOS/MacChannelApp" \
        >>"$signing_log" 2>&1
    clean_codesign "${signing_args[@]}" \
        --requirements "=designated => identifier \"$bundle_id\" and info[MacChannelUpdateTestSigner] = \"$signer\"" \
        "$destination" >>"$signing_log" 2>&1
    assert_test_signature_chain "$destination" "$signer" "$expected_team"
}

assert_test_signature_chain() {
    local app=$1 expected_signer=$2 expected_team=$3
    local sparkle="$app/Contents/Frameworks/Sparkle.framework"
    local host_details host_team code code_details code_team requirement
    host_details="$(clean_codesign -dvvv "$app" 2>&1)"
    host_team="$(sed -n 's/^TeamIdentifier=//p' <<<"$host_details" | tail -1)"
    [[ "$host_team" == "$expected_team" ]]
    local -a signed_code=(
        "$sparkle/Versions/Current/XPCServices/Downloader.xpc"
        "$sparkle/Versions/Current/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
        "$sparkle/Versions/Current/XPCServices/Installer.xpc"
        "$sparkle/Versions/Current/XPCServices/Installer.xpc/Contents/MacOS/Installer"
        "$sparkle/Versions/Current/Updater.app"
        "$sparkle/Versions/Current/Updater.app/Contents/MacOS/Updater"
        "$sparkle/Versions/Current/Autoupdate"
        "$sparkle"
        "$sparkle/Versions/Current/Sparkle"
        "$app/Contents/MacOS/WebRTC.framework"
        "$app/Contents/MacOS/WebRTC.framework/Versions/Current/WebRTC"
        "$app/Contents/MacOS/MacChannelUpdateAcceptance"
        "$app/Contents/MacOS/MacChannelUpdateLoadProbe"
        "$app/Contents/MacOS/MacChannelApp"
        "$app"
    )
    for code in "${signed_code[@]}"; do
        [[ ! -e "$code" ]] && continue
        clean_codesign --verify --strict "$code"
        code_details="$(clean_codesign -dvvv "$code" 2>&1)"
        code_team="$(sed -n 's/^TeamIdentifier=//p' <<<"$code_details" | tail -1)"
        [[ "$code_team" == "$host_team" ]]
        requirement="$(clean_codesign -d -r- "$code" 2>&1)"
        grep -F 'designated =>' <<<"$requirement" >/dev/null
    done
    clean_codesign --verify --deep --strict "$app"
    requirement="$(clean_codesign -d -r- "$app" 2>&1)"
    grep -F "info[MacChannelUpdateTestSigner] = $expected_signer" <<<"$requirement" >/dev/null
    if clean_codesign -d --entitlements - "$app/Contents/MacOS/MacChannelApp" 2>&1 | \
        grep -F 'com.apple.security.cs.disable-library-validation' >/dev/null; then
        printf 'main host unexpectedly disables library validation\n' >&2
        return 1
    fi
    for code in \
        "$app/Contents/MacOS/MacChannelUpdateAcceptance" \
        "$app/Contents/MacOS/MacChannelUpdateLoadProbe"; do
        clean_codesign -d --entitlements - "$code" 2>&1 | \
            grep -F 'com.apple.security.cs.disable-library-validation' >/dev/null
    done
}

# First establish the complete static inside-out signature chain, then launch
# exactly one host smoke before any HTTPS/updater case.
smoke_root="$test_root/case-signature-smoke"
smoke_bundle="com.mason.macchannel.update-acceptance.smoke.$fixture_token"
mkdir -p "$smoke_root/home"; chmod 700 "$smoke_root" "$smoke_root/home"
prepare_app "$base_source" "$smoke_root/host/MacChannel.app" "$smoke_bundle" primary \
    "base-smoke-$fixture_token"
alternate_static_root="$test_root/case-signature-alternate-static"
alternate_static_bundle="com.mason.macchannel.update-acceptance.altstatic.$fixture_token"
mkdir -p "$alternate_static_root/home"
chmod 700 "$alternate_static_root" "$alternate_static_root/home"
prepare_app "$alternate_source" "$alternate_static_root/host/MacChannel.app" \
    "$alternate_static_bundle" alternate "alternate-static-$fixture_token"
if [[ "$static_only" == 1 ]]; then
    clean_security list-keychains -d user >"$test_root/keychains.static-final"
    cmp "$test_root/keychains.before" "$test_root/keychains.static-final"
    assert_no_fixture_process
    printf 'update-acceptance static signing PASS\n'
    exit 0
fi
smoke_marker="$smoke_root/launch.marker"
run_bounded "$smoke_root/smoke.log" 20 env -i PATH="$PATH" HOME="$smoke_root/home" \
    CFFIXED_USER_HOME="$smoke_root/home" TMPDIR="$smoke_root/" LANG=C LC_ALL=C \
    MACCHANNEL_RUNTIME=local-shell "$smoke_root/host/MacChannel.app/Contents/MacOS/MacChannelApp" \
    --smoke-test "$smoke_marker"
[[ "$bounded_status" -eq 0 && -f "$smoke_marker" ]]
grep -qx 'ready accessory' "$smoke_marker"
assert_no_fixture_process
printf 'update-acceptance case=signature-smoke result=pass\n'

start_server() {
    local case_root=$1 certificate_host=$2 redirect_url=${3:-}
    clean_fixture_tool openssl req -x509 -newkey rsa:2048 -nodes -keyout "$case_root/tls.key" \
        -out "$case_root/tls.crt" -days 1 -subj "/CN=$certificate_host" \
        -addext "subjectAltName=DNS:$certificate_host" \
        -addext 'basicConstraints=critical,CA:FALSE' \
        -addext 'keyUsage=critical,digitalSignature,keyEncipherment' \
        -addext 'extendedKeyUsage=serverAuth' >/dev/null 2>&1
    chmod 600 "$case_root/tls.key" "$case_root/tls.crt"
    tls_pin="$(clean_fixture_tool openssl x509 -in "$case_root/tls.crt" -outform DER | shasum -a 256 | awk '{print $1}')"
    local -a redirect_arguments=(--root "$case_root" --certificate "$case_root/tls.crt" \
        --key "$case_root/tls.key" --port-file "$case_root/server.port")
    [[ -z "$redirect_url" ]] || redirect_arguments+=(--redirect-url "$redirect_url")
    env -i PATH="$PATH" HOME="$case_root/home" TMPDIR="$case_root/" /usr/bin/python3 \
        "$https_server" "${redirect_arguments[@]}" >"$case_root/server.log" 2>&1 &
    server_pid=$! server_root="$case_root"
    for _ in {1..100}; do
        [[ -s "$case_root/server.port" ]] && break
        kill -0 "$server_pid" 2>/dev/null || break
        sleep 0.05
    done
    [[ -s "$case_root/server.port" ]]
    server_port="$(tr -d '\r\n' <"$case_root/server.port")"
    [[ "$server_port" =~ ^[1-9][0-9]*$ ]]
}

run_harness() {
    local case_root=$1 feed_url=$2 user_agent=$3 host="$1/host/MacChannel.app"
    local -a tls_environment=()
    case "${tls_configuration:-valid}" in
        valid)
            tls_environment+=(MACCHANNEL_UPDATE_TEST_TLS_CERT_SHA256="$tls_pin")
            tls_environment+=(MACCHANNEL_UPDATE_TEST_TLS_HOSTNAME=localhost)
            ;;
        missing-pin)
            tls_environment+=(MACCHANNEL_UPDATE_TEST_TLS_HOSTNAME=localhost)
            ;;
        malformed-pin)
            tls_environment+=(MACCHANNEL_UPDATE_TEST_TLS_CERT_SHA256=not-a-sha256)
            tls_environment+=(MACCHANNEL_UPDATE_TEST_TLS_HOSTNAME=localhost)
            ;;
        *) return 64 ;;
    esac
    run_bounded "$case_root/acceptance.log" 40 env -i PATH="$PATH" HOME="$case_root/home" \
        CFFIXED_USER_HOME="$case_root/home" TMPDIR="$case_root/" LANG=C LC_ALL=C \
        "${tls_environment[@]}" \
        "$host/Contents/MacOS/MacChannelUpdateAcceptance" "$host" --feed-url "$feed_url" \
        --check-immediately --grant-automatic-checks --verbose --user-agent-name "$user_agent"
    harness_status=$bounded_status
}

assert_exact_failure_chain() {
    local log=$1 expected=$2 actual
    actual="$(sed -n 's/^macchannel-update-acceptance state=failed domain=\([^ ]*\) code=\([-0-9]*\)$/\1:\2/p' "$log" | paste -sd, -)"
    [[ "$actual" == "$expected" ]] || {
        printf 'unexpected updater chain expected=%s actual=%s\n' "$expected" "$actual" >&2
        return 1
    }
}

assert_postconditions() {
    local case_root=$1 expected_build=$2 expected_signer=$3 expected_payload=$4 label=$5
    local app="$case_root/host/MacChannel.app"
    current_stage=postcondition-version
    test "$(plutil -extract CFBundleVersion raw -o - "$app/Contents/Info.plist")" = "$expected_build"
    current_stage=postcondition-signer
    test "$(plutil -extract MacChannelUpdateTestSigner raw -o - "$app/Contents/Info.plist")" = "$expected_signer"
    current_stage=postcondition-payload
    test "$(shasum -a 256 "$app/Contents/Resources/UpdateAcceptancePayload.txt" | awk '{print $1}')" = \
        "$(printf '%s\n' "$expected_payload" | shasum -a 256 | awk '{print $1}')"
    current_stage=postcondition-signature
    assert_test_signature_chain "$app" "$expected_signer" \
        "$(test_team_for_signer "$expected_signer")"
    local marker="Load${label//-/}${fixture_token}"
    current_stage=postcondition-load
    run_bounded "$case_root/post-load.log" 5 env -i PATH="$PATH" HOME="$case_root/home" \
        TMPDIR="$case_root/" MACCHANNEL_UPDATE_TEST_PROBE_MARKER="$marker" \
        "$app/Contents/MacOS/MacChannelUpdateLoadProbe"
    [[ "$bounded_status" -eq 0 ]]
    grep -Fx "macchannel-update-load-probe marker=$marker sparkle=2.9.6" "$case_root/post-load.log" >/dev/null
    local launch_marker="$case_root/launch.marker"
    current_stage=postcondition-launch
    run_bounded "$case_root/post-launch.log" 20 env -i PATH="$PATH" HOME="$case_root/home" \
        CFFIXED_USER_HOME="$case_root/home" TMPDIR="$case_root/" LANG=C LC_ALL=C \
        MACCHANNEL_RUNTIME=local-shell "$app/Contents/MacOS/MacChannelApp" \
        --smoke-test "$launch_marker"
    [[ "$bounded_status" -eq 0 && -f "$launch_marker" ]]
    grep -qx 'ready accessory' "$launch_marker"
    assert_no_fixture_process
}

resign_feed() {
    clean_fixture_tool "$sign_update" --ed-key-file "$test_root/sparkle-a.key" "$1" >/dev/null
}

run_case() {
    local name=$1 update_source=$2 signer=$3 mutation=$4 expectation=$5 expected_chain=$6
    local case_root="$test_root/case-$name"
    local bundle_id="com.mason.macchannel.update-acceptance.$name.$fixture_token"
    local base_payload="base-$name-$fixture_token" update_payload="update-$name-$fixture_token"
    current_case="$name" current_stage=prepare
    tls_configuration=valid
    mkdir -p "$case_root/home" "$case_root/stage"; chmod 700 "$case_root" "$case_root/home" "$case_root/stage"
    prepare_app "$base_source" "$case_root/host/MacChannel.app" "$bundle_id" primary "$base_payload"
    prepare_app "$update_source" "$case_root/stage/MacChannel.app" "$bundle_id" "$signer" "$update_payload"
    clean_fixture_tool hdiutil create -srcfolder "$case_root/stage" -volname "MacChannel $name" -fs HFS+ \
        -format UDZO -ov "$case_root/MacChannel.dmg" >/dev/null
    local certificate_host=localhost redirect_url="" feed_scheme=https
    [[ "$mutation" != hostname-mismatch ]] || certificate_host=wrong.local
    [[ "$mutation" != redirect-external ]] || redirect_url=https://example.invalid/appcast.xml
    [[ "$mutation" != non-https ]] || feed_scheme=http
    start_server "$case_root" "$certificate_host" "$redirect_url"
    [[ "$mutation" != wrong-certificate-pin ]] || \
        tls_pin=0000000000000000000000000000000000000000000000000000000000000000
    [[ "$mutation" != missing-pin ]] || tls_configuration=missing-pin
    [[ "$mutation" != malformed-pin ]] || tls_configuration=malformed-pin
    (cd "$case_root" && clean_fixture_tool "$generate_appcast" --ed-key-file "$test_root/sparkle-a.key" \
        --download-url-prefix "https://localhost:$server_port/" --maximum-versions 1 \
        --maximum-deltas 0 -o "$case_root/appcast.xml" "$case_root" >"$case_root/generate.log" 2>&1)
    case "$mutation" in
        tampered-feed) perl -0pi -e 's#<title>1\.2\.1</title>#<title>tampered</title>#' "$case_root/appcast.xml" ;;
        tampered-dmg) printf X >>"$case_root/MacChannel.dmg" ;;
        wrong-key)
            wrong_signature="$(clean_fixture_tool "$sign_update" --ed-key-file "$test_root/sparkle-b.key" -p "$case_root/MacChannel.dmg")"
            WRONG_SIGNATURE="$wrong_signature" perl -0pi -e \
                's#sparkle:edSignature="[^"]+"#sparkle:edSignature="$ENV{WRONG_SIGNATURE}"#' "$case_root/appcast.xml"
            resign_feed "$case_root/appcast.xml" ;;
        invalid-signature)
            perl -0pi -e 's#sparkle:edSignature="[^"]+"#sparkle:edSignature="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="#' "$case_root/appcast.xml"
            resign_feed "$case_root/appcast.xml" ;;
        downgrade)
            perl -0pi -e 's#<sparkle:version>12</sparkle:version>#<sparkle:version>14</sparkle:version>#; s#<sparkle:shortVersionString>1\.1\.0</sparkle:shortVersionString>#<sparkle:shortVersionString>1.2.1</sparkle:shortVersionString>#' "$case_root/appcast.xml"
            resign_feed "$case_root/appcast.xml" ;;
        external-enclosure)
            perl -0pi -e 's#url="https://localhost:[0-9]+/MacChannel.dmg"#url="https://example.invalid/MacChannel.dmg"#' "$case_root/appcast.xml"
            resign_feed "$case_root/appcast.xml" ;;
        external-release-notes)
            perl -0pi -e 's#</item>#<sparkle:releaseNotesLink>https://example.invalid/release-notes.md</sparkle:releaseNotesLink></item>#' "$case_root/appcast.xml"
            resign_feed "$case_root/appcast.xml" ;;
        hostname-mismatch|redirect-external|non-https|wrong-certificate-pin|missing-pin|malformed-pin|none) ;;
        *) return 64 ;;
    esac
    current_stage=updater
    run_harness "$case_root" "$feed_scheme://localhost:$server_port/appcast.xml" "Task7-$name"
    stop_server
    if [[ "$expectation" == reject ]]; then
        current_stage=updater-status
        [[ "$harness_status" -ne 0 && "$harness_status" -ne 124 ]]
        current_stage=error-chain
        assert_exact_failure_chain "$case_root/acceptance.log" "$expected_chain"
        assert_postconditions "$case_root" 13 primary "$base_payload" "$name"
    else
        current_stage=updater-status
        [[ "$harness_status" -eq 0 ]]
        current_stage=installation-finished
        grep -F 'Installation Finished.' "$case_root/acceptance.log" >/dev/null
        assert_postconditions "$case_root" 14 "$signer" "$update_payload" "$name"
    fi
    current_stage=tls-policy
    case "$mutation" in
        external-enclosure|external-release-notes) grep -F 'state=tls-policy-reject reason=non-local-host' "$case_root/acceptance.log" >/dev/null ;;
        redirect-external) grep -F 'state=tls-policy-reject reason=redirect' "$case_root/acceptance.log" >/dev/null ;;
        hostname-mismatch|wrong-certificate-pin) grep -F 'state=tls-policy-reject reason=certificate-or-hostname' "$case_root/acceptance.log" >/dev/null ;;
        missing-pin|malformed-pin) grep -F 'state=tls-policy-reject reason=invalid-pinning-configuration' "$case_root/acceptance.log" >/dev/null ;;
        non-https) grep -F 'state=tls-policy-reject reason=non-https' "$case_root/acceptance.log" >/dev/null ;;
    esac
    assert_no_fixture_process
    printf 'update-acceptance case=%s result=%s chain=%s\n' "$name" "$expectation" "${expected_chain:-none}"
    current_case=matrix current_stage=between-cases
}

run_case tampered-feed "$primary_source" primary tampered-feed reject SUSparkleErrorDomain:1000,SUSparkleErrorDomain:3002
run_case tampered-dmg "$primary_source" primary tampered-dmg reject SUSparkleErrorDomain:4005,SUSparkleErrorDomain:4005,SUSparkleErrorDomain:3002
run_case wrong-key "$alternate_source" alternate wrong-key reject SUSparkleErrorDomain:4005,SUSparkleErrorDomain:4005,SUSparkleErrorDomain:3002
run_case wrong-signer-invalid-ed "$alternate_source" alternate invalid-signature reject SUSparkleErrorDomain:4005,SUSparkleErrorDomain:4005,SUSparkleErrorDomain:3002
run_case downgrade "$downgrade_source" primary downgrade reject SUSparkleErrorDomain:4005,SUSparkleErrorDomain:10,SUSparkleErrorDomain:4006

# A dead server is a control that cannot satisfy crypto/downgrade assertions.
control_root="$test_root/case-dead-server-control"
control_bundle="com.mason.macchannel.update-acceptance.dead.$fixture_token"
control_payload="base-dead-$fixture_token"
mkdir -p "$control_root/home" "$control_root/stage"; chmod 700 "$control_root" "$control_root/home" "$control_root/stage"
prepare_app "$base_source" "$control_root/host/MacChannel.app" "$control_bundle" primary "$control_payload"
prepare_app "$primary_source" "$control_root/stage/MacChannel.app" "$control_bundle" primary "update-dead-$fixture_token"
clean_fixture_tool hdiutil create -srcfolder "$control_root/stage" -volname 'MacChannel dead control' -fs HFS+ \
    -format UDZO -ov "$control_root/MacChannel.dmg" >/dev/null
start_server "$control_root" localhost
(cd "$control_root" && clean_fixture_tool "$generate_appcast" --ed-key-file "$test_root/sparkle-a.key" \
    --download-url-prefix "https://localhost:$server_port/" --maximum-versions 1 \
    --maximum-deltas 0 -o "$control_root/appcast.xml" "$control_root" >"$control_root/generate.log" 2>&1)
control_port=$server_port control_pin=$tls_pin
stop_server
tls_pin=$control_pin
run_harness "$control_root" "https://localhost:$control_port/appcast.xml" Task7-DeadControl
[[ "$harness_status" -ne 0 && "$harness_status" -ne 124 ]]
assert_exact_failure_chain "$control_root/acceptance.log" \
    SUSparkleErrorDomain:2001,SUSparkleErrorDomain:2001,SUSparkleErrorDomain:2001,NSURLErrorDomain:-1004,kCFErrorDomainCFNetwork:-1004
! grep -F 'domain=SUSparkleErrorDomain code=3002' "$control_root/acceptance.log" >/dev/null
! grep -F 'domain=SUSparkleErrorDomain code=4006' "$control_root/acceptance.log" >/dev/null
assert_postconditions "$control_root" 13 primary "$control_payload" deadcontrol
printf 'update-acceptance case=dead-server-control result=distinct chain=NSURLErrorDomain:-1004\n'

run_case non-https-feed "$primary_source" primary non-https reject \
    SUSparkleErrorDomain:2001,SUSparkleErrorDomain:2001,SUSparkleErrorDomain:2001,NSURLErrorDomain:-1002
run_case missing-tls-pin "$primary_source" primary missing-pin reject \
    SUSparkleErrorDomain:2001,SUSparkleErrorDomain:2001,SUSparkleErrorDomain:2001,NSURLErrorDomain:-1002
run_case malformed-tls-pin "$primary_source" primary malformed-pin reject \
    SUSparkleErrorDomain:2001,SUSparkleErrorDomain:2001,SUSparkleErrorDomain:2001,NSURLErrorDomain:-1002
run_case wrong-certificate-pin "$primary_source" primary wrong-certificate-pin reject \
    SUSparkleErrorDomain:2001,SUSparkleErrorDomain:2001,SUSparkleErrorDomain:2001,NSURLErrorDomain:-999
run_case hostname-mismatch "$primary_source" primary hostname-mismatch reject \
    SUSparkleErrorDomain:2001,SUSparkleErrorDomain:2001,SUSparkleErrorDomain:2001,NSURLErrorDomain:-999
run_case redirect-external "$primary_source" primary redirect-external reject \
    SUSparkleErrorDomain:2001,SUSparkleErrorDomain:2001,SUSparkleErrorDomain:2001,NSURLErrorDomain:-1002
run_case external-enclosure "$primary_source" primary external-enclosure reject \
    SUSparkleErrorDomain:2001,NSURLErrorDomain:-1002
run_case external-release-notes "$primary_source" primary external-release-notes accept ''
grep -Fx 'macchannel-update-acceptance state=release-notes-failed domain=NSURLErrorDomain code=-1002' \
    "$test_root/case-external-release-notes/acceptance.log" >/dev/null
run_case rotated-signer-valid-ed "$alternate_source" alternate none accept ''

# Offline retains build 13; retry installs valid primary build 14.
offline_root="$test_root/case-offline-retry"
offline_bundle="com.mason.macchannel.update-acceptance.offline.$fixture_token"
offline_base_payload="base-offline-$fixture_token" offline_update_payload="update-offline-$fixture_token"
mkdir -p "$offline_root/home" "$offline_root/stage"; chmod 700 "$offline_root" "$offline_root/home" "$offline_root/stage"
prepare_app "$base_source" "$offline_root/host/MacChannel.app" "$offline_bundle" primary "$offline_base_payload"
prepare_app "$primary_source" "$offline_root/stage/MacChannel.app" "$offline_bundle" primary "$offline_update_payload"
clean_fixture_tool hdiutil create -srcfolder "$offline_root/stage" -volname 'MacChannel offline' -fs HFS+ \
    -format UDZO -ov "$offline_root/MacChannel.dmg" >/dev/null
start_server "$offline_root" localhost
offline_port=$server_port offline_pin=$tls_pin
(cd "$offline_root" && clean_fixture_tool "$generate_appcast" --ed-key-file "$test_root/sparkle-a.key" \
    --download-url-prefix "https://localhost:$offline_port/" --maximum-versions 1 \
    --maximum-deltas 0 -o "$offline_root/appcast.xml" "$offline_root" >"$offline_root/generate.log" 2>&1)
stop_server
tls_pin=$offline_pin
run_harness "$offline_root" "https://localhost:$offline_port/appcast.xml" Task7-Offline
[[ "$harness_status" -ne 0 && "$harness_status" -ne 124 ]]
assert_exact_failure_chain "$offline_root/acceptance.log" \
    SUSparkleErrorDomain:2001,SUSparkleErrorDomain:2001,SUSparkleErrorDomain:2001,NSURLErrorDomain:-1004,kCFErrorDomainCFNetwork:-1004
assert_postconditions "$offline_root" 13 primary "$offline_base_payload" offline
rm -f "$offline_root/server.port"
start_server "$offline_root" localhost
retry_port=$server_port
(cd "$offline_root" && clean_fixture_tool "$generate_appcast" --ed-key-file "$test_root/sparkle-a.key" \
    --download-url-prefix "https://localhost:$retry_port/" --maximum-versions 1 \
    --maximum-deltas 0 -o "$offline_root/appcast.xml" "$offline_root" >"$offline_root/retry-generate.log" 2>&1)
run_harness "$offline_root" "https://localhost:$retry_port/appcast.xml" Task7-Retry
stop_server
[[ "$harness_status" -eq 0 ]]
grep -F 'Installation Finished.' "$offline_root/acceptance.log" >/dev/null
assert_postconditions "$offline_root" 14 primary "$offline_update_payload" offlineretry
printf 'update-acceptance case=offline-retry result=recovered chain=NSURLErrorDomain:-1004\n'

clean_security list-keychains -d user >"$test_root/keychains.final"
cmp "$test_root/keychains.before" "$test_root/keychains.final"
assert_no_fixture_process
printf 'update-acceptance full-matrix-complete cases=17\n'
printf 'update acceptance PASS\n'
