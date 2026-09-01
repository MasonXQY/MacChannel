#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repo_root"
generate_appcast="$repo_root/.build/tools/Sparkle-2.9.6/bin/generate_appcast"
sign_update="$repo_root/.build/tools/Sparkle-2.9.6/bin/sign_update"
[[ -x "$generate_appcast" && -x "$sign_update" ]]

temp_base="${TMPDIR:-/tmp}"
temp_base="${temp_base%/}"
test_root="$(mktemp -d "$temp_base/macchannel-update-acceptance.matrix.XXXXXX")"
chmod 700 "$test_root"
server_pid=""
child_pid=""
preserve_root=0

cleanup() {
    local exit_code=$?
    trap - EXIT INT TERM
    set +e
    if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
        kill "$server_pid" 2>/dev/null
        wait "$server_pid" 2>/dev/null
    fi
    if [[ -n "$child_pid" ]] && kill -0 "$child_pid" 2>/dev/null; then
        kill "$child_pid" 2>/dev/null
        preserve_root=1
    fi
    if ps -axo command= | grep -F "$test_root" | grep -v grep >/dev/null; then
        preserve_root=1
    fi
    if [[ "$preserve_root" -eq 0 ]]; then
        rm -rf "$test_root"
    else
        printf 'update-acceptance failure residual-process root-retained\n' >&2
    fi
    exit "$exit_code"
}
trap cleanup EXIT INT TERM

assert_no_fixture_process() {
    for _ in {1..30}; do
        if ! ps -axo command= | grep -F "$test_root" | grep -v grep >/dev/null; then
            return 0
        fi
        sleep 0.1
    done
    printf 'update-acceptance failure residual-process\n' >&2
    preserve_root=1
    return 1
}

openssl genpkey -algorithm Ed25519 -out "$test_root/sparkle-a.pem" >/dev/null 2>&1
openssl pkey -in "$test_root/sparkle-a.pem" -outform DER 2>/dev/null | \
    tail -c 32 | base64 >"$test_root/sparkle-a.key"
openssl pkey -in "$test_root/sparkle-a.pem" -pubout -outform DER 2>/dev/null | \
    tail -c 32 | base64 >"$test_root/sparkle-a.pub"
openssl genpkey -algorithm Ed25519 -out "$test_root/sparkle-b.pem" >/dev/null 2>&1
openssl pkey -in "$test_root/sparkle-b.pem" -outform DER 2>/dev/null | \
    tail -c 32 | base64 >"$test_root/sparkle-b.key"
chmod 600 "$test_root"/sparkle-*

fixture_token="matrix$(date +%s)$$"
fixture_bundle_id="com.mason.macchannel.update-acceptance.$fixture_token"
common_build_environment=(
    MACCHANNEL_UPDATE_TESTING=1
    MACCHANNEL_BUILD_CONFIGURATION=release
    MACCHANNEL_UPDATE_TEST_BUNDLE_ID="$fixture_bundle_id"
    MACCHANNEL_UPDATE_TEST_FEED_URL=https://localhost:49191/appcast.xml
    MACCHANNEL_UPDATE_TEST_PUBLIC_KEY_PATH="$test_root/sparkle-a.pub"
    MACCHANNEL_UPDATE_TEST_EMBED_HARNESS=1
    MACCHANNEL_CODESIGN_IDENTITY=-
)

build_fixture_app() {
    local output=$1 version=$2 build=$3 signer=$4
    env "${common_build_environment[@]}" \
        MACCHANNEL_UPDATE_TEST_SIGNER_VARIANT="$signer" \
        MACCHANNEL_VERSION="$version" \
        MACCHANNEL_BUILD_NUMBER="$build" \
        MACCHANNEL_APP_OUTPUT="$output" \
        bash Scripts/build-app.sh >"$test_root/build-$signer-$build.log" 2>&1
    codesign --verify --deep --strict "$output"
}

