# Native device approval controller implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Connect the reviewed pending transport and durable intents to explicit native approval actions, with no transfer trust granted from a receipt alone.

**Architecture:** AccountSessionController remains the sole credential/lifecycle owner. Thin actor-isolated wrappers capture exact session context and use a focused immutable flow helper with synchronous invalidation fences. Read-only history inspection shares the existing verifier's replay rules without creating a pin.

**Tech Stack:** Swift actors, Foundation/CryptoKit, reviewed account services and intent storage, deterministic XCTest gates.

## Global Constraints

- Existing manual pairing, transfer protocol, installed apps and live services remain unchanged.
- No UI, provisioning, Keychain access using personal data, installation, deployment or feature activation in this task.
- Apple login alone does not establish device trust; an untrusted server response cannot independently authorize its own anchor.
- Original session identity, request ID, exact key bytes and signed payloads survive retries unchanged; refresh cannot inherit unfinished approval consent.
- No tokens, private keys, session IDs or full proof/intent payloads in logs or user-facing results.
- Group membership is not transfer authorization or automatic receive consent.

## Task 1: Session-owned approval workflow and nonmutating history inspection

**Files:**
- Create Sources/MacChannelCore/Accounts/AccountDeviceApproval.swift for optional configuration, immutable public ticket/view and errors.
- Create Sources/MacChannelCore/Accounts/AccountDeviceApprovalFlow.swift for captured-context proof/service/storage orchestration.
- Modify Sources/MacChannelCore/Accounts/AccountSessionController.swift for lifecycle-owned wrappers and private current ticket.
- Modify Sources/MacChannelCore/Accounts/AccountGroupHistoryVerifier.swift for internal inspection and shared pure replay logic.
- Create Tests/MacChannelCoreTests/AccountDeviceApprovalControllerTests.swift and AccountDeviceApprovalControllerFixtures.swift.
- Extend Tests/MacChannelCoreTests/AccountGroupHistoryVerifierTests.swift for inspection/no-write regressions.

Read docs/superpowers/plans/2026-09-20-device-approval-native-flow.md and
.superpowers/sdd/native-approval-controller-contract.md for verified placement,
independent verification format and operation ordering. Consume the reviewed
intent implementation's real interfaces directly; do not create parallel DTOs or
another storage authority. Dispatch requires that intent task to be accepted first.

Intent component interface mapping (verify against its accepted report at dispatch):
AccountDeviceApprovalRequestContext owns the exact request tuple and requestCode;
AccountDeviceApprovalCapsule.parse(_:expectedRequest:expectedDraft:) checks the
independent import. AccountGroupApprovalIntent.Scope binds binding/account/request/
role. Acknowledgment retains server epoch milliseconds. Proof owns draft/capsule
and both comparison digests. ActivePhase is subjectRequested, actorProposed(Proof)
or subjectCountersigned(Proof, AccountGroupEvent); terminal retains that predecessor
plus acknowledged status or local abandonment. Use replacing(phase:acknowledgment:)
and storage.replace(scope:expected:with:) for exact monotonic updates, not a mutable
view-state dictionary. Raw create acknowledgment times may shorten but never extend
confirmationDeadline derived from preparedAtMilliseconds/originalAccessExpiresAtMilliseconds.

### Public controller surface

```swift
func supportsDeviceApproval() -> Bool
func pendingDeviceApprovals() async throws -> [AccountGroupPendingSummary]
func deviceApproval(requestID: String) async throws -> AccountDeviceApprovalView
func prepareDeviceJoin() async throws -> AccountDeviceApprovalTicket
func confirmDeviceJoin(ticketID: UUID) async throws -> AccountDeviceApprovalView
func prepareDeviceApproval(requestID: String) async throws -> AccountDeviceApprovalTicket
func confirmDeviceApproval(ticketID: UUID, joiningCode: String) async throws -> AccountDeviceApprovalView
func prepareDeviceJoinConfirmation(requestID: String, memberCode: String) async throws -> AccountDeviceApprovalTicket
func confirmDeviceJoinConfirmation(ticketID: UUID) async throws -> AccountDeviceApprovalView
func resumeDeviceApproval(requestID: String) async throws -> AccountDeviceApprovalView
func cancelDeviceJoin(requestID: String) async throws -> AccountDeviceApprovalView
func rejectDeviceJoin(requestID: String) async throws -> AccountDeviceApprovalView
func dismissDeviceApprovalTicket(ticketID: UUID)
```

Add default-nil AccountDeviceApproval configuration to both controller initializers.
It contains local DeviceIdentity and AccountGroupApprovalIntentStorage, not tokens.
Capability requires exact matching local identity/binding, group verifier and
pending/history/discovery service support, with no network request.

Ticket has immutable UUID, operation, expiry and credential-free presentation.
Its constructor is internal. One private current ticket additionally captures
session/revision and exact candidate bytes; preparation replaces it. Confirmation
consumes only the matching operation/ticket synchronously before any await.
First-device enrollment and subsequent approval tickets are mutually exclusive:
preparing either clears the other's pending ticket, without deleting durable
intents. Add a regression that an old first-device callback cannot execute after
opening a subsequent-device action, and the reverse ordering.
Expiry is the minimum of preparation+300 seconds, original access expiry and any
known request expiry. Wrong/expired/consumed callback produces invalidTicket.
This bound applies to unfinished request mutations. A historical committed
receipt has a separate verification-only ticket described below; its expired
request deadline cannot authorize mutations and must not make recovery impossible.

