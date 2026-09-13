# Identity and acknowledged trust synchronization

Status: implemented and locally verified; independent review pending.
Task baseline: f90fc72. Worktree: MacChannel/.worktrees/dropmesh-iphone.
Root's concurrent documentation changes are excluded from this implementation commit.

## Implementation

- The shared owner always requests fresh signed identity-only authentication.
  The standalone session's source-compatible default connect behavior is retained.
  There is no proof/identity fallback toggle in the shared production owner.
- `PresenceSessionState.online` means authenticated connectivity only.
  `PresenceTrustSyncState` independently reports idle, synchronizing,
  synchronized, or needsAttention. A rejected current proof remains needsAttention
  while unrelated records continue; no rejection disconnect or proof deletion.
- An attempt-local synchronizer is the only trust-update writer. The sole session
  reader is marked active before starting the worker and delivers ACKs directly;
  no consumer is added to trustResults. A pending result slot precedes send.
- Snapshots are sorted by issuer, sequence, then signature. Accepted and rejected
  signatures are accounted for only in this session. Refresh requests coalesce,
  unchanged records are not resent, and a new session retries current proofs.
- Auth and each complete send/ACK exchange have a 15-second deadline, including
  ACK received while transport send remains suspended. Expiry requests retirement
  and close. All reader, writer, timer, liveness, directory and forwarder work
  must actually join before a replacement socket is created.
- The mobile adapter adds state/callback, records-provider and deadline-clock
  seams. Default record source remains repository.authenticationRecords.
- Root-authorized adjacent repair: presence renewal rechecks each peer after
  actor hops and serializes already admitted directory deliveries per peer.
  A newer offline event cannot be overwritten by an older online renewal.
  Cleanup retains and joins all admitted deliveries. No transfer protocol,
  trust admission, identity/key, pairing or revocation rules changed.

## TDD evidence

1. `swift test --disable-automatic-resolution --filter PresenceTrustSynchronizerTests`
   before implementation, `.build/identity-trust-sync-red.log`, exit 1:
   - `XCTAssertTrue failed - Connectivity must authenticate identity directly`
   - `XCTAssertEqual failed: ("21") is not equal to ("1") - One in-flight record until trust-ok, including concurrent refresh`
   - Follow-on expected-count wait also failed because the old publisher sent
     every concurrent refresh without ACK gating. Initial corrected regression
     GREEN: one test, zero failures, `.build/identity-trust-sync-green.log`.
2. `swift test --disable-automatic-resolution --filter PresenceTrustSynchronizerTests.testRejectedProof`
   `.build/identity-trust-sync-rejection-red.log`, exit 1:
   `("synchronizing") is not equal to ("needsAttention")` while another record
   was pending after a rejection. Fixed state calculation; final focused GREEN.
3. `swift test --disable-automatic-resolution --filter 'PresenceDrainTests.testRenewalRechecks|PresenceDrainTests.testSamePeerOffline'`
   `.build/identity-trust-sync-renewal-red.log`, exit 1, two tests/two failures:
   - `An old iterator cannot renew an offline peer`
   - `An admitted renewal cannot overtake a newer offline input`
   Both fail without disconnect, then pass with per-peer ordered delivery.
   The old heartbeat drain test now queues same-peer offline concurrently because
   offline correctly waits behind the already admitted renewal. Its stopped/drain
   and replacement-presence assertions remain intact.
4. `swift test --disable-automatic-resolution --filter PresenceTrustSynchronizerTests.testAckBeforeBlocked`
   `.build/identity-trust-sync-send-red.log`, exit 1: timeout waiting for socket
   closure after ACK arrived but send remained blocked. Removing the early-ACK
   exception from deadline expiry makes this pass. The test cleans up its held
   continuation on RED too; no abandoned task is required for the reproducer.

Supplemental boundary coverage was added after the first minimal GREEN, rather
than claiming each supplemental case independently failed on the old API.

## Final verification

