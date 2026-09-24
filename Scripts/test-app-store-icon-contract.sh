#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/dropmesh-store-icon.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

generator="$repo_root/Scripts/package-app-store-icon.swift"
source_png="$repo_root/Distribution/AppStoreBrand/app-icon-1024.png"
source_svg="$repo_root/Distribution/AppStoreBrand/app-icon-1024.svg"
mark_svg="$repo_root/Distribution/AppStoreBrand/mark-transparent.svg"

test -f "$source_png" && test ! -L "$source_png"
test -f "$source_svg" && test ! -L "$source_svg"
test -f "$mark_svg" && test ! -L "$mark_svg"
test "$(shasum -a 256 "$source_png" | awk '{print $1}')" = 7e88a745f71d71ee1f49dd206f581156dcf12c47820750ba0c806315177f6354
test "$(shasum -a 256 "$source_svg" | awk '{print $1}')" = 7eb8c52db462e5a258f0bc2dab8d2c5a95073dd7fc15e9140cca39808d472edf
test "$(shasum -a 256 "$mark_svg" | awk '{print $1}')" = e026f30a9c3af01c515b9f20fad8e577efde7bbeddffc113ac213fd274039d65

if xcrun swift "$generator" "$test_root/missing.png" "$test_root/missing.icns" 2>"$test_root/missing.log"; then
    echo "missing Store icon input unexpectedly succeeded" >&2
    exit 1
fi
grep -F "source PNG must be a regular file" "$test_root/missing.log" >/dev/null

printf 'not a png\n' >"$test_root/malformed.png"
if xcrun swift "$generator" "$test_root/malformed.png" "$test_root/malformed.icns" 2>"$test_root/malformed.log"; then
    echo "malformed Store icon input unexpectedly succeeded" >&2
    exit 1
fi
grep -F "source PNG must be a decodable 1024x1024 image" "$test_root/malformed.log" >/dev/null

sips -s format jpeg "$source_png" --out "$test_root/jpeg-source.jpg" >/dev/null
mv "$test_root/jpeg-source.jpg" "$test_root/jpeg-named.png"
if xcrun swift "$generator" "$test_root/jpeg-named.png" "$test_root/jpeg.icns" 2>"$test_root/jpeg.log"; then
    echo "JPEG bytes named .png unexpectedly succeeded" >&2
    exit 1
fi
grep -F "source image format must be PNG" "$test_root/jpeg.log" >/dev/null

xcrun swift "$generator" "$source_png" "$test_root/DropMesh.icns"
test -s "$test_root/DropMesh.icns"
iconutil -c iconset "$test_root/DropMesh.icns" -o "$test_root/DropMesh.iconset"
for required in icon_16x16.png icon_16x16@2x.png icon_128x128.png icon_128x128@2x.png icon_256x256.png icon_256x256@2x.png icon_512x512.png icon_512x512@2x.png; do
    test -s "$test_root/DropMesh.iconset/$required"
done

# The Direct generator remains source-free and compatible with its original invocation.
xcrun swift "$repo_root/Scripts/generate-dropmesh-icon.swift" "$test_root/Direct.icns"
test -s "$test_root/Direct.icns"
grep -F 'package-app-store-icon.swift' "$repo_root/Scripts/build-app-store-app.sh" >/dev/null
grep -F 'generate-dropmesh-icon.swift' "$repo_root/Scripts/build-app.sh" >/dev/null

echo "app store icon contract PASS"
