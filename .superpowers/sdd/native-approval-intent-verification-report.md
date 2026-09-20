# Native approval verification and durable intent report

Implemented from task base `bf8d4e2`; coordinator's intervening documentation-only
`a67fb22` preserved. Scope is exactly three new core files and three new test files,
plus this report. No controller, UI, protocol, bootstrap semantics, installed app,
capability, service, database, or real personal Keychain changes.

## Public interfaces for controller integration

`AccountDeviceApprovalValueError`: invalidValue, verificationMismatch,
invalidTransition, conflict, capacity, secureStorage.

`AccountDeviceApprovalRequestContext` is immutable, Equatable, Sendable, redacted:

```swift
init(origin: URL, requestID: String, accountID: String, groupID: String,
     generation: UInt64, subjectDeviceID: String, subjectPublicKey: Data) throws
init(origin: URL, summary: AccountGroupPendingSummary) throws
var requestDigest: Data { get }
var requestCode: String { get }
func matchesRequestCode(_ code: String) -> Bool
```

Stored properties expose origin, requestID, accountID, groupID, generation,
subjectDeviceID and exact subjectPublicKey. Origin normalizes with the existing
AccountSessionBinding; public-key representations remain exact. Request comparison
accepts only uppercase `DMJR1-` prefix followed by full 64 hex digits, allowing hex
case and ASCII space/hyphen grouping inside the body. Input is bounded to 512 bytes.

`AccountDeviceApprovalCapsule` is immutable, Equatable, Sendable, redacted:

```swift
init(origin: URL, requestID: String, draft: AccountGroupApprovalDraft,
     expectedAnchorHash: Data) throws
static func parse(_ code: String,
                  expectedRequest: AccountDeviceApprovalRequestContext,
                  expectedDraft: AccountGroupApprovalDraft) throws -> Self
```

Properties: origin, requestID, anchorHash, canonicalPayload, code,
comparisonDigest, fingerprint. Both construction and parsing validate the supplied
actor-only draft through its accepted codec, never finalized-event validation.
Parsing matches the exact expected request tuple and canonical actor payload.
The capsule contains anchor plus canonical payload, not a signature envelope;
the independently fetched validated draft supplies the actor proof. Valid imported
JSON formatting is retained in `code` byte-for-byte. Canonical standard base64,
four string fields, duplicate/escaped-duplicate rejection, 8192 decoded JSON bytes
and 4096 context bytes are enforced. The inherited bounded raw string parser is
used before any keyed Foundation decoding can lose duplicates.

**A supplied/imported anchor is not thereby trusted.** Controller must verify
history under that independent evidence, enforce consent and local membership,
and own any later authorized checkpoint pin. An anchor substitution produces a
different full fingerprint, not automatic rejection based on server authority.

`AccountGroupApprovalIntent` is immutable, Equatable, Sendable and redacted:

```swift
enum Role: String { case subject, actor }
struct Scope {
  init(binding: AccountSessionBinding, accountID: String,
       requestID: String, role: Role) throws
}
struct Acknowledgment {
  init(createdAtMilliseconds: UInt64, expiresAtMilliseconds: UInt64) throws
}
struct Proof {
  init(request: AccountDeviceApprovalRequestContext,
       draft: AccountGroupApprovalDraft, capsule: AccountDeviceApprovalCapsule) throws
}
enum ActivePhase {
  case subjectRequested
  case actorProposed(Proof)
  case subjectCountersigned(Proof, AccountGroupEvent)
}
enum TerminalOutcome {
  case locallyAbandoned
  case acknowledged(AccountGroupPendingStatus)
}
enum Phase {
  case active(ActivePhase)
  case terminal(ActivePhase, TerminalOutcome)
}
init(scope: Scope, intentID: UUID, originalSessionIdentity: AccountSessionIdentity,
     localPublicKey: Data, request: AccountDeviceApprovalRequestContext,
     preparedAtMilliseconds: UInt64, originalAccessExpiresAtMilliseconds: UInt64,
     acknowledgment: Acknowledgment? = nil, phase: Phase) throws
func replacing(phase: Phase, acknowledgment: Acknowledgment? = nil) throws -> Self
func canReplace(with next: Self) -> Bool
```

All constructor data are readable immutable properties, plus version=1, groupID,
generation, confirmationDeadlineMilliseconds/confirmationDeadline,
activePredecessor, isAcknowledgedTerminal. Proof exposes draft, capsule,
canonicalPayloadDigest (SHA256 of canonical actor payload), requestComparisonDigest.
Deadline is the minimum of original preparation+300000 milliseconds, original
access expiry, and retained acknowledged server expiry. An acknowledgment cannot
be replaced after recorded. A candidate replacement still needs store CAS; merely
constructing one does not authorize it. Controllers must supply acknowledgment
times when obtained and perform current-session/freshness checks before writes.

Phase transitions retain exact original session and all immutable context.
Terminal stores one nonrecursive active predecessor. Locally abandoned may become
acknowledged terminal only with that same predecessor; it never becomes active.
SubjectRequested cannot become committed terminal without signed proof, and
storage never initially inserts a countersigned or terminal record.

`AccountGroupApprovalIntentStorage` (all operations async throws):

