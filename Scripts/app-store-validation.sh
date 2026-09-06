#!/usr/bin/env bash

macchannel_plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
}

macchannel_plist_array_is_exactly() {
    local plist="$1" key="$2" expected="$3"
    [[ "$(macchannel_plist_value "$plist" "$key:0")" == "$expected" ]] || return 1
    [[ -z "$(macchannel_plist_value "$plist" "$key:1")" ]] || return 1
}

macchannel_validate_macos_profile() {
    local profile_plist="$1" kind="$2" expected_application_id="$3" expected_team="$4" expected_app_group="$5"
    [[ -f "$profile_plist" && ! -L "$profile_plist" ]] || return 1
    [[ "$kind" == development || "$kind" == distribution ]] || return 1
    plutil -lint "$profile_plist" >/dev/null 2>&1 || return 1
    [[ -n "$(macchannel_plist_value "$profile_plist" UUID)" ]] || return 1
    macchannel_plist_array_is_exactly "$profile_plist" TeamIdentifier "$expected_team" || return 1
    macchannel_plist_array_is_exactly "$profile_plist" Platform OSX || return 1

    local profile_application_id profile_team profile_group expected_profile_group
    profile_application_id="$(macchannel_plist_value "$profile_plist" 'Entitlements:com.apple.application-identifier')"
    [[ "$profile_application_id" == "$expected_application_id" && "$profile_application_id" != *'*'* ]] || return 1
    profile_team="$(macchannel_plist_value "$profile_plist" 'Entitlements:com.apple.developer.team-identifier')"
    [[ "$profile_team" == "$expected_team" ]] || return 1
    expected_profile_group="$expected_team.*"
    profile_group="$(macchannel_plist_value "$profile_plist" 'Entitlements:keychain-access-groups:0')"
    [[ "$profile_group" == "$expected_profile_group" && "$expected_app_group" == "$expected_team."* ]] || return 1
    [[ -z "$(macchannel_plist_value "$profile_plist" 'Entitlements:keychain-access-groups:1')" ]] || return 1

    local provisions_all
    provisions_all="$(macchannel_plist_value "$profile_plist" ProvisionsAllDevices)"
    [[ "$provisions_all" != true ]] || return 1
    if [[ "$kind" == development ]]; then
        [[ -n "$(macchannel_plist_value "$profile_plist" 'ProvisionedDevices:0')" ]] || return 1
    else
        [[ -z "$(macchannel_plist_value "$profile_plist" 'ProvisionedDevices:0')" ]] || return 1
        plutil -extract ProvisionedDevices xml1 -o - "$profile_plist" >/dev/null 2>&1 && return 1
    fi

    local expiry expiry_epoch
    expiry="$(macchannel_plist_value "$profile_plist" ExpirationDate)"
    expiry_epoch="$(date -j -u -f '%a %b %d %H:%M:%S %Z %Y' "$expiry" '+%s' 2>/dev/null || true)"
    if [[ ! "$expiry_epoch" =~ ^[0-9]+$ ]]; then
        expiry="$(plutil -extract ExpirationDate raw -o - "$profile_plist" 2>/dev/null || true)"
        expiry_epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$expiry" '+%s' 2>/dev/null || true)"
    fi
    [[ "$expiry_epoch" =~ ^[0-9]+$ && "$expiry_epoch" -gt "$(date -u +%s)" ]] || return 1
    if plutil -convert xml1 -o - "$profile_plist" | grep -q '<key>com\.apple\.security\.temporary-exception'; then
        return 1
    fi
}

macchannel_validate_signed_app_entitlements() {
    local entitlements="$1" expected_application_id="$2" expected_team="$3" expected_app_group="$4"
    plutil -lint "$entitlements" >/dev/null 2>&1 || return 1
    local keys expected_keys
    keys="$(/usr/libexec/PlistBuddy -c Print "$entitlements" | sed -nE 's/^    ([^ ]+) = .*/\1/p' | sort)"
    expected_keys=$'com.apple.application-identifier\ncom.apple.developer.team-identifier\ncom.apple.security.app-sandbox\ncom.apple.security.files.downloads.read-write\ncom.apple.security.files.user-selected.read-write\ncom.apple.security.network.client\ncom.apple.security.network.server\nkeychain-access-groups'
    [[ "$keys" == "$expected_keys" ]] || return 1
    [[ "$(macchannel_plist_value "$entitlements" com.apple.application-identifier)" == "$expected_application_id" ]] || return 1
    [[ "$(macchannel_plist_value "$entitlements" com.apple.developer.team-identifier)" == "$expected_team" ]] || return 1
    macchannel_plist_array_is_exactly "$entitlements" keychain-access-groups "$expected_app_group" || return 1
    local key
    for key in com.apple.security.app-sandbox com.apple.security.network.client com.apple.security.network.server com.apple.security.files.downloads.read-write com.apple.security.files.user-selected.read-write; do
        [[ "$(macchannel_plist_value "$entitlements" "$key")" == true ]] || return 1
    done
}

