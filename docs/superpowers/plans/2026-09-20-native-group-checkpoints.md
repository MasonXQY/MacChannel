# Native group checkpoints implementation plan

> **For agentic workers:** Use subagent-driven-development and test-driven-development. This is a bounded implementation of the approved account design, not a new product decision.

**Goal:** Preserve independently confirmed group pins and monotonically verified group heads across native process restarts.
**Architecture:** A dedicated Keychain checkpoint holds binding, anchor, head sequence/hash. A coordinator accepts complete signed histories only, verifies against the independent pin and the previous head within the history, and saves before returning the new snapshot. No snapshot is published from cached checkpoints alone.
**Tech Stack:** Existing Swift Foundation/CryptoKit, KeychainPolicy/SecretStore, XCTest. No dependencies.

## Global Constraints

- Apple login does not grant transfer trust. No TrustStore, routing or identity reset changes.
- No live keys, Keychain, service, portal, schema, deployment or phone writes during tests.
- Leave current UI/login/build and unrelated dirty files unchanged.
- Invalid input yields a generic typed error, no partial membership mutation.
- Logout must not erase anti-replay knowledge. No delete/reset checkpoint API.

### Task 1: Durable group checkpoint store and full-history acceptance

Own new Sources/MacChannelCore/Accounts/AccountGroupCheckpoint.swift,
AccountGroupCheckpointStorage.swift, AccountGroupHistoryVerifier.swift,
Tests/MacChannelCoreTests/AccountGroupCheckpointTests.swift and
AccountGroupHistoryVerifierTests.swift. Report .superpowers/sdd/group-checkpoints-report.md.

Consume AccountSessionBinding (deviceID/audience/normalized HTTPS origin),
AccountGroupEvent and AccountGroupState. Produce public immutable checkpoint
and pinned history verifier with APIs equivalent to:
```swift
public struct AccountGroupCheckpoint: Equatable, Sendable {
    public let binding: AccountSessionBinding
    public let accountID: String
    public let groupID: String
    public let generation: UInt64
    public let anchorHash: Data
    public let sequence: UInt64
    public let headHash: Data
    // Throwing initializer validates all fields.
}
public protocol AccountGroupCheckpointStorage: Sendable {
    func load(binding: AccountSessionBinding, accountID: String, groupID: String) async throws -> AccountGroupCheckpoint?
    func save(_ checkpoint: AccountGroupCheckpoint) async throws
}
// Dedicated KeychainAccountGroupCheckpointStorage uses existing SecretStore.
// Public construction only dedicated policy; internal injected store for tests.
// AccountGroupHistoryVerifier actor uses injected storage, with operations:
// confirm(anchor:expectedAccountID:expectedGroupID:expectedGeneration:expectedAnchorHash:binding:)
// accept(history:[AccountGroupEvent],binding:accountID:groupID:)
// Each returns fully verified AccountGroupSnapshot only after required durable save.
```

No token/UI/session coupling in this task. Pin confirmation is an explicit caller
operation, never inferred from server history or absence of storage. Confirm uses
AccountGroupState independently supplied expected values. It only creates a new
checkpoint if absent; repeated confirmation must match the existing pin, never
reset a later head (reject if later state cannot be returned from the anchor).

Dedicated Keychain policy: service com.zensystech.dropmesh.account-group-checkpoint,
accessGroup nil, afterFirstUnlockThisDeviceOnly, synchronizable false. Scope one
record per normalized binding + account + group using unambiguous deterministic
hash encoding. Version1, at most4096 bytes per record; exact schema/types and
validated lowercase canonical UUIDs, generation/sequence1...Int64.max,
anchorHash/headHash32bytes, sequence1 requires head==anchor. Generic typed errors,
no secrets in errors/logs. Existing malformed/protected data must not be overwritten.
Save checks existing binding/pin immutable, rejects lower sequence or same sequence
different hash; equal identical record idempotent. Do not store sessions/tokens,
private keys, full journal, or current authorization grants in Keychain.

Verifier accepts complete nonempty histories at most8192 events, requires existing
checkpoint, replays all proofs from pinned bootstrap, checks prior persisted head
at EXACT old sequence inside candidate history (not just final sequence), rejects
shorter history, same-head forks, newer chains bypassing old head, different group,
generation, account or binding. A valid head that removes last member remains valid
empty membership and cannot roll back. An accepted new head is saved before it is
returned; failed save returns no membership. Subsequent valid retry may succeed.
Concurrent operations must not regress storage or return stale snapshots after a
newer operation completed. Serialize complete verifier operations across awaits
(explicit operation queue or equivalent tested admission guard), not merely actor
isolation. Cancellation must not release the gate while storage work is in flight.
Selected implementation: bounded busy admission guard; overlapping confirm/accept
throws AccountGroupCheckpointError.operationInProgress immediately. No queued
operations or unbounded continuation array. Hold guard until awaited storage settles.
One coordinator/storage instance per runtime is the supported ownership boundary;
no cross-process compare-and-swap guarantee is claimed.

- [ ] RED: add test confirming a correctly signed synthetic bootstrap then use a
  fresh verifier over same in-memory SecretStore to reject earlier valid prefix
  after accepting bootstrap/approve/remove. Run focused swift test to prove fail.
- [ ] Implement checkpoint validation, dedicated bounded storage codec, monotonic
  save and verifier using existing signed proof reducer. All edits apply_patch.
- [ ] Tests: first confirm, missing pin refusal, wrong confirm pin, repeatconfirm
  cannotreset, fullrestart, valid continuation, rollback/fork at previoushead,
  maxjournal bound, malformed checkpoint/schema/version/size, protectedread and
  failedwrite preserve data, binding isolation, generation/account mismatch,
  terminalempty, idempotence. Use synthetic keys and injected memory only.
- [ ] Deterministic suspended storage tests: overlapping accepts, confirmation
  during accept, cancellation while write pending, failed save retry; verify
  no partial snapshot and no stale head publication after newer commit.
- [ ] GREEN: swift test --filter 'AccountGroup(Checkpoint|HistoryVerifier|Proof)Tests'
  and swift test --filter 'Account(Session|ServiceClient)' regression. Report
  exact counts, failures, skips and warnings. No live Keychain tests.
- [ ] Scoped commit only owned files/report, independent task review.

Network page collection and account-session lifecycle integration follow this
checkpoint gate; current task does not enable group UI or install a phone build.
