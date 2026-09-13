# Durable Trust Publication Integration Plan

> Execute with TDD and an independent safety review after identity/trust synchronization and durable pairing surface tasks. No simultaneous implementers touching the runtime composition.

**Goal:** The shared synchronizer publishes only eligible signed proofs whose exact content is acknowledged by the existing persisted snapshot owner. A memory-only pairing mutation is not described as durably synchronized.

## Global Constraints

- Preserve DeviceID, keys, record format, sequence reservation, revocation and transfer protocol.
- Never re-sign, reset or delete old user proofs to obtain synchronization success.
- Saved state cannot override a newer in-memory revocation. Compare complete signed records, not names or signature bytes alone.
- Retain existing cryptographic routing and receiving checks. No device/server mutations in this implementation task.
- No newly introduced alternate persistence owner, generic cache or second trust-update writer.

### Task 1: Saved/current proof provider and composition

Files:
- Sources/MacChannelCore/Identity/TrustRepository.swift (atomic selection if needed)
- Sources/MacChannelCore/Identity/TrustRecord.swift (additive exact-value equality if needed; no serialization or signature changes)
- Sources/MacChannelCore/Identity/AuthenticatedTrustSnapshotStore.swift (existing persisted receipt interface only)
- New focused Core durable-publication tests
- Sources/DropMeshMobileRuntime/MobileIdentityContext.swift, MobilePresenceSupervisor.swift, MobileProductionForegroundNetwork.swift, MobileForegroundRuntime.swift
- App/ProductionAppRuntime.swift
- Corresponding mobile/Core runtime tests

- [ ] RED: current authorization not yet saved is excluded; same signed authorization after a successful receipt is included; wrong-owner receipt and altered content with reused signature are excluded; local revoke immediately excludes the old authorization before save; saving that revoke later includes the revoke; stale receipt cannot restore removed trust; multiple devices and same-name IDs are independent; startup legacy receipt remains conservative without fabricating proofs.
- [ ] Add a small repository actor operation that intersects its current eligible authentication records with the saved receipt's exact records in one actor turn. Receipt owner/generation must be consistent with current repository. No sequence lowering, timestamp rewriting or dynamic network input enters this operation. Existing authenticated load already validates legacy auxiliary proofs.
- [ ] Wire Mac closure to existing concrete trustStore.persistedState and repository selection. Wire MobileIdentityContext closure through foreground graph/presence adapter into the same shared owner. Tests may inject an explicit provider; production must not fall back silently to raw current records.
- [ ] Both repository mutations and successfully persisted receipt changes must request coalesced refresh. A send-before-save request may contain no new proof; the later successful save must trigger a new refresh even if repository generation no longer changes. All observers belong to existing joined runtime lifecycle.
- [ ] Inspect what an excluded-but-current proof means to sync status. Do not emit synchronized for a snapshot silently filtered due to pending persistence. Extend the record-source result with a bounded pending-persistence indicator if necessary, shared by both adapters. Missing durable receipt after a new mutation must remain recoverable, not an identity rejection or endless socket reconnect loop.
- [ ] Confirm failures propagate to existing save-retry state, while unrelated persisted eligible records can still synchronize. No peer routing rights arise from identity-only authentication.
- [ ] Run focused publication/sync/runtime/pairing tests and both Mac product builds, report exact test commands and results, commit scoped changes and obtain independent review.

## Admission audit and honest acceptance

`iPhone/App/MobileDurableTrust.swift` currently gates presentation trusted IDs. It is NOT a runtime incoming-transfer admission guarantee. MobileForegroundRuntime and Mac IncomingRuntimeController currently build receiving policies from repository trust, while WebRTC cryptographic checks also use that repository. Preserve these checks; explicitly document their actual scope. If a test demonstrates a new operation admitted after an unpersisted mutation despite a claimed durable gate, fix the concrete admission boundary with the same persisted/current eligibility source before claiming durable admission. Do not redesign the transfer protocol or claim distributed atomic persistence. Existing paired baseline transfers and immediate local revocation must remain safe.
