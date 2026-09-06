#!/usr/bin/env bash
set -uo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repo_root"
source Scripts/app-store-validation.sh

expected_team=XKAZ67HN45
expected_bundle=com.zensystech.dropmesh
expected_application_id=XKAZ67HN45.com.zensystech.dropmesh
anchor=Distribution/AppStoreProfileAnchor.plist
development_profile="${MACCHANNEL_APP_STORE_DEVELOPMENT_PROFILE:-}"
distribution_profile="${MACCHANNEL_APP_STORE_DISTRIBUTION_PROFILE:-}"
development_identity="${MACCHANNEL_APP_STORE_DEVELOPMENT_IDENTITY:-}"
application_identity="${MACCHANNEL_APP_STORE_APPLICATION_IDENTITY:-}"
installer_identity="${MACCHANNEL_APP_STORE_INSTALLER_IDENTITY:-}"
app_store_id="${MACCHANNEL_APP_STORE_APP_ID:-}"
api_key_id="${MACCHANNEL_APP_STORE_API_KEY_ID:-}"
api_issuer_id="${MACCHANNEL_APP_STORE_API_ISSUER_ID:-}"
api_private_key="${MACCHANNEL_APP_STORE_API_PRIVATE_KEY:-}"
declare -a blockers=()
work_root="$(mktemp -d "${TMPDIR:-/tmp}/dropmesh-store-audit.XXXXXX")" || exit 2
chmod 700 "$work_root"
trap 'rm -rf "$work_root"' EXIT

block() { blockers+=("$1"); }
plist_value() { plutil -extract "$2" raw -o - "$1" 2>/dev/null || true; }

