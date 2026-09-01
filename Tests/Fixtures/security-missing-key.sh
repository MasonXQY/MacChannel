#!/usr/bin/env bash
set -euo pipefail

[[ -z "${MACCHANNEL_SECURITY_SHIM_MARKER:-}" ]] || \
    : >"$MACCHANNEL_SECURITY_SHIM_MARKER"

case "${1:-}" in
    login-keychain)
        printf '"%s"\n' "${MACCHANNEL_SECURITY_SHIM_LOGIN_KEYCHAIN:?}"
        ;;
    find-generic-password)
        printf '%s\n' "${MACCHANNEL_SECURITY_SHIM_NOISE:-missing fixed account}" >&2
        exit 44
        ;;
    *)
        exit 64
        ;;
esac
