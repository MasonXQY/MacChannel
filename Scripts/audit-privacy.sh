#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repository_root}"

mode=blocked
if [[ $# -eq 1 && "$1" == "--static-only" ]]; then
  mode=static
elif [[ $# -ne 0 ]]; then
  mode=blocked
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
    ! -path 'Scripts/test-*.sh' \
    ! -name 'audit-privacy.sh' ! -name 'check-sensitive-logging.sh' \
    ! -name 'test-privacy-audit.sh' ! -name 'test-privacy-runtime-block.sh' -print
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
echo "privacy RUNTIME BLOCKED: trusted producer and verifier are NOT IMPLEMENTED; runtime evidence is not read" >&2
exit 2
