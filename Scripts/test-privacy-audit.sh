#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/macchannel-privacy-mutants.XXXXXX")"
cleanup() {
  case "${test_root}" in
    "${TMPDIR:-/tmp}"/macchannel-privacy-mutants.*) rm -rf "${test_root}" ;;
    *) echo "refusing unexpected cleanup target: ${test_root}" >&2 ;;
  esac
}
trap cleanup EXIT INT TERM

printf '%s\n' 'package mutant' 'func leak(payload string) { log.Printf("payload=%s", payload) }' > "${test_root}/payload.go"
printf '%s\n' 'package mutant' 'func leak(content string) {' '  log.Printf(' '    "content=%s",' '    content,' '  )' '}' > "${test_root}/multiline.go"
printf '%s\n' 'func leak(path: String) { print("path=\(path)") }' > "${test_root}/path.swift"
printf '%s\n' '#!/usr/bin/env bash' 'echo "private_key=${private_key}"' > "${test_root}/secret.sh"
printf '%s\n' 'package safe' 'func status(err error) { log.Printf("cleanup category: %v", err) }' > "${test_root}/safe.go"

for mutant in payload.go multiline.go path.swift secret.sh; do
  if "${repository_root}/Scripts/check-sensitive-logging.sh" "${test_root}/${mutant}" >/dev/null 2>&1; then
    echo "privacy mutant survived: ${mutant}" >&2
    exit 1
  fi
done
"${repository_root}/Scripts/check-sensitive-logging.sh" "${test_root}/safe.go" >/dev/null

evidence_root="${test_root}/evidence"
mkdir -p "${evidence_root}"
canaries_file="${test_root}/canaries.env"
printf '%s\n' \
  'filename=FILENAME_CANARY_123456' \
  'path=PATH_CANARY_1234567890' \
  'content=CONTENT_CANARY_123456' \
  'pairing_code=PAIRING_CANARY_123456' \
  'private_key=PRIVATE_KEY_CANARY_123456' \
  'turn_username=TURN_USER_CANARY_123456' > "${canaries_file}"
for evidence_name in client.log rendezvous.log coturn.log postgres.json metrics.txt; do
  printf '%s\n' 'bounded fixed-category evidence' > "${evidence_root}/${evidence_name}"
done
"${repository_root}/Scripts/scan-privacy-evidence.sh" "${evidence_root}" "${canaries_file}" >/dev/null

for leak_case in pairing_code private_key turn_username; do
  cp "${evidence_root}/rendezvous.log" "${test_root}/clean.log"
  awk -F= -v wanted="${leak_case}" '$1 == wanted {print $2}' "${canaries_file}" > "${evidence_root}/rendezvous.log"
  failure_output="$("${repository_root}/Scripts/scan-privacy-evidence.sh" "${evidence_root}" "${canaries_file}" 2>&1 || true)"
  leaked_value="$(awk -F= -v wanted="${leak_case}" '$1 == wanted {print $2}' "${canaries_file}")"
  [[ "${failure_output}" != *"${leaked_value}"* ]] || { echo "privacy scanner echoed canary" >&2; exit 1; }
  [[ "${failure_output}" == *"FAIL"* ]] || { echo "privacy leak mutant survived" >&2; exit 1; }
  cp "${test_root}/clean.log" "${evidence_root}/rendezvous.log"
done

printf '%s\n' 'CONTENT_CANARY_' '123456' > "${evidence_root}/client.log"
if "${repository_root}/Scripts/scan-privacy-evidence.sh" "${evidence_root}" "${canaries_file}" >/dev/null 2>&1; then
  echo "multiline canary mutant survived" >&2
  exit 1
fi
printf '%s\n' 'bounded fixed-category evidence' > "${evidence_root}/client.log"
dd if=/dev/zero of="${evidence_root}/metrics.txt" bs=1048576 count=17 >/dev/null 2>&1
if "${repository_root}/Scripts/scan-privacy-evidence.sh" "${evidence_root}" "${canaries_file}" >/dev/null 2>&1; then
  echo "oversized evidence mutant survived" >&2
  exit 1
fi
printf '\0TURN_USER_CANARY_123456\0' > "${evidence_root}/metrics.txt"
if "${repository_root}/Scripts/scan-privacy-evidence.sh" "${evidence_root}" "${canaries_file}" >/dev/null 2>&1; then
  echo "binary canary mutant survived" >&2
  exit 1
fi
if "${repository_root}/Scripts/scan-privacy-evidence.sh" "${test_root}/missing" "${canaries_file}" >/dev/null 2>&1; then
  echo "empty evidence mutant survived" >&2
  exit 1
fi
echo "privacy logging mutants PASS"
