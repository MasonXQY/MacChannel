#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
runner="$root/Scripts/run-local-stack.sh"
migration="$root/Services/migrations/006_pairing_rejection.sql"
bilateral_migration="$root/Services/migrations/007_bilateral_pairing.sql"

test -f "$migration"
rg -q 'ADD COLUMN IF NOT EXISTS authorization_rejected_at' "$migration"
rg -q '006_pairing_rejection\.sql' "$runner"
rg -q '007_bilateral_pairing\.sql' "$runner"
rg -q 'encrypted_peer_authorization' "$bilateral_migration"
rg -q 'ON_ERROR_STOP=1' "$runner"

echo "local stack migration contract PASS"
