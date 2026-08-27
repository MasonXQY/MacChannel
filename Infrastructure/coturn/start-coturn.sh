#!/bin/sh
set -eu

secret_file=/run/secrets/turn_shared_secret
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

umask 077
cp /etc/coturn/turnserver.conf "$runtime_config"
printf '\nstatic-auth-secret=%s\n' "$secret" >> "$runtime_config"
exec turnserver -c "$runtime_config"
