#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 EVIDENCE_DIR CANARIES_FILE" >&2
  exit 2
fi
evidence_directory="$1"
canaries_file="$2"
maximum_bytes=$((16 * 1024 * 1024))
required_outputs=(client.log rendezvous.log coturn.log postgres.json metrics.txt)
required_categories=(filename path content pairing_code private_key turn_username)

[[ -d "${evidence_directory}" && -f "${canaries_file}" ]] || {
  echo "privacy evidence FAIL: required input missing" >&2
  exit 1
}

while IFS='=' read -r category token; do
  [[ -n "${category}" ]] || continue
  [[ "${token}" =~ ^[A-Za-z0-9_-]{16,128}$ ]] || {
    echo "privacy evidence FAIL: invalid canary format" >&2
    exit 1
  }
done < "${canaries_file}"
canary_for() { awk -F= -v wanted="$1" '$1 == wanted {print $2; exit}' "${canaries_file}"; }
for category in "${required_categories[@]}"; do
  [[ -n "$(canary_for "${category}")" ]] || {
    echo "privacy evidence FAIL: canary category missing" >&2
    exit 1
  }
done

for evidence_name in "${required_outputs[@]}"; do
  evidence_path="${evidence_directory}/${evidence_name}"
  [[ -f "${evidence_path}" ]] || {
    echo "privacy evidence FAIL: missing ${evidence_name}" >&2
    exit 1
  }
  evidence_size="$(stat -f '%z' "${evidence_path}" 2>/dev/null || stat -c '%s' "${evidence_path}")"
  [[ "${evidence_size}" -le "${maximum_bytes}" ]] || {
    echo "privacy evidence FAIL: oversized ${evidence_name}" >&2
    exit 1
  }
  for category in "${required_categories[@]}"; do
    canary="$(canary_for "${category}")"
    set +o pipefail
    set +e
    LC_ALL=C tr -d '\r\n' < "${evidence_path}" \
      | rg -a -q -F -f <(printf '%s\n' "${canary}")
    scan_status="${PIPESTATUS[1]}"
    set -e
    set -o pipefail
    if [[ "${scan_status}" -eq 0 ]]; then
      echo "privacy evidence FAIL: ${category} canary found in ${evidence_name}" >&2
      exit 1
    fi
  done
done

echo "privacy evidence content scan PASS"
