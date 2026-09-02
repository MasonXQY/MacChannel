#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repo_root"

for required in Scripts/install-personal-mesh.sh Scripts/accept-personal-mesh.sh; do
    if [[ ! -x "$required" ]]; then
        echo "$required is missing or not executable" >&2
        exit 1
    fi
done

identity="${MACCHANNEL_CODESIGN_IDENTITY:-}"
[[ -n "$identity" ]] || { echo "MACCHANNEL_CODESIGN_IDENTITY is required" >&2; exit 2; }

test_root="$(mktemp -d "${TMPDIR:-/tmp}/macchannel-install-contract.XXXXXX")"
mount_path=""
cleanup() {
    if [[ -n "$mount_path" ]] && mount | grep -F " on $mount_path " >/dev/null; then
        hdiutil detach "$mount_path" -quiet || true
    fi
    case "$test_root" in
        "${TMPDIR:-/tmp}"/macchannel-install-contract.*) rm -rf "$test_root" ;;
        *) echo "refusing unexpected cleanup target" >&2 ;;
    esac
}
trap cleanup EXIT INT TERM

MACCHANNEL_CODESIGN_IDENTITY="$identity" bash Scripts/build-distribution.sh

fake_cli="$test_root/tailscale"
cat >"$fake_cli" <<'CLI'
#!/usr/bin/env bash
if [[ "$1 $2" == "status --json" ]]; then
    printf '%s\n' '{"BackendState":"Running"}'
elif [[ "$1 $2 $3" == "serve status --json" ]]; then
    printf '%s\n' '{}'
else
    exit 2
fi
CLI
chmod +x "$fake_cli"

applications="$test_root/Applications"
mkdir -p "$applications"
data_root="$test_root/Application Support/MacChannel"
mkdir -p "$data_root"
printf 'preserve-me\n' >"$data_root/settings.json"

MACCHANNEL_INSTALL_TESTING=1 \
MACCHANNEL_INSTALL_SKIP_LAUNCH=1 \
    bash Scripts/install-personal-mesh.sh \
    --dmg dist/DropMesh.dmg \
    --manifest dist/DropMesh.manifest.json \
    --applications-dir "$applications" \
    --tailscale-cli "$fake_cli" \
    --expected-commit "$(git rev-parse HEAD)"
codesign --verify --deep --strict "$applications/MacChannel.app"
grep -qx 'preserve-me' "$data_root/settings.json"

mkdir -p "$applications/MacChannel.app/Contents"
printf 'old-version\n' >"$applications/MacChannel.app/Contents/old.txt"
set +e
MACCHANNEL_INSTALL_TESTING=1 \
MACCHANNEL_INSTALL_SKIP_LAUNCH=1 \
MACCHANNEL_INSTALL_FAIL_AT=after-backup \
    bash Scripts/install-personal-mesh.sh \
    --dmg dist/DropMesh.dmg \
    --manifest dist/DropMesh.manifest.json \
    --applications-dir "$applications" \
    --tailscale-cli "$fake_cli" \
    --expected-commit "$(git rev-parse HEAD)" >/dev/null 2>&1
rollback_status=$?
set -e
test "$rollback_status" -eq 70
test -f "$applications/MacChannel.app/Contents/old.txt"

expect_failure() {
    local expected="$1"
    shift
    set +e
    "$@" >"$test_root/failure.log" 2>&1
    local actual=$?
    set -e
    test "$actual" -eq "$expected"
}

expect_failure 2 env MACCHANNEL_INSTALL_TESTING=1 MACCHANNEL_INSTALL_SKIP_LAUNCH=1 \
    bash Scripts/install-personal-mesh.sh --dmg dist/DropMesh.dmg \
    --manifest dist/DropMesh.manifest.json --applications-dir "$applications" \
    --tailscale-cli "$fake_cli" --expected-commit 0000000000000000000000000000000000000000

logged_out="$test_root/tailscale-logged-out"
sed 's/Running/Stopped/' "$fake_cli" >"$logged_out"
chmod +x "$logged_out"
expect_failure 2 env MACCHANNEL_INSTALL_TESTING=1 MACCHANNEL_INSTALL_SKIP_LAUNCH=1 \
    bash Scripts/install-personal-mesh.sh --dmg dist/DropMesh.dmg \
    --manifest dist/DropMesh.manifest.json --applications-dir "$applications" \
    --tailscale-cli "$logged_out" --expected-commit "$(git rev-parse HEAD)"

conflict="$test_root/tailscale-conflict"
sed 's/{}/{"TCP":{"51337":{"TCPForward":"127.0.0.1:9999"}}}/' "$fake_cli" >"$conflict"
chmod +x "$conflict"
expect_failure 2 env MACCHANNEL_INSTALL_TESTING=1 MACCHANNEL_INSTALL_SKIP_LAUNCH=1 \
    bash Scripts/install-personal-mesh.sh --dmg dist/DropMesh.dmg \
    --manifest dist/DropMesh.manifest.json --applications-dir "$applications" \
    --tailscale-cli "$conflict" --expected-commit "$(git rev-parse HEAD)"

mv "$fake_cli" "$test_root/tailscale-missing"
expect_failure 2 env MACCHANNEL_INSTALL_TESTING=1 MACCHANNEL_INSTALL_SKIP_LAUNCH=1 \
    bash Scripts/install-personal-mesh.sh --dmg dist/DropMesh.dmg \
    --manifest dist/DropMesh.manifest.json --applications-dir "$applications" \
    --tailscale-cli "$fake_cli" --expected-commit "$(git rev-parse HEAD)"

cp dist/DropMesh.dmg "$test_root/mutated.dmg"
printf 'mutation' >>"$test_root/mutated.dmg"
expect_failure 1 env MACCHANNEL_INSTALL_TESTING=1 MACCHANNEL_INSTALL_SKIP_LAUNCH=1 \
    bash Scripts/install-personal-mesh.sh --dmg "$test_root/mutated.dmg" \
    --manifest dist/DropMesh.manifest.json --applications-dir "$applications" \
    --tailscale-cli "$test_root/tailscale-missing" --expected-commit "$(git rev-parse HEAD)"

if rg -n -i 'spctl[^\n]*master-disable|csrutil|xattr[^\n]*quarantine' \
    Scripts/install-personal-mesh.sh Scripts/accept-personal-mesh.sh; then
    echo "installer attempts to weaken macOS security" >&2
    exit 1
fi

bash Scripts/accept-personal-mesh.sh --validate-only docs/acceptance/personal-mesh-real-mac.md
echo "personal mesh installer contract PASS"
