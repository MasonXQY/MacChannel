# Multi-Mac Membership Sync Implementation Plan

**Goal:** Pair a new Mac once with any trusted Mac, then make the complete trusted-device set converge across online and temporarily offline Macs without trusting the rendezvous service.

**Architecture:** Persist a signed, hash-linked membership event log beside the existing trust snapshot. A trusted member signs additions and removals; each client verifies issuer trust, key binding, parent digest, limits, and replay rules before changing `TrustRepository`. The rendezvous service stores opaque signed envelopes and monotonically addressed delivery cursors only.

## Task 1: Membership event domain and verifier

- Add canonical `MembershipEvent` and `SignedMembershipEvent` encodings with group ID, event ID, issuer, subject, subject public key, action, parent digest, timestamp, and signature.
- RED tests: valid add/remove, tampering, wrong key, untrusted issuer, duplicate idempotency, device/key conflict, missing parent quarantine, removed issuer rejection, bounded sizes.
- Implement verification without network or persistence dependencies.
- Gate: focused Swift tests pass and fixed canonical vectors remain stable.

## Task 2: Durable client log and v1.0.1 migration

- Add an authenticated atomic membership-log store with ordered applied events and quarantined out-of-order events.
- Convert existing bilateral `SignedTrustRecord` entries into deterministic bootstrap events without rotating identity or deleting trust.
- Apply events to `TrustRepository` only after durable commit; removal invalidates active eligibility immediately.
- RED tests: restart, truncated/corrupt file, duplicate delivery, out-of-order catch-up, conflict isolation, removal and re-pair.

## Task 3: Rendezvous opaque mailbox

- Add PostgreSQL migration and memory/PostgreSQL stores for opaque membership envelopes and per-device cursors.
- Add authenticated publish/fetch/ack endpoints; the service validates size, participant identity, limits and TTL but never makes trust decisions.
- RED Go tests: participant binding, pagination, idempotency, offline catch-up, expired delivery, abuse limits, no sensitive logging.
- Update wire documentation and Swift HTTP client with cross-language fixtures.

## Task 4: Pairing and runtime integration

- On host approval, sign and publish the new-member event together with the existing bilateral authorization.
- Give the new Mac the verified existing event chain; existing Macs catch up after reconnect.
- Feed membership updates into `DeviceDirectory`, settings, and active connection authorization.
- Gate: a three-client harness pairs A-B, adds C through B, proves A-C trust, removes C while A is offline, then proves convergence after A reconnects.

## Task 5: Full gate

- Run Swift full tests, Go race/vet, cross-language interop, privacy audit, and three-client integration.
- Commit only with zero failures and no server persistence of filenames, paths, content, or private keys.
