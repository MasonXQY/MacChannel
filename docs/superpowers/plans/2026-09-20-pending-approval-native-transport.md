# Pending approval native transport implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Give the shared Swift account client strictly validated pending-request operations matching the authenticated Go endpoints.

**Architecture:** Add immutable summary/full-record models and a Sendable service protocol, implemented by AccountServiceClient with existing signed requests. Reuse PageParser primitives and strict draft/final proof codecs; never create consent or local trust in the transport.

**Tech Stack:** Swift Foundation/CryptoKit, existing URLSession transport, XCTest and synthetic Go/Swift fixture interoperability.

## Global Constraints

- Existing manual pairing, transfer protocol, installed apps and live services remain unchanged.
- Pending requests and actor-only drafts grant no membership. Only a fully signed, committed journal transition does.
- No raw tokens, private keys, full proof payloads or session IDs in outputs/logs.
- Exact route/wire rules in2026-09-20-pending-approval-transport-contract.md apply.
- Native transport cannot sign group proofs, pin discovery, persist membership or silently refresh approval authority.
- No UI, keychain, provisioning, device installation, deployment or feature activation in this task.

## Task 1: Shared pending models, strict parser, signed service and interoperability

**Files:**
- Create Sources/MacChannelCore/Accounts/AccountGroupPendingRequest.swift
- Create Sources/MacChannelCore/Accounts/AccountGroupPendingService.swift
- Create Tests/MacChannelCoreTests/AccountGroupPendingRequestTests.swift
- Create Tests/MacChannelCoreTests/AccountGroupPendingServiceTests.swift
- Create Fixtures/account-group-pending-v1.json (synthetic identities/proofs only)
- Create Services/rendezvous/internal/accountauth/native_group_pending_wire_test.go to validate fixture through actual Go response serialization.
- Narrow helper visibility/comment changes in AccountGroupPage.swift only if needed; preserve page behavior and existing tests.

**Produces:**

```swift
public enum AccountGroupPendingStatus: String, Sendable {
 case requested, proposed, countersigned, committed, rejected, cancelled, expired, invalidated
}
public struct AccountGroupPendingSummary: Equatable, Sendable {
 public let requestID, accountID, groupID, deviceID: String
 public let generation: UInt64
 public let publicKey: Data
 public let status: AccountGroupPendingStatus
 public let createdAtMilliseconds, expiresAtMilliseconds: UInt64
 public var createdAt: Date { Date(timeIntervalSince1970: Double(createdAtMilliseconds) / 1000) }
 public var expiresAt: Date { Date(timeIntervalSince1970: Double(expiresAtMilliseconds) / 1000) }
}
public struct AccountGroupPendingRequest: Equatable, Sendable {
 public let summary: AccountGroupPendingSummary
 public let draft: AccountGroupApprovalDraft?
 public let event: AccountGroupEvent?
 public let eventHash: Data?
}
public protocol AccountGroupPendingService: Sendable {
 func createGroupJoin(accessToken: String, accountID: String, requestID: String, groupID: String, generation: UInt64) async throws -> AccountGroupPendingRequest
 func groupJoin(accessToken: String, accountID: String, requestID: String) async throws -> AccountGroupPendingRequest
 func groupJoins(accessToken: String, accountID: String) async throws -> [AccountGroupPendingSummary]
 func proposeGroupJoin(accessToken: String, accountID: String, requestID: String, draft: AccountGroupApprovalDraft) async throws -> AccountGroupPendingRequest
 func countersignGroupJoin(accessToken: String, accountID: String, requestID: String, draftHash: Data, subjectSignature: Data) async throws -> AccountGroupPendingRequest
 func commitGroupJoin(accessToken: String, accountID: String, requestID: String, draftHash: Data) async throws -> AccountGroupPendingRequest
 func cancelGroupJoin(accessToken: String, accountID: String, requestID: String) async throws -> AccountGroupPendingRequest
 func rejectGroupJoin(accessToken: String, accountID: String, requestID: String) async throws -> AccountGroupPendingRequest
}
```

