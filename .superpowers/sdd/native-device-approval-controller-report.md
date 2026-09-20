# Session-owned native device approval controller

Implemented from task base `80e183a`, preserving coordinator documentation commits
and unrelated dirty files. Scope: the seven specified Swift source/test paths and
this report only. No UI, installed application, Apple capability, personal Keychain,
Go/SQL, service lifecycle, pairing, transfer protocol or automatic-receive change.

## Interfaces and ownership

Both AccountSessionController initializers accept default-nil
`deviceApproval: AccountDeviceApproval?`. Configuration retains DeviceIdentity and
the accepted AccountGroupApprovalIntentStorage. Capability checks identity/binding,
pending/history/discovery protocols and the existing verifier without I/O.

All thirteen brief methods are implemented with the exact requested signatures:
supportsDeviceApproval, pendingDeviceApprovals, deviceApproval(requestID:),
prepareDeviceJoin, confirmDeviceJoin(ticketID:), prepareDeviceApproval(requestID:),
confirmDeviceApproval(ticketID:joiningCode:),
prepareDeviceJoinConfirmation(requestID:memberCode:),
confirmDeviceJoinConfirmation(ticketID:), resumeDeviceApproval(requestID:),
cancelDeviceJoin(requestID:), rejectDeviceJoin(requestID:), and
dismissDeviceApprovalTicket(ticketID:).

Public immutable, Equatable, Sendable values:

- AccountDeviceApprovalTicket: id UUID, operation {requestJoin, approveJoin,
  confirmJoin, verifyCommitted}, expiresAt Date, presentation.
- AccountDeviceApprovalPresentation: requestID, groupID, requestCode?, fingerprint?.
- AccountDeviceApprovalView: summary, role {subject, actor, otherMember}, phase,
  requestCode?, memberCode?, fingerprint?, snapshot?. Phases match the architecture
  report: waitingForMember, needsMemberVerification, waitingForSubject,
  needsSubjectConfirmation, waitingForActor, verifyingHistory, joined, removed,
  rejected, cancelled, expired, invalidated, needsSignIn, retryableFailure.
- AccountDeviceApprovalError: unavailable, busy, invalidTicket,
  verificationMismatch, requestExpired, sessionChanged, requestConflict,
  invalidHistory, secureStorage. Existing transport/checkpoint/value errors remain
  typed at their boundaries; capacity is AccountDeviceApprovalValueError.capacity.

Public tickets/views/presentation descriptions redact their contents. Their
constructors are internal. Comparison values are deliberately exposed properties;
credentials, session identities, raw proofs and intents are not returned.

Controller remains the sole credential actor. The captured value flow
has no session lookup, refresh authority, mutable view dictionary, second actor,
or asynchronous authorization callback. The shared lock-backed authorization is
installed before the first dependency, revoked by operationRevision synchronously,
and checked before issuance/after settlement. Retained intents can only shorten
its confirmation deadline, including nested verifier operations during resume.
Group admission remains held through cancellation/noncooperative dependency I/O.

One private session/revision-bound candidate contains exact retained values.
Confirmation consumes only a matching operation/UUID before suspension. First-device
and subsequent-device preparation invalidate each other's tickets. Fresh request
preparation alone can refresh before capture; existing-request entry points never
use the refreshing session helper.

## Proof, persistence and uncertainty

The implementation directly consumes reviewed RequestContext, Capsule, Proof,
Intent.ActivePhase and full-record storage CAS APIs. Create persists the tuple
before HTTP; actor proposal and subject final event persist exact signatures before
HTTP. Retry never makes a new UUID, timestamp, key or signature. Acknowledgment
times only shorten original deadlines. Subject confirmation retains fetched server
times even if the original Create acknowledgment was lost.

Member proposal requires accepted complete history against its existing pin, exact
current actor membership and absent subject. Confirmation checks the full joining
code and refetches the exact request/predecessor before signing. Subject preparation
imports independent capsule bytes, checks the exact fetched draft and original
session intent, then inspects complete history without pinning. Commit is restricted
to the original retained actor proposal. Countersign receipts remain waiting.

