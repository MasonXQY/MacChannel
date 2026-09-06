#!/usr/bin/env bash

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