Models have throwing public initializers enforcing structural/proof invariants;
no public unchecked decoding path. Stored timestamp integers retain exact positive epochms
within JSON safe integer bound, with exact five-minute TTL; Date accessors are display-only. Serialization may
truncate server microseconds but validation must not authorize based on local
wall-clock. Receive expired state safely instead of pretending every historical
record is currently fresh. IDs canonical lowercase, key-derived identity exact.

- [ ] RED: strict full-record/summary fixtures initially missing model/parser. Test every live and terminal status with allowed retained proofs. Direct initializer rejects wrongproof/action/account/group/generation/device/key/digest; malformed text parser rejects duplicate escaped aliases and trailing input, not just JSONDecoder errors.
- [ ] Implement bounded64KiB schema parser by extending PageParser with dedicated methods in new file. Full wrapper exactly request; list wrapper exactly requests. Fixed field counts and explicit null proofs; max32 unique active summaries. Strings parsed with JSONDecoder only for individual string escape rules, not whole-object duplicate elimination. Final event calls strict wire parser/validation; draft calls accepted strict draft parser. Compare canonical payload and actor signature when both present. Hash32bytes and committed digest match. Terminal rows may retain no proof, draft only, or draft+event, but no eventHash.
- [ ] RED: signed-service request test asserts all eight exact paths/purposes, expected fields, fresh nonce/signature and exact identity publicKey. Create derives publicKey from client.identity, never takes external substitute. Propose requires actor account/device/key equal current client/argument before sending.
- [ ] Implement service using existing send(path:fields:requestDate:). Central narrow pending-send helper performs cancellation before request, after response and in catch; validates expected account/request binding after decoding. No implicit session refresh. Invalid local IDs/token/generation/digest/signature reject before transport. For propose/countersign/commit, when returned retained proof exists its digest must match request; digest is SHA256 of canonical draft payload (draft has no subject proof and cannot call final-event digest validation). Cancel/get may return terminal/committed state from a competing valid action, not fake cancellation success. Membership is never derived here.
- [ ] Regression matrix: every missing/null/wrongtype/unknown/duplicate field; noncanonical IDs/base64/numbers including exponent/fraction/overflow; 65_536 limit and65_537reject;33listitems/duplicates/terminal summaries; bad DER/signature/digest; foreignaccount/request/device; output matches exact localcreate; late successful/error transport aftercancel; all HTTPerror mappings preserved; no extra transport on invalidinput. Use deterministic async gates, not sleeps.

Core signed request assertions:

```swift
let proof = try JSONDecoder().decode(RendezvousSignedEnvelope.self,
    from: XCTUnwrap(request.httpBody))
XCTAssertEqual(proof.publicKey, identity.publicKey.rawRepresentation)
XCTAssertEqual(proof.deviceID, identity.id.rawValue.uuidString.lowercased())
XCTAssertTrue(identity.publicKey.isValidSignature(
    try P256.Signing.ECDSASignature(derRepresentation: proof.signature),
    for: try proof.canonicalPayload()))
XCTAssertEqual(try JSONDecoder().decode([String:String].self, from: proof.payload), expected)
```

- [ ] Create one synthetic immutable cross-language fixture with requested/proposed/countersigned/committed/terminal record JSON, active summary list and exact draft/finaldigest. Go test decodes proof and calls actual HTTP serializer to compare fields/raw canonical JSON; Swift test parses exact fixturebytes and verifies same signedpayload/digest. Do not assert two unrelated independently generated events are interoperability. Any test-only private key must be visibly synthetic fixture-only and never used for live calls.
- [ ] Focused GREEN then affected regressions once, retain output:

```sh
swift test --filter 'AccountGroupPending|AccountGroupEnrollmentServiceTests|AccountGroupServiceTests|AccountGroupApprovalDraftTests'
go test ./internal/accountauth -run TestNativePendingWire -count=1 -v
```

Agent owns Swift/Go caches serially for this task; no SQL required for staticwire
fixture, HTTP implementation report carries guardedSQLflow evidence. Do not claim
native workflow/physical acceptance from transport tests.

- [ ] Scoped diffcheck and commit; report .superpowers/sdd/pending-approval-native-transport-report.md with RED/GREEN, fixtureproof, exactrevision, limitations/cache release. Independent review before controller/native UI task.
