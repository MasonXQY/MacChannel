#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fixture_root="$(mktemp -d -t macchannel-launch-contract.XXXXXX)"
crashing_executable="$fixture_root/crashing-launch-fixture"
cleanup() {
    rm -rf "$fixture_root"
}
trap cleanup EXIT INT TERM

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'while (($#)); do' \
    '    if [[ "$1" == "--smoke-test" ]]; then' \
    '        printf "ready accessory\\n" > "$2"' \
    '        exit 37' \
    '    fi' \
    '    shift' \
    'done' \
    'exit 0' > "$crashing_executable"
chmod +x "$crashing_executable"

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

# A marker is not a successful launch: the app's real crash status must fail the smoke run.
if MACCHANNEL_LAUNCH_TESTING=1 MACCHANNEL_LAUNCH_TEST_EXECUTABLE="$crashing_executable" \
    bash "$repository_root/Scripts/test-app-launch.sh" >/dev/null 2>&1; then
    echo "app launch contract accepted a marker-then-crash executable" >&2
    exit 1
else
    crash_status=$?
fi
[[ "$crash_status" -eq 37 ]] || {
    echo "app launch contract hid the marker-then-crash status: $crash_status" >&2
    exit 1
}

echo "app launch version contract PASS"
