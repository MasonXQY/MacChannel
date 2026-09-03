#!/usr/bin/env bash
set -euo pipefail

if [[ $# -eq 0 ]]; then
  repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source_files=()
  while IFS= read -r source_file; do source_files+=("${source_file}"); done < <(
    find "$repository_root/App" "$repository_root/Sources" \
      "$repository_root/Services/rendezvous" "$repository_root/Scripts" -type f \
      \( -name '*.swift' -o -name '*.go' -o -name '*.sh' \) \
      ! -path "$repository_root/Scripts/test-*.sh" \
      ! -name 'audit-privacy.sh' ! -name 'check-sensitive-logging.sh' -print
  )
  set -- "${source_files[@]}"
fi

sensitive='(payload|file_?name|filename|file_?path|filepath|path|content|pairing_?code|private_?key|privatekey|secret|credential|password|tailscale_?ip|mesh_?ip|magicdns|host_?name|hostname|fingerprint|cli_?stdout|cli_?stderr|command_?stdout|command_?stderr)'
swift_sink='(^|[^[:alnum:]_])(print|NSLog|os_log)[[:space:]]*\(|Logger\.[[:alnum:]_]+[[:space:]]*\('
go_sink='(^|[^[:alnum:]_])(log\.(Print|Printf|Println|Fatal|Fatalf|Panic|Panicf)|fmt\.(Print|Printf|Println|Fprint|Fprintf|Fprintln))[[:space:]]*\('
shell_sink='^[[:space:]]*(echo|printf|logger)([[:space:]]|$)'
found=false

for source_file in "$@"; do
  [[ -f "${source_file}" ]] || continue
  matches=
  case "${source_file}" in
    *.swift)
      matches="$(rg -n -U -i --pcre2 "(${swift_sink})(?s:.{0,160}?)(${sensitive})(?s:.{0,120}?)\\)" "${source_file}" || true)"
      ;;
    *.go)
      matches="$(rg -n -U -i --pcre2 "(${go_sink})(?s:.{0,160}?)(${sensitive})(?s:.{0,120}?)\\)" "${source_file}" || true)"
      matches="$(printf '%s\n' "${matches}" \
        | rg -v '^[0-9]+:[[:space:]]*fmt\.Println\("stack-secrets: persistent material is ready"\)$' \
        | rg -v '^[0-9]+:[[:space:]]*_, _ = fmt\.Fprintln\(os\.Stderr, "(secret-launcher|stack-secrets): failed"\)$' \
        || true)"
      ;;
    *.sh)
      matches="$(rg -n -i "(${shell_sink}).*(\\$\\{?${sensitive}|%[a-z].*${sensitive})" "${source_file}" || true)"
      ;;
  esac
  if [[ -n "${matches}" ]]; then
    printf '%s:%s\n' "${source_file}" "${matches}"
    found=true
  fi
done

if [[ "${found}" == true ]]; then
  echo "sensitive logging contract FAIL" >&2
  exit 1
fi
echo "sensitive logging contract PASS"
