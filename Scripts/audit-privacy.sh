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

required_evidence=(manifest.json manifest.sig receipt.json canaries.env client.log rendezvous.log coturn.log postgres.json metrics.txt compose-ps.json inspect.json mounts.json postgres-before.json postgres-after.json destination.bin)
[[ -f "${fixture_file}" ]] || { echo "privacy runtime audit FAIL: fixture file missing" >&2; exit 1; }
[[ -d "${evidence_directory}" ]] || { echo "privacy runtime audit FAIL: evidence directory missing" >&2; exit 1; }
for evidence_name in "${required_evidence[@]}"; do
  [[ -f "${evidence_directory}/${evidence_name}" ]] || {
    echo "privacy runtime audit FAIL: missing ${evidence_name}" >&2
    exit 1
  }
done
for command_name in docker jq openssl; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "privacy RUNTIME BLOCKED: missing verifier ${command_name}" >&2
    exit 2
  }
done
pinned_auditor_key="Infrastructure/privacy-auditor-public-key.pem"
[[ -f "${pinned_auditor_key}" ]] || {
  echo "privacy RUNTIME BLOCKED: independently controlled auditor public key is not provisioned" >&2
  exit 2
}
openssl dgst -sha256 -verify "${pinned_auditor_key}" \
  -signature "${evidence_directory}/manifest.sig" "${evidence_directory}/manifest.json" >/dev/null || {
  echo "privacy runtime audit FAIL: manifest signature invalid" >&2
  exit 1
}

manifest="${evidence_directory}/manifest.json"
receipt="${evidence_directory}/receipt.json"
jq -e '.schemaVersion == 1 and (.codeCommit | test("^[0-9a-f]{40}$")) and (.transferID | test("^[0-9A-Fa-f-]{36}$")) and (.canaryID | test("^[A-Za-z0-9_-]{16,128}$")) and .startUTC < .endUTC and .sourceSHA256 == .destinationSHA256' "${manifest}" >/dev/null
jq -e --slurpfile manifest "${manifest}" '.transferID == $manifest[0].transferID and .canaryID == $manifest[0].canaryID and .sourceSHA256 == $manifest[0].sourceSHA256 and .destinationSHA256 == $manifest[0].destinationSHA256 and .startUTC >= $manifest[0].startUTC and .endUTC <= $manifest[0].endUTC' "${receipt}" >/dev/null

source_hash="$(shasum -a 256 "${fixture_file}" | awk '{print $1}')"
destination_hash="$(shasum -a 256 "${evidence_directory}/destination.bin" | awk '{print $1}')"
[[ "${source_hash}" == "${destination_hash}" ]] || { echo "privacy runtime audit FAIL: transfer hash mismatch" >&2; exit 1; }
jq -e --arg source_hash "${source_hash}" '.sourceSHA256 == $source_hash and .destinationSHA256 == $source_hash' "${manifest}" >/dev/null

manifest_commit="$(jq -r '.codeCommit' "${manifest}")"
git cat-file -e "${manifest_commit}^{commit}" 2>/dev/null || { echo "privacy runtime audit FAIL: unknown code commit" >&2; exit 1; }

while IFS= read -r container_id; do
  [[ -n "${container_id}" ]] || continue
  docker inspect "${container_id}" >/dev/null 2>&1 || { echo "privacy runtime audit FAIL: referenced container is not live" >&2; exit 1; }
  jq -e --arg id "${container_id}" 'map(select(.Id == $id)) | length == 1' "${evidence_directory}/inspect.json" >/dev/null
done < <(jq -r '.containerIDs[]' "${manifest}")
jq -e '[.[] | select((.Name | contains("coturn")) and ([.Mounts[]? | select(.RW == true and .Type != "tmpfs")] | length > 0))] | length == 0' "${evidence_directory}/mounts.json" >/dev/null
jq -e --slurpfile manifest "${manifest}" '.capturedUTC >= $manifest[0].startUTC and .capturedUTC <= $manifest[0].endUTC' "${evidence_directory}/postgres-before.json" >/dev/null
jq -e --slurpfile manifest "${manifest}" '.capturedUTC >= $manifest[0].startUTC and .capturedUTC <= $manifest[0].endUTC and .expiredPairingRows == 0' "${evidence_directory}/postgres-after.json" >/dev/null

Scripts/scan-privacy-evidence.sh "${evidence_directory}" "${evidence_directory}/canaries.env" >/dev/null
echo "privacy RUNTIME PASS: signed manifest and raw live evidence cross-validated"
