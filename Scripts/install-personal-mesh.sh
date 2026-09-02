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
requested_failure_point="${MACCHANNEL_INSTALL_FAIL_AT:-}"
requested_signal_point="${MACCHANNEL_INSTALL_SIGNAL_AT:-}"
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
    case "$requested_failure_point" in
        ""|before-backup|after-backup|after-install|after-success) ;;
        *) echo "invalid installer failure injection point" >&2; exit 2 ;;
    esac
    case "$requested_signal_point" in
        ""|after-backup:INT|after-backup:TERM|after-backup:HUP|after-install:INT|after-install:TERM|after-install:HUP|after-success:INT|after-success:TERM|after-success:HUP) ;;
        *) echo "invalid installer signal injection point" >&2; exit 2 ;;
    esac
elif [[ "$applications_dir" != /Applications ]]; then
    echo "custom application directory is available only to the installer contract test" >&2
    exit 2
elif [[ -n "$install_test_root" || -n "$requested_stapler_command" || \
    -n "$requested_spctl_command" || -n "$requested_failure_point" || \
    -n "$requested_signal_point" ]]; then
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

check_root="$(macchannel_create_test_root macchannel-install-mount)" || {
    echo "无法创建安全的镜像检查目录" >&2
    exit 1
}
mount_path="$check_root/mounted"
target_path="$applications_dir/MacChannel.app"
transaction_root=""
staging_root=""
backup_root=""
staged_path=""
backup_path=""
transaction_identity=""
staging_root_identity=""
backup_root_identity=""
staged_identity=""
old_target_identity=""
applications_dir_physical=""
current_uid=""
mounted=0
backup_created=0
new_installed=0
success=0
commit_critical=0
pending_signal_status=0

