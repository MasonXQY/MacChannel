# Native account group proofs implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: subagent-driven-development and test-driven-development. This executes approved account group design, no new product decisions.

**Goal:** Native verification of backend-compatible group proofs and pinned membership histories.
**Architecture:** Pure Swift value types in MacChannelCore mirror reviewed Go Event/State. Explicit caller-provided bootstrap pins, no server trust root. Synthetic Go/Swift bidirectional interoperability is an acceptance gate.
**Tech Stack:** Existing Foundation/CryptoKit, Swift XCTest, Go crypto/ecdsa. No dependencies.

## Global Constraints

- Apple login does not grant transfer trust. No TrustStore, routing or identity reset changes.
- No live keys, Keychain, service, portal, schema, deployment or phone writes.
- Leave current UI/login/build and unrelated dirty files unchanged.
- Invalid input yields a generic typed error, no partial membership mutation.

### Task 1: Native verified proofs and pinned state

Own new Sources/MacChannelCore/Accounts/AccountGroupEvent.swift,
AccountGroupState.swift, Tests/MacChannelCoreTests/AccountGroupProofTests.swift,
AccountGroupInteropTests.swift, and new
Services/rendezvous/internal/accountgroup/native_interop_test.go only.
Report .superpowers/sdd/native-group-proofs-report.md.

Interfaces may use idiomatic naming but must be documented in report:
```swift
public struct AccountGroupWireEvent: Codable, Equatable, Sendable {
 public let payload: String
 public let signature: String
 public let subjectSignature: String
}
public enum AccountGroupProofError: Error, Equatable { case invalidEvent, invalidTransition }
// Event exposes immutable validated fields, canonicalPayload(), digest(),
// wire encoding/decoding; construction can be unsigned for signing explicitly,
// but verifying/wire conversion/digest MUST validate required signatures.
// State value type: init(anchor:expectedAccountID:expectedGroupID:
// expectedGeneration:expectedAnchorHash:), mutating apply(event), snapshot.
```

Exact contract is current Go accountgroup/event.go, wire.go and state.go: copy
semantics in Swift value types; no automatic signing, external effects or locks
needed for owned value state. Do not create a generic crypto abstraction.
Public IDs as canonical lowercase strings, not UUID-normalized accepting uppercase.
Generation/sequence UInt64 restricted1...Int64.max; timestamp Int64positive.
64-byte raw or65-byte uncompressed P256 accepted, deviceID SHA256(originalkey)
first16bytes formatted lowercase UUID, no UUID version-bit rewrite. Signature DER
max80bytes, SHA256 exact canonical payload. Validate actor and subject identity
and required signatures. Bootstrap selfsamekey seq1emptyhash no subject signature;
approve distinct identities seq>=2hash32 dualsigned; remove permits selfsamekey,
actoronly signature, rejects surplus subject signature. Digest signature-independent
but only returns for signature-valid event. Canonical JSON all Go fields+purpose,
same sorted keys/escaping/base64; wire retains precise64/65 key encoding.

Decode bounds wire payload4096chars/signatures108 before Base64; strict standard
padded roundtrip. Decode exact canonical payload schema and scalar types with
byte-for-byte re-encoding equality; duplicate/unknown/null/omitted/reordered keys,
fractional/exponent numeric spelling, wrong purpose, trailing JSON rejected.
Never use Double for counters. Outer WireEvent Codable must reject unknown,
missing and null string fields; duplicate key handling must be tested/documented,
use a bounded strict helper if Foundation decoder cannot detect duplicates.
Clarification: Codable checks exactkeys/types/length; it cannot detect duplicates
already collapsed by Foundation. Provide mandatory decodeJSON(Data) raw-wire
entry point with8KiB input bound and flat three-string-key duplicate detection
(including escaped-key aliases). Document and test the distinction; never claim
plain JSONDecoder provides duplicate detection. No general JSON parser framework.

State anchor independently supplied expected account/group/generation/hash;
do not construct expected values from untrusted server response in production.
Empty initial group forbidden. Apply exact nextseq/previoushash/samegeneration,
active actor exactkey; approve absentmember max64; remove present exactkey.
Old approval afterremove rejected; fresh dualsigned rejoin allowed; lastmember
selfremove yields terminal empty membership. No automatic genesis/generationreset,
no wallclock freshness rule here. Snapshot sorted by deviceID, ownedvaluebuffers.
Failure leaves snapshot unchanged. Overflow-safe arithmetic. No file persistence
or transfer authorization; those follow after native proof acceptance.

- [ ] TDD meaningful RED on unsigned correct-pin anchor or valid signed roundtrip
  with minimal API stubs; then minimal implementation.
- [ ] Focused XCTest:64/65 forms and independently computed identity, exact
  canonical golden, dualsigned approve/remove/selfremove, randomizedsignature
  same digest, unsigned/tampered every boundfield/wrongkey/missing signatures,
  oversized/base64/noncanonical/unknown/duplicate/null/malformed wire input.
- [ ] State tests: wrongpins, unsigned exactpins, oldgeneration, gaps/forks,
  inactiveactor, wrongsubjectkey, duplicateapprove, removedapprovalreplay,
  freshrejoin, cap64, maxInt64, failedstateunchanged, copyisolation.
- [ ] Bidirectional real interoperability using synthetic ephemeral keys ONLY:
  Go test opt-in env DROPMESH_GROUP_INTEROP_DIR reads/writes fixtures within an
  explicit temporary directory prefixed dropmesh-group-interop-. Without env
  skip. Reject non-absolute/symlink or wrongprefix directories before writes;
  no DB. Mode export writes Go signed bootstrap/approve/remove wire events;
  mode verify reads Swift signed events and applies reviewed Go State.
  Swift interop test opt-in DROPMESH_RUN_GROUP_INTEROP=1 owns mktemp-equivalent
  temporary directory, invokes go test focused helper from rendezvous root,
  decodes/verifies Go proof chain using new native code, generates independent
  Swift synthetic chain and invokes Go verify. Validate separate64/65 fixture
  coverage where supported; no storing raw private keys in fixturefiles.
  Bound subprocess time and fixture size; use one Go invocation eachdirection,
  report actual acceptance not skippedtest success. No runtime dependencies.
- [ ] Run swift test --filter AccountGroup focused default and opt-in interop.
  Run existing AccountServiceClientTests regression. Run focused Go accountgroup
  tests (no SQL fixture needed). Report warning/failure honestly, don't suppress.
- [ ] Scoped commit + independent review. Do not modify client/session/UI/API.

Native network pagination/session integration is the next bounded slice, after
this pure verification implementation passes both-language tests. This task
does not claim a phone installation or automatic device connectivity.