```swift
func load(scope: AccountGroupApprovalIntent.Scope) -> AccountGroupApprovalIntent?
func list(binding: AccountSessionBinding, accountID: String) -> [AccountGroupApprovalIntent]
func insert(_ intent: AccountGroupApprovalIntent)
func replace(scope: AccountGroupApprovalIntent.Scope,
             expected: AccountGroupApprovalIntent, with intent: AccountGroupApprovalIntent)
func pruneTerminal(scope: AccountGroupApprovalIntent.Scope,
                   expected: AccountGroupApprovalIntent)
```

`KeychainAccountGroupApprovalIntentStorage()` supplies the dedicated production
adapter; internal `init(store:)` injects the synchronous fake SecretStore in tests.
One collection per binding/account, domain-separated SHA256 key, unique request/role
sort, max32 entries, max16384 bytes per canonical record and max1048576 collection.
Full collection read/validation/CAS/store has no await. Reads never use stale cached
collections. Identical insertion/replacement retry is idempotent. Prune requires
the exact acknowledged terminal; it rewrites even an empty collection and never
calls removeAll or writes an auxiliary index. Canonical decode/reencode rejects
unknown/duplicate fields, malformed proofs/ownership, altered numeric forms,
noncanonical encoding and trailing data. No automatic pruning or reset API.

Policy: service `com.zensystech.dropmesh.account-group-approval`, nil accessGroup,
afterFirstUnlockThisDeviceOnly, synchronizable=false. Intent/capsule descriptions
and debug descriptions redact all contents. No logging, tokens or private keys.

## Evidence

RED missing public verification types: `/tmp/approval-intent-red.log`.
Initial verification GREEN: `/tmp/approval-verification-green.log`, 2/0.
RED missing durable intent/storage APIs: `/tmp/approval-storage-red.log`.
Initial complete GREEN: `/tmp/approval-intent-green-initial.log`, 7/0.

Behavioral RED `/tmp/approval-capsule-retention-red.log`: valid imported JSON
formatting was lost by reconstruction. Fixed by retaining exact independently
imported `code`. Same run exposed a test-vector mistake: proposed previousHash
substitution was the fixture's unchanged 0x42 byte; corrected to 0x43. Expanded
GREEN `/tmp/approval-intent-expanded.log`, 11/0.

Behavioral RED `/tmp/approval-intent-zero-session-red.log`: zero account UUID was
accepted, unlike existing session storage. Constructor now rejects it; no change
to existing storage or session semantics.

Final required literal command, run once:

```sh
swift test --filter 'AccountDeviceApprovalVerification|AccountGroupApprovalIntent|AccountGroupBootstrapIntent|AccountGroupCheckpointStorage'
```

`/tmp/approval-intent-swift-final.log`: 17 tests, zero failures, exit0. This includes
12 new tests and 5 bootstrap regressions. The brief's checkpoint filter names no
actual test class; repository class is AccountGroupCheckpointTests. Corrected
regression run once, without repeating already passing intent/bootstrap tests:

```sh
swift test --filter AccountGroupCheckpointTests
```

`/tmp/approval-intent-checkpoint-regression.log`: 6 tests, zero failures, exit0.
No skips. No newly emitted warnings in these final logs. `git diff --check` clean.

Tests cover independently reconstructed storage actors, capacity32/33, one-winner
same-key concurrent replacement, proof/final-event preservation, malformed and
foreign collection ownership, unrelated account/request/role retention, protected
reads, failed replace/prune writes, exact terminal prune and uncertainty retention.
Verification tests substitute every payload field and expected request field,
domain, origin, request ID, anchor, key representation, malformed/missing/unknown/
null/type/duplicate/escaped-duplicate fields, size/base64/overflow representations.
Only injected in-memory stores were used; no actual Keychain query occurred.

Literal digests were independently derived with Ruby Digest::SHA256, Base64 and
`[byteLength].pack("Q>")` from existing synthetic fixture payloads; production Swift
digest helpers were not used to generate expected values. Origin is
`https://example.com`, request UUID `33333333-3333-3333-3333-333333333333`, anchor
32 bytes of 0x41. Fixture order and exact literals:

| Fixture | Request digest | Full comparison digest |
| --- | --- | --- |
| actor64-subject65 | EBC60E82B5EBE5C713FA212344D0B989AB7BB62932EC58A071A29A8E920751F6 | ACF7CA24FE19B66132F89A372D831CD8613367C98EB4F275579B60D5808AF5DF |
| actor65-subject64 | 5F91553E4949B5C8424A57F346EAB5FE96C8F6CAA4A89037B151F9164F5F09FD | 23A77325DA721E881BDA99E08868090DC1542436953A56684AE4165A49C27659 |

## Limitations and next gate

One actor/writer per runtime is required; no cross-process or independent-writer
CAS guarantee. Canonical account-collection corruption fails that account closed.
Actual Keychain capacity/protection/device behavior remains untested; fake-store
tests are not installation, persistence-on-device or two-device acceptance.
No human comparison, anchor trust, membership, transport connection, or fresh
consent can be inferred from construction/parsing/storage.

An unsigned Create that never reached the server remains uncertain even after
local abandonment. It cannot be pruned as acknowledged cancellation. Such records
can consume the bounded capacity until the controller provides safe explicit
reconciliation; this component does not weaken the distinction to reclaim space.

Swift test/build processes completed and sole Swift-cache ownership is released.
No Go/SQL/cache or service lifecycle work occurred. Independent review is required
before the controller composes consent, current-session checks and callbacks.
