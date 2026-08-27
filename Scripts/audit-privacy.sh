#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repository_root}"

mode=blocked
evidence_directory=
fixture_file=
if [[ $# -eq 1 && "$1" == "--static-only" ]]; then
  mode=static
elif [[ $# -eq 4 && "$1" == "--runtime-evidence" && "$3" == "--fixture-file" ]]; then
  mode=runtime
  evidence_directory="$2"
  fixture_file="$4"
elif [[ $# -ne 0 ]]; then
  echo "usage: $0 [--static-only | --runtime-evidence DIR --fixture-file FILE]" >&2
  exit 2
fi

for command_name in git rg awk shasum find; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "privacy audit BLOCKED: missing ${command_name}" >&2
    exit 2
  fi
done

if rg -n -i '\b(file_?name|file_?path|private_?key|transfer_?history|file_?content)\b' \
  Services/migrations -g '*.sql'; then
  echo "privacy static audit FAIL: forbidden server persistence column" >&2
  exit 1
fi

source_files=()
while IFS= read -r source_file; do source_files+=("${source_file}"); done < <(
  find App Sources Services/rendezvous Scripts -type f \
    \( -name '*.swift' -o -name '*.go' -o -name '*.sh' \) \
    ! -name 'audit-privacy.sh' ! -name 'check-sensitive-logging.sh' \
    ! -name 'test-privacy-audit.sh' -print
)
Scripts/check-sensitive-logging.sh "${source_files[@]}" >/dev/null
Scripts/test-privacy-audit.sh >/dev/null

coturn_block="$({
  awk '/^  coturn:/{inside=1; next} inside && (/^  [[:alnum:]_-]+:/ || /^[^ ]/){exit} inside{print}' \
    Infrastructure/docker-compose.yml
} || true)"
unexpected_coturn_volume="$(printf '%s\n' "${coturn_block}" \
  | awk '/^    volumes:/{volumes=1; next} volumes && /^    [[:alnum:]_-]+:/{exit} volumes && /-/{print}' \
  | rg -v ':ro$' || true)"
if [[ -n "${unexpected_coturn_volume}" ]]; then
  printf '%s\n' "${unexpected_coturn_volume}" >&2
  echo "privacy static audit FAIL: coturn has an unexpected persistent writable mount" >&2
  exit 1
fi
rg -q '^no-cli$' Infrastructure/coturn/turnserver.conf
rg -q '^log-file=/dev/null$' Infrastructure/coturn/turnserver.conf
rg -q '^no-stdout-log$' Infrastructure/coturn/turnserver.conf
printf '%s\n' "${coturn_block}" | rg -q '^    read_only: true$'
printf '%s\n' "${coturn_block}" | rg -q '^    tmpfs:$'

echo "privacy STATIC PASS: schema, sensitive-log mutants, and coturn persistence contract"
if [[ "${mode}" == static ]]; then exit 0; fi
if [[ "${mode}" == blocked ]]; then
  echo "privacy RUNTIME BLOCKED: provide a transferred fixture and collected client/rendezvous/coturn/PostgreSQL/metrics evidence" >&2
  exit 2
fi

required_evidence=(client.log rendezvous.log coturn.log postgres.txt metrics.txt mounts.txt expiry.txt fixture.sha256)
[[ -f "${fixture_file}" ]] || { echo "privacy runtime audit FAIL: fixture file missing" >&2; exit 1; }
[[ -d "${evidence_directory}" ]] || { echo "privacy runtime audit FAIL: evidence directory missing" >&2; exit 1; }
for evidence_name in "${required_evidence[@]}"; do
  [[ -f "${evidence_directory}/${evidence_name}" ]] || {
    echo "privacy runtime audit FAIL: missing ${evidence_name}" >&2
    exit 1
  }
done

expected_fixture_hash="$(shasum -a 256 "${fixture_file}" | awk '{print $1}')"
recorded_fixture_hash="$(awk 'NF {print $1; exit}' "${evidence_directory}/fixture.sha256")"
[[ "${recorded_fixture_hash}" == "${expected_fixture_hash}" ]] || {
  echo "privacy runtime audit FAIL: fixture receipt hash mismatch" >&2
  exit 1
}
fixture_name="$(basename "${fixture_file}")"
fixture_content="$(LC_ALL=C tr -d '\n' < "${fixture_file}")"
[[ -n "${fixture_name}" && -n "${fixture_content}" ]] || {
  echo "privacy runtime audit FAIL: fixture name/content must be non-empty" >&2
  exit 1
}
for evidence_name in client.log rendezvous.log coturn.log postgres.txt metrics.txt; do
  if rg -n -F -e "${fixture_name}" -e "${fixture_content}" "${evidence_directory}/${evidence_name}"; then
    echo "privacy runtime audit FAIL: fixture leaked into ${evidence_name}" >&2
    exit 1
  fi
done
rg -q '^coturn_persistent_writable_volumes=0$' "${evidence_directory}/mounts.txt"
rg -q '^expired_pairing_rows=0$' "${evidence_directory}/expiry.txt"
echo "privacy RUNTIME PASS: explicit fixture receipt and all required evidence scanned"
