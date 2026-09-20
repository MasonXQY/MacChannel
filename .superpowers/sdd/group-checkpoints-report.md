# Native group checkpoint implementation report

Status: implemented and locally verified; ready for independent coordinator review.
Base: `8297a76e1398054291137479e320b511c68bf4d9`.
Worktree: `/Users/mason/Documents/ChatGPT/Deepseek/MacChannel/.worktrees/dropmesh-iphone`.
Date: 2026-09-20.

## Scope and API

Owned changes only:

- `Sources/MacChannelCore/Accounts/AccountGroupCheckpoint.swift`
- `Sources/MacChannelCore/Accounts/AccountGroupCheckpointStorage.swift`
- `Sources/MacChannelCore/Accounts/AccountGroupHistoryVerifier.swift`
- `Tests/MacChannelCoreTests/AccountGroupCheckpointTests.swift`
- `Tests/MacChannelCoreTests/AccountGroupHistoryVerifierTests.swift`
- This report.

The immutable checkpoint holds normalized `AccountSessionBinding`, canonical
lowercase account/group UUID strings, generation, independent anchor hash, and
verified head sequence/hash. Integer range is 1...Int64.max, hashes are 32 bytes,
and sequence 1 requires head == anchor.

`AccountGroupCheckpointStorage` provides only async throwing
`load(binding:accountID:groupID:)` and `save(_:)`; there is no reset/remove API.
`KeychainAccountGroupCheckpointStorage()` always owns the dedicated policy;
SecretStore injection is internal for synthetic tests. Service is
`com.zensystech.dropmesh.account-group-checkpoint`, accessGroup nil,
afterFirstUnlockThisDeviceOnly, synchronizable false.

One record per device/audience/normalized origin/account/group is addressed by a
domain-separated SHA256 over fixed-order, UInt64 byte-length-prefixed UTF-8
fields. Canonical version-1 JSON has exactly ten fields and at most 4096 bytes.
Decode validates the value and requires exact canonical re-encoding: duplicate,
unknown or missing keys, wrong types, numeric aliases, noncanonical UUID/base64
or origin spelling, unsupported version, trailing data, and excess size fail
closed. Protected/malformed reads cannot become absent records or be overwritten.
Existing binding/pin is immutable. Lower sequence or equal sequence with a
different head fails; identical records do not write again. The storage actor
does not suspend inside read/check/write.

Public verifier signatures match the brief:

```swift
AccountGroupHistoryVerifier(storage: any AccountGroupCheckpointStorage)
confirm(anchor:expectedAccountID:expectedGroupID:expectedGeneration:expectedAnchorHash:binding:)
    async throws -> AccountGroupSnapshot
accept(history:binding:accountID:groupID:)
    async throws -> AccountGroupSnapshot
```

Confirmation validates signed bootstrap with independently supplied pins. It
creates only when absent; repeated matching sequence-1 confirmation is
idempotent, and confirmation cannot replace a pin or reset a later head.
Acceptance requires a stored pin and a full 1...8192-event journal, replays the
existing proof reducer from bootstrap, and compares the previous durable head at
its exact old sequence inside that journal. Only a fully verified, durably saved
head returns membership. Terminal empty membership remains valid and cannot be
rolled back or resurrected by a removed signer.

Generic error cases: `invalidCheckpoint`, `secureStorage`, `missingCheckpoint`,
`invalidHistory`, `operationInProgress`. Errors carry no payload/secrets.
Cancellation returns `invalidHistory`; an already in-flight successful write can
advance durable high-water but returns no snapshot to the cancelled operation.

## Concurrency decision

As explicitly permitted by the coordinator, a bounded admission guard rejects
overlapping confirm/accept immediately with `operationInProgress`. It spans all
storage awaits and releases only when the awaited I/O has settled. There is no
unbounded queue or detached storage task. A cancelled request cannot release
admission during a pending write. Subsequent operations must reload persisted
high-water; they cannot publish an older head after a newer operation completes.

One coordinator/storage instance per runtime is the supported ownership boundary.
Cross-process CAS is not claimed. Caller session lifecycle fencing and explicit
device consent remain outside this task; valid membership alone grants no
transfer trust.

