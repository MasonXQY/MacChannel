#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repository_root/Scripts/app-build-defaults.sh"

release_consumers=(
    Scripts/build-app.sh
    Scripts/build-distribution.sh
    Scripts/build-update-feed.sh
    Scripts/test-release-signing.sh
)

for consumer in "${release_consumers[@]}"; do
    source_path="$repository_root/$consumer"
    if rg -q 'MACCHANNEL_VERSION:-[0-9]+\.[0-9]+\.[0-9]+|MACCHANNEL_BUILD_NUMBER:-[0-9]+' "$source_path"; then
        echo "release default is hard-coded in $consumer" >&2
        exit 1
    fi
    rg -q 'Scripts/app-build-defaults\.sh' "$source_path"
    rg -q 'MACCHANNEL_VERSION:-\$macchannel_default_version' "$source_path"
    rg -q 'MACCHANNEL_BUILD_NUMBER:-\$macchannel_default_build_number' "$source_path"
done

test "$macchannel_default_version" = 1.2.6
test "$macchannel_default_build_number" = 21

direct_baseline="$repository_root/Distribution/DirectBaseline-v1.2.6.plist"
direct_regression_test="$repository_root/Scripts/test-direct-regression-baseline.sh"
test -f "$direct_baseline"
test -x "$direct_regression_test"
test "$(plutil -extract version raw -o - "$direct_baseline")" = 1.2.6
test "$(plutil -extract build raw -o - "$direct_baseline")" = 21
test "$(plutil -extract bundleIdentifier raw -o - "$direct_baseline")" = com.mason.macchannel

echo "release defaults contract PASS"
