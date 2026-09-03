#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The normal packaged-app smoke must accept the version/build emitted by its build script.
bash "$repository_root/Scripts/test-app-launch.sh"

# Build inputs cannot implicitly redefine the authoritative acceptance expectation.
if MACCHANNEL_VERSION=9.9.9 MACCHANNEL_BUILD_NUMBER=99 \
    bash "$repository_root/Scripts/test-app-launch.sh" >/dev/null 2>&1; then
    echo "app launch contract accepted build inputs as its own expectation" >&2
    exit 1
fi

# A deliberately mismatched expectation must be rejected before the app is launched.
if MACCHANNEL_EXPECTED_VERSION=0.0.0 MACCHANNEL_EXPECTED_BUILD_NUMBER=1 \
    bash "$repository_root/Scripts/test-app-launch.sh" >/dev/null 2>&1; then
    echo "app launch contract accepted a mismatched version/build" >&2
    exit 1
fi

# The script must work when launched by absolute path outside the repository.
(
    cd /tmp
    bash "$repository_root/Scripts/test-app-launch.sh"
)

echo "app launch version contract PASS"