build_fixture_app "$test_root/base/MacChannel.app" 1.2.0 13 primary
build_fixture_app "$test_root/update-primary/MacChannel.app" 1.2.1 14 primary
build_fixture_app "$test_root/update-alternate/MacChannel.app" 1.2.1 14 alternate
build_fixture_app "$test_root/update-downgrade/MacChannel.app" 1.1.0 12 primary
MACCHANNEL_BUILD_CONFIGURATION=release \
    MACCHANNEL_APP_OUTPUT="$test_root/production/MacChannel.app" \
    bash Scripts/build-app.sh >"$test_root/build-production.log" 2>&1

test_app="$test_root/base/MacChannel.app"
harness="$test_app/Contents/MacOS/MacChannelUpdateAcceptance"
load_probe="$test_app/Contents/MacOS/MacChannelUpdateLoadProbe"
for executable in "$harness" "$load_probe"; do
    entitlement_output="$(codesign -d --entitlements - "$executable" 2>&1)"
    grep -F '[Key] com.apple.security.cs.disable-library-validation' \
        <<<"$entitlement_output" >/dev/null
    grep -F '[Bool] true' <<<"$entitlement_output" >/dev/null
    otool -L "$executable" | \
        grep -F '@rpath/Sparkle.framework/Versions/B/Sparkle' >/dev/null
done
[[ ! -e "$test_root/production/MacChannel.app/Contents/MacOS/MacChannelUpdateAcceptance" ]]
[[ ! -e "$test_root/production/MacChannel.app/Contents/MacOS/MacChannelUpdateLoadProbe" ]]
if plutil -extract MacChannelUpdateTestSigner raw -o - \
    "$test_root/production/MacChannel.app/Contents/Info.plist" >/dev/null 2>&1; then
    exit 1
fi
test "$(security list-keychains -d user | tr -d ' \t\"')" = \
    /Users/mason/Library/Keychains/login.keychain-db

probe_marker="Probe${fixture_token}"
MACCHANNEL_UPDATE_TEST_PROBE_MARKER="$probe_marker" \
    "$load_probe" >"$test_root/load-probe.log" 2>&1 &
child_pid=$!
probe_done=0
for _ in {1..50}; do
    if ! kill -0 "$child_pid" 2>/dev/null; then probe_done=1; break; fi
    sleep 0.1
done
[[ "$probe_done" -eq 1 ]] || exit 70
wait "$child_pid"
child_pid=""
grep -Fx "macchannel-update-load-probe marker=$probe_marker sparkle=2.9.6" \
    "$test_root/load-probe.log" >/dev/null
assert_no_fixture_process

prepare_app() {
    local source=$1 destination=$2 bundle_id=$3 signer=$4
    mkdir -p "$(dirname "$destination")"
    ditto "$source" "$destination"
    plutil -replace CFBundleIdentifier -string "$bundle_id" \
        "$destination/Contents/Info.plist"
    codesign --force --sign - --options runtime --timestamp=none \
        --requirements "=designated => identifier \"$bundle_id\" and info[MacChannelUpdateTestSigner] = \"$signer\"" \
        "$destination" >/dev/null
    codesign --verify --deep --strict "$destination"
}

start_server() {
    local case_root=$1 port=$2
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$case_root/tls.key" -out "$case_root/tls.crt" -days 1 \
        -subj /CN=localhost -addext subjectAltName=DNS:localhost >/dev/null 2>&1
    chmod 600 "$case_root/tls.key" "$case_root/tls.crt"
    tls_pin="$(openssl x509 -in "$case_root/tls.crt" -outform DER | \
        shasum -a 256 | awk '{print $1}')"
    python3 -c 'import http.server,ssl,sys;root,cert,key,port=sys.argv[1:];h=lambda *a,**kw:http.server.SimpleHTTPRequestHandler(*a,directory=root,**kw);s=http.server.ThreadingHTTPServer(("127.0.0.1",int(port)),h);c=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);c.load_cert_chain(cert,key);s.socket=c.wrap_socket(s.socket,server_side=True);s.serve_forever()' \
        "$case_root" "$case_root/tls.crt" "$case_root/tls.key" "$port" \
        >"$case_root/server.log" 2>&1 &
    server_pid=$!
    local ready=0
    for _ in {1..50}; do
        kill -0 "$server_pid" 2>/dev/null || break
        if curl --silent --insecure "https://localhost:$port/appcast.xml" >/dev/null; then
            ready=1
            break
        fi
        sleep 0.1
    done
    [[ "$ready" -eq 1 ]]
}

