#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repository_root}"

for command_name in git rg awk; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "privacy audit BLOCKED: missing ${command_name}" >&2
    exit 2
  fi
done

fixture_marker="MACCHANNEL_PRIVACY_FIXTURE_$(uuidgen)"
tracked_scope=(App Sources Services Infrastructure)

if git grep -n -F "${fixture_marker}" -- "${tracked_scope[@]}"; then
  echo "privacy audit FAIL: unique fixture marker appeared in tracked service material" >&2
  exit 1
fi

if rg -n -i \
  '\b(file_?name|file_?path|private_?key|transfer_?history|file_?content)\b' \
  Services/migrations -g '*.sql'; then
  echo "privacy audit FAIL: forbidden server persistence column" >&2
  exit 1
fi

if rg -n \
  '(^|[^[:alnum:]_])(print|NSLog|Logger|os_log)\(|Logger\.|log\.(Print|Printf|Println|Fatal|Fatalf|Panic|Panicf)\([^"`]' \
  App Sources Services/rendezvous \
  -g '*.swift' -g '*.go'; then
  echo "privacy audit FAIL: review data-bearing production log call" >&2
  exit 1
fi

coturn_block="$({
  awk '/^  coturn:/{inside=1; next} inside && (/^  [[:alnum:]_-]+:/ || /^[^ ]/){exit} inside{print}' \
    Infrastructure/docker-compose.yml
} || true)"
unexpected_coturn_volume="$(printf '%s\n' "${coturn_block}" \
  | awk '/^    volumes:/{volumes=1; next} volumes && /^    [[:alnum:]_-]+:/{exit} volumes && /-/{print}' \
  | rg -v ':ro$' || true)"
if [[ -n "${unexpected_coturn_volume}" ]]; then
  printf '%s\n' "${unexpected_coturn_volume}" >&2
  echo "privacy audit FAIL: coturn has an unexpected persistent-looking mount" >&2
  exit 1
fi

rg -q '^no-stdout-log$' Infrastructure/coturn/turnserver.conf
rg -q '^no-cli$' Infrastructure/coturn/turnserver.conf
printf '%s\n' "${coturn_block}" | rg -q '^    read_only: true$'
printf '%s\n' "${coturn_block}" | rg -q '^    tmpfs:$'

echo "repository privacy fixture scan PASS marker-sha256=$(printf '%s' "${fixture_marker}" | shasum -a 256 | awk '{print $1}')"
echo "runtime rendezvous/coturn/PostgreSQL/metrics log scan NOT RUN: requires Docker stack"