Internal verifier inspect uses the same pure replay implementation as accept;
it checks optional checkpoint owner/generation/anchor/high-water/fork and never
saves. Unreadable storage is not absence. Public confirm/accept contracts remain.

Committed mutation completion requires full replay under retained independent
evidence and the exact final event at its sequence, followed by missing-pin confirm
only with live consent. Existing pins advance without reset. Historical recovery
uses verifyCommitted with fresh independent capsule input and confirmation, bounded
by current access expiry/preparation+300 seconds, never old request expiry. It
re-fetches and verifies current history, including later removal, without mutation
HTTP or signatures.

Coordinator clarified the explicit read-only bullet after the first scoped gate:
code-less list/get never publish membership. Get may independently inspect history
to reject invalid data, but returns verifyingHistory with nil snapshot even when
retained proof exists. Only explicit resume/confirmation returns verified membership;
historical resume inspects only and cannot install a missing pin or reuse consent.

Cancellation invalidates outstanding local authority before suspension, stores
local abandonment before HTTP and cannot claim success when commit won. Lost
responses preserve uncertainty. Acknowledged noncommitted terminal records are
pruned only using exact expected terminal CAS; committed evidence remains retained
for independent history inspection. Unacknowledged abandoned Create is never
silently discarded. It continues consuming the accepted bounded collection capacity;
no account-wide reset, automatic eviction or fabricated cancellation exists.

## Verification evidence

TDD missing-interface RED logs:

- `/tmp/approval-controller-inspect-red.log`: missing inspect API.
- `/tmp/approval-controller-red.log`: missing controller/configuration/value APIs.
- `/tmp/approval-controller-inspect-green.log`: 2 new inspection tests pass.
- `/tmp/approval-controller-initial-green.log`: first 4 controller tests pass.

Behavioral REDs and fixes:

- `/tmp/approval-controller-deadline-red.log`: suspended resume could publish after
  retained confirmation expiry. Shared synchronous authority now tightens to the
  retained deadline before any resume side effect.
- `/tmp/approval-controller-historical-red.log`: expired terminal resume advanced
  checkpoint. Historic session/deadline classification now precedes terminal
  reconciliation and selects nonmutating inspection.
- `/tmp/approval-controller-proof-red.log`: a differently signed final event with
  the same canonical payload could replace subject's exact retained proof on read.
  Subject receipts now match the complete persisted final event.
- `/tmp/approval-controller-current-source.log`: all 20 controller tests pass.

An intermediate full-pair failure came from the fake service downgrading committed
on identical Countersign retry; fake corrected to preserve terminal idempotency.
Initial integration also corrected a fixture type-name collision and Int64/UInt64
constructor conversions. No production checks were weakened.

Required scoped final command, run once after current-source controller tests:

```sh
swift test --filter 'AccountDeviceApproval|AccountGroupApprovalIntent|AccountGroupHistoryVerifier|AccountSessionController|AccountSessionGroupTests|AccountFirstDeviceEnrollment'
```

Before the final read-only clarification, `/tmp/approval-controller-final.log`:
104 tests, zero failures/skips; 12.748 seconds.
20 controller, 4 verification, 20 first-device, 8 intent/storage, 18 verifier,
22 session controller and 12 session-group tests. No warning/error lines.
`git diff --check` clean.

Final clarification RED `/tmp/approval-controller-read-red.log`: code-less committed
get returned joined/snapshot despite the strict observation-only requirement.
Final source focused GREEN (not a repeat of the broad gate):

```sh
swift test --filter 'AccountDeviceApprovalControllerTests|AccountGroupHistoryVerifierTests/testIndependentInspection|AccountGroupHistoryVerifierTests/testInspectionRetains'
```

`/tmp/approval-controller-final-read-green.log`: 23 tests, zero failures/skips,
exit 0, no warnings/errors: all 21 controller cases plus both new inspect cases.
The earlier 104-test result predates only this status-presentation restriction.