stop_server() {
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    server_pid=""
}

run_harness() {
    local case_root=$1 port=$2 user_agent=$3
    local host="$case_root/host/MacChannel.app"
    MACCHANNEL_UPDATE_TEST_TLS_CERT_SHA256="$tls_pin" \
        HOME="$case_root/home" CFFIXED_USER_HOME="$case_root/home" \
        "$host/Contents/MacOS/MacChannelUpdateAcceptance" "$host" \
        --feed-url "https://localhost:$port/appcast.xml" \
        --check-immediately --grant-automatic-checks --verbose \
        --user-agent-name "$user_agent" >"$case_root/acceptance.log" 2>&1 &
    child_pid=$!
    local completed=0
    for _ in {1..300}; do
        if ! kill -0 "$child_pid" 2>/dev/null; then completed=1; break; fi
        sleep 0.1
    done
    [[ "$completed" -eq 1 ]] || return 70
    set +e
    wait "$child_pid"
    harness_status=$?
    set -e
    child_pid=""
}

run_case() {
    local name=$1 update_source=$2 signer=$3 mutation=$4 expectation=$5
    local case_root="$test_root/case-$name"
    local bundle_id="com.mason.macchannel.update-acceptance.$name.$fixture_token"
    mkdir -p "$case_root/stage" "$case_root/home"
    prepare_app "$test_root/base/MacChannel.app" \
        "$case_root/host/MacChannel.app" "$bundle_id" primary
    prepare_app "$update_source" "$case_root/stage/MacChannel.app" "$bundle_id" "$signer"
    hdiutil create -srcfolder "$case_root/stage" -volname "MacChannel $name" \
        -fs HFS+ -format UDZO -ov "$case_root/MacChannel.dmg" >/dev/null
    local port
    port="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
    (cd "$case_root" && "$generate_appcast" --ed-key-file "$test_root/sparkle-a.key" \
        --download-url-prefix "https://localhost:$port/" --maximum-versions 1 \
        --maximum-deltas 0 -o "$case_root/appcast.xml" "$case_root" \
        >"$case_root/generate.log" 2>&1)
    case "$mutation" in
        tampered-feed)
            perl -0pi -e 's#<title>1\.2\.1</title>#<title>tampered</title>#' \
                "$case_root/appcast.xml"
            ;;
        tampered-dmg)
            printf X >>"$case_root/MacChannel.dmg"
            ;;
        wrong-key)
            wrong_signature="$("$sign_update" --ed-key-file "$test_root/sparkle-b.key" \
                -p "$case_root/MacChannel.dmg")"
            WRONG_SIGNATURE="$wrong_signature" perl -0pi -e \
                's#sparkle:edSignature="[^"]+"#sparkle:edSignature="$ENV{WRONG_SIGNATURE}"#' \
                "$case_root/appcast.xml"
            "$sign_update" --ed-key-file "$test_root/sparkle-a.key" \
                "$case_root/appcast.xml" >/dev/null
            ;;
        invalid-signature)
            perl -0pi -e \
                's#sparkle:edSignature="[^"]+"#sparkle:edSignature="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="#' \
                "$case_root/appcast.xml"
            "$sign_update" --ed-key-file "$test_root/sparkle-a.key" \
                "$case_root/appcast.xml" >/dev/null
            ;;
        downgrade)
            perl -0pi -e \
                's#<sparkle:version>12</sparkle:version>#<sparkle:version>14</sparkle:version>#; s#<sparkle:shortVersionString>1\.1\.0</sparkle:shortVersionString>#<sparkle:shortVersionString>1.2.1</sparkle:shortVersionString>#' \
                "$case_root/appcast.xml"
            "$sign_update" --ed-key-file "$test_root/sparkle-a.key" \
                "$case_root/appcast.xml" >/dev/null
            ;;
        none) ;;
    esac
    start_server "$case_root" "$port"
    run_harness "$case_root" "$port" "Task7-$name"
    stop_server
    host="$case_root/host/MacChannel.app"
    if [[ "$expectation" == reject ]]; then
        [[ "$harness_status" -ne 0 ]]
        grep -F 'macchannel-update-acceptance state=failed' \
            "$case_root/acceptance.log" >/dev/null
        test "$(plutil -extract CFBundleVersion raw -o - "$host/Contents/Info.plist")" = 13
    else
        [[ "$harness_status" -eq 0 ]]
        grep -F 'Installation Finished.' "$case_root/acceptance.log" >/dev/null
        test "$(plutil -extract CFBundleVersion raw -o - "$host/Contents/Info.plist")" = 14
    fi
    assert_no_fixture_process
    printf 'update-acceptance case=%s result=%s\n' "$name" "$expectation"
}

