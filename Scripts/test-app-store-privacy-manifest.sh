#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="$repository_root/App/Resources/PrivacyInfo.xcprivacy"
audit="$repository_root/docs/security/app-store-privacy-audit.md"

[[ -f "$manifest" ]] || { echo "privacy manifest contract FAIL: missing app manifest" >&2; exit 1; }
[[ -f "$audit" ]] || { echo "privacy manifest contract FAIL: missing App Store privacy audit" >&2; exit 1; }
plutil -lint "$manifest" >/dev/null

python3 - "$manifest" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    manifest = plistlib.load(handle)

def fail(message):
    raise SystemExit(f"privacy manifest contract FAIL: {message}")

if manifest.get("NSPrivacyTracking") is not False:
    fail("NSPrivacyTracking must be false")
if manifest.get("NSPrivacyTrackingDomains") != []:
    fail("NSPrivacyTrackingDomains must be an empty array")

collected = manifest.get("NSPrivacyCollectedDataTypes")
if not isinstance(collected, list):
    fail("NSPrivacyCollectedDataTypes must be an array")
expected = {
    "NSPrivacyCollectedDataType": "NSPrivacyCollectedDataTypeDeviceID",
    "NSPrivacyCollectedDataTypeLinked": True,
    "NSPrivacyCollectedDataTypeTracking": False,
    "NSPrivacyCollectedDataTypePurposes": ["NSPrivacyCollectedDataTypePurposeAppFunctionality"],
}
if collected != [expected]:
    fail("only the reviewed Device ID / App Functionality disclosure is allowed")

# Required-reason declarations must come from the final signed archive privacy
# report. Until that evidence exists, an app-level guessed category/reason is a
# more dangerous result than an explicit release blocker.
if "NSPrivacyAccessedAPITypes" in manifest:
    fail("app required-reason API declarations are unreviewed before the final archive report")
PY

grep -F '| WebRTC framework |' "$audit" >/dev/null || {
    echo "privacy manifest contract FAIL: missing WebRTC framework manifest inventory" >&2
    exit 1
}
grep -F 'FINAL SIGNED ARCHIVE PRIVACY REPORT: BLOCKED' "$audit" >/dev/null || {
    echo "privacy manifest contract FAIL: final archive evidence must remain BLOCKED" >&2
    exit 1
}

echo "App Store privacy manifest contract PASS (draft disclosure; archive reasons blocked)"