View exposes immutable summary, role (subject/actor/otherMember), presentation
phase, optional independent verification codes and optional VERIFIED snapshot.
Use phases from the architecture report. Returned codes are deliberate public
comparison values, not descriptions/log output. Snapshot never comes directly
from discovery or a pending receipt. All receipt types are revalidated at this
dependency boundary, including test/injected service implementations.

### Implementation and tests

- [ ] RED: absent configuration/support returns unavailable and does zero service,
storage or signing work. A read-only list/get never creates a request, restores a
ticket, signs, pins or publishes membership. Build fakes with counted calls and
explicit suspend/release gates, not sleep timing.
- [ ] Add lifecycle wrappers holding existing group admission until a suspended
noncooperative dependency settles. Create authorization before the first side
effect; operationRevision changes invalidate synchronously. Check authorization
before each signature/write/HTTP and after every await. Recheck exact session and
revision before exposing tickets/results. Existing-request paths never call the
refreshing enrollmentSession helper. Fresh prepare may refresh before capture.
- [ ] RED/GREEN internal history inspect signature from native-flow notes:
complete bounded history + independently supplied anchor, optional existing
checkpoint high-water/fork checks, zero saves. Share one pure replay implementation
with accept; preserve all existing confirm/accept error and persistence contracts.
Count writes and reject unreadable checkpoint, rollback, fork, alternate binding,
bad proof, removed actor and invalidated authorization. Hold admission through
blocked loads and release it only after settlement.
- [ ] Fresh subject: discover group only as informational candidate; prepare returns
ticket without intent/server writes. Confirm creates one request UUID/intent,
saves before Create, and records returned times without extending the original
deadline. A lost response retains exact tuple. Existing local uncertainty cannot
be silently replaced or relabelled cancellation. Display request verification code
from the retained context. No membership/checkpoint writes.
- [ ] Member: get request, accept full history against existing pin, require exact
local member and absent subject, then prepare unsigned next-sequence/head event.
Confirm checks full joining code before signing; save the exact actor proposal,
verified anchor and capsule before Propose. Changed account/key/request/head or
code mismatch causes zero signature/Propose/new pin. Any current verified member
may reject; only original actor may resume/commit a retained proposal.
- [ ] Subject: load exact original-session intent; parse independently supplied
member capsule, match fetched draft/local request exactly; inspect full history
under its independent anchor and require proposal predecessor/current actor.
Prepare performs zero signing/new pin. Confirm signs that payload, finalizes and
persists exact event before Countersign. Receipt still means waiting, not joined.
- [ ] Resume is explicit after reconstruction. It may resend retained Create tuple,
actor draft or countersign bytes, and original actor may commit its exact
countersigned proposal. Never generate a new timestamp/key/request/signature in
resume. Confirmed live operation may finish identical commit without a second
approval dialog. Original actor offline remains waiting; no actor reassignment.
- [ ] Committed receipt: verify full journal under retained independent anchor,
require exact finalized event at its sequence, then authorized missing-pin
confirmation and accept. Existing pin is advanced, never reset. Require exact
local device/key in current snapshot for joined; committed-then-removed returns
removed. Historic receipt under a new session is display/history lookup only;
never reuse unfinished old-session consent to sign or create a missing pin.
- [ ] Explicit committed-receipt recovery: if its pin is absent and the original
request/session deadline is past, prepareDeviceJoinConfirmation may accept a
fresh independently supplied member capsule for the exact committed event and
current account/local key. Return a distinct verifyCommitted operation ticket,
bounded by now+300 seconds and CURRENT access expiry, not the old request expiry.
After affirmative confirmation, re-fetch and inspect complete current history,
then install/accept its independently verified pin. This branch never creates,
proposes, countersigns or commits, and never reuses the old ticket. A code-less
status read cannot enter it. Tests cover expired request, rotated session,
already-removed subject, substituted event/capsule and zero mutation HTTP/signing.
- [ ] Cancel invalidates outstanding consent before suspension and records local
abandonment before sending Cancel. A competing committed result is not successful
cancellation. Reconcile acknowledged terminal status and prune only through the
reviewed exact expected-value API. Transport/storage errors retain uncertainty.
Do not add an account-wide reset or automatic record eviction.
- [ ] Test exact create/propose/countersign/commit acknowledgment-loss retries;
same-request two taps; wrong/stale operation ticket; each lifecycle boundary
during storage/network/history suspension; logout/account switch/refresh/restart;
zero unauthorized later dependency after cancellation; source unchanged for
independent manual pairs; terminal and cancel/commit races. Use actual controller
and pure verifier rather than a view-only fake success path.
- [ ] Focused final gate, once current-source tests pass:

```sh
swift test --filter 'AccountDeviceApproval|AccountGroupApprovalIntent|AccountGroupHistoryVerifier|AccountSessionController|AccountSessionGroupTests|AccountFirstDeviceEnrollment'
```

No Go, SQL, device or broad package suite is needed for this component gate.
Report exact interfaces, RED/GREEN commands/logs, deterministic race evidence,
known uncertainty/capacity behavior and cache release at
.superpowers/sdd/native-device-approval-controller-report.md. Scoped commit and
independent review precede UI or actual two-device integration claims.
