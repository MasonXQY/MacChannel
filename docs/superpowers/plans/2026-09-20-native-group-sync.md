# Native authenticated group sync implementation plan

> **For agentic workers:** Use subagent-driven-development and test-driven-development after native checkpoint task passes independent review.

**Goal:** Fetch and verify a known, independently pinned device group through the native authenticated account session without leaking credentials or accepting late results after logout.
**Architecture:** Add bounded signed group read to AccountServiceClient, then a session-controller entry point that collects pages, invokes durable pinned history verification and fences credential lifecycle across suspension. No group discovery or trust grants in this slice.
**Tech Stack:** Existing Swift Foundation/CryptoKit, URLSession transport, XCTest and reviewed Go endpoint contract.

## Global Constraints

- Apple login does not grant transfer trust. No TrustStore, routing or identity reset changes.
- No live keys, Keychain, service, portal, schema, deployment or phone writes during tests.
- Leave current UI/login/build and unrelated dirty files unchanged.
- Invalid input yields a generic typed error, no partial membership mutation.
- Logout must not erase anti-replay knowledge. No delete/reset checkpoint API.
- Account credentials remain private to AccountSessionController, never in UI snapshots or group responses.

### Task 1: Authenticated native page collection and session-fenced sync

Own new Sources/MacChannelCore/Accounts/AccountGroupPage.swift,
AccountGroupService.swift, Tests/MacChannelCoreTests/AccountGroupServiceTests.swift,
AccountSessionGroupTests.swift; narrow edits AccountServiceClient.swift and
AccountSessionController.swift only. Report .superpowers/sdd/native-group-sync-report.md.
Do not edit already-reviewed checkpoint implementation unless root approves a
concrete API mismatch. Client private access can become internal only where needed
for a same-module extension; do not expose identity, token or generic signing APIs.

Consume reviewed Go group_http.go response and AccountGroupHistoryVerifier.
Expose AccountGroupService protocol with groupHistory(accessToken:groupID:)
returning [AccountGroupEvent], implemented by AccountServiceClient. Expose
AccountSessionController.syncGroup(groupID:) async throws -> AccountGroupSnapshot.
Optional verifier dependency defaults nil in current controller initializers,
so existing UI/login remains unchanged until explicitly wired. Use separate
AccountGroupService protocol rather than adding requirements to existing mocks.

Signed POST /v1/account/group/events exact fields:
```swift
[
 "purpose": "dropmesh.account.group.events.v1", "audience": audience,
 "accessToken": accessToken, "groupID": groupID,
 "afterSequence": String(after), "expectedHeadHash": expectedHead
]
```
Reuse send's proof/nonce/date/HTTPS validation. Group only404 maps unavailable,
409 maps changedHead; legacy login status mapping stays byte-for-byte equivalent.
Error bodies are never surfaced or logged. Response limits remain65536bytes and
16events/page. Complete history maximum8192events. Exactly eight keys:
groupID,generation,headSequence,headHash,afterSequence,nextSequence,hasMore,events.
Use exact lowercase UUID, generation1...Int64.max, headSequence1...8192,
after/next0...8192, strict canonical padded Base64hash32bytes. Raw JSON boundary
rejects duplicate keys including escaped aliases at page/event levels, unknown
or missing keys/null/wrongtype, fractional/exponent/negative/overflow counters,
trailing data, oversized bytes/events. A bounded schema-specific raw parser may
extract event object bytes and call AccountGroupWireEvent.decodeJSON; avoid
reimplementing a general JSON library or claiming JSONDecoder detects duplicates.
JSON member order/whitespace may vary; don't require Go field order.

Each page matches requested group/after and stable generation/headSequence/hash;
next==after+events.count, exact successive event.sequence, event.groupID and
generation match header, hasMore==(next<headSequence). Require forward progress
while collecting, at most512pages. Verify proof on each event and full final
head digest/header consistency before returning. Do not self-pin returned data;
full membership authorization remains checkpoint verifier's job.
On409 discard partial collection and restart from0 up to two restarts (three
attempts total), each fresh signed request. Persistent409 yields changedHead.
Unsolicited metadata changes or malformed page are invalidResponse, not retries.
No partial records returned on failure/cancellation. Check cancellation before
request and after awaits; transport error semantics preserved. No token logging.

Session sync only begins with configured verifier and group service, active
signedIn current session, no restore/login/logout/refresh in progress; fail busy
or needsSignIn appropriately. An expired access token may use existing explicit
refresh lifecycle before capture, then recheck guards; never copy tokens into
snapshot or add a public token accessor. Capture an operation revision and
account/session binding. Bump revision whenever credential/state lifecycle starts
or changes so logout intent invalidates before network awaits. After network
await, before checkpoint verification and after its save await, require same
revision/binding/active session and check cancellation. Derive accountID from
the captured session, not server. Require accessExpiresAt > validNow at each publication
fence, including after a suspended checkpoint save. Expiry during the operation
rejects the result; a later caller may refresh and retry. Add deterministic clock
tests for expiry during fetch and save. Late high-water persistence is allowed only
as anti-replay knowledge; never return membership after lifecycle invalidation.
No cached current group snapshot added to UI in this task. Concurrent sync may
be rejected busy with deterministic tests; do not allow later stale result
after newer successful sync. Logout/session failure never erases checkpoints.

- [ ] RED: signed multi-page request test with exact fields/cursors fails before
  adding group service; deterministic suspended fetch then logout test fails
  without session fence. Use synthetic keys, fake transport/storage only.
- [ ] Implement parser/page collector and narrow send error mapping. Test first
  and last page, multiplepages,409restart/exhaustion,404disabled,no-progress,
  falsehasMore, wrongheaders/sequence/group/generation/head, tamperedsignatures,
  duplicatekeys/escapedaliases/null/boolcounter/exponent/overflow/size boundaries,
  requestsignature/nonce exactpayload, cancelled blockedresponse no partialreturn.
- [ ] Implement controller sync and operation fencing; tests accepted pinned
  chain after durable save, missingpin, wrongaccount, storagefailure, signedout,
  busyrefresh/login/logout, delayedfetch+logout/relogin/refresh rejection,
  delayedcheckpointsave+logout rejection, cancellation and concurrent sync.
- [ ] GREEN: swift test --filter 'AccountGroupServiceTests|AccountSessionGroupTests'
  followed by swift test --filter 'AccountGroup|AccountSession|AccountServiceClient'
  and report counts/skips/warnings. Synthetic-only; no live session access.
- [ ] Scoped commit, independent review, root end-to-end synthetic verification.

This is known-group sync only; separate approved next work is discovery/consent
mutation API, native consent UI, distinct authorization provenance and invitations.
Do not install unchanged UI and claim automatic pairing works.
