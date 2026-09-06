#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

for command_name in plutil python3 rg; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "App Store privacy audit BLOCKED: missing $command_name" >&2
        exit 2
    }
done

Scripts/test-app-store-privacy-manifest.sh >/dev/null
Scripts/check-sensitive-logging.sh >/dev/null
Scripts/audit-privacy.sh --static-only >/dev/null

for evidence_marker in \
    'PRODUCTION PRIVACY EVIDENCE: BLOCKED' \
    'FINAL SIGNED ARCHIVE PRIVACY REPORT: BLOCKED'; do
    rg -Fq "$evidence_marker" docs/security/app-store-privacy-audit.md || {
        echo "App Store privacy audit FAIL: evidence status is missing" >&2
        exit 1
    }
done
rg -Fq 'APP STORE CONNECT ANSWERS: DRAFT / BLOCKED' docs/security/app-store-connect-privacy.md
rg -Fq 'EXPORT COMPLIANCE DECISION: BLOCKED' docs/security/app-store-export-compliance.md

echo "App Store privacy audit BLOCKED: draft manifest is valid, but final archive, production runtime, App Store Connect, and export evidence are missing" >&2
exit 2
