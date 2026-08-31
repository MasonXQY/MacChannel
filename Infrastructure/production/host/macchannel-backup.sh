#!/usr/bin/env bash
set -euo pipefail

umask 077
backup_root=/var/backups/macchannel
production_root=/opt/macchannel/Infrastructure/production
environment_file=/etc/macchannel/production.env
mkdir -p "${backup_root}"

set -a
source "${environment_file}"
set +a

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
temporary_path="${backup_root}/.${timestamp}.sql.gz.partial"
final_path="${backup_root}/${timestamp}.sql.gz"
trap 'rm -f "${temporary_path}"' EXIT

cd "${production_root}"
docker compose -f docker-compose.yml -f docker-compose.single-host.yml \
  exec -T postgres pg_dump \
    --username "${MACCHANNEL_POSTGRES_USER}" \
    --dbname "${MACCHANNEL_POSTGRES_DB}" \
    --format plain --no-owner --no-privileges \
  | gzip -9 > "${temporary_path}"
test -s "${temporary_path}"
gzip -t "${temporary_path}"
mv "${temporary_path}" "${final_path}"
find "${backup_root}" -type f -name '*.sql.gz' -mtime +7 -delete
trap - EXIT
