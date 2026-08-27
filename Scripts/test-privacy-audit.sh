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
printf '%s\n' 'func leak(tailscaleIP: String) { print("mesh=\(tailscaleIP)") }' > "${test_root}/tailscale.swift"
printf '%s\n' 'package mutant' 'func leak(magicDNS string) { log.Printf("peer=%s", magicDNS) }' > "${test_root}/magicdns.go"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "${fingerprint}"' > "${test_root}/fingerprint.sh"
printf '%s\n' 'package mutant' 'func leak(cliStdout string) { fmt.Fprintf(os.Stderr, "cli=%s", cliStdout) }' > "${test_root}/stdout.go"
printf '%s\n' 'package mutant' 'func leak(pairingCode string) { log.Printf("code=%s", pairingCode) }' > "${test_root}/pairing.go"
printf '%s\n' 'package safe' 'func status(err error) { log.Printf("cleanup category: %v", err) }' > "${test_root}/safe.go"

for mutant in payload.go multiline.go path.swift secret.sh tailscale.swift magicdns.go fingerprint.sh stdout.go pairing.go; do
  if "${repository_root}/Scripts/check-sensitive-logging.sh" "${test_root}/${mutant}" >/dev/null 2>&1; then
    echo "privacy mutant survived: ${mutant}" >&2
    exit 1
  fi
done
"${repository_root}/Scripts/check-sensitive-logging.sh" "${test_root}/safe.go" >/dev/null
echo "privacy logging mutants PASS"
