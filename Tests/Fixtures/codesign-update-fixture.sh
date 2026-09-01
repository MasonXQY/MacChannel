#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    --verify)
        if [[ " $* " == *" --test-requirement "* ]]; then
            [[ -z "${MACCHANNEL_CODESIGN_FIXTURE_ANCHOR_MARKER:-}" ]] || \
                : >"$MACCHANNEL_CODESIGN_FIXTURE_ANCHOR_MARKER"
            if [[ "${MACCHANNEL_CODESIGN_FIXTURE_CERT_CLASS:-developer-id-application}" == \
                apple-development ]]; then
                [[ " $* " != *"1.2.840.113635.100.6.1.13"* ]]
            else
                [[ "${MACCHANNEL_CODESIGN_FIXTURE_ANCHOR_MATCH:-pass}" == pass ]]
            fi
        else
            [[ "${MACCHANNEL_CODESIGN_FIXTURE_VERIFY:-pass}" == pass ]]
        fi
        ;;
    -d)
        [[ -z "${MACCHANNEL_CODESIGN_FIXTURE_POST_MOUNT_MARKER:-}" ]] || \
            : >"$MACCHANNEL_CODESIGN_FIXTURE_POST_MOUNT_MARKER"
        printf 'Executable=%s\n' "${*: -1}" >&2
        printf 'Identifier=%s\n' "${MACCHANNEL_CODESIGN_FIXTURE_BUNDLE_ID:?}" >&2
        printf 'TeamIdentifier=%s\n' "${MACCHANNEL_CODESIGN_FIXTURE_TEAM_ID:?}" >&2
        printf 'designated => %s\n' "${MACCHANNEL_CODESIGN_FIXTURE_REQUIREMENT:?}" >&2
        ;;
    *)
        exit 64
        ;;
esac
