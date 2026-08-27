#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
dmg="$repo_root/dist/MacChannel.dmg"
manifest="$repo_root/dist/MacChannel.manifest.json"
applications_dir="/Applications"
tailscale_cli=""
expected_commit=""

usage() {
    echo "usage: $0 [--dmg PATH] [--manifest PATH] [--applications-dir PATH] [--tailscale-cli PATH] [--expected-commit COMMIT]" >&2
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dmg) [[ $# -ge 2 ]] || usage; dmg="$2"; shift 2 ;;
        --manifest) [[ $# -ge 2 ]] || usage; manifest="$2"; shift 2 ;;
        --applications-dir) [[ $# -ge 2 ]] || usage; applications_dir="$2"; shift 2 ;;
        --tailscale-cli) [[ $# -ge 2 ]] || usage; tailscale_cli="$2"; shift 2 ;;
        --expected-commit) [[ $# -ge 2 ]] || usage; expected_commit="$2"; shift 2 ;;
        *) usage ;;
    esac
done

if [[ "$applications_dir" != /Applications && "${MACCHANNEL_INSTALL_TESTING:-}" != 1 ]]; then
    echo "custom application directory is available only to the installer contract test" >&2
    exit 2
fi
if [[ -n "$tailscale_cli" && "${MACCHANNEL_INSTALL_TESTING:-}" != 1 ]]; then
    echo "custom Tailscale CLI is available only to the installer contract test" >&2
    exit 2
fi
[[ -f "$dmg" && -f "$manifest" ]] || { echo "安装包或清单不存在" >&2; exit 2; }

if [[ -z "$expected_commit" ]]; then
    expected_commit="$(plutil -extract gitCommit raw -o - "$manifest" 2>/dev/null || true)"
fi
[[ "$expected_commit" =~ ^[0-9a-f]{40}$ ]] || { echo "预期提交无效" >&2; exit 2; }

manifest_commit="$(plutil -extract gitCommit raw -o - "$manifest" 2>/dev/null || true)"
manifest_sha="$(plutil -extract dmgSHA256 raw -o - "$manifest" 2>/dev/null || true)"
manifest_team="$(plutil -extract teamID raw -o - "$manifest" 2>/dev/null || true)"
release_state="$(plutil -extract releaseState raw -o - "$manifest" 2>/dev/null || true)"
[[ "$manifest_commit" == "$expected_commit" ]] || { echo "安装包提交与预期不一致" >&2; exit 2; }
[[ "$manifest_sha" =~ ^[0-9a-f]{64}$ && "$manifest_team" =~ ^[A-Z0-9]{10}$ ]] || {
    echo "安装包清单无效" >&2
    exit 1
}
actual_sha="$(shasum -a 256 "$dmg" | awk '{print $1}')"
[[ "$actual_sha" == "$manifest_sha" ]] || { echo "安装包校验和不一致" >&2; exit 1; }
codesign --verify --strict --verbose=2 "$dmg"

if [[ -z "$tailscale_cli" ]]; then
    for candidate in \
        /Applications/Tailscale.app/Contents/MacOS/Tailscale \
        /usr/local/bin/tailscale \
        /opt/homebrew/bin/tailscale; do
        if [[ -x "$candidate" ]]; then tailscale_cli="$candidate"; break; fi
    done
fi
[[ -x "$tailscale_cli" ]] || {
    echo "请先从 https://tailscale.com/download/mac 安装 Tailscale" >&2
    exit 2
}

check_root="$(mktemp -d "${TMPDIR:-/tmp}/macchannel-install.XXXXXX")"
chmod 700 "$check_root"
mount_path="$check_root/mounted"
status_json="$check_root/status.json"
serve_json="$check_root/serve.json"
backup_path="$applications_dir/.MacChannel.backup.$$"
new_path="$applications_dir/.MacChannel.install.$$"
target_path="$applications_dir/MacChannel.app"
mounted=0
backup_created=0
new_installed=0
success=0

cleanup() {
    local result=$?
    if [[ "$mounted" -eq 1 ]]; then
        hdiutil detach "$mount_path" -quiet >/dev/null 2>&1 || true
    fi
    if [[ "$success" -ne 1 && -w "$applications_dir" ]]; then
        if [[ "$new_installed" -eq 1 && -e "$target_path" ]]; then rm -rf "$target_path"; fi
        if [[ "$backup_created" -eq 1 && -e "$backup_path" ]]; then mv "$backup_path" "$target_path"; fi
        if [[ -e "$new_path" ]]; then rm -rf "$new_path"; fi
    fi
    case "$check_root" in
        "${TMPDIR:-/tmp}"/macchannel-install.*) rm -rf "$check_root" ;;
    esac
    exit "$result"
}
trap cleanup EXIT INT TERM HUP

if ! "$tailscale_cli" status --json >"$status_json" 2>/dev/null; then
    echo "无法读取 Tailscale 状态" >&2
    exit 2
fi
[[ "$(stat -f %z "$status_json")" -le 1048576 ]] || { echo "Tailscale 状态过大" >&2; exit 2; }
[[ "$(plutil -extract BackendState raw -o - "$status_json" 2>/dev/null || true)" == Running ]] || {
    echo "请先在 Tailscale 中登录并连接" >&2
    exit 2
}

if "$tailscale_cli" serve status --json >"$serve_json" 2>/dev/null; then
    [[ "$(stat -f %z "$serve_json")" -le 1048576 ]] || { echo "Serve 状态过大" >&2; exit 2; }
    forward=""
    forward_file="$check_root/serve-forward.txt"
    if plutil -extract 'TCP.51337.TCPForward' raw -o "$forward_file" "$serve_json" \
        >/dev/null 2>&1; then
        forward="$(<"$forward_file")"
    fi
    if [[ -n "$forward" && "$forward" != "127.0.0.1:51338" && \
        "$forward" != "tcp://127.0.0.1:51338" ]]; then
        echo "Tailscale Serve 端口 51337 已被其他服务使用" >&2
        exit 2
    fi
fi

mkdir -p "$mount_path"
hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$mount_path" -quiet
mounted=1
codesign --verify --deep --strict --verbose=2 "$mount_path/MacChannel.app"
app_details="$(codesign -dvvv "$mount_path/MacChannel.app" 2>&1)"
grep -F "TeamIdentifier=$manifest_team" <<<"$app_details" >/dev/null
version="$(plutil -extract version raw -o - "$manifest")"
build="$(plutil -extract build raw -o - "$manifest")"
test "$(plutil -extract CFBundleShortVersionString raw -o - "$mount_path/MacChannel.app/Contents/Info.plist")" = "$version"
test "$(plutil -extract CFBundleVersion raw -o - "$mount_path/MacChannel.app/Contents/Info.plist")" = "$build"

if [[ ! -d "$applications_dir" ]]; then
    mkdir -p "$applications_dir"
fi

if [[ -w "$applications_dir" ]]; then
    ditto --noextattr --noqtn "$mount_path/MacChannel.app" "$new_path"
    codesign --verify --deep --strict "$new_path"
    if [[ -e "$target_path" ]]; then
        mv "$target_path" "$backup_path"
        backup_created=1
    fi
    if [[ "${MACCHANNEL_INSTALL_TESTING:-}" == 1 && \
        "${MACCHANNEL_INSTALL_FAIL_AT:-}" == after-backup ]]; then
        exit 70
    fi
    mv "$new_path" "$target_path"
    new_installed=1
else
    echo "“应用程序”目录需要管理员授权，请在打开的 DMG 中把 MacChannel 拖到“应用程序”。" >&2
    open "$dmg"
    exit 2
fi

codesign --verify --deep --strict --verbose=2 "$target_path"
if [[ "$backup_created" -eq 1 && -e "$backup_path" ]]; then rm -rf "$backup_path"; fi
backup_created=0
success=1

if [[ "${MACCHANNEL_INSTALL_SKIP_LAUNCH:-}" != 1 ]]; then
    /usr/bin/open -n "$target_path"
fi

echo "MacChannel 已安装到“应用程序”"
if [[ "$release_state" == internalSignedNotNotarized ]]; then
    echo "此版本已签名但未公证。若 macOS 首次阻止打开，请在 Finder 中右键 MacChannel，选择一次“打开”；不要关闭 Gatekeeper 或 SIP。"
fi
echo "下一步：打开设置，选择“个人网络（推荐）”，点击“启用个人网络通道”。"
