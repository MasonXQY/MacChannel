# Native approval intent and independent verification plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Provide bounded, exact-session durable approval intents and explicit independent verification values for the native controller.

**Architecture:** Pure validated immutable values encode request comparisons and trusted-member capsules without changing signed event wire. One dedicated Keychain collection per binding/account persists up to32 request-role records with atomic single-item writes and exact expected-value updates inside one storage actor.

**Tech Stack:** Swift Foundation/CryptoKit, existing SecretStore/KeychainPolicy, XCTest synthetic identities.

## Global Constraints

- Existing manual pairing, transfer protocol, installed apps and live services remain unchanged.
- No method in this component signs a new group event, creates a server request, pins an anchor or grants membership.
- Exact key bytes and original session identity must be preserved, never transferred across refresh.
- No tokens/private keys; redact complete intent and capsule data from logs/descriptions.
- Dedicated Keychain service only, nil accessGroup, afterFirstUnlockThisDeviceOnly, synchronizable false; never use removeAll.
- No UI/Apple capability/installation/deployment changes or real personal Keychain access in tests.

## Task 1: Verification values and durable intent collection

**Files:** new Sources/MacChannelCore/Accounts/AccountDeviceApprovalVerification.swift,
AccountGroupApprovalIntent.swift, AccountGroupApprovalIntentStorage.swift;
new Tests/MacChannelCoreTests/AccountDeviceApprovalVerificationTests.swift,
AccountGroupApprovalIntentTests.swift, AccountGroupApprovalIntentStorageTests.swift.
Read .superpowers/sdd/native-approval-controller-contract.md for complete agreed
verification formats and lifecycle boundaries. Its storage amendment supersedes
the earlier per-request-key suggestion. Do not edit existing bootstrap semantics.

**Interface decisions:** expose immutable request scope (binding,accountID,
requestID,role), exact original AccountSessionIdentity, local key, groupID/generation,
intent UUID, conservative confirmation deadline and monotonic phase. Use throwing
constructors that validate every scope/session/proof/key binding. Store offers
load(scope:), list(binding:accountID:), insert(intent), replace(scope:expected:with:)
and pruneTerminal(scope:expected:); operations async throws, owned values Sendable.
`expected` is full immutable record, not a version integer or requestID alone.

- [ ] RED: fixed request-code vector and member capsule roundtrip. Domain-separated
SHA256 and UInt64 big-endian length-prefixed fields exactly as architecture report.
DMJR1 request code compares full256bits; strictDMJA1 capsule contains four strings,
fullanchorhash plus exact canonical actor-signed approval payload. Construct capsule
only from explicit supplied validated draft+expected anchor; this does not attest
that the supplied anchor is trusted. Controller owns that authority. Public parsing
must take expected origin/request and exact local context for matching, not adopt
embedded origin. No camera/deeplink/clipboard/network access.
- [ ] Implement pure verification values, bounded raw duplicate-key rejecting parser,
canonical base64 and payload validation. Display digest grouping may ignore only
ASCII spaces/hyphens within body and hex case; reject partial/prefix/confusable
matches. Capsule <=8192decoded JSON, context<=4096. No final-event Validate call
on an actor-only draft; use accepted draft codec and canonical payload identity.
- [ ] RED/GREEN substitutions: each domain/origin/request/account/group/generation/
actor/subject/exactkey/anchor/head/timestamp change rejects expected comparison;
raw64/X9.63 preserves exact representations, malformed duplicate/escapedduplicate,
unknown/missing/type/null/trailing/overflow/size/base64 rejects. Fixed literal
expected digest independently calculated in fixture construction, not samefunction
on both sides. Parsing never signs/pins or requests networking.
- [ ] Implement phases: subjectRequested, actorProposed, subjectCountersigned,
terminal. Subject create tuple exists before server acknowledgment. Actor retains
exactdraft/digest/pinnedanchor/capsule beforePropose. Subject retains exactfinalevent
and independently importedcapsule beforeCountersign. Terminal preserves prior
record plus status/abandonment; localabandonment is not serveracknowledgment and
cannot be pruned as confirmed cancellation. No unsigned predecessor can skip
straight to a finalizedproof. Validate signatures and unchanged session/scope.
- [ ] Storage RED/GREEN with injected SecretStore: protected/malformed read is an
error, never absence; identical insert idempotent; conflicting insert/CAS rejects;
otherrequest/role/account records survive; invalidtransition cannot write; writefail
retains old bytes; exact acknowledgedterminalprune only. No await between read,
CAS check and store call. Tests use counting fake store and explicit write faults.
- [ ] One canonical collection per normalized binding/account, key derived from
domain-separated length-prefixed scope. Entries uniquely sorted by requestID/role;
max32, max16KiB perintent, max1MiB fullcanonicalcollection. Strict decode+reencode
equality rejects lost duplicates/unknownfields and malformed ownership. Missing
collection returns empty. Pruning writes remaining collection (even empty), never
calls service-wide delete; pending/uncertain records retained. No secondindex and
no crossprocessCAS claim. KeychainStore uses oneSecItemUpdate/initialAdd viaexisting
SecretStore; do not access realstore inunit tests.
- [ ] Run focused tests and existing bootstrap/checkpointstorage regression once:

```sh
swift test --filter 'AccountDeviceApprovalVerification|AccountGroupApprovalIntent|AccountGroupBootstrapIntent|AccountGroupCheckpointTests'
```

Add roundtrip across independently reconstructed storageactor, capacity32/33,
canonical bounds, unrelated account sentinel and same-key replacement races.
Task owns Swiftcache exclusively. No actual Keychain persistence/device acceptance
claim from fakestore. Report capability/privacy/serialization limitations explicitly.
- [ ] Scoped diffcheck/commit; report .superpowers/sdd/native-approval-intent-verification-report.md
with exactinterfaces, test/log evidence and releasedcache. Independent review before
controller orchestrates consent and callbacks.
