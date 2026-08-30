#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose_file="${repository_root}/Infrastructure/docker-compose.yml"
local_only=false
stack_started=false
state_root=
temporary_files=()

if [[ ${#} -gt 1 ]]; then
  echo "用法: ${0} [--local-only]" >&2
  exit 2
fi
if [[ ${#} -eq 1 ]]; then
  if [[ "${1}" != "--local-only" ]]; then
    echo "用法: ${0} [--local-only]" >&2
    exit 2
  fi
  local_only=true
fi

cleanup() {
  local saved_exit_code="${?}"
  trap - EXIT INT TERM
  set +e
  if [[ "${stack_started}" == true ]]; then
    docker compose -f "${compose_file}" down --volumes --remove-orphans >/dev/null 2>&1
  fi
  local temporary_file
  if ((${#temporary_files[@]} > 0)); then
    for temporary_file in "${temporary_files[@]}"; do
      case "${temporary_file}" in
        "${TMPDIR:-/tmp}"/macchannel-local-e2e.*|"${TMPDIR:-/tmp}"/macchannel-stack-e2e.*)
          rm -f "${temporary_file}"
          ;;
        *) echo "拒绝清理未验证的临时日志：${temporary_file}" >&2 ;;
      esac
    done
  fi
  if [[ -n "${state_root}" && -d "${state_root}" ]]; then
    case "${state_root}" in
      "${TMPDIR:-/tmp}"/macchannel-e2e.*) rm -rf "${state_root}" ;;
      *) echo "拒绝清理未验证的临时目录：${state_root}" >&2 ;;
    esac
  fi
  exit "${saved_exit_code}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

run_local_integration() {
  local output_file="${1}"
  (
    cd "${repository_root}"
    env -u MACCHANNEL_E2E_STACK -u MACCHANNEL_E2E_STACK_ORIGIN \
      swift test --no-parallel --filter TransferIntegrationTests
  ) | tee "${output_file}"
  grep -F "direct-lan PASS" "${output_file}" >/dev/null
}

if [[ "${local_only}" == true ]]; then
  local_output="$(mktemp "${TMPDIR:-/tmp}/macchannel-local-e2e.XXXXXX")"
  temporary_files+=("${local_output}")
  run_local_integration "${local_output}"
  rm -f "${local_output}"
  echo "local direct integration PASS；Internet/TURN 未运行。"
  exit 0
fi

for command_name in docker go swift openssl; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "E2E BLOCKED：缺少 ${command_name}；真实 rendezvous/STUN/TURN 测试未运行。" >&2
    exit 2
  fi
done
if ! docker compose version >/dev/null 2>&1; then
  echo "E2E BLOCKED：Docker Compose v2 不可用；真实 relay 测试未运行。" >&2
  exit 2
fi

state_root="$(mktemp -d "${TMPDIR:-/tmp}/macchannel-e2e.XXXXXX")"
export MACCHANNEL_LOCAL_STATE_ROOT="${state_root}"
export MACCHANNEL_COMPOSE_PROJECT_NAME="macchannel-e2e-$$"
export COMPOSE_PROJECT_NAME="${MACCHANNEL_COMPOSE_PROJECT_NAME}"
stack_arguments=(--no-trust)
if [[ -n "${MACCHANNEL_TURN_EXTERNAL_IP:-}" ]]; then
  stack_arguments+=(--turn-external-ip "${MACCHANNEL_TURN_EXTERNAL_IP}")
fi
"${repository_root}/Scripts/run-local-stack.sh" "${stack_arguments[@]}"
stack_started=true

local_ca="${state_root}/tls/local-ca.pem"

(
  cd "${repository_root}"
  swift test --no-parallel --skip TransferIntegrationTests
)
(
  cd "${repository_root}/Services/rendezvous"
  env -u MACCHANNEL_COMPOSE_PROJECT_NAME -u COMPOSE_PROJECT_NAME go test -race ./...
  env -u MACCHANNEL_COMPOSE_PROJECT_NAME -u COMPOSE_PROJECT_NAME go vet ./...
)

e2e_output="$(mktemp "${TMPDIR:-/tmp}/macchannel-stack-e2e.XXXXXX")"
temporary_files+=("${e2e_output}")
(
  cd "${repository_root}"
  MACCHANNEL_E2E_STACK=1 \
    MACCHANNEL_E2E_STACK_ORIGIN=https://localhost:8443 \
    MACCHANNEL_E2E_CA_FILE="${local_ca}" \
    swift test --no-parallel --filter TransferIntegrationTests
) | tee "${e2e_output}"

grep -F "direct-lan PASS" "${e2e_output}" >/dev/null
grep -F "internet-stun PASS" "${e2e_output}" >/dev/null
grep -F "relay PASS" "${e2e_output}" >/dev/null
grep -F "resume PASS" "${e2e_output}" >/dev/null
rm -f "${e2e_output}"
echo "完整 E2E PASS：direct-lan、Internet ICE、forced relay、resume 与 SHA-256 证据均已验证。"
