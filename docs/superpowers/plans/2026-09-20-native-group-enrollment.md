# Native group enrollment implementation plan

> **For agentic workers:** Use subagent-driven-development and test-driven-development; continue the previously approved account design without routine checkpoints.

**Goal:** Connect the native client to the verified discovery/bootstrap boundary without trusting server-provided pins or silently joining devices.
**Architecture:** First a bounded signed transport API, then actor-private session orchestration and persisted explicit first-device intent. Existing independently pinned history remains the membership authority. Approval/invitation flows remain distinct subsequent slices.
**Tech Stack:** Swift, existing DeviceIdentity, AccountServiceClient, checkpoint verifier and XCTest.

## Global Constraints

- Apple login alone grants no group membership or file-transfer authority.
- Preserve legacy pairing, production services, submitted builds and unrelated dirty work.
- No UI, deployment, capabilities, device installation or real credentials in Task 1.
- Discovery is informational; never pass its returned anchor to confirm as an independent pin.
- Bootstrap acknowledgment is historical recording, not current membership.
- No key upload/synchronization, trust-store insertion or automatic receive permissions.

### Task 1: Native discovery/bootstrap signed transport

**Files:** create `Sources/MacChannelCore/Accounts/AccountGroupEnrollmentService.swift`, `Tests/MacChannelCoreTests/AccountGroupEnrollmentServiceTests.swift`; narrow edits to `AccountServiceClient.swift` and `AccountGroupPage.swift` only when needed for shared strict parser primitives. Report `.superpowers/sdd/native-enrollment-transport-report.md`.

**Interfaces:** add `AccountGroupEnrollmentService: Sendable` with
`discoverGroup(accessToken: String, accountID: String) async throws -> AccountGroupDiscovery`
and `recordGroupBootstrap(accessToken: String, event: AccountGroupEvent) async throws`.
Client conforms. `AccountGroupDiscovery` is Equatable/Sendable absent or present
with immutable groupID, generation, anchor, anchorHash, headSequence, headHash.
Document these as untrusted discovery metadata, never a membership snapshot.
No method creates/signs an event; caller must supply explicitly consented bootstrap.

- [ ] Begin with behavioral failing tests (temporary throwing skeleton is acceptable, remove it). Synthetic transport captures real signed envelopes using existing client initializer; do not use real secrets/network.
- [ ] Discovery sends `/v1/account/group/discover` exact fields `purpose=dropmesh.account.group.discover.v1`, audience, accessToken. Validate canonical account UUID and token before any transport. After reply require exact status absent (one key) or present (seven keys: status,groupID,generation,anchor,anchorHash,headSequence,headHash).
- [ ] Present validation: 64KiB bound, strict duplicate/escaped-alias/unknown/null/type rejection, canonical UUID/base64 hashes32bytes, integer lexical forms only (generation1...Int64.max, headSequence1...8192), valid bootstrap anchor with accountID/groupID/generation matching request/result, computed anchorHash matching. When headSequence1 require headHash==anchorHash; later head is informational, not provable without full history. Use existing strict wire codec for anchor. Preserve existing page API behavior if sharing parser primitives; no broad generic JSON framework.
- [ ] Bootstrap sends `/v1/account/group/bootstrap` exact purpose `dropmesh.account.group.bootstrap.v1`, audience, accessToken, `confirmation=join_this_device`, canonical base64 JSON of existing wire event. Before network validate token, event signature/action bootstrap and actor ID/key exactly match client's identity. Encoded event1...4096bytes. Server authenticates event account; native orchestration will bind current account separately.
- [ ] Ack exact status recorded,groupID,generation,eventHash; strict raw schema and hash/counters; compare every identity/hash to submitted event. Return Void, never membership or trusted state.
- [ ] Only these two paths map404 to unavailable and409 to a new enrollment conflict error. Preserve existing group changed-head and login behavior. No automatic bootstrap retry on409 or transport failure. Check cancellation before request and after both success/error transport returns, including noncooperative fake transport. No token/error-body logging.
- [ ] Tests cover success absent/present/recorded, real envelope signature/payload/path/fresh nonce, all malformed schemas/types/duplicate aliases/trailing data/oversize/counter forms/hash and anchor mismatches, wrong local actor/action/signature, input rejection no requests, exact status mappings without login regression, transport failure, cancellation before and during noncooperative await. Use deterministic bounded gates, no sleeps. Reuse existing test helpers only if actual signatures fit.
- [ ] Run `swift test --disable-automatic-resolution --filter 'AccountGroupEnrollmentServiceTests|AccountGroupServiceTests|AccountServiceClientTests'` and related parser/proof tests if changed. Single Swift cache owner; root does not build concurrently. Scoped commit; report RED/GREEN, commands, warnings, limits. Independent review required before orchestration.

## Following integration boundary

Session actor must retain tokens, bind discovery to current account/revision and
withhold stale replies across logout/refresh. First-device join needs explicit
confirmation and durable locally created signed intent before transmission; retry
must reuse that intent, not generate another group. After acknowledgment confirm
only the locally created anchor then verify latest history. A server-discovered
foreign anchor cannot authorize adoption. Existing groups require independently
confirmed trusted-device approval; no silent self-pin. These behaviors are not
claimed by the transport slice.
