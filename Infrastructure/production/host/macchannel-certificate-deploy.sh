#!/usr/bin/env bash
set -euo pipefail

source_root=/etc/letsencrypt/live/channel.zensys-tech.com
destination_root=/etc/macchannel/secrets/tls
install -d -m 0700 "${destination_root}"
install -m 0600 "${source_root}/fullchain.pem" "${destination_root}/localhost.pem"
install -m 0600 "${source_root}/privkey.pem" "${destination_root}/localhost-key.pem"
systemctl try-reload-or-restart macchannel.service
