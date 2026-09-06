#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"
tool_root=Tools/AuditOwnerPreflight
build_root=.build/audit-owner-preflight-check
mkdir -p "$build_root"

# Deliberate review tripwire, not a cryptographic trust policy: this tiny adapter
# must remain capability-only. Re-review every native API before updating it.
adapter_digest="$(shasum -a 256 "$tool_root/NativeMain.swift" | awk '{print $1}')"
[[ "$adapter_digest" == 1bc9f8de1114d37f445c5ee5b68a52a966ab56ac3886445ed5692563a8a36462 ]] || {
    echo 'audit preflight native adapter requires read-only review' >&2
    exit 1
}
xcrun swiftc -warnings-as-errors "$tool_root/Preflight.swift" "$tool_root/Tests.swift" -o "$build_root/tests"
"$build_root/tests"
xcrun swiftc -warnings-as-errors "$tool_root/SigningSession.swift" "$tool_root/SigningSessionTests.swift" -o "$build_root/signing-session-tests"
"$build_root/signing-session-tests"
xcrun swiftc -warnings-as-errors "$tool_root/Preflight.swift" "$tool_root/NativeMain.swift" -o "$build_root/audit-owner-preflight"

assert_usage() {
    local actual_status=0
    "$build_root/audit-owner-preflight" "$@" > "$build_root/result" 2>&1 || actual_status=$?
    [[ "$actual_status" -eq 2 ]]
    [[ "$(< "$build_root/result")" == 'AUDIT_PREFLIGHT_BLOCKED:usage' ]]
    [[ "$(wc -l < "$build_root/result" | tr -d ' ')" == 1 ]]
}
assert_usage
assert_usage enroll
assert_usage sign
assert_usage production
assert_usage preflight SENSITIVE_SENTINEL

actual_status=0
"$build_root/audit-owner-preflight" preflight > "$build_root/result" 2>&1 || actual_status=$?
[[ "$(wc -l < "$build_root/result" | tr -d ' ')" == 1 ]]
case "$actual_status:$(< "$build_root/result")" in
    0:AUDIT_PREFLIGHT_CAPABLE_NOT_ENROLLED) echo 'AUDIT_PREFLIGHT_CAPABLE_NOT_ENROLLED' ;;
    2:AUDIT_PREFLIGHT_BLOCKED:secure-enclave) echo 'AUDIT_PREFLIGHT_BLOCKED:secure-enclave' ;;
    2:AUDIT_PREFLIGHT_BLOCKED:owner-authentication) echo 'AUDIT_PREFLIGHT_BLOCKED:owner-authentication' ;;
    *) echo 'audit preflight native contract FAIL' >&2; exit 1 ;;
esac
bash Scripts/check-sensitive-logging.sh
bash Scripts/test-privacy-runtime-block.sh
echo 'audit preflight contract PASS (capability only; no enrollment or release approval)'
