#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f Scripts/app-store-export-fragment.sh ]] || { echo 'candidate contract FAIL: export fragment missing'; exit 1; }
source Scripts/app-store-export-fragment.sh
for decision in true false; do
    [[ "$(macchannel_store_export_fragment release "Tests/Fixtures/store-export-approved-$decision.txt")" == "<key>ITSAppUsesNonExemptEncryption</key><$decision/>" ]]
done
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
fragment="$(macchannel_store_export_fragment review-candidate docs/security/app-store-export-compliance.md)"
[[ "$fragment" == '<key>DropMeshReleaseStage</key><string>review-candidate</string>' ]]
if macchannel_store_export_fragment release docs/security/app-store-export-compliance.md >/dev/null 2>&1; then
    echo 'candidate contract FAIL: draft accepted for release'; exit 1
fi
if macchannel_store_export_fragment unknown docs/security/app-store-export-compliance.md >/dev/null 2>&1; then
    echo 'candidate contract FAIL: unknown mode accepted'; exit 1
fi
status=0
bash Scripts/build-app-store-app.sh --unknown >"$test_root/result" 2>&1 || status=$?
[[ "$status" == 2 ]]
rg -Fq 'usage: build-app-store-app.sh [--review-candidate]' "$test_root/result"
status=0
bash Scripts/build-app-store-app.sh --review-candidate extra >"$test_root/result" 2>&1 || status=$?
[[ "$status" == 2 ]]
rg -Fq 'usage: build-app-store-app.sh [--review-candidate]' "$test_root/result"
echo 'app store candidate contract PASS'
