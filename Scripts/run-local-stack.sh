#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
infrastructure_root="$repository_root/Infrastructure"
secret_root="$infrastructure_root/.local-secrets"
tls_root="$secret_root/tls"
compose_file="$infrastructure_root/docker-compose.yml"
prepare_only=false
install_trust=true

for argument in "$@"; do
  case "$argument" in
    --prepare-only) prepare_only=true ;;
    --no-trust) install_trust=false ;;
    *) echo "用法: $0 [--prepare-only] [--no-trust]" >&2; exit 2 ;;
  esac
done

for command_name in openssl curl; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "缺少必需命令：$command_name" >&2
    exit 1
  fi
done
if [[ "$prepare_only" == false ]]; then
  if ! command -v docker >/dev/null 2>&1; then
    echo "未安装 Docker，无法启动本地 Postgres、rendezvous 和 coturn。" >&2
    exit 1
  fi
  if ! docker compose version >/dev/null 2>&1; then
    echo "Docker Compose v2 不可用。" >&2
    exit 1
  fi
fi

umask 077
mkdir -p "$tls_root"
chmod 700 "$secret_root" "$tls_root"

if [[ ! -s "$secret_root/postgres-password" ]]; then
  openssl rand -base64 36 | tr -d '\n' > "$secret_root/postgres-password"
fi
if [[ ! -s "$secret_root/turn-shared-secret" ]]; then
  openssl rand -base64 48 | tr -d '\n' > "$secret_root/turn-shared-secret"
fi
chmod 600 "$secret_root/postgres-password" "$secret_root/turn-shared-secret"

if [[ ! -s "$tls_root/local-ca-key.pem" || ! -s "$tls_root/local-ca.pem" ]]; then
  openssl req -x509 -newkey rsa:3072 -sha256 -nodes \
    -keyout "$tls_root/local-ca-key.pem" \
    -out "$tls_root/local-ca.pem" \
    -days 3650 \
    -subj "/CN=MacChannel Local Development Root/O=MacChannel Local"
fi

if [[ ! -s "$tls_root/localhost-key.pem" || ! -s "$tls_root/localhost.pem" ]] || \
  ! openssl x509 -checkend 2592000 -noout -in "$tls_root/localhost.pem" >/dev/null 2>&1; then
  openssl req -newkey rsa:3072 -sha256 -nodes \
    -keyout "$tls_root/localhost-key.pem" \
    -out "$tls_root/localhost.csr" \
    -subj "/CN=localhost/O=MacChannel Local"
  openssl x509 -req -sha256 \
    -in "$tls_root/localhost.csr" \
    -CA "$tls_root/local-ca.pem" \
    -CAkey "$tls_root/local-ca-key.pem" \
    -CAcreateserial \
    -out "$tls_root/localhost.pem" \
    -days 397 \
    -extfile <(printf '%s\n' \
      'basicConstraints=critical,CA:FALSE' \
      'keyUsage=critical,digitalSignature,keyEncipherment' \
      'extendedKeyUsage=serverAuth' \
      'subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1')
  rm -f "$tls_root/localhost.csr" "$tls_root/local-ca.srl"
fi
chmod 600 "$tls_root/local-ca-key.pem" "$tls_root/localhost-key.pem"
chmod 644 "$tls_root/local-ca.pem" "$tls_root/localhost.pem"

openssl verify -CAfile "$tls_root/local-ca.pem" -verify_hostname localhost "$tls_root/localhost.pem" >/dev/null
certificate_public_key="$(openssl x509 -in "$tls_root/localhost.pem" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | openssl sha256)"
private_public_key="$(openssl pkey -in "$tls_root/localhost-key.pem" -pubout -outform DER 2>/dev/null | openssl sha256)"
if [[ "$certificate_public_key" != "$private_public_key" ]]; then
  echo "localhost TLS 证书与私钥不匹配。" >&2
  exit 1
fi

if [[ "$install_trust" == true ]]; then
  if [[ "$(uname -s)" != Darwin ]]; then
    echo "当前系统不是 macOS；请手动信任 $tls_root/local-ca.pem 后再连接。" >&2
    exit 1
  fi
  if ! command -v security >/dev/null 2>&1; then
    echo "缺少 macOS security 命令，无法让默认 wss://localhost:8443 通过系统信任校验。" >&2
    exit 1
  fi
  login_keychain="$(security default-keychain -d user | tr -d ' "')"
  if ! security verify-cert -c "$tls_root/localhost.pem" -p ssl -n localhost -L -q >/dev/null 2>&1; then
    echo "正在把仅用于本地开发的 MacChannel CA 加入当前用户钥匙串；macOS 可能要求确认。"
    security add-trusted-cert -r trustRoot -p ssl -s localhost -k "$login_keychain" "$tls_root/local-ca.pem"
  fi
fi

if [[ "$prepare_only" == true ]]; then
  echo "本地密钥与 localhost TLS 证书已准备并验证。"
  exit 0
fi

docker compose -f "$compose_file" up -d --build --wait
curl --fail --silent --show-error http://localhost:8080/healthz >/dev/null
curl --fail --silent --show-error --cacert "$tls_root/local-ca.pem" https://localhost:8443/healthz >/dev/null
docker compose -f "$compose_file" exec -T coturn sh -ec '
  secret=$(cat /run/secrets/turn_shared_secret)
  turnutils_uclient -u stack-health -W "$secret" -y -c -n 1 127.0.0.1 >/dev/null
  turnutils_uclient -t -S -E /run/secrets/local_ca_cert -p 5349 -u stack-health -W "$secret" -y -c -n 1 127.0.0.1 >/dev/null
'
docker compose -f "$compose_file" ps
echo "本地服务与 TURN REST 共享密钥已实测就绪：wss://localhost:8443/v1/ws，STUN/TURN localhost:3478，TURN TLS localhost:5349。"
