#!/usr/bin/env bash
set -euo pipefail
[[ $# == 1 && -f "$1" && ! -L "$1" ]] || exit 2
script_root="$(cd "$(dirname "$0")" && pwd -P)"
if bash "$script_root/check-store-rpath.sh" "$1" >/dev/null 2>&1; then exit 0; fi
# Only run on the copied executable, before signing the Store bundle.
install_name_tool -add_rpath '@executable_path/../Frameworks' "$1"
bash "$script_root/check-store-rpath.sh" "$1"