require_private_transaction_root() {
    local root="$1"
    local physical_root root_mode root_uid root_name actual_identity

    [[ -n "$applications_dir_physical" && -n "$current_uid" ]] || return 1
    [[ "$root" == "$applications_dir"/.DropMesh.transaction.?????? ]] || return 1
    root_name="${root##*/}"
    [[ "$root_name" =~ ^\.DropMesh\.transaction\.[A-Za-z0-9]{6}$ ]] || return 1
    [[ "${root%/*}" == "$applications_dir" && -d "$root" && ! -L "$root" ]] || return 1
    physical_root="$(cd "$root" 2>/dev/null && /bin/pwd -P)" || return 1
    [[ "$physical_root" == "$root" ]] || return 1
    [[ "$(cd "${root%/*}" 2>/dev/null && /bin/pwd -P)" == \
        "$applications_dir_physical" ]] || return 1
    root_mode="$(/usr/bin/stat -f %Lp "$root" 2>/dev/null)" || return 1
    root_uid="$(/usr/bin/stat -f %u "$root" 2>/dev/null)" || return 1
    actual_identity="$(/usr/bin/stat -f '%d:%i' "$root" 2>/dev/null)" || return 1
    [[ "$root_mode" == 700 && "$root_uid" == "$current_uid" ]] || return 1
    [[ -z "$transaction_identity" || "$actual_identity" == "$transaction_identity" ]]
}

require_private_child_root() {
    local path="$1"
    local required_name="$2"
    local path_mode path_uid actual_identity expected_identity

    require_private_transaction_root "$transaction_root" || return 1
    [[ "$required_name" == staging || "$required_name" == backup ]] || return 1
    [[ "$path" == "$transaction_root/$required_name" && -d "$path" && ! -L "$path" ]] || return 1
    [[ "$(cd "$path" 2>/dev/null && /bin/pwd -P)" == "$path" ]] || return 1
    [[ "$(cd "${path%/*}" 2>/dev/null && /bin/pwd -P)" == "$transaction_root" ]] || return 1
    path_mode="$(/usr/bin/stat -f %Lp "$path" 2>/dev/null)" || return 1
    path_uid="$(/usr/bin/stat -f %u "$path" 2>/dev/null)" || return 1
    actual_identity="$(/usr/bin/stat -f '%d:%i' "$path" 2>/dev/null)" || return 1
    if [[ "$required_name" == staging ]]; then
        expected_identity="$staging_root_identity"
    else
        expected_identity="$backup_root_identity"
    fi
    [[ "$path_mode" == 700 && "$path_uid" == "$current_uid" ]] || return 1
    [[ -z "$expected_identity" || "$actual_identity" == "$expected_identity" ]]
}

require_staged_destination() {
    local path="$1"

    require_private_child_root "$staging_root" staging || return 1
    [[ "$path" == "$staging_root/MacChannel.app" && -d "$path" && ! -L "$path" ]] || return 1
    [[ "$(cd "$path" 2>/dev/null && /bin/pwd -P)" == "$path" ]] || return 1
    [[ "$(cd "${path%/*}" 2>/dev/null && /bin/pwd -P)" == "$staging_root" ]] || return 1
    [[ "$(/usr/bin/stat -f %u "$path" 2>/dev/null)" == "$current_uid" ]] || return 1
    [[ -z "$staged_identity" || \
        "$(/usr/bin/stat -f '%d:%i' "$path" 2>/dev/null)" == "$staged_identity" ]]
}

inject_test_failure() {
    local point="$1"
    if [[ "$installer_testing" == 1 && "$requested_failure_point" == "$point" ]]; then
        exit 70
    fi
}

inject_test_signal() {
    local point="$1"
    local configured_point signal_name

    [[ "$installer_testing" == 1 && -n "$requested_signal_point" ]] || return 0
    configured_point="${requested_signal_point%%:*}"
    [[ "$configured_point" == "$point" ]] || return 0
    signal_name="${requested_signal_point##*:}"
    /bin/kill -s "$signal_name" "$$"
}

inject_test_event() {
    local point="$1"
    inject_test_failure "$point"
    inject_test_signal "$point"
}

handle_install_signal() {
    local status="$1"
    if [[ "$commit_critical" -eq 1 ]]; then
        if [[ "$pending_signal_status" -eq 0 ]]; then
            pending_signal_status="$status"
        fi
        return 0
    fi
    exit "$status"
}

process_pending_signal() {
    local status
    if [[ "$pending_signal_status" -ne 0 ]]; then
        status="$pending_signal_status"
        pending_signal_status=0
        exit "$status"
    fi
}

cleanup() {
    local result=$?
    local cleanup_failed=0 target_identity
    trap - EXIT
    trap '' INT TERM HUP

    if [[ "$mounted" -eq 1 ]]; then
        /usr/bin/hdiutil detach "$mount_path" -quiet >/dev/null 2>&1 || true
    fi

    if [[ "$success" -ne 1 && "$new_installed" -eq 1 ]]; then
        if [[ -d "$target_path" && ! -L "$target_path" ]]; then
            target_identity="$(/usr/bin/stat -f '%d:%i' "$target_path" 2>/dev/null || true)"
            if [[ -n "$staged_identity" && "$target_identity" == "$staged_identity" ]]; then
                /bin/rm -rf "$target_path" || cleanup_failed=1
            else
                cleanup_failed=1
            fi
        elif [[ -e "$target_path" || -L "$target_path" ]]; then
            cleanup_failed=1
        fi
        [[ ! -e "$target_path" && ! -L "$target_path" ]] || cleanup_failed=1
    fi

    if [[ "$success" -ne 1 && "$backup_created" -eq 1 ]]; then
        if [[ "$cleanup_failed" -eq 0 && ! -e "$target_path" && ! -L "$target_path" && \
            -d "$backup_path" && ! -L "$backup_path" && \
            "${backup_path%/*}" == "$backup_root" && \
            "$(/usr/bin/stat -f '%d:%i' "$backup_path" 2>/dev/null)" == \
                "$old_target_identity" ]]; then
            /bin/mv "$backup_path" "$target_path" || cleanup_failed=1
        else
            cleanup_failed=1
        fi
    fi

    if [[ -n "$transaction_root" ]]; then
        if require_private_transaction_root "$transaction_root"; then
            if [[ "$cleanup_failed" -eq 0 || "$success" -eq 1 ]]; then
                /bin/rm -rf "$transaction_root" || cleanup_failed=1
            fi
        elif [[ -e "$transaction_root" || -L "$transaction_root" ]]; then
            cleanup_failed=1
        fi
    fi
    if macchannel_require_canonical_test_root "$check_root"; then
        /bin/rm -rf "$check_root" || cleanup_failed=1
    else
        cleanup_failed=1
    fi
    if [[ "$cleanup_failed" -ne 0 ]]; then
        echo "安装回滚或安全清理未能完成" >&2
        result=70
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'handle_install_signal 130' INT
trap 'handle_install_signal 143' TERM
trap 'handle_install_signal 129' HUP

/bin/mkdir -m 700 "$mount_path"
/usr/bin/hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$mount_path" -quiet
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
    applications_dir_physical="$(cd "$applications_dir" 2>/dev/null && /bin/pwd -P)" || {
        echo "“应用程序”目录无效" >&2
        exit 1
    }
    [[ "$applications_dir_physical" == "$applications_dir" && ! -L "$applications_dir" ]] || {
        echo "“应用程序”目录无效" >&2
        exit 1
    }

    current_uid="$(/usr/bin/id -u)"
    transaction_root="$(umask 077; /usr/bin/mktemp -d \
        "$applications_dir/.DropMesh.transaction.XXXXXX")" || {
        echo "无法创建安全安装事务" >&2
        exit 1
    }
    /bin/chmod 700 "$transaction_root"
    transaction_identity="$(/usr/bin/stat -f '%d:%i' "$transaction_root")" || exit 1
    require_private_transaction_root "$transaction_root" || {
        echo "安装事务目录无效" >&2
        exit 1
    }
    staging_root="$transaction_root/staging"
    backup_root="$transaction_root/backup"
    /bin/mkdir -m 700 "$staging_root" "$backup_root"
    staging_root_identity="$(/usr/bin/stat -f '%d:%i' "$staging_root")" || exit 1
    backup_root_identity="$(/usr/bin/stat -f '%d:%i' "$backup_root")" || exit 1
    require_private_child_root "$staging_root" staging || exit 1
    require_private_child_root "$backup_root" backup || exit 1
    staged_path="$staging_root/MacChannel.app"
    backup_path="$backup_root/MacChannel.app"
    /bin/mkdir -m 700 "$staged_path"
    staged_identity="$(/usr/bin/stat -f '%d:%i' "$staged_path")" || exit 1
    require_staged_destination "$staged_path" || exit 1

    /usr/bin/ditto --noextattr --noqtn "$mounted_app" "$staged_path"
    require_staged_destination "$staged_path" || exit 1
    /usr/bin/codesign --verify --deep --strict "$staged_path"
    /usr/bin/codesign --verify --deep --strict \
        --test-requirement "=$anchor_requirement" "$staged_path"
    if [[ -L "$target_path" || ( -e "$target_path" && ! -d "$target_path" ) ]]; then
        echo "现有应用路径无效，未进行替换" >&2
        exit 1
    fi

    inject_test_failure before-backup
    commit_critical=1
    if [[ -d "$target_path" ]]; then
        old_target_identity="$(/usr/bin/stat -f '%d:%i' "$target_path")" || exit 1
        /bin/mv "$target_path" "$backup_path"
        backup_created=1
        [[ "$(/usr/bin/stat -f '%d:%i' "$backup_path")" == "$old_target_identity" ]] || exit 1
    fi
    inject_test_event after-backup
    /bin/mv "$staged_path" "$target_path"
    new_installed=1
    installed_identity="$(/usr/bin/stat -f '%d:%i' "$target_path")" || exit 1
    [[ "$installed_identity" == "$staged_identity" && -d "$target_path" && \
        ! -L "$target_path" ]] || exit 1
    inject_test_event after-install
    success=1
    commit_critical=0
    process_pending_signal
    inject_test_event after-success
else
    echo "“应用程序”目录需要管理员授权，请在打开的 DMG 中把 DropMesh 拖到“应用程序”。" >&2
    open "$dmg"
    exit 2
fi

if [[ "${MACCHANNEL_INSTALL_SKIP_LAUNCH:-}" != 1 ]]; then
    /usr/bin/open -n "$target_path"
fi

echo "DropMesh 已安装到“应用程序”"
echo "启动后，DropMesh 会自动连接内置安全服务；在菜单栏完成设备配对即可传输文件。"
