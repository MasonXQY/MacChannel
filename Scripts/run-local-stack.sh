#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
infrastructure_root="${repository_root}/Infrastructure"
secret_root="${MACCHANNEL_LOCAL_STATE_ROOT:-${infrastructure_root}/.local-secrets}"
tls_root="${secret_root}/tls"
compose_file="${infrastructure_root}/docker-compose.yml"
prepare_only=false
install_trust=true
turn_external_ip=
trust_added=false
stack_touched=false
stack_secret_volume_existed=true
postgres_volume_existed=true
completed=false
login_keychain=
certificate_hash=

usage() {
  echo "用法: ${0} [--prepare-only] [--no-trust] [--turn-external-ip IPv4]" >&2
}

while [[ ${#} -gt 0 ]]; do
  case "${1}" in
    --prepare-only) prepare_only=true; shift ;;
    --no-trust) install_trust=false; shift ;;
    --turn-external-ip)
      if [[ ${#} -lt 2 ]]; then usage; exit 2; fi
      turn_external_ip="${2}"
      shift 2
      ;;
    *) usage; exit 2 ;;
  esac
done

rollback() {
  local original_code="${1}"
  trap - EXIT INT TERM
  if [[ "${completed}" == false && "${original_code}" -ne 0 ]]; then
    set +e
    if [[ "${stack_touched}" == true ]]; then
      TURN_EXTERNAL_IP="${turn_external_ip:-127.0.0.1}" \
        docker compose -f "${compose_file}" down --remove-orphans >/dev/null 2>&1
      if [[ "${stack_secret_volume_existed}" == false ]]; then
        docker volume rm macchannel-local_stack_secrets >/dev/null 2>&1
      fi
      if [[ "${postgres_volume_existed}" == false ]]; then
        docker volume rm macchannel-local_postgres_data >/dev/null 2>&1
      fi
    fi
    if [[ "${trust_added}" == true ]]; then
      security delete-certificate -Z "${certificate_hash}" -t "${login_keychain}" >/dev/null 2>&1
    fi
    echo "启动失败；本次新增的钥匙串信任和 Compose 状态已回滚。" >&2
  fi
  exit "${original_code}"
}
trap 'saved_exit_code=${?}; rollback "${saved_exit_code}"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

is_valid_external_ipv4() {
  printf '%s\n' "${1}" | awk -F. '
    NF == 4 && $1 != 0 && $1 != 127 {
      for (i = 1; i <= 4; i++) if ($i !~ /^[0-9]+$/ || $i > 255) exit 1
      exit 0
    }
    { exit 1 }
  '
}

validate_exported_material() {
  chmod 600 "${secret_root}/turn-shared-secret" "${tls_root}/localhost-key.pem"
  chmod 644 "${tls_root}/local-ca.pem" "${tls_root}/localhost.pem"
  openssl verify -CAfile "${tls_root}/local-ca.pem" -verify_hostname localhost "${tls_root}/localhost.pem" >/dev/null
  local certificate_public_key
  local private_public_key
  certificate_public_key="$(openssl x509 -in "${tls_root}/localhost.pem" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | openssl sha256)"
  private_public_key="$(openssl pkey -in "${tls_root}/localhost-key.pem" -pubout -outform DER 2>/dev/null | openssl sha256)"
  if [[ "${certificate_public_key}" != "${private_public_key}" ]]; then
    echo "localhost TLS 证书与私钥不匹配。" >&2
    return 1
  fi
  if [[ ! -s "${secret_root}/turn-shared-secret" ]]; then
    echo "TURN 共享密钥导出失败。" >&2
    return 1
  fi
  local exported_turn_secret
  exported_turn_secret="$(tr -d '\r\n' < "${secret_root}/turn-shared-secret")"
  if [[ ${#exported_turn_secret} -lt 32 ]] || printf '%s' "${exported_turn_secret}" | grep -q '[^A-Za-z0-9_+/=-]'; then
    echo "TURN 共享密钥格式无效。" >&2
    return 1
  fi
}

prepare_standalone_material() {
  umask 077
  mkdir -p "${tls_root}"
  chmod 700 "${secret_root}" "${tls_root}"
  if [[ ! -s "${secret_root}/postgres-password" ]]; then
    openssl rand -base64 36 | tr -d '\n' > "${secret_root}/postgres-password"
  fi
  if [[ ! -s "${secret_root}/turn-shared-secret" ]]; then
    openssl rand -base64 48 | tr -d '\n' > "${secret_root}/turn-shared-secret"
  fi
  chmod 600 "${secret_root}/postgres-password" "${secret_root}/turn-shared-secret"
  if [[ ! -s "${tls_root}/local-ca-key.pem" || ! -s "${tls_root}/local-ca.pem" ]]; then
    openssl req -x509 -newkey rsa:3072 -sha256 -nodes \
      -keyout "${tls_root}/local-ca-key.pem" \
      -out "${tls_root}/local-ca.pem" \
      -days 3650 \
      -subj "/CN=MacChannel Local Development Root/O=MacChannel Local"
  fi
  if [[ ! -s "${tls_root}/localhost-key.pem" || ! -s "${tls_root}/localhost.pem" ]] || \
    ! openssl x509 -checkend 2592000 -noout -in "${tls_root}/localhost.pem" >/dev/null 2>&1; then
    openssl req -newkey rsa:3072 -sha256 -nodes \
      -keyout "${tls_root}/localhost-key.pem" \
      -out "${tls_root}/localhost.csr" \
      -subj "/CN=localhost/O=MacChannel Local"
    openssl x509 -req -sha256 \
      -in "${tls_root}/localhost.csr" \
      -CA "${tls_root}/local-ca.pem" \
      -CAkey "${tls_root}/local-ca-key.pem" \
      -CAcreateserial \
      -out "${tls_root}/localhost.pem" \
      -days 397 \
      -extfile <(printf '%s\n' \
        'basicConstraints=critical,CA:FALSE' \
        'keyUsage=critical,digitalSignature,keyEncipherment' \
        'extendedKeyUsage=serverAuth' \
        'subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1')
    rm -f "${tls_root}/localhost.csr" "${tls_root}/local-ca.srl"
  fi
  chmod 600 "${tls_root}/local-ca-key.pem" "${tls_root}/localhost-key.pem"
  validate_exported_material
}

install_local_trust_if_needed() {
  if [[ "${install_trust}" != true ]]; then
    return
  fi
  if [[ "$(uname -s)" != Darwin ]]; then
    echo "当前系统不是 macOS；请手动信任 ${tls_root}/local-ca.pem 后再连接。" >&2
    return 1
  fi
  if ! command -v security >/dev/null 2>&1; then
    echo "缺少 macOS security 命令，无法让默认 wss://localhost:8443 通过系统信任校验。" >&2
    return 1
  fi
  login_keychain="$(security default-keychain -d user | tr -d ' \"')"
  if ! security verify-cert -c "${tls_root}/localhost.pem" -p ssl -n localhost -L -q >/dev/null 2>&1; then
    echo "正在把仅用于本地开发的 MacChannel CA 加入当前用户钥匙串；macOS 可能要求确认。"
    certificate_hash="$(openssl x509 -in "${tls_root}/local-ca.pem" -fingerprint -sha1 -noout | awk -F= '{gsub(":", "", $2); print $2}')"
    security add-trusted-cert -r trustRoot -p ssl -s localhost -k "${login_keychain}" "${tls_root}/local-ca.pem"
    trust_added=true
  fi
}

for command_name in openssl curl awk; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "缺少必需命令：${command_name}" >&2
    exit 1
  fi
done
if [[ "${prepare_only}" == false ]]; then
  for command_name in docker go; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
      echo "缺少必需命令：${command_name}；无法启动并验证本地服务。" >&2
      exit 1
    fi
  done
  if ! docker compose version >/dev/null 2>&1; then
    echo "Docker Compose v2 不可用。" >&2
    exit 1
  fi
  if [[ -z "${turn_external_ip}" ]]; then
    if ! command -v route >/dev/null 2>&1 || ! command -v ipconfig >/dev/null 2>&1; then
      echo "无法自动检测可达地址；请传入 --turn-external-ip IPv4。" >&2
      exit 1
    fi
    default_interface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
    turn_external_ip="$(ipconfig getifaddr "${default_interface}" 2>/dev/null || true)"
  fi
  if ! is_valid_external_ipv4 "${turn_external_ip}"; then
    echo "TURN 对外地址必须是非回环 IPv4；本机开发请传入局域网地址，部署时传入宿主机可达地址。" >&2
    exit 1
  fi
fi

if [[ "${prepare_only}" == true ]]; then
  prepare_standalone_material
  install_local_trust_if_needed
  completed=true
  echo "本地密钥与 localhost TLS 证书已准备并验证。"
  exit 0
fi

umask 077
mkdir -p "${tls_root}"
chmod 700 "${secret_root}" "${tls_root}"
export TURN_EXTERNAL_IP="${turn_external_ip}"

if ! docker volume inspect macchannel-local_stack_secrets >/dev/null 2>&1; then
  stack_secret_volume_existed=false
fi
if ! docker volume inspect macchannel-local_postgres_data >/dev/null 2>&1; then
  postgres_volume_existed=false
fi
stack_touched=true
docker compose -f "${compose_file}" up --build --no-deps secret-init
docker compose -f "${compose_file}" cp secret-init:/stack-secrets/turn-shared-secret "${secret_root}/turn-shared-secret"
docker compose -f "${compose_file}" cp secret-init:/stack-secrets/tls/local-ca.pem "${tls_root}/local-ca.pem"
docker compose -f "${compose_file}" cp secret-init:/stack-secrets/tls/localhost.pem "${tls_root}/localhost.pem"
docker compose -f "${compose_file}" cp secret-init:/stack-secrets/tls/localhost-key.pem "${tls_root}/localhost-key.pem"
validate_exported_material
install_local_trust_if_needed

docker compose -f "${compose_file}" up -d --build --wait

# The launchers copy the root-readable named-volume files to private tmpfs,
# then replace PID 1 under an unprivileged UID with no effective capabilities.
docker compose -f "${compose_file}" exec -T rendezvous sh -ec '
  test "$(awk "/^Uid:/{print \$2}" /proc/1/status)" = 65532
  test "$(awk "/^CapEff:/{print \$2}" /proc/1/status)" = 0000000000000000
  test "$(stat -c "%u:%g:%a" /run/macchannel/turn-shared-secret)" = 65532:65532:400
'
docker compose -f "${compose_file}" exec -T coturn sh -ec '
  test "$(awk "/^Uid:/{print \$2}" /proc/1/status)" = 65534
  test "$(awk "/^CapEff:/{print \$2}" /proc/1/status)" = 0000000000000000
  test "$(stat -c "%u:%g:%a" /run/coturn/secrets/turn-shared-secret)" = 65534:65534:400
'

curl --fail --silent --show-error http://localhost:8080/healthz >/dev/null
curl --fail --silent --show-error --cacert "${tls_root}/local-ca.pem" https://localhost:8443/healthz >/dev/null
openssl s_client -connect localhost:5349 -CAfile "${tls_root}/local-ca.pem" -verify_return_error </dev/null >/dev/null 2>&1

# Host-side allocation: both the address and one-to-one published relay port
# must match the Compose contract. Task 13 adds the full peer data-plane probe.
(cd "${repository_root}/Services/rendezvous" && go run ./cmd/turn-probe \
  --server 127.0.0.1:3478 \
  --secret-file "${secret_root}/turn-shared-secret" \
  --expected-ip "${turn_external_ip}" \
  --min-port 49160 \
  --max-port 49200)

device_marker=DEVICE_ID_MUST_NEVER_APPEAR_IN_COTURN_LOGS
docker compose -f "${compose_file}" exec -T coturn sh -ec \
  "turnutils_uclient -u '${device_marker}' -w invalid-password -y -c -n 1 127.0.0.1 >/dev/null 2>&1 || true"
# logs coturn: explicit authentication-error-path disclosure contract.
if docker compose -f "${compose_file}" logs coturn 2>&1 | grep -F "${device_marker}" >/dev/null; then
  echo "coturn 错误日志泄露了设备标识。" >&2
  exit 1
fi

docker compose -f "${compose_file}" ps
completed=true
echo "本地服务已验证：wss://localhost:8443/v1/ws；TURN XOR-RELAYED-ADDRESS 为 ${turn_external_ip}:49160-49200。"
