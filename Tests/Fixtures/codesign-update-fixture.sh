#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    --verify)
        [[ "${MACCHANNEL_CODESIGN_FIXTURE_VERIFY:-pass}" == pass ]]
        ;;
    -d)
        printf 'Executable=%s\n' "${*: -1}" >&2
        printf 'Identifier=%s\n' "${MACCHANNEL_CODESIGN_FIXTURE_BUNDLE_ID:?}" >&2
        printf 'TeamIdentifier=%s\n' "${MACCHANNEL_CODESIGN_FIXTURE_TEAM_ID:?}" >&2
        printf 'designated => %s\n' "${MACCHANNEL_CODESIGN_FIXTURE_REQUIREMENT:?}" >&2
        ;;
    *)
        exit 64
        ;;
esac
