#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repo_root"

if [[ $# -gt 1 || (${1:-} != "" && ${1:-} != "--local-only") ]]; then
    echo "usage: $0 [--local-only]" >&2
    exit 2
fi

if pgrep -f '/MacChannel\.app/Contents/MacOS/MacChannelApp' >/dev/null; then
    echo "DropMesh verification requires no pre-existing app process" >&2
    exit 1
fi

swift test --filter PersonalMeshIntegrationTests
bash Scripts/audit-privacy.sh --static-only

if pgrep -f '/MacChannel\.app/Contents/MacOS/MacChannelApp' >/dev/null; then
    echo "DropMesh verification left an app process" >&2
    exit 1
fi

commit="$(git rev-parse HEAD)"
printf '{"schemaVersion":1,"commit":"%s","localMesh":"PASS","realMac":"NOT RUN","runtimePrivacy":"BLOCKED"}\n' \
    "$commit"

if [[ ${1:-} == "--local-only" ]]; then
    exit 0
fi

echo "personal mesh external acceptance BLOCKED: two real Macs and signed runtime privacy evidence are required" >&2
exit 2