- `swift test --disable-automatic-resolution --filter 'PresenceTrustSynchronizerTests|SharedPresenceOwnerTests|MobileIdentityRecoveryTests|MobilePresenceSupervisorTests|TrustAuthenticationExportTests|PresenceDrainTests'`
  `.build/identity-trust-sync-focused.log`: 60 tests, zero failures, exit 0.
- `swift test --disable-automatic-resolution`
  `.build/identity-trust-sync-full.log`: 1046 tests, five existing conditional
  skips, zero failures, exit 0; 52.729 seconds. Includes unchanged signature,
  invalid catch-up, owner revocation, policy and transport regressions.
- `swift build --disable-automatic-resolution --product MacChannelApp`
  `.build/identity-trust-sync-direct-build.log`: exit 0, build complete.
- `swift build --disable-automatic-resolution --product DropMeshAppStore`
  `.build/identity-trust-sync-store-build.log`: exit 0, build complete.
- `git diff --check`: exit 0.
- No compiler warnings or unexpected test failures in final logs. Existing
  DEBUG closed-category transport diagnostics remain during negative fixtures.

The 13 new protocol-fixture tests cover signed identity-only first auth, invalid
identity never-online, sequential ACK gating, concurrent and duplicate refresh,
stable record ordering, rejected proof then valid revoke, refreshed snapshots,
rejected-proof retry in a new session, close during ACK, cancellation-insensitive
send both before and after ACK, late ACK from a retired socket, and injected-clock
10-second successful handover/15-second auth expiry. Clock timers are checked
empty after stop. A single owner/bridge test executes 20 consecutive disconnect
cycles (21 fresh authentications), ACKs each session, and observes zero socket
replacements before prior close. These are automated synthetic transport tests,
not physical network-interface or installed-device acceptance.

## Owned files

- Sources/MacChannelCore/Discovery/AuthenticatedPresenceSupervisor.swift
- Sources/MacChannelCore/Discovery/PresenceTrustSynchronizer.swift
- Sources/MacChannelCore/Discovery/PresenceClient.swift
- Sources/DropMeshMobileRuntime/MobilePresenceSupervisor.swift
- Tests/MacChannelCoreTests/PresenceTrustSynchronizerTests.swift
- Tests/MacChannelCoreTests/PresenceDrainTests.swift
- Tests/MacChannelCoreTests/SharedPresenceOwnerTests.swift
- Tests/DropMeshMobileRuntimeTests/MobileIdentityRecoveryTests.swift
- Tests/DropMeshMobileRuntimeTests/MobilePresenceSupervisorTests.swift
- This report.

## Self-review and boundaries

Reviewed all owned changes. Retired-token checks precede retirement actor hops;
bridge invalidation precedes external sync callbacks, and the old synchronizer
is captured before those hops. Stop does not grant replacement permission until
cancel-insensitive operations return. Unsolicited/duplicate ACK while no matching
single pending result exists retires the session. The unchanged wire protocol
has no request IDs; server's single ordered response per request remains the
correlation contract.

Production receipt filtering and durable pairing/UI integration are explicitly
not done here. Synchronization accounting follows the brief's signature-per-
session contract; future durable receipt filtering must match the exact record.
Identity connectivity never changes graph/routing, receive policy or transfer
identity checks. No production deployment, installed binary replacement, device
private-key access, record clearing or physical transfer acceptance occurred.

## Independent-review follow-up: deterministic offline admission

Independent review approved the implementation with one Minor test-strength
finding: the same-peer overlap test inferred admission from a 30ms sleep.
Replaced that wait with an explicit lock-protected admission signal. The internal
PresenceClient fixture initializer optionally observes a delivery synchronously
after its task and per-peer tail are recorded, before awaiting the delivery.
The production initializer supplies no observer. This adds no callback actor hop,
logging, or ordering change. The test releases the held renewal only after the
offline delivery is actually queued.

`swift test --disable-automatic-resolution --filter 'PresenceDrainTests|PresenceTrustSynchronizerTests|SharedPresenceOwnerTests'`
passed 33 tests, zero failures, exit 0; no compiler warnings. Evidence:
`.build/identity-trust-sync-admission-green.log`. `git diff --check` passed.
The full suite was not repeated for this narrow test seam, per coordinator scope.
