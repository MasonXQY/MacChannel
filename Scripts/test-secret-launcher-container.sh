#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${repository_root}/.build/secret-launcher-contract.XXXXXX")"
fixture_path="${fixture_root}/secret"
second_fixture_path="${fixture_root}/second-secret"

cleanup() {
    rm -rf "$fixture_root"
}
trap cleanup EXIT

printf 'container-capability-contract\n' > "$fixture_path"
printf 'same-parent-second-copy\n' > "$second_fixture_path"
chmod 600 "$fixture_path" "$second_fixture_path"

TURN_EXTERNAL_IP=192.0.2.1 docker compose \
    -f "${repository_root}/Infrastructure/docker-compose.yml" \
    build rendezvous >/dev/null

docker run --rm \
    --entrypoint /usr/local/bin/secret-launcher \
    --read-only \
    --security-opt no-new-privileges:true \
    --cap-drop ALL \
    --cap-add CHOWN \
    --cap-add DAC_OVERRIDE \
    --cap-add SETGID \
    --cap-add SETUID \
    --mount "type=bind,src=${fixture_path},dst=/stack-secrets/secret,readonly" \
    --mount "type=bind,src=${second_fixture_path},dst=/stack-secrets/second-secret,readonly" \
    --tmpfs /run/macchannel:size=1m,uid=0,gid=0,mode=0700 \
    macchannel-local-rendezvous \
    --uid 65532 \
    --gid 65532 \
    --copy /stack-secrets/secret=/run/macchannel/secret \
    --copy /stack-secrets/second-secret=/run/macchannel/second-secret \
    -- /bin/sh -ec '
        test "$(id -u):$(id -g)" = 65532:65532
        test "$(stat -c "%u:%g:%a" /run/macchannel)" = 65532:65532:700
        test "$(stat -c "%u:%g:%a" /run/macchannel/secret)" = 65532:65532:400
        test "$(stat -c "%u:%g:%a" /run/macchannel/second-secret)" = 65532:65532:400
    '

echo "secret launcher container capability PASS"
