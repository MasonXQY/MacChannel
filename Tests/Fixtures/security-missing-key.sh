#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    login-keychain)
        exec /usr/bin/security "$@"
        ;;
    find-generic-password)
        [[ -z "${MACCHANNEL_SECURITY_SHIM_MARKER:-}" ]] || \
            : >"$MACCHANNEL_SECURITY_SHIM_MARKER"
        printf '%s\n' "${MACCHANNEL_SECURITY_SHIM_NOISE:-missing fixed account}" >&2
        exit 44
        ;;
    *)
        exit 64
        ;;
esac