macchannel_resolve_store_identity() {
    local requested="$1"
    local identity_listing="$2"
    local expected_team=XKAZ67HN45
    case "$requested" in
        "Apple Distribution: "*" ($expected_team)"|\
        "Mac App Distribution: "*" ($expected_team)"|\
        "3rd Party Mac Developer Application: "*" ($expected_team)") ;;
        *) return 1 ;;
    esac

    local count=0 fingerprint="" line label candidate
    while IFS= read -r line; do
        [[ "$line" == *'"'*'"' ]] || continue
        label="${line#*\"}"
        label="${label%\"*}"
        [[ "$label" == "$requested" ]] || continue
        candidate="$(printf '%s\n' "$line" | awk '{print $2}')"
        [[ "$candidate" =~ ^[[:xdigit:]]{40}$ ]] || return 1
        fingerprint="$(printf '%s' "$candidate" | tr '[:lower:]' '[:upper:]')"
        count=$((count + 1))
    done <"$identity_listing"
    [[ "$count" -eq 1 ]] || return 1
    printf '%s\n' "$fingerprint"
}

macchannel_require_profile_certificate() {
    local profile_plist="$1"
    local expected="$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')"
    local requested_identity="$3"
    local certificate_dump count index encoded der actual subject
    certificate_dump="$(plutil -extract DeveloperCertificates xml1 -o - "$profile_plist" 2>/dev/null)" || return 1
    count="$(printf '%s\n' "$certificate_dump" | grep -c '<data>')"
    [[ "$count" -gt 0 ]] || return 1
    index=0
    while [[ "$index" -lt "$count" ]]; do
        encoded="$(plutil -extract "DeveloperCertificates.$index" raw -o - "$profile_plist" 2>/dev/null)" || return 1
        der="$(mktemp "${TMPDIR:-/tmp}/dropmesh-profile-cert.XXXXXX")" || return 1
        if ! printf '%s' "$encoded" | base64 -D >"$der" 2>/dev/null; then
            rm -f "$der"; return 1
        fi
        actual="$(/usr/bin/openssl x509 -inform der -in "$der" -noout -fingerprint -sha1 2>/dev/null | sed 's/.*=//; s/://g' | tr '[:lower:]' '[:upper:]')"
        subject="$(/usr/bin/openssl x509 -inform der -in "$der" -noout -subject -nameopt RFC2253 2>/dev/null || true)"
        rm -f "$der"
        if [[ "$actual" == "$expected" && "$subject" == *"OU=XKAZ67HN45"* && "$subject" == *"CN=$requested_identity"* ]]; then
            return 0
        fi
        index=$((index + 1))
    done
    return 1
}

macchannel_validate_store_output_path() {
    local repo_root="$1"
    local requested="$2"
    [[ -n "$requested" && "$requested" == */DropMesh.app ]] || return 1
    local combined
    case "$requested" in
        /*) combined="$requested" ;;
        *) combined="$repo_root/$requested" ;;
    esac

    local remainder="${combined#/}" component current="" count=0
    local -a components normalized
    IFS='/' read -r -a components <<<"$remainder"
    for component in "${components[@]}"; do
        case "$component" in
            ''|.) continue ;;
            ..)
                [[ "$count" -gt 0 ]] || return 1
                unset 'normalized[count-1]'
                count=$((count - 1))
                current=""
                local part
                for part in "${normalized[@]}"; do current="$current/$part"; done
                ;;
            *)
                local candidate="$current/$component"
                [[ ! -L "$candidate" ]] || return 1
                normalized[$count]="$component"
                count=$((count + 1))
                current="$candidate"
                ;;
        esac
    done
    local output_abs=""
    local part
    for part in "${normalized[@]}"; do output_abs="$output_abs/$part"; done
    [[ "$output_abs" == */DropMesh.app ]] || return 1

    local dist="$repo_root/dist"
    case "$output_abs" in "$dist"|"$dist/"*) return 1 ;; esac
    [[ ! -e "$output_abs" && ! -L "$output_abs" ]] || return 1
    printf '%s\n' "$output_abs"
}
