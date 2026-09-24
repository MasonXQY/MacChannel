# iPhone authentication recovery — 2026-09-13

## Scope and result

iPhone development app 0.1.0 (4) installed in place. Existing device identity,
pairing proofs and receive data preserved. Physical cold launch and rapid
relaunch both produced `authentication_failed`, then a fresh challenge,
`accepted`, and `peer_online`. No subsequent stream failure was observed during
the respective bounded 45/55-second captures. The final ordinary launch succeeded.
This verifies service/presence recovery, not a new physical file-transfer or
iCloud Files-picker acceptance run, nor availability of every paired device.

## Evidence and findings

- Phone reached the production service on both reported network types; server
  returned authentication rejection, not a general connectivity failure.
- Production read-only aggregate check: 54 established/mutually confirmed pairs;
  no expired or overdue pending pair rows; all stored hashes match the signed
  canonical records. Two of 49 issuers have durable high-water above surviving
  pair sequences. No raw proofs, identities or credentials were printed.
- An isolated synthetic PostgreSQL test reproduced exact expired-proof replay
  being accepted by restored memory validation but rejected by durable high-water.
  The individual phone proof was not extracted, so exact attribution remains
  narrower than these aggregate findings.
- Live graph catch-up exported unrelated third-party proofs; the existing
  restore-consistency predicate now also filters authentication export.
- Mobile retries an explicitly rejected nonempty proof batch using existing
  identity-only wire authentication on a fresh socket/challenge. Signed identity
  verification and all server peer authorization checks remain unchanged.
- Current eligible proofs are submitted individually after recovery, preserving
  order, revocations and later pairings without a stale proof poisoning a batch.
- Physical build 3 exposed transient capacity rejection consuming recovery.
  Build 4 preserves recovery through explicit capacity and transport failures;
  explicit identity rejection still disables it, without resetting its budget.

## Verification

- Root Swift selection: 147 tests, zero failures, including identity, directory,
  recovery, supervisor, foreground runtime, and proof persistence checks.
  Log: `.build/iphone-recovery-root-build4-tests.log`.
- Root `go test ./internal/httpapi ./internal/auth -race -count=1` passed.
  Real WebSocket tests verify invalid identity/nonce/signature rejection,
  unchanged trust state after empty authentication, established-peer routing,
  and forbidden routing to revoked or unknown peers.
- Root independently reran the synthetic PostgreSQL reproducer with race checks.
  The isolated local PostgreSQL process was stopped afterward.
- TDD failures and fixes retained in `.build/trust-auth-export-*`,
  `.build/mobile-identity-recovery-*`, and `.build/mobile-identity-transient-*`.
- Signed device build, embedded-extension validation and strict deep codesign
  verification succeeded. Logs: `.build/iphone-recovery-build4.log`,
  `.build/iphone-recovery-install4.json`, and
  `.build/iphone-recovery-final-launch4.json`.
- Bounded console commands intentionally end by timeout; the timeout is not
  authentication failure or success evidence. Only preceding coarse events are.

## Preserved boundaries

No server authentication behavior/schema/data changes in this turn. Previously
authorized diagnostic server image remains deployed; rollback reference and
one-shot image override caveat remain in HANDOFF.md. Temporary SSH source was
removed and verified fully applied. No Mac binary replacement, Store upload,
Direct replacement, or Mac B control. Only the existing local Store process was
restarted; absence of an app-owned TLS socket alone does not prove it offline.