## RED and verification evidence

Initial RED, before production files existed:

```sh
swift test --filter 'AccountGroupHistoryVerifierTests.testRestartRejectsEarlierValidPrefixAfterApprovalAndRemoval'
```

`/tmp/dropmesh-checkpoint-red.log`: failed compilation on missing checkpoint,
storage and verifier symbols, as expected for the new feature. This is a
missing-API RED, not an assertion-level rollback failure; the same restart
rollback test passed after implementation. It confirms bootstrap, accepts signed
bootstrap/approve/remove, creates a fresh verifier and storage actor over the
same in-memory SecretStore, rejects an earlier valid prefix, and restores the
full accepted history.

Additional assertion-level regression proof:

```sh
swift test --filter 'AccountGroupHistoryVerifierTests.testOverlappingAcceptIsRejectedUntilEarlierWriteCompletes'
```

Temporarily removing the admission guard produced 1 test / 3 failures
(1 unexpected) in `/tmp/dropmesh-checkpoint-admission-red.log`. The newer
sequence-3 operation incorrectly succeeded while the sequence-2 write was
suspended; durable state was 3 instead of the expected unchanged 1, and the
earlier write then failed monotonic storage. Restoring the guard made the
deterministic test pass. No mutation remains.

Final focused GREEN:

```sh
swift test --filter 'AccountGroup(Checkpoint|HistoryVerifier|Proof)Tests'
```

`/tmp/dropmesh-checkpoint-green.log`, completed 11:58:50 local test timestamp:
33 executed, 0 failures, 0 skips, 0 warnings, 11.955 seconds.
Breakdown: checkpoint 6, history verifier 16, existing proof reducer 11.
The maximum valid 8192-event journal passed (11.696 seconds including synthetic
construction and verification); 8193 entries were rejected.

Required regression GREEN:

```sh
swift test --filter 'Account(Session|ServiceClient)'
```

`/tmp/dropmesh-checkpoint-account-regression.log`, completed 11:59:16 local test
timestamp: 34 selected, 33 passed, 1 skipped, 0 failures, 0 warnings, 0.032 seconds.
Breakdown: service client 8 passed, session controller 22 passed, session storage
3 passed; `GoAccountInteropTests.testLiveSignedAccountSessionLifecycle` skipped
because its isolated Go integration launcher was not running. No service was
started or contacted for this task. Swift Testing's separate zero-test summary
is not included in the XCTest totals.

## Coverage and self-review

- First confirm, missing-pin refusal, wrong independent pins, unsigned bootstrap,
  idempotence, repeated confirmation cannot replace/reset, fresh-instance restart,
  valid continuation, shorter-history rollback, equal-height fork and longer
  valid fork bypassing persisted head, binding/account/group isolation, generation
  mismatch, proof replay, terminal empty state, 8192/8193 journal bounds.
- Typed checkpoint bounds, dedicated policy, round trip, scope normalization,
  copied-record scope mismatch, immutable pin, monotonic heads, malformed schema,
  every missing/null field, duplicate keys, numeric types, version, size,
  canonical encodings, protected read, failed write, and retry preservation.
- Six deterministic continuation-driven suspended-I/O tests: overlapping accepts,
  confirmation during accept, cancellation during pending write, failed pending
  save then retry, cancellation during pending load, and initial confirmation
  held until persistence. No timers or sleeps; real codec/storage and real
  synthetic signed proof verification are exercised.
- `git diff --check` passed. Source reviewed for actor reentrancy, exact old-head
  comparison, save-before-return, cancellation ownership, bounded decoding,
  read-before-write, generic errors, and scope-only changes.

No live Keychain, device keys, private identity files, network/service/portal,
schema/deployment, TrustStore/routing, UI/login/session, or phone changes were
performed. Existing dirty files were preserved. No new dependency, production
grant persistence, journal storage, or token storage was added. Local unit tests
do not claim installed-device or real-Keychain acceptance. Independent review
and coordinator integration verification remain the next gate.
