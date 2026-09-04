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
test "$macchannel_default_build_number" = 20
echo "release defaults contract PASS"
