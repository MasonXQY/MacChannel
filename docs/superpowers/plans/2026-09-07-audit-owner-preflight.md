# Audit Owner Preflight Implementation Plan

> **For agentic workers:** Use executing-plans for this bounded slice under the
> Engineering Working Agreement; no new agent or repeated scope approval needed.

**Goal:** Check the owner's Mac for audit signing prerequisites without keys,
prompts, production access or app changes.

**Architecture:** Pure command decision logic accepts two capability closures;
a minimal native adapter probes CryptoKit and LocalAuthentication. Compile a
standalone binary using the existing Xcode toolchain, separate from app targets.

**Tech Stack:** Swift, CryptoKit, LocalAuthentication, shell contract tests.

## Global Constraints

- Sole accepted command is `preflight`; fixed lines and statuses in the spec.
- No keys, Keychain access, authentication prompts, input files or network.
- Preflight success is not enrollment, signing verification or release approval.
- Preserve existing fixture verifier, app targets and production gates.

### Task 1: Tested command and native adapter

Files: Tools/AuditOwnerPreflight/{Preflight.swift,NativeMain.swift,Tests.swift}.
Interface: `AuditPreflight.run(_ args: [String], enclave: () -> Bool,
ownerAuthentication: () -> Bool) -> PreflightResult`; result fields `status: Int32`
and `line: String`. Tests compile without NativeMain; the binary excludes Tests.

- [x] Write executable assertions for each capability combination and rejection
  of empty, extra, unknown, sign/enroll/production and sensitive sentinel args.
  Count probe calls to prove invalid requests do not reach native operations.
- [x] Compile/run the tests against a blocked-only scaffold; observe the
  successful-capability assertion fail, not an unrelated compiler error.
- [x] Implement early argument check, then hardware check, then authentication
  check, returning exactly the spec lines. Native adapter uses:
  `SecureEnclave.isAvailable`; create `LAContext`, defer `invalidate()`, then
  `canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)`.
- [x] Run tests with `xcrun swiftc` and invoke real binary `preflight` plus invalid
  commands. Verify fixed outputs, exit status and no authentication prompt.

### Task 2: Safety regression and handoff

Files: Scripts/test-audit-owner-preflight.sh; Tools/AuditOwnerPreflight/README.md;
Scripts/check-sensitive-logging.sh; HANDOFF.md.

- [x] Add reproducible build/tests and strict native-source allowlist contract
  so unexpected key creation, I/O or authentication APIs require explicit review.
- [x] Include new Swift tool in default sensitive logging scan; do not suppress
  sensitive output. Run scanner mutation and existing runtime-block contracts.
- [x] Inspect scoped diff and actual preflight result, document limitations and
  remaining signer/collector acceptance. Keep existing branch, no install/push.
