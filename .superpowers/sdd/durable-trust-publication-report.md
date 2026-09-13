# Durable trust publication implementation report

Status: implemented and locally verified; independent review pending.

Worktree: `/Users/mason/Documents/ChatGPT/Deepseek/MacChannel/.worktrees/dropmesh-iphone`.
Source base: `81a44ab`; coordinator documentation-only commit `88c482a` arrived during work.
The commit containing this report contains the scoped source and tests below.

## Implementation

- `TrustRepository.publicationSnapshot(persisted:)` captures current eligible
  authentication records and intersects the successful saved receipt in one actor
  turn. It rejects wrong owner/key and receipt generation ahead of the repository.
  Older receipts can publish unrelated exact records still eligible now, but cannot
  restore removed authorization or publish an unpersisted replacement/revocation.
- `SignedTrustRecord` now has synthesized complete-value Hashable/Equatable
  conformance. All stored fields participate, including content and signature.
  Codable layout, canonical payload and signing are unchanged.
- `TrustPublicationSnapshot` carries records plus one pending-persistence Boolean.
  The sole `PresenceTrustSynchronizer` retains ACK gating, deadlines, and one
  writer. It uses full records for ACK accounting. Eligible saved records can be
  sent while other current records await persistence. After ACKs, the status is
  pendingPersistence instead of synchronized if anything current was excluded.
  A rejected eligible proof still reports needsAttention. Pending persistence
  itself never retires an authenticated socket.
- A refresh received while the synchronizing state callback is suspended causes
  a new provider read before admitting the next send. An already transmitted
  proof is not retroactively cancelled; its ACK still belongs to its one writer.
- The existing shared presence owner owns repository and successful-receipt
  observers when production receipt updates are supplied. Both observers only
  request coalesced refresh. They are cancelled and joined before that owner's
  stop completes, including cancellation-insensitive subscription construction.
- Mac bootstrap supplies the concrete existing snapshot store's receipt and
  update stream. Its old bootstrap refresh observer is removed; the nullable
  initializer task seam remains source compatible and production supplies nil.
- MobileIdentityContext exposes the same repository/store selection. Foreground
  runtime passes it through the production network and mobile presence adapter.
  The production network constructor requires both source and receipt updates;
  it cannot silently use raw current records. Existing explicit array test
  providers and shared-owner test constructors remain compatible.
- Existing runtime repository observers retain persistence/save-error and
  receiving-policy duties. Mobile no longer duplicates publication refresh from
  that path; saved receipts and repository events go directly to the shared owner.
  No new persistence owner, cache, trust writer, or receipt synthesis was added.

## TDD evidence

Commands were run from the worktree above. Logs live under its ignored `.build/`.

1. `swift test --filter TrustPersistenceReceiptTests > .build/durable-publication-red.log 2>&1`
   - RED: 8 tests, 7 assertion failures. The three new scenarios used the baseline
     production `authenticationRecords()` source in a test helper. This exposed
     inclusion before save, inclusion after failed save, unpublished revoke,
     stale receipt, wrong owner, future generation, and reused-signature content.
   - The helper was then switched to the real repository atomic selector.
   - `swift test --filter TrustPersistenceReceiptTests > .build/durable-publication-green.log 2>&1`
   - GREEN: 8 tests, 0 failures.

2. `swift test --filter PresenceTrustSynchronizerTests.testUnsavedProof > .build/durable-sync-red.log 2>&1`
   - RED: initial state was synchronized despite filtering an unsaved proof;
     a receipt arriving without a repository mutation never triggered sending.
     The bounded transition wait consequently timed out (recorded CancellationError).
   - Provider status and joined receipt/repository observations were implemented.
     A first compile attempt exposed an async nil-coalescing fallback mistake;
     it was corrected to explicit async branches (in `.build/durable-sync-green.log`).

3. `swift test --filter 'PresenceTrustSynchronizerTests.testRefreshWhile|PresenceTrustSynchronizerTests.testUnsaved' > .build/durable-refresh-red.log 2>&1`
   - The saved-receipt scenario now passed.
   - RED for the gated callback race: sendCount was 1 instead of 0 after refresh
     arrived while state delivery was blocked. The fix reconsiders refresh before
     send admission, retaining the original ACK writer and in-flight ownership.
   - `swift test --filter 'PresenceTrustSynchronizerTests|TrustPersistenceReceiptTests|MobilePresenceSupervisorTests|MobileIdentityContextTests' > .build/durable-adapters-green.log 2>&1`
   - GREEN: 44 tests, 0 failures.

Additional regressions exercise legacy snapshot-only startup without fabricated
proofs or erased trust, current revoke before save then successful receipt with no
further mutation, observer subscription drain, receipt-driven mobile publication,
and no refresh after mobile owner stop. Multi-device records are independent by
DeviceID, with unrelated saved proofs surviving another device's pending save.
Display names are not an input to this selection; equal names cannot merge IDs.

## Final verification and fixture correction

`swift test --filter 'TrustPersistenceReceiptTests|TrustAuthenticationExportTests|PresenceTrustSynchronizerTests|SharedPresenceOwnerTests|PresenceDrainTests|MobilePresenceSupervisorTests|MobileIdentityContextTests|MobileForegroundRuntimeTests|MobileProductionForegroundNetworkTests|DurablePairing|PairingPersistence|PairingCoordinator' > .build/durable-publication-focused.log 2>&1`

