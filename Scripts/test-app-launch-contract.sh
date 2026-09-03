#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The normal packaged-app smoke must accept the version/build emitted by its build script.
bash "$repository_root/Scripts/test-app-launch.sh"

# A deliberately mismatched expectation must be rejected before the app is launched.
if MACCHANNEL_EXPECTED_VERSION=0.0.0 MACCHANNEL_EXPECTED_BUILD_NUMBER=1 \
    bash "$repository_root/Scripts/test-app-launch.sh" >/dev/null 2>&1; then
    echo "app launch contract accepted a mismatched version/build" >&2
    exit 1
fi

echo "app launch version contract PASS"
