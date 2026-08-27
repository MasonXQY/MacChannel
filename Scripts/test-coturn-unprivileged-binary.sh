#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TURN_EXTERNAL_IP=192.0.2.1 docker compose \
    -f "${repository_root}/Infrastructure/docker-compose.yml" \
    build coturn >/dev/null

docker run --rm \
    --user 65534:65534 \
    --read-only \
    --security-opt no-new-privileges:true \
    --cap-drop ALL \
    --entrypoint /usr/local/bin/turnserver-unprivileged \
    macchannel-local-coturn --version >/dev/null

echo "coturn unprivileged executable PASS"
