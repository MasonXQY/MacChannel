# Identity and Trust Sync Separation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans.

**Goal:** Stop requiring a deliberately failed authentication before recovery; explicitly track trust synchronization acknowledgements independently of identity connectivity.

**Architecture:** Shared AuthenticatedPresenceSupervisor uses existing `connect(includeTrustRecords: false)`. Its single run reader continues processing catch-up, presence and trust results. A serialized single-record sync worker advances only after trust-ok/error; no request IDs or new wire messages. Missing acknowledgement retires the whole socket before another attempt, preventing late acknowledgements being attributed to new work.

**Tech Stack:** Swift 6 actors and existing Go WebSocket protocol.

## Global Constraints

- Preserve DeviceID, keys, pairing records, signatures, revocation barriers and transfer protocol.
- Successful identity authentication never grants peer routing rights; existing trust graph, local receive policy and per-transfer identity checks remain mandatory.
- One WebSocket reader and one trust-update writer per active session; no independent consumers of trustResults.
- Rejection does not delete local proofs, clear pairings, lower sequence numbers or automatically reauthorize peers.
- No production or installed-app changes in this task.

### Task 1: Shared confirmation-driven synchronizer

**Files:**
- Modify Sources/MacChannelCore/Discovery/AuthenticatedPresenceSupervisor.swift
- Create Sources/MacChannelCore/Discovery/PresenceTrustSynchronizer.swift
- Modify Sources/MacChannelCore/Discovery/PresenceClient.swift only for additive internal delivery/stop support if required
- Create Tests/MacChannelCoreTests/PresenceTrustSynchronizerTests.swift
- Modify Tests/DropMeshMobileRuntimeTests/MobileIdentityRecoveryTests.swift for new identity-first contract, preserving equivalent security/transport cases

**Interfaces:**
```swift
public enum PresenceTrustSyncState: Equatable, Sendable {
    case idle, synchronizing, synchronized, needsAttention
}
```
Expose separate state and callback on the shared supervisor; existing connection state.online continues to mean authenticated connectivity, not proof acceptance. Records source is an injected async throwing closure returning signed records, defaulting to repository.authenticationRecords for source compatibility. Production durable sources will be wired in pairing-persistence task; do not weaken existing persisted receive admission.

- [ ] Step 1 RED: Real protocol-frame fixture tests assert first auth contains zero proofs, fresh nonce/signed identity retained, invalid identity never becomes online, stale proof rejection does not disconnect an otherwise authenticated session, and accepted result is never reported before trust-ok. Old proof-first recovery expectation must fail before intentional behavior change.
- [ ] Step 2 RED: Test one in-flight update with concurrent refresh requests; rejected record followed by valid revoke; close during acknowledgement; cancellation-insensitive send; ack timeout followed by late old ack; reconnect with new session; duplicate refresh without new records. New assertions must fail for the current fire-and-forget publisher.
- [ ] Step 3: Start the single reader before the synchronization worker. Serialize snapshots of current records in issuer/sequence order with stable signature tie-breaker. Correlate acknowledgement only to one pending record within one session token. Accepted/rejected signatures are accounted for per session; refresh coalesces current records and does not hot-loop rejected signatures. A new session may retry current proofs. Any rejected current proof leaves needsAttention until the relevant current snapshot is all confirmed. All original signed records remain stored.
- [ ] Step 4: Bound auth and ack waits to 15 seconds, longer than server's 10-second handover drain. Timer requests socket retirement/close; it cannot permit a second owner before old work has actually joined. Tests inject timing to cover the 5–10 second boundary without long wall-clock sleeps. Timer/continuation cleanup must finish on every stop or stream-end path.
- [ ] Step 5: On timeout/transport failure reconnect with backoff; on trust rejection continue unrelated valid records and expose needsAttention, without calling it an identity failure. On malformed frames preserve existing fail-closed behavior. Reset retry count after successful authenticated session. No perpetual proof/identity toggling fallback remains in production shared owner.
- [ ] Step 6: Run `swift test --disable-automatic-resolution --filter 'PresenceTrustSynchronizerTests|SharedPresenceOwnerTests|MobileIdentityRecoveryTests|MobilePresenceSupervisorTests|TrustAuthenticationExportTests'`; adjust all owned fixtures to send real trust acknowledgements. Run both Mac product builds. Retain negative signature/revocation/catch-up cases.
- [ ] Step 7: Self-review, report .superpowers/sdd/identity-trust-sync-report.md with RED/GREEN evidence, commit owned files, independent safety review. Explicitly distinguish connection state from sync state in report.

## Dependency and continuation

Execute after shared owner extraction. Following work connects sync state to both UI snapshots, supplies durable record sources, and gates pairing success on completed local persistence. Final installed bidirectional/network-switch tests remain mandatory.
