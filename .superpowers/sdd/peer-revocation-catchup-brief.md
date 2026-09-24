# Corrective task: peer revocation catch-up

Read `docs/superpowers/plans/2026-09-13-peer-revocation-catchup.md` completely; it is the binding scope and constraints. Read `.superpowers/sdd/shared-owner-live-interop-report.md` for the real three-run reproduction, commit `a03ef7c`.

The live gate already proves identity-only authentication, withholding unsaved proofs, real receipt publication/ACKs, fresh bilateral presence and both signal payloads. Its first-side post-revoke forbidden passes; the revoked subject disconnects while ingesting the received revoke because generic TrustStore.apply refuses subject==owner before validating it.

Do not weaken the live test or suppress arbitrary errors. Resolve the legitimate signed peer-withdrawal event separately from local owner identity revocation, preserving all existing key/protocol/anti-replay boundaries and unrelated peer trust. Use focused behavioral tests and actual live loopback RED/GREEN. No physical or production operations.

Full report path: `.superpowers/sdd/peer-revocation-catchup-report.md`. Controller owns HANDOFF, ledger and acceptance documents. Keep full report in the file; return concise status, commit(s), commands/results summary and concerns.
