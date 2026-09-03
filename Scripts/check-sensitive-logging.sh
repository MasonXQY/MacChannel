#!/usr/bin/env bash
set -euo pipefail

if [[ $# -eq 0 ]]; then
  repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source_files=()
  while IFS= read -r source_file; do source_files+=("${source_file}"); done < <(
    find "$repository_root/App" "$repository_root/Sources" \
      "$repository_root/Services/rendezvous" "$repository_root/Scripts" -type f \
      \( -name '*.swift' -o -name '*.go' -o -name '*.sh' \) \
      ! -name 'audit-privacy.sh' ! -name 'check-sensitive-logging.sh' -print
  )
  set -- "${source_files[@]}"
fi

sensitive='(payload|file_?name|filename|file_?path|filepath|path|content|pairing_?code|private_?key|privatekey|secret|credential|password|tailscale_?ip|mesh_?ip|magicdns|host_?name|hostname|fingerprint|cli_?stdout|cli_?stderr|command_?stdout|command_?stderr)'
swift_sink='(^|[^[:alnum:]_])(print|NSLog|os_log)[[:space:]]*\(|Logger\.[[:alnum:]_]+[[:space:]]*\('
go_sink='(^|[^[:alnum:]_])(log\.(Print|Printf|Println|Fatal|Fatalf|Panic|Panicf)|fmt\.(Print|Printf|Println|Fprint|Fprintf|Fprintln))[[:space:]]*\('
shell_sink='^[[:space:]]*(echo|printf|logger)([[:space:]]|$)'
found=false

remove_fixture_data_write() {
  local matches="$1"
  local fixture_path="$2"
  local line
  while IFS= read -r line; do
    if [[ "$line" == *"printf "* && "$line" == *">"* && "$line" == *"$fixture_path"* ]]; then
      continue
    fi
    printf '%s\n' "$line"
  done <<< "$matches"
}

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
      case "${source_file}" in
        */Scripts/test-privacy-audit.sh)
          matches="$(remove_fixture_data_write "$matches" '${test_root}/')"
          ;;
        */Scripts/test-update-acceptance.sh)
          matches="$(remove_fixture_data_write "$matches" 'UpdateAcceptancePayload.txt')"
          ;;
        */Scripts/test-personal-mesh-install.sh)
          matches="$(remove_fixture_data_write "$matches" 'MacChannel.app/Contents/MacChannelApp')"
          matches="$(remove_fixture_data_write "$matches" 'MacChannel.app/Contents/Resources/state.bin')"
          ;;
        */Scripts/test-sensitive-logging-contract.sh|*/Scripts/test-privacy-audit-contract.sh)
          matches="$(remove_fixture_data_write "$matches" '"$mutation_path"')"
          ;;
      esac
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
