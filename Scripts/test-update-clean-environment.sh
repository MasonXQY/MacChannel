#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repo_root"

if rg -n 'env -u MACCHANNEL_UPDATE_TEST_ROOT' Scripts/build-distribution.sh >/dev/null; then
    printf 'distribution build still uses ambient environment subtraction\n' >&2
    exit 1
fi
grep -F 'env -i PATH="$PATH" HOME="$signing_home"' Scripts/build-distribution.sh >/dev/null
grep -F 'clean_codesign()' Scripts/test-update-acceptance.sh >/dev/null
grep -F 'clean_fixture_tool()' Scripts/test-update-acceptance.sh >/dev/null
if rg -n '^[[:space:]]+codesign[[:space:]]' Scripts/test-update-acceptance.sh >/dev/null; then
    printf 'acceptance fixture still invokes ambient codesign directly\n' >&2
    exit 1
fi
if rg -n '(^|&&)[[:space:]]*"\$(generate_appcast|sign_update)"' \
    Scripts/test-update-acceptance.sh >/dev/null; then
    printf 'acceptance Sparkle signing tool still inherits ambient environment\n' >&2
    exit 1
fi
grep -F 'clean_update_tool()' Scripts/build-update-feed.sh >/dev/null
if rg -n '^[[:space:]]+"\$(generate_appcast|sign_update)"[[:space:]]' \
    Scripts/build-update-feed.sh >/dev/null; then
    printf 'feed signing tool still inherits ambient environment\n' >&2
    exit 1
fi
grep -F 'env -i PATH="$PATH" HOME="$signing_home"' Scripts/test-release-signing.sh >/dev/null
grep -F 'clean_build_tool()' Scripts/build-app.sh >/dev/null
grep -F 'clean_codesign()' Scripts/build-app.sh >/dev/null
if rg -n '^[[:space:]]+(swift build|codesign[[:space:]])' Scripts/build-app.sh >/dev/null; then
    printf 'app build or signing subprocess still inherits ambient environment\n' >&2
    exit 1
fi

printf 'update clean environment contract PASS\n'
