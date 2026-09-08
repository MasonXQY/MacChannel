#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { echo "Store staging FAIL: $*" >&2; exit 1; }
[[ -f Scripts/create-store-staging.sh ]] || fail 'isolated staging helper missing'
first=''
second=''
cleanup() {
    [[ -z "$first" ]] || rmdir "$first"
    [[ -z "$second" ]] || rmdir "$second"
}
trap cleanup EXIT
first="$(TMPDIR="$PWD" bash Scripts/create-store-staging.sh)"
second="$(TMPDIR=/nonexistent/dropmesh-test bash Scripts/create-store-staging.sh)"
for directory in "$first" "$second"; do
    [[ "$directory" == /private/tmp/dropmesh-store.* ]] || fail 'staging follows output or TMPDIR'
    [[ -d "$directory" && ! -L "$directory" ]] || fail 'not a real directory'
    [[ "$(stat -f %Lp "$directory")" == 700 ]] || fail 'staging is not owner-only'
    [[ "$(stat -f %u "$directory")" == "$(id -u)" ]] || fail 'wrong owner'
done
[[ "$first" != "$second" ]] || fail 'staging reused'
rg -Fq 'work_root="$(bash "$repo_root/Scripts/create-store-staging.sh")"' Scripts/build-app-store-app.sh || fail 'builder does not use isolated staging'
echo 'Store staging PASS'
