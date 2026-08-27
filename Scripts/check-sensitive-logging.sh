#!/usr/bin/env bash
set -euo pipefail

if [[ $# -eq 0 ]]; then
  echo "usage: $0 <source-file>..." >&2
  exit 2
fi

sensitive='(payload|file_?name|filename|file_?path|filepath|path|content|pairing_?code|private_?key|privatekey|secret|credential|password)'
swift_sink='(^|[^[:alnum:]_])(print|NSLog|os_log)[[:space:]]*\(|Logger\.[[:alnum:]_]+[[:space:]]*\('
go_sink='(^|[^[:alnum:]_])(log\.(Print|Printf|Println|Fatal|Fatalf|Panic|Panicf)|fmt\.(Print|Printf|Println))[[:space:]]*\('
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
        | rg -v '^[0-9]+:[[:space:]]*fmt\.Println\("stack-secrets: persistent material is ready"\)$' || true)"
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
