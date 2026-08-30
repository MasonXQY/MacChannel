#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
compose="$root/Infrastructure/production/docker-compose.yml"
example="$root/Infrastructure/production/env.example"

test -f "$compose"
test -f "$example"
rg -q 'MACCHANNEL_RENDEZVOUS_IMAGE=.*@sha256' "$example"
rg -q 'MACCHANNEL_COTURN_IMAGE=.*@sha256' "$example"
rg -q 'POSTGRES_SSLMODE: verify-full' "$compose"
rg -q 'read_only: true' "$compose"
rg -q 'no-new-privileges:true' "$compose"
rg -q '127\.0\.0\.1:8080:8080' "$compose"
rg -q '443:8443' "$compose"
rg -q '3478:3478/udp' "$compose"
rg -q '5349:5349/tcp' "$compose"
rg -q '49160-49200:49160-49200/udp' "$compose"
if rg -n 'https?://localhost|wss?://localhost|localhost:[0-9]|example\.com|change-?me|TAILSCALE' "$compose"; then
    echo "production deployment contains a development endpoint or default secret" >&2
    exit 1
fi
if rg -n 'POSTGRES_PASSWORD=|TURN_SHARED_SECRET=' "$compose"; then
    echo "production deployment embeds a secret in the environment" >&2
    exit 1
fi

echo "production deployment contract PASS"
