#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
source "$repo_root/Scripts/update-test-paths.sh"
dmg="$repo_root/dist/DropMesh.dmg"
manifest="$repo_root/dist/DropMesh.manifest.json"
applications_dir="/Applications"
expected_commit=""

usage() {
    echo "usage: $0 [--dmg PATH] [--manifest PATH] [--applications-dir PATH] [--expected-commit COMMIT]" >&2
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dmg) [[ $# -ge 2 ]] || usage; dmg="$2"; shift 2 ;;
        --manifest) [[ $# -ge 2 ]] || usage; manifest="$2"; shift 2 ;;
        --applications-dir) [[ $# -ge 2 ]] || usage; applications_dir="$2"; shift 2 ;;
        --expected-commit) [[ $# -ge 2 ]] || usage; expected_commit="$2"; shift 2 ;;
        *) usage ;;
    esac
done

installer_testing="${MACCHANNEL_INSTALL_TESTING:-0}"
install_test_root="${MACCHANNEL_INSTALL_TEST_ROOT:-}"
requested_stapler_command="${MACCHANNEL_INSTALL_STAPLER_COMMAND:-}"
requested_spctl_command="${MACCHANNEL_INSTALL_SPCTL_COMMAND:-}"
case "$installer_testing" in
    0|1) ;;
    *) echo "MACCHANNEL_INSTALL_TESTING must be 0 or 1" >&2; exit 2 ;;
esac

if [[ "$installer_testing" == 1 ]]; then
    if [[ "$applications_dir" == /Applications ]] || \
        ! macchannel_require_isolated_test_root "$repo_root" "$install_test_root" || \
        ! macchannel_require_direct_child_path "$install_test_root" \
            "$applications_dir" Applications; then
        echo "installer test controls require a non-/Applications controlled root" >&2
        exit 2
    fi
    for requested_command in "$requested_stapler_command" "$requested_spctl_command"; do
        if [[ -n "$requested_command" ]]; then
            macchannel_require_contained_regular_file "$install_test_root" \
                "$requested_command" || {
                echo "installer test validator must be contained in the controlled root" >&2
                exit 2
            }
            [[ -x "$requested_command" ]] || {
                echo "installer test validator must be executable" >&2
                exit 2
            }
        fi
    done
elif [[ "$applications_dir" != /Applications ]]; then
    echo "custom application directory is available only to the installer contract test" >&2
    exit 2
elif [[ -n "$install_test_root" || -n "$requested_stapler_command" || \
    -n "$requested_spctl_command" || -n "${MACCHANNEL_INSTALL_FAIL_AT:-}" ]]; then
    echo "installer test controls require MACCHANNEL_INSTALL_TESTING=1" >&2
    exit 2
fi

run_stapler_validate() {
    if [[ -n "$requested_stapler_command" ]]; then
        "$requested_stapler_command" validate "$dmg"
    else
        /usr/bin/xcrun stapler validate "$dmg"
    fi
}

run_spctl_open() {
    if [[ -n "$requested_spctl_command" ]]; then
        "$requested_spctl_command" --assess --type open \
            --context context:primary-signature --verbose=2 "$dmg"
    else
        /usr/sbin/spctl --assess --type open --context context:primary-signature \
            --verbose=2 "$dmg"
    fi
}

run_spctl_execute() {
    local mounted_app="$1"
    if [[ -n "$requested_spctl_command" ]]; then
        "$requested_spctl_command" --assess --type execute --verbose=2 "$mounted_app"
    else
        /usr/sbin/spctl --assess --type execute --verbose=2 "$mounted_app"
    fi
}

[[ -f "$dmg" && ! -L "$dmg" && -f "$manifest" && ! -L "$manifest" ]] || {
    echo "安装包或清单不存在" >&2
    exit 2
}

anchor_path="$repo_root/Distribution/ProductionSigningAnchor.plist"
[[ -f "$anchor_path" && ! -L "$anchor_path" ]] || {
    echo "生产签名锚点无效" >&2
    exit 1
}
anchor_product="$(plutil -extract product raw -o - "$anchor_path" 2>/dev/null || true)"
anchor_bundle_id="$(plutil -extract bundleIdentifier raw -o - "$anchor_path" 2>/dev/null || true)"
anchor_executable="$(plutil -extract bundleExecutable raw -o - "$anchor_path" 2>/dev/null || true)"
anchor_team="$(plutil -extract teamID raw -o - "$anchor_path" 2>/dev/null || true)"
anchor_requirement="$(plutil -extract designatedRequirement raw -o - "$anchor_path" 2>/dev/null || true)"
expected_anchor_requirement='identifier "com.mason.macchannel" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = XKAZ67HN45'
[[ "$anchor_product" == DropMesh && \
    "$anchor_bundle_id" == com.mason.macchannel && \
    "$anchor_executable" == MacChannelApp && \
    "$anchor_team" == XKAZ67HN45 && \
    "$anchor_requirement" == "$expected_anchor_requirement" ]] || {
    echo "生产签名锚点无效" >&2
    exit 1
}

if [[ -z "$expected_commit" ]]; then
    expected_commit="$(plutil -extract gitCommit raw -o - "$manifest" 2>/dev/null || true)"
fi
[[ "$expected_commit" =~ ^[0-9a-f]{40}$ ]] || { echo "预期提交无效" >&2; exit 2; }

manifest_commit="$(plutil -extract gitCommit raw -o - "$manifest" 2>/dev/null || true)"
manifest_sha="$(plutil -extract dmgSHA256 raw -o - "$manifest" 2>/dev/null || true)"
manifest_team="$(plutil -extract teamID raw -o - "$manifest" 2>/dev/null || true)"
manifest_requirement="$(plutil -extract designatedRequirement raw -o - "$manifest" 2>/dev/null || true)"
manifest_bundle_id="$(plutil -extract bundleIdentifier raw -o - "$manifest" 2>/dev/null || true)"
manifest_product="$(plutil -extract product raw -o - "$manifest" 2>/dev/null || true)"
version="$(plutil -extract version raw -o - "$manifest" 2>/dev/null || true)"
build="$(plutil -extract build raw -o - "$manifest" 2>/dev/null || true)"
release_state="$(plutil -extract releaseState raw -o - "$manifest" 2>/dev/null || true)"
[[ "$manifest_commit" == "$expected_commit" ]] || { echo "安装包提交与预期不一致" >&2; exit 2; }
[[ "$manifest_sha" =~ ^[0-9a-f]{64}$ && \
    "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ && \
    "$build" =~ ^[1-9][0-9]*$ ]] || {
    echo "安装包清单无效" >&2
    exit 1
}
[[ "$manifest_product" == "$anchor_product" && \
    "$manifest_bundle_id" == "$anchor_bundle_id" && \
    "$manifest_team" == "$anchor_team" && \
    "$manifest_requirement" == "$anchor_requirement" && \
    "$release_state" == notarized ]] || {
    echo "安装包清单与生产签名锚点不一致" >&2
    exit 1
}
actual_sha="$(shasum -a 256 "$dmg" | awk '{print $1}')"
[[ "$actual_sha" == "$manifest_sha" ]] || { echo "安装包校验和不一致" >&2; exit 1; }
/usr/bin/codesign --verify --strict --verbose=2 "$dmg"
dmg_details="$(/usr/bin/codesign -dvvv "$dmg" 2>&1)"
actual_dmg_team="$(sed -n 's/^TeamIdentifier=//p' <<<"$dmg_details" | tail -n 1)"
[[ "$actual_dmg_team" == "$anchor_team" ]] || {
    echo "安装镜像签名者不受信任" >&2
    exit 1
}
run_stapler_validate
run_spctl_open

check_root="$(mktemp -d "${TMPDIR:-/tmp}/macchannel-install.XXXXXX")"
chmod 700 "$check_root"
mount_path="$check_root/mounted"
backup_path="$applications_dir/.DropMesh.backup.$$"
new_path="$applications_dir/.DropMesh.install.$$"
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

mkdir -p "$mount_path"
hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$mount_path" -quiet
mounted=1
mounted_app="$mount_path/MacChannel.app"
mounted_plist="$mounted_app/Contents/Info.plist"
[[ -d "$mounted_app" && ! -L "$mounted_app" && -f "$mounted_plist" && \
    ! -L "$mounted_plist" ]] || {
    echo "安装镜像中的应用无效" >&2
    exit 1
}
/usr/bin/codesign --verify --deep --strict --verbose=2 "$mounted_app"
/usr/bin/codesign --verify --deep --strict \
    --test-requirement "=$anchor_requirement" "$mounted_app"
app_identity="$(/usr/bin/codesign -d --verbose=4 --requirements - "$mounted_app" 2>&1)"
actual_team="$(sed -n 's/^TeamIdentifier=//p' <<<"$app_identity" | tail -n 1)"
actual_requirement="$(sed -n 's/^designated => //p' <<<"$app_identity" | tail -n 1)"
actual_bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$mounted_plist" 2>/dev/null || true)"
actual_executable="$(plutil -extract CFBundleExecutable raw -o - "$mounted_plist" 2>/dev/null || true)"
actual_product="$(plutil -extract CFBundleName raw -o - "$mounted_plist" 2>/dev/null || true)"
actual_version="$(plutil -extract CFBundleShortVersionString raw -o - "$mounted_plist" 2>/dev/null || true)"
actual_build="$(plutil -extract CFBundleVersion raw -o - "$mounted_plist" 2>/dev/null || true)"
[[ "$actual_team" == "$anchor_team" && \
    "$actual_requirement" == "$anchor_requirement" && \
    "$actual_bundle_id" == "$anchor_bundle_id" && \
    "$actual_executable" == "$anchor_executable" && \
    "$actual_product" == "$anchor_product" && \
    "$actual_version" == "$version" && "$actual_build" == "$build" ]] || {
    echo "安装镜像中的应用身份或版本不受信任" >&2
    exit 1
}
run_spctl_execute "$mounted_app"

if [[ ! -d "$applications_dir" ]]; then
    mkdir -p "$applications_dir"
fi

if [[ -w "$applications_dir" ]]; then
    ditto --noextattr --noqtn "$mounted_app" "$new_path"
    /usr/bin/codesign --verify --deep --strict "$new_path"
    /usr/bin/codesign --verify --deep --strict \
        --test-requirement "=$anchor_requirement" "$new_path"
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
    echo "“应用程序”目录需要管理员授权，请在打开的 DMG 中把 DropMesh 拖到“应用程序”。" >&2
    open "$dmg"
    exit 2
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$target_path"
/usr/bin/codesign --verify --deep --strict \
    --test-requirement "=$anchor_requirement" "$target_path"
if [[ "$backup_created" -eq 1 && -e "$backup_path" ]]; then rm -rf "$backup_path"; fi
backup_created=0
success=1

if [[ "${MACCHANNEL_INSTALL_SKIP_LAUNCH:-}" != 1 ]]; then
    /usr/bin/open -n "$target_path"
fi

echo "DropMesh 已安装到“应用程序”"
echo "启动后，DropMesh 会自动连接内置安全服务；在菜单栏完成设备配对即可传输文件。"
