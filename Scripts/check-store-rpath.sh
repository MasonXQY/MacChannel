#!/usr/bin/env bash
set -euo pipefail
[[ $# == 1 && -f "$1" ]] || exit 2
# Check every architecture, not just the host slice.
for arch in $(lipo -archs "$1"); do
    otool -arch "$arch" -l "$1" | awk '
        $1 == "cmd" { rpath = ($2 == "LC_RPATH") }
        rpath && $1 == "path" && $2 == "@executable_path/../Frameworks" { found = 1 }
        END { exit !found }
    ' || { echo "Store executable missing Frameworks rpath: $arch" >&2; exit 1; }
done