run_case tampered-feed "$test_root/update-primary/MacChannel.app" primary tampered-feed reject
run_case tampered-dmg "$test_root/update-primary/MacChannel.app" primary tampered-dmg reject
run_case wrong-key "$test_root/update-alternate/MacChannel.app" alternate wrong-key reject
run_case wrong-signer-invalid-ed "$test_root/update-alternate/MacChannel.app" alternate invalid-signature reject
run_case downgrade "$test_root/update-downgrade/MacChannel.app" primary downgrade reject
run_case rotated-signer-valid-ed "$test_root/update-alternate/MacChannel.app" alternate none accept

offline_root="$test_root/case-offline-retry"
offline_bundle="com.mason.macchannel.update-acceptance.offline.$fixture_token"
mkdir -p "$offline_root/stage" "$offline_root/home"
prepare_app "$test_root/base/MacChannel.app" "$offline_root/host/MacChannel.app" \
    "$offline_bundle" primary
prepare_app "$test_root/update-primary/MacChannel.app" "$offline_root/stage/MacChannel.app" \
    "$offline_bundle" primary
hdiutil create -srcfolder "$offline_root/stage" -volname 'MacChannel offline' \
    -fs HFS+ -format UDZO -ov "$offline_root/MacChannel.dmg" >/dev/null
offline_port="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
host="$offline_root/host/MacChannel.app"
MACCHANNEL_UPDATE_TEST_TLS_CERT_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    HOME="$offline_root/home" CFFIXED_USER_HOME="$offline_root/home" \
    "$host/Contents/MacOS/MacChannelUpdateAcceptance" "$host" \
    --feed-url "https://localhost:$offline_port/appcast.xml" --check-immediately \
    --grant-automatic-checks --verbose --user-agent-name Task7-Offline \
    >"$offline_root/offline.log" 2>&1 &
child_pid=$!
offline_done=0
for _ in {1..150}; do
    if ! kill -0 "$child_pid" 2>/dev/null; then offline_done=1; break; fi
    sleep 0.1
done
[[ "$offline_done" -eq 1 ]] || exit 70
set +e
wait "$child_pid"
offline_status=$?
set -e
child_pid=""
[[ "$offline_status" -ne 0 ]]
grep -F 'state=failed domain=NSURLErrorDomain code=-1004' \
    "$offline_root/offline.log" >/dev/null
test "$(plutil -extract CFBundleVersion raw -o - "$host/Contents/Info.plist")" = 13
assert_no_fixture_process
retry_port="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
(cd "$offline_root" && "$generate_appcast" --ed-key-file "$test_root/sparkle-a.key" \
    --download-url-prefix "https://localhost:$retry_port/" --maximum-versions 1 \
    --maximum-deltas 0 -o "$offline_root/appcast.xml" "$offline_root" \
    >"$offline_root/generate.log" 2>&1)
start_server "$offline_root" "$retry_port"
run_harness "$offline_root" "$retry_port" Task7-Retry
stop_server
[[ "$harness_status" -eq 0 ]]
grep -F 'Installation Finished.' "$offline_root/acceptance.log" >/dev/null
test "$(plutil -extract CFBundleVersion raw -o - "$host/Contents/Info.plist")" = 14
assert_no_fixture_process
printf 'update-acceptance case=offline-retry result=recovered\n'
printf 'update acceptance PASS\n'