Deterministic continuations, no sleeps, cover Create list/insert/HTTP/replace
boundaries against logout/refresh/cancel, suspended member-history preparation,
recovery get/history/inspect-load/accept-load/confirm-load/confirm-save, admission
while storage is outstanding, duplicate/wrong/consumed/dismissed callbacks,
first-device mutual exclusion, request/access expiry, original-session rotation,
reconstructed Create retry, four acknowledgment-loss paths, both-device proof
chain, wrong joining code, substituted capsule/anchor/final proof, old terminal
history, current-member rejection and cancel/commit race. Already-issued writes
may settle; later writes/network/results are rejected.

## Remaining gates

This is synthetic in-process controller/crypto/storage verification, not installed,
live-service, physical two-device, Keychain protection/capacity or UI callback
acceptance. Independent review remains required before UI integration. Group
membership grants no manual-pair trust, transfer relationship or auto-receive.
No broad package, SQL, Go, device build, installation or deployment was run.

All Swift test processes settled; process inventory found no swift-test,
swift-build or MacChannelPackageTests process. Swift cache ownership released
to coordinator at final focused GREEN, before documentation/commit work.

## Independent review rework: exact receipt expiry (2026-09-20)

Resolved the Important finding in native-device-approval-review.md under the bounded
native-device-approval-expiry-fix-brief.md. Tested source commit `05f7ae7` (based on
`93aabe5` plus protected unrelated mobile work). Only AccountDeviceApprovalFlow and
the two owned controller test/fixture files changed; this report is appended.

The existing shared receipt/intent match helper now compares the full saved server
creation/expiry pair. Earlier and later substitutions both fail requestConflict
before subject history/signature/proof write and before actor proposal retry or
Commit. When the original Create acknowledgment was lost, mutation matching
synchronously restricts the existing lifecycle authorization to the newly learned
receipt expiry and immediately rechecks it. The same fence remains active after
history/checkpoint/storage awaits. Create acknowledgment persistence also uses
this guard. No signature bytes, sessions, public API, storage schema or codec changed.

Historical matching validates any known pair but does not impose an expired mutation
deadline on independent verification-only recovery. Code-less reads remain unable
to publish membership/install pins. Explicit verifyCommitted still uses its fresh
independent capsule/current-session ticket and performs no mutation HTTP/signature.

Deterministic RED command:

```sh
swift test --filter 'AccountDeviceApprovalControllerTests/testReceiptExpiry'
```

`/tmp/approval-expiry-review-red.log`: 4 tests, 9 failed assertions, exit 1.
Observed effects include Commit requests after timestamp substitution and a durable
subjectCountersigned transition after learning an already expired receipt or after
an earlier learned expiry passed during a suspended history dependency. Known-time
subject cases also showed the refetch proceeded to a later history dependency.
Failures did not print credentials or complete proof/intent values.

The same selector after the narrow fix: `/tmp/approval-expiry-review-green.log`,
4 tests, zero failures/skips, exit 0. Tests cover earlier expired, earlier still-valid
and later timestamp substitutions for subject and actor, nil acknowledgment after
a real lost Create response, and a newly learned five-second remaining window that
expires while history is held. The gate is released before any throwing assertion
or result await. Assertions count signed-phase persistence/HTTP and retain the exact
original unsigned record, rather than relying only on a thrown error.

Final controller group, run once:

```sh
swift test --filter AccountDeviceApprovalControllerTests
```

`/tmp/approval-expiry-review-final.log`: 25 tests, zero failures/skips, exit 0,
1.129 seconds, no warnings/errors. Includes existing exact-proof loss/restart,
session lifecycle, independent historical recovery/removal, and code-less read
regressions. Self-review confirmed all known receipt-to-mutation paths reach the
shared match fence; no weaker parallel validator or new actor was introduced.
`git diff --check` clean. No UI suite, installation, live activation, Go/SQL or
personal Keychain operation. Swift processes settled and cache ownership released
before source/report commit work. Frozen-delta independent rereview remains required.
