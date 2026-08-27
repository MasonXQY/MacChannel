#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/macchannel-runtime-block.XXXXXX")"
cleanup() {
  case "${test_root}" in
    "${TMPDIR:-/tmp}"/macchannel-runtime-block.*) rm -rf "${test_root}" ;;
    *) echo "refusing unexpected cleanup target" >&2 ;;
  esac
}
trap cleanup EXIT INT TERM

mkdir -p "${test_root}/empty" "${test_root}/self-signed"
printf '%s\n' '{"claimed":"PASS"}' > "${test_root}/self-signed/manifest.json"
printf '%s\n' 'fake signature' > "${test_root}/self-signed/manifest.sig"
printf '%s\n' 'unreadable evidence' > "${test_root}/unreadable"
chmod 000 "${test_root}/unreadable"
ln -s "${test_root}/self-signed" "${test_root}/symlink"

assert_blocked() {
  output_file="${test_root}/output"
  set +e
  "$@" > "${output_file}" 2>&1
  command_status=$?
  set -e
  [[ ${command_status} -eq 2 ]] || { echo "runtime privacy gate was not BLOCKED" >&2; exit 1; }
  rg -q 'RUNTIME BLOCKED' "${output_file}"
  if rg -q 'RUNTIME PASS' "${output_file}"; then
    echo "runtime privacy gate emitted PASS" >&2
    exit 1
  fi
}

assert_blocked "${repository_root}/Scripts/audit-privacy.sh"
assert_blocked "${repository_root}/Scripts/audit-privacy.sh" --runtime-evidence "${test_root}/empty"
assert_blocked "${repository_root}/Scripts/audit-privacy.sh" --runtime-evidence "${test_root}/self-signed" --fixture-file "${test_root}/self-signed/manifest.json"
assert_blocked "${repository_root}/Scripts/audit-privacy.sh" --runtime-evidence "${test_root}/unreadable"
assert_blocked "${repository_root}/Scripts/audit-privacy.sh" --runtime-evidence "${test_root}/symlink"

echo "privacy runtime permanently-blocked contract PASS"