Initial expanded run: 111 tests, one existing cancellation test assertion failed.
`MobileForegroundRuntimeTests.testRevocationCancelsWorkOnAnEstablishedChannel`
read the first published snapshot immediately after refresh. `cancel()` synchronously
claims desiredSnapshot then queues the FIFO writer; snapshots expose durableSnapshot
only. Thus cancellation intent can be correct while the first published snapshot
still reflects the previous persisted phase. An isolated rerun passed, but was not
treated as sufficient acceptance.

The final fixture explicitly blocks terminal persistence, verifies cancellation
intent while the write is blocked, releases the gate, then uses the existing bounded
observable-condition helper to await published `.cancelled`. No arbitrary extra
delay and no production cancellation/receiving/routing changes were introduced.

`swift test > .build/durable-publication-full.log 2>&1`

- 1,072 tests, 5 conditional skips, 0 failures, 51.470 seconds.
- This full run compiled final production source and ran before the test-only
  cancellation-fixture correction. No production code changed afterward.
- Skips: live Go wrapper absent; optional offscreen localization capture absent;
  optional native icon rendering absent; two Docker Internet/TURN acceptance cases
  lacked their environment. These are not passed live interoperability evidence.

`swift test --filter 'TrustPersistenceReceiptTests|TrustAuthenticationExportTests|PresenceTrustSynchronizerTests|SharedPresenceOwnerTests|PresenceDrainTests|MobilePresenceSupervisorTests|MobileIdentityContextTests|MobileForegroundRuntimeTests|MobileProductionForegroundNetworkTests|DurablePairing|PairingPersistence|PairingCoordinator' > .build/durable-publication-focused-final.log 2>&1`

- Final source and corrected fixture: 111 tests, 0 skips, 0 failures, 3.902 seconds.
- `swift build --product MacChannelApp > .build/durable-publication-mac-build.log 2>&1`: passed (0.51 seconds).
- `swift build --product DropMeshAppStore > .build/durable-publication-store-build.log 2>&1`: passed (0.21 seconds).
- `git diff --check`: passed. Final full/focused/build logs contain no compiler
  warnings or errors; expected closed-category DEBUG reconnect messages remain.

## Admission audit and limits

This is durable proof publication, NOT a new durable transfer admission guarantee.
`iPhone/App/MobileDurableTrust.swift` is presentation filtering. It was inspected
but is not an incoming-transfer boundary and was not changed in this slice.

MobileForegroundRuntime still builds ReceivePolicy from current repository trusted
IDs. Mac IncomingRuntimeController does likewise when configuring the receiver.
ConnectionCoordinator/WebRTCConnectionListener still require repository pinned
public keys before transport setup and recheck the same key after asynchronous
setup (ConnectionCoordinator.swift). AuthenticatedPresenceSession retains current
repository checks for authenticated peer signaling/presence. Identity-only socket
authentication therefore does not grant peer routing rights.

Those existing crypto and receiving checks are preserved. No claim is made that a
newly committed but unsaved local pairing cannot be admitted by those separate
existing boundaries. No distributed atomic persistence or cancellation of already
transmitted proof is claimed. The shared durable pairing gate was not redesigned.
The next presentation slice must not label the UI filter as runtime admission.

No installed app, signing, phone, production service, or server changes were made.
Tests use ephemeral identities and temporary local fixture stores. No user DeviceID,
keys, old proofs, sequence reservation, serialization, revocation semantics or
transfer protocol was reset, re-signed or altered to obtain synchronization success.

## Files and self-review

Production: TrustRepository.swift, TrustRecord.swift, PresenceTrustSynchronizer.swift,
AuthenticatedPresenceSupervisor.swift, MobileIdentityContext.swift,
MobilePresenceSupervisor.swift, MobileProductionForegroundNetwork.swift,
MobileForegroundRuntime.swift, App/ProductionAppRuntime.swift.

Tests: TrustPersistenceReceiptTests.swift, PresenceTrustSynchronizerTests.swift,
MobileIdentityContextTests.swift, MobilePresenceSupervisorTests.swift,
MobileForegroundRuntimeTests.swift. This report is the only scoped documentation.
Coordinator-owned HANDOFF, progress and plan edits were not staged.

Self-review checked full-record comparison, stale receipt exclusion, current revoke,
successful-save-only retry notification, shared refresh ownership, joined observer
shutdown, pending status without reconnect, and preserved test provider seams.
No remaining implementation issue identified. Actual installed cross-device and
live shared-owner Go acceptance remain later work; independent review is required.

## Independent review follow-up

Review approved the implementation and requested two minor test improvements.
Both are addressed in this test-only follow-up to `4bde8d9`:

- The two fixed 50 ms waits in PresenceTrustSynchronizerTests now await observed
  pendingPersistence. The gated refresh regression waits for that transition
  after releasing the synchronizing callback, proving the worker reconsidered
  its snapshot before asserting zero sends. Failure cleanup releases the gate
  and joins the synchronizer; the initial pending-save test stops its owner if
  the bounded transition wait fails.
- MobileForegroundRuntimeTests now uses its existing five-second bounded
  observable-condition helper for terminal persistence entry. Failure cleanup
  releases terminal persistence, closes/releases the held channel, and stops the
  runtime before propagating the failure. It retains separate claimed-intent and
  durably published cancellation assertions.

Verification from the same worktree:

`swift test --filter 'PresenceTrustSynchronizerTests|MobileForegroundRuntimeTests' > .build/durable-publication-review-tests.log 2>&1`

Result: 39 tests, 0 skips, 0 failures, 2.219 seconds; no compiler warnings/errors.
`git diff --check` passed. No production changes; the previously recorded full
suite and both product builds remain the production-source evidence. A second
full run or rebuild was not needed for this test-only review correction.
