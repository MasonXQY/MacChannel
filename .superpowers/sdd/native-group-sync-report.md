# Native known-group authenticated sync implementation report

## Scope and state

Implemented against base `978a8e2` in the isolated dropmesh-iphone worktree.
Implementation is ready for independent review and coordinator-owned real
Go-handler/native acceptance. It does not constitute deployed group service,
UI consent, phone installation, group discovery, invitations or transfer trust.

Owned files only:

- `Sources/MacChannelCore/Accounts/AccountGroupPage.swift` (new)
- `Sources/MacChannelCore/Accounts/AccountGroupService.swift` (new)
- `Sources/MacChannelCore/Accounts/AccountServiceClient.swift` (narrow changes)
- `Sources/MacChannelCore/Accounts/AccountSessionController.swift` (narrow changes)
- `Tests/MacChannelCoreTests/AccountGroupServiceTests.swift` (new)
- `Tests/MacChannelCoreTests/AccountSessionGroupTests.swift` (new)
- This report.

Reviewed checkpoint implementation/storage/state/proof files were not changed.
Existing unrelated dirty UI/mobile/transfer/release/HANDOFF files were preserved.
The coordinator owns HANDOFF updates. No live credentials, Keychain, phone,
portal, network service, remote database, schema or deployment writes occurred.

## Implementation

`AccountGroupService.groupHistory(accessToken:groupID:)` is a separate public
protocol implemented by AccountServiceClient. Client internal access expanded
only for audience, requestDate and send so the same-module extension reuses
the established nonce/signature/date/origin/HTTPS transport boundary. Identity,
transport, nonce generator and public token access remain unchanged/private.

Signed POST fields are exactly purpose, audience, accessToken, groupID,
afterSequence and expectedHeadHash. The original legacy status switch is
unchanged; group route alone maps404 to AccountServiceError.unavailable and409
to AccountGroupServiceError.changedHead. Error body bytes are never decoded,
surfaced or logged. Existing transport failure mapping is preserved.

The schema-specific raw page reader allows member order/whitespace variations,
requires exactly eight unique decoded names and expected scalar types, and
rejects escaped duplicate aliases, unknown/missing/null fields, noncanonical
integers, overflow, trailing bytes and oversized page/event arrays. It extracts
each exact three-string wire event object and delegates its bytes to the
existing AccountGroupWireEvent.decodeJSON and proof-verifying event initializer.
It is not a generic JSON parser and does not assume JSONDecoder detects duplicate
keys. Limits:65,536 bytes/page,16 events/page, generation1...Int64.max,
head1...8192, cursors0...8192, exact lowercase UUID and canonical padded32-byte
Base64 hash.

Collector verifies request group/cursor correspondence, stable head metadata,
exact successive sequences, group/generation/account continuity, hash links,
forward progress, exact hasMore/next/header relationship and final proven head.
It returns only complete history. A409 discards all collected records and
restarts from0 at most twice, issuing a fresh proof each time; malformed or
unsolicited metadata changes never retry. Both pre-request and post-await
cancellation are checked, including failed transport awaits. No data is pinned
by this layer. At most512 pages and8192 events are accepted. Smaller-than16
nonfinal pages are allowed, but a server using those pages must still finish
within512 requests; this follows the brief's independent bounds. Reviewed Go
returns full16-event nonfinal pages.

Controller gains optional `groupVerifier` defaulting nil in both initializers;
existing UI/login composition remains unchanged. It obtains group service via
the separate protocol, rejects unavailable/signed-out/busy entry, and allows
one sync at a time without blocking logout/refresh. Expired access uses the
existing explicit refresh lifecycle before capture. Credentials never enter
a public snapshot. The captured account ID comes from the active local session.
Revision invalidation occurs when restore/refresh/logout intent starts (before
task suspension) and every published state transition. Before network use,
after fetch, and after verifier save, the fence checks revision, active binding,
identity, phase, lifecycle admission, cancellation and access expiry. Failed
awaits also check the fence. A late checkpoint write may retain anti-replay
knowledge but cannot return membership. Logout never touches checkpoints.

