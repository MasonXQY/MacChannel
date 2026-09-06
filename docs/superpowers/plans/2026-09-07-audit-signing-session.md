# Audit Signing Session Implementation Plan

> **For agentic workers:** Use executing-plans under the approved Engineering
> Working Agreement. Keep implementation local and obtain an independent review.

**Goal:** Enforce immutable, one-use, expiring signing review before native-key integration.
**Architecture:** A bounded locked Swift session; CryptoKit verifies all backend
results. A separate executable tests the session with fixed in-memory test keys.
**Tech Stack:** Swift, Foundation, CryptoKit; no new dependencies.

## Global constraints

- No app integration, key provisioning/lookup, production access or gate changes.
- Nonempty manifest at most 65536 bytes; 65-byte uncompressed P-256 public point.
- Lifetime 300 seconds monotonic; failures never return raw backend error text.
- Matching review digest is not proof of actual user presence or semantic audit.

### Task 1: Session and negative tests

Files: Tools/AuditOwnerPreflight/SigningSession.swift and SigningSessionTests.swift.
Interface: throwing initializer `init(manifest: Data, publicPoint: Data,
clock: @escaping () -> TimeInterval)` (default system uptime); `reviewDigest:
String`; `cancel()`; `sign(approvedDigest: String, backend: (Data) throws -> Data)
throws -> Data`. `AuditSigningFailure` fixed error cases.

- [x] Compile failing tests against a fail-closed session scaffold; confirm valid
  round trip fails because signing is unavailable, not a compiler error.
- [x] Freeze and validate input, compute digest with CryptoKit SHA256, implement
  lock-protected state transition and 300-second checks.
- [x] Use `P256.Signing.ECDSASignature(derRepresentation:)` and
  `P256.Signing.PublicKey(x963Representation:)` to verify exact returned bytes.
- [x] Run all acceptance cases in the spec; test genuine signatures with fixed
  synthetic software keys only, plus cancellation and replay callbacks.

### Task 2: Integration and review

Files: Scripts/test-audit-owner-preflight.sh, Tools/AuditOwnerPreflight/README.md,
HANDOFF.md.

- [x] Add separate session test compile/run; keep NativeMain compile unchanged.
- [x] Run native preflight and serial scanner/runtime-block contracts; inspect
  app/production diff and independent review. Record exact evidence/limitations.
