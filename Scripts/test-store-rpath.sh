#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_root="$(mktemp -d /private/tmp/dropmesh-rpath-test.XXXXXX)"
trap 'rm -rf "$test_root"' EXIT
# Use the real SwiftPM output: this is the executable layout that caused the
# installed build2 dyld crash. Never modify the installed app or signed archive.
product_path="$(swift build -c release --product DropMeshAppStore --arch arm64 --arch x86_64 --show-bin-path)"
cp -X "$product_path/DropMeshAppStore" "$test_root/DropMeshAppStore"
if bash Scripts/check-store-rpath.sh "$test_root/DropMeshAppStore" >/dev/null 2>&1; then
    echo 'fixture already has Frameworks rpath; update regression fixture' >&2; exit 1
fi
[[ -f Scripts/fix-store-rpath.sh ]] || { echo 'FAIL: Store rpath repair missing'; exit 1; }
bash Scripts/fix-store-rpath.sh "$test_root/DropMeshAppStore"
bash Scripts/check-store-rpath.sh "$test_root/DropMeshAppStore"
bash Scripts/fix-store-rpath.sh "$test_root/DropMeshAppStore"
bash Scripts/check-store-rpath.sh "$test_root/DropMeshAppStore"
echo 'Store rpath regression PASS'