identity_fingerprint() {
    local requested="$1" listing="$2" policy="$3" count=0 fingerprint="" line label candidate
    case "$policy:$requested" in
        development:"Apple Development: "*" ($expected_team)"|development:"Mac Developer: "*" ($expected_team)"|\
        application:"Apple Distribution: "*" ($expected_team)"|application:"Mac App Distribution: "*" ($expected_team)"|application:"3rd Party Mac Developer Application: "*" ($expected_team)"|\
        installer:"Mac Installer Distribution: "*" ($expected_team)"|installer:"3rd Party Mac Developer Installer: "*" ($expected_team)") ;;
        *) return 1 ;;
    esac
    while IFS= read -r line; do
        [[ "$line" == *\"*\"* ]] || continue
        label="${line#*\"}"; label="${label%\"*}"
        [[ "$label" == "$requested" ]] || continue
        candidate="$(printf '%s\n' "$line" | awk '{print $2}')"
        [[ "$candidate" =~ ^[[:xdigit:]]{40}$ ]] || return 1
        fingerprint="$(printf '%s' "$candidate" | tr '[:lower:]' '[:upper:]')"
        count=$((count + 1))
    done <"$listing"
    [[ "$count" -eq 1 ]] || return 1
    printf '%s\n' "$fingerprint"
}

check_profile() {
    local kind="$1" profile="$2" expected_task_allow="$3" expected_identity="$4" expected_fingerprint="$5"
    if [[ -z "$profile" || ! -f "$profile" || -L "$profile" ]]; then
        block "$kind profile is missing or is not a regular file"
        return
    fi
    local decoded="$work_root/$kind.plist"
    if ! security cms -D -i "$profile" >"$decoded" 2>/dev/null || ! plutil -lint "$decoded" >/dev/null 2>&1; then
        block "$kind profile CMS signature or payload could not be verified"
        return
    fi
    local name uuid expiry expiry_epoch app_id team sandbox task_allow
    name="$(plist_value "$decoded" Name)"; uuid="$(plist_value "$decoded" UUID)"; expiry="$(plist_value "$decoded" ExpirationDate)"
    app_id="$(plist_value "$decoded" Entitlements.application-identifier)"
    team="$(plist_value "$decoded" TeamIdentifier.0)"
    sandbox="$(plist_value "$decoded" Entitlements.com.apple.security.app-sandbox)"
    task_allow="$(plist_value "$decoded" Entitlements.get-task-allow)"
    [[ -n "$uuid" ]] || block "$kind profile has no UUID"
    [[ "$app_id" == "$expected_application_id" && "$app_id" != *'*'* ]] || block "$kind profile lacks the explicit application identifier"
    [[ "$team" == "$expected_team" ]] || block "$kind profile Team ID does not match"
    [[ "$sandbox" == true ]] || block "$kind profile does not enable App Sandbox"
    [[ "$task_allow" == "$expected_task_allow" ]] || block "$kind profile has the wrong profile type"
    if [[ "$kind" == development ]]; then
        plutil -extract ProvisionedDevices xml1 -o - "$decoded" >/dev/null 2>&1 || block "development profile has no registered devices"
    else
        if plutil -extract ProvisionedDevices xml1 -o - "$decoded" >/dev/null 2>&1 || [[ "$(plist_value "$decoded" ProvisionsAllDevices)" == true ]]; then
            block "distribution profile is not a Mac App Store distribution profile"
        fi
    fi
    expiry_epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$expiry" '+%s' 2>/dev/null || true)"
    [[ "$expiry_epoch" =~ ^[0-9]+$ && "$expiry_epoch" -gt "$(date -u +%s)" ]] || block "$kind profile is expired or has an invalid expiration"
    if [[ -z "$expected_fingerprint" ]] || ! macchannel_require_profile_certificate "$decoded" "$expected_fingerprint" "$expected_identity"; then
        block "$kind profile does not contain its selected application certificate"
    fi
    printf '%s profile: Name=%s UUID=%s Expiry=%s\n' "$kind" "${name:-unknown}" "${uuid:-unknown}" "${expiry:-unknown}"
}

codesigning_listing="$work_root/codesigning-identities.txt"
all_listing="$work_root/all-identities.txt"
development_fingerprint=""; application_fingerprint=""; installer_fingerprint=""
if ! security find-identity -v -p codesigning >"$codesigning_listing" 2>/dev/null; then
    block "installed code-signing identities and private keys could not be queried"
else
    if ! development_fingerprint="$(identity_fingerprint "$development_identity" "$codesigning_listing" development)"; then
        block "exactly one development identity with a private key is required"
    else
        printf 'development certificate subject: %s\n' "$development_identity"
    fi
    if ! application_fingerprint="$(identity_fingerprint "$application_identity" "$codesigning_listing" application)"; then
        block "exactly one Store application identity with a private key is required"
    else
        printf 'application certificate subject: %s\n' "$application_identity"
    fi
fi
if ! security find-identity -v >"$all_listing" 2>/dev/null; then
    block "installed installer identities and private keys could not be queried"
elif ! installer_fingerprint="$(identity_fingerprint "$installer_identity" "$all_listing" installer)"; then
    block "exactly one Store installer identity with a private key is required"
else
    printf 'installer certificate subject: %s\n' "$installer_identity"
fi

check_profile development "$development_profile" true "$development_identity" "$development_fingerprint"
check_profile distribution "$distribution_profile" false "$application_identity" "$application_fingerprint"

anchor_id="$(plist_value "$anchor" appStoreID)"
if [[ ! "$app_store_id" =~ ^[1-9][0-9]*$ || "$anchor_id" != "$app_store_id" ]]; then
    block "numeric App Store ID is missing or does not match the committed anchor"
fi

if [[ -z "$api_key_id" || -z "$api_issuer_id" || -z "$api_private_key" || ! -f "$api_private_key" || -L "$api_private_key" ]]; then
    block "upload authentication is missing"
elif [[ ! "$api_key_id" =~ ^[A-Z0-9]+$ || ! "$api_issuer_id" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
    block "upload authentication identifiers are malformed"
else
    key_mode="$(stat -f '%Lp' "$api_private_key" 2>/dev/null || true)"
    if [[ "$key_mode" != 600 && "$key_mode" != 400 ]]; then
        block "upload authentication private key permissions are not owner-only"
    else
        credential_home="$work_root/upload-home"
        credential_dir="$credential_home/.appstoreconnect/private_keys"
        mkdir -p "$credential_dir"
        chmod 700 "$credential_home" "$credential_home/.appstoreconnect" "$credential_dir"
        cp -p "$api_private_key" "$credential_dir/AuthKey_$api_key_id.p8"
        chmod 600 "$credential_dir/AuthKey_$api_key_id.p8"
        if ! env HOME="$credential_home" xcrun altool --list-apps --apiKey "$api_key_id" --apiIssuer "$api_issuer_id" >"$work_root/altool.txt" 2>/dev/null; then
            block "upload authentication could not be verified with App Store Connect"
        fi
    fi
fi

if ((${#blockers[@]})); then
    echo "app-store-prerequisites BLOCKED"
    for reason in "${blockers[@]}"; do printf 'BLOCKED: %s\n' "$reason"; done
    exit 2
fi
echo "app-store-prerequisites PASS bundle=$expected_bundle team=$expected_team app-store-id=$app_store_id"