## RED / GREEN and failures

Read the task brief, plan constraints, applicable AGENTS/HANDOFF, TDD skill and
its test anti-pattern reference. Initial two tests were added before production
API implementation: exact signed multipage payload/proof and deterministic
suspended fetch followed by logout. Initial RED was a compilation failure for
missing groupHistory, AccountGroupService, syncGroup and groupVerifier dependency
(`/tmp/native-group-sync-red.log`), not a runnable behavioral failure. An unrelated
missing `try` in the test was corrected before retaining that RED evidence.

After implementation, the initial two tests passed. Explicit temporary behavioral
mutations then changed the signed cursor to0 and removed the session fence:
`/tmp/native-group-sync-mutation-red.log` records2 tests failing3 assertions
(wrong second cursor, unexpected post-logout membership, unwanted checkpoint
advance). Both mutations were fully restored before final GREEN.

Coordinator identified access expiry during a suspended operation as an additional
active-session requirement. The new deterministic clock test first failed3
assertions with the existing implementation: `/tmp/native-group-expiry-red.log`.
The publication fence now checks validNow against access expiry, including before
checkpoint verification; the test passes for both delayed fetch and delayed save.

One adversarial test mistakenly uppercased an all-numeric fixture UUID (no actual
input change). It was corrected to an alphabetic uppercase UUID. No production
behavior was relaxed to address that fixture defect.

## Final verification

- `swift test --filter 'AccountGroupServiceTests|AccountSessionGroupTests'`
  PASS27 tests,0 skipped,0 failures,21.523s.
  Log: `/tmp/native-group-sync-focused-final.log`.
- `swift test --filter 'AccountGroup|AccountSession|AccountServiceClient'`
  PASS95 discovered/executed,2 expected skips,93 passed,0 failures,32.587s.
  Log: `/tmp/native-group-sync-regression.log`.
- The two skips are existing opt-in real Go proof interop and isolated Go account
  session lifecycle tests; this run did not enable their fixtures.
- No compiler warnings in the final focused or regression logs.
- `git diff --check` passed.

Service tests cover first/last/multiple pages, exact route/method/fields/proof/
nonce, whitespace/order,409 discard/restart/exhaustion,404 disabled and legacy
mapping, malformed/duplicate/escaped/null/type/counter/overflow/trailing data,
UUID/hash limits,65,536/65,537 bytes,16/17 events, no progress/false hasMore,
header/cursor/head/sequence/link/generation tampering, bad signatures, transport
failure, cancellation of uncooperative blocked transport,512-page exhaustion,
and successful complete8192-event collection across512 pages.

Session tests cover durable publication, missing pin/wrong account/write failure,
signed-out/default-disabled configuration, restore/login/refresh/logout busy
states, overlapping sync rejection, delayed fetch with logout/relogin/refresh,
logout intent before its response, delayed checkpoint save with logout,
cancellation during fetch/save, access expiry during fetch/save and pre-sync
refresh. They use generated synthetic keys, fake service/transport/storage,
continuations and a controllable clock, with real proof and checkpoint verifier
logic. No timers or private credentials are required.

## Self-review and remaining acceptance

Verified source diff leaves the legacy login status mapping unchanged, does not
add AccountSessionService requirements, does not cache group state into UI and
does not delete checkpoint data. Parser has bounded schema loops and no recursive
untrusted nesting. Maximum-history test exercises both independent bounds.
Credential lifecycle can invalidate sync even when relogin/refresh returns the
same account/session identity. Revision uses UUID to avoid integer wraparound.

No known implementation blocker. Independent review and root's synthetic real
Go-handler/native HTTP acceptance remain required. This report does not claim
real Keychain behavior, deployed endpoint activation, installed UI behavior or
physical device/group acceptance.
