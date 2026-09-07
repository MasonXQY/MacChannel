#!/usr/bin/env bash

# Emit only controlled XML literals. Omitting the encryption key is not an
# exemption declaration; a review candidate still needs export review.
macchannel_store_export_fragment() {
    local mode="$1" record="$2" decision
    case "$mode" in
        review-candidate)
            echo '<key>DropMeshReleaseStage</key><string>review-candidate</string>'
            ;;
        release)
            [[ -f "$record" && ! -L "$record" ]] || return 2
            grep -Eiq '^Status:[[:space:]]*approved[[:space:]]*$' "$record" || return 2
            decision="$(sed -nE 's/^Decision:[[:space:]]*ITSAppUsesNonExemptEncryption[[:space:]]*=[[:space:]]*(true|false)[[:space:]]*$/\1/p' "$record")"
            [[ "$decision" == true || "$decision" == false ]] || return 2
            echo "<key>ITSAppUsesNonExemptEncryption</key><$decision/>"
            ;;
        *) return 2 ;;
    esac
}
