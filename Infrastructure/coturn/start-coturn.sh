#!/bin/sh
set -eu

secret_file=/run/coturn/secrets/turn-shared-secret
runtime_config=/run/coturn/turnserver.conf

if [ ! -r "$secret_file" ]; then
  echo "coturn: TURN shared-secret file is unavailable" >&2
  exit 1
fi

secret=$(tr -d '\r\n' < "$secret_file")
if [ "${#secret}" -lt 32 ] || printf '%s' "$secret" | grep -q '[^A-Za-z0-9_+/=-]'; then
  echo "coturn: TURN shared secret is malformed" >&2
  exit 1
fi

if ! printf '%s\n' "${TURN_EXTERNAL_IP:-}" | awk -F. '
  NF == 4 && $1 != 0 && $1 != 127 {
    for (i = 1; i <= 4; i++) if ($i !~ /^[0-9]+$/ || $i > 255) exit 1
    exit 0
  }
  { exit 1 }
'; then
  echo "coturn: TURN_EXTERNAL_IP must be a non-loopback IPv4 address" >&2
  exit 1
fi

container_ip=
for candidate in $(hostname -i); do
  case "$candidate" in
    127.*|0.*|*:*|'') ;;
    *) container_ip=$candidate; break ;;
  esac
done
if [ -z "$container_ip" ]; then
  echo "coturn: no private container IPv4 address is available" >&2
  exit 1
fi

umask 077
cp /etc/coturn/turnserver.conf "$runtime_config"
printf '\nstatic-auth-secret=%s\nexternal-ip=%s/%s\n' "$secret" "$TURN_EXTERNAL_IP" "$container_ip" >> "$runtime_config"
exec turnserver -c "$runtime_config"
