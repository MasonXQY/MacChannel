# Account credential primitives — final local verification

## Completed scope

Plan `db22597`, isolation branch `feature/dropmesh-accounts` in the existing
DropMesh iPhone worktree. Prior dirty release/client files preserved.

1. Apple developer client-secret provider: implementation `c60abb2`, corrective
   wall-clock comparison `c9567aa`. Dedicated in-memory PKCS8 configuration,
   short-lived ES256 JWT, configured audience binding, no real key access.
2. Apple refresh-credential protection: implementation `2e2226d`, precise
   pre-decryption size bound `17588dd`. Standard AES-256 random-nonce GCM,
   record-bound authenticated data and bounded rotation keys.

## Review findings and fixes

Task 1 independent review found one Important issue: Go's monotonic timestamp
comparison would miss a wall-clock rollback. `Round(0)` removes monotonic
metadata while retaining nanoseconds. Real-time fixture regression failed before
the change and passed after it. Final independent review Approved, no findings.

Task 2 review approved with one Minor suggestion: tighten the envelope bound for
short key IDs before decryption. Implemented and tested using real authenticated
oversized ciphertext plus a counting wrapper around real AEAD. RED proved it
previously reached decryption, GREEN proves pre-decryption rejection. Independent
follow-up at `17588dd`: spec and quality Approved, no findings remaining.

Root additionally checked code and final diffs. Reused binding helpers are pure
validation; there is no SQL/network access through that reuse. Crypto remains
standard-library code, not a custom encryption algorithm. No existing service
implementation file or migration changed during these two tasks.

## Fresh verification

- Starting accountauth baseline PASS14.476s.
- Root signer/integration scoped race at initial signer revision PASS2.503s.
- Implementer corrected signer scoped race PASS1.785s; full default Go suite
  passed before the one-line clock correction.
- Implementer protector final full default `go test ./... -count=1` PASS;
  accountauth13.710s. Existing SQL opt-in tests not exercised by default.
- Root combined accountauth race at `2e2226d`: PASS19.833s.
- Root FINAL `go test -race ./internal/accountauth -count=1` at `17588dd`:
  PASS20.265s. This includes both final components and existing accountauth tests.
- `git diff --check`: exit0; scoped service status clean after commits.
- Submitted iOS1.0(8) IPA freshly rehashed, unchanged:
  `436ae5d4e20db6b14539d5a6e53e2f62ad9d21a19d1f52fb5d2a87d3698f0ab9`.
- No accountauth import in service router/startup. No phone install, portal
  capability change, real-credential read, production request or deployment.

## Remaining work

This is locally verified credential handling, NOT live Apple login or encrypted
database persistence. Implement protected credential storage and revocable
device-bound sessions next, including refresh-reuse detection, deletion/revocation
and restart tests. Then integrate signed HTTP operations and native UI/capabilities.
Before production, establish key custody, rotation/use limits and rollback-safe
record/session state. Neither the encrypted record nor Apple identity grants
device trust. See the approved design and account-credential-integration-boundaries.

The entire account branch remains unfinished and unmerged; whole-program review
and physical cross-device acceptance remain required before release.
