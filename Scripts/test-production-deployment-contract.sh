#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
compose="$root/Infrastructure/production/docker-compose.yml"
example="$root/Infrastructure/production/env.example"
workflow="$root/.github/workflows/publish-service-images.yml"
acceptance_workflow="$root/.github/workflows/public-service-acceptance.yml"
single_host="$root/Infrastructure/production/docker-compose.single-host.yml"
official_environment="$root/Infrastructure/production/official.env"

test -f "$compose"
test -f "$example"
test -f "$workflow"
test -f "$acceptance_workflow"
test -f "$single_host"
test -f "$official_environment"
rg -q 'MACCHANNEL_RENDEZVOUS_IMAGE=.*@sha256' "$example"
rg -q 'MACCHANNEL_COTURN_IMAGE=.*@sha256' "$example"
rg -q 'MACCHANNEL_POSTGRES_MIGRATION_IMAGE=.*@sha256' "$example"
rg -q 'POSTGRES_SSLMODE: verify-full' "$compose"
rg -q '^  migrate-v1-1:' "$compose"
rg -q '006_pairing_rejection\.sql' "$compose"
rg -q '007_bilateral_pairing\.sql' "$compose"
rg -q 'condition: service_completed_successfully' "$compose"
rg -q '/migrations:ro' "$compose"
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
rg -q '^MACCHANNEL_ALLOWED_WS_ORIGINS=https://channel\.zensys-tech\.com$' "$official_environment"
rg -q '^MACCHANNEL_TURN_REALM=turn\.zensys-tech\.com$' "$official_environment"
if rg -n 'PASSWORD=|SECRET=|TOKEN=|0000000000000000|your-domain|\.invalid' "$official_environment"; then
    echo "official production environment contains a secret or placeholder" >&2
    exit 1
fi

rg -q '^  postgres:' "$single_host"
rg -q 'postgres:17\.11-alpine3\.24@sha256:' "$single_host"
rg -q 'ssl=on' "$single_host"
rg -q 'ssl_ca_file=/run/postgresql/tls/ca\.pem' "$single_host"
rg -q '^    internal: true$' "$single_host"
if rg -n '5432:5432|0\.0\.0\.0:5432|ports:.*5432' "$single_host"; then
    echo "single-host PostgreSQL must not publish a host port" >&2
    exit 1
fi

rg -q 'docker compose run --rm migrate-v1-1' "$root/Infrastructure/production/README.md"

rg -q 'packages: write' "$workflow"
rg -q 'ghcr\.io/masonxqy/macchannel-rendezvous' "$workflow"
rg -q 'ghcr\.io/masonxqy/macchannel-coturn' "$workflow"
rg -q 'platforms: linux/amd64,linux/arm64' "$workflow"
rg -q 'sbom: true' "$workflow"
rg -q 'provenance: mode=max' "$workflow"
if rg -n 'uses: [^@[:space:]]+@v[0-9]' "$workflow"; then
    echo "service image workflow contains a mutable major-version action reference" >&2
    exit 1
fi
rg -q 'MACCHANNEL_E2E_STACK_ORIGIN: https://channel\.zensys-tech\.com' "$acceptance_workflow"
rg -q 'swift test --no-parallel --filter TransferIntegrationTests' "$acceptance_workflow"
if rg -n 'uses: [^@[:space:]]+@v[0-9]' "$acceptance_workflow"; then
    echo "public acceptance workflow contains a mutable major-version action reference" >&2
    exit 1
fi

rg -q 'PasswordAuthentication no' "$root/Infrastructure/production/host/99-macchannel-ssh.conf"
rg -q 'live-restore' "$root/Infrastructure/production/host/docker-daemon.json"
rg -q 'EnvironmentFile=/etc/macchannel/production.env' "$root/Infrastructure/production/host/macchannel.service"
rg -q 'gzip -t' "$root/Infrastructure/production/host/macchannel-backup.sh"
rg -q 'OnCalendar=' "$root/Infrastructure/production/host/macchannel-backup.timer"
rg -q 'systemctl try-reload-or-restart macchannel.service' "$root/Infrastructure/production/host/macchannel-certificate-deploy.sh"

echo "production deployment contract PASS"
