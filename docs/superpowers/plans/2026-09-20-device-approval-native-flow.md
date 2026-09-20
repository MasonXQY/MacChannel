# Native device approval continuation outline

Status: design-to-code integration notes within approved account-device scope;
not an implementation task itself. The executable continuation is
2026-09-20-native-device-approval-controller.md, after intent review. Its explicit
verifyCommitted ticket clarifies historical receipt recovery: new independent
comparison and consent can verify current history without reviving an expired
mutation ticket or old session. Do not enable/install a partial workflow.

## Placement and user tasks

Keep Send/History/Devices tabs unchanged. In Devices, personal device-group status
belongs with account controls; a compact pending-request count opens a focused
native list. A request opens one detail sheet, not a second long home section.
Only intentional affirmative controls invoke signing. Technical proof/hash/session
details are not exposed in routine rows. Security comparison has clear instructions
because a signed-in account alone does not establish device trust.

- No group: existing explicit first-device join remains.
- Existing group but no verified local membership: Request to join, then waiting,
  expiry/retry/cancel. No Joined badge from successful HTTP response.
- Current member: pending inbox, request detail, deliberate verification then
  Approve or Reject. A proposal is Waiting for confirmation, not Connected.
- Joining device: exact proposed group and approving device verification, explicit
  confirmation, then waiting for original approving device to finish.
- Approving device: when the subject countersigns, commit the exact consented
  proposal; no fresh dialog for a network retry of the identical retained intent.
- Committed: fetch and verify complete journal, then show group membership. Actual
  automatic transfer relationship remains gated by provenance integration.

## Controller authority and storage

### Implementation placement after intent types land

Keep credential ownership and operation admission in AccountSessionController.
Its public approval methods are thin actor-isolated wrappers that capture one
current session/revision, consume a matching ticket before suspension, hold the
existing group operation admission, and invalidate their synchronous authorization
on exit. Existing-request operations use a new no-refresh capture helper. Fresh
join preparation alone may refresh before capture. The optional approval
configuration defaults to nil in both initializers.

Put proof preparation/replay and awaited service/storage steps in a focused
internal value helper, AccountDeviceApprovalFlow.swift. It receives immutable
captured context and the existing lock-backed verification authorization; it is
not a second credential actor and cannot refresh or look up a newer session.
Every signature and dependency issuance must synchronously require authorization,
with another check after return. Controller wrappers additionally recheck their
captured revision before installing a ticket or publishing a result. This keeps
the existing session file from absorbing all request/proof parsing logic without
exposing mutable session state or introducing an async authorization race.

The helper returns immutable proposed tickets/results; it cannot install a UI
ticket itself. A cancelled/stale result is discarded. Tickets bind the operation,
exact request/intent/session/key, verified predecessor and expiry. Read operations
return presentation state only. An explicit resume may reissue Create using the
same already-persisted subjectRequested tuple after a lost acknowledgment; it must
never allocate a new request ID or silently sign a replacement proof.

Add an internal, authorization-fenced read-only history-verifier operation for
validating an independently supplied anchor against a complete candidate journal
and any existing checkpoint. It must not persist a new pin/head during subject
preparation. Reuse the same pure replay/high-water rules used by accept rather
than introducing a weaker second journal validator. Existing public confirm and
accept behavior remains unchanged. Tests must distinguish zero writes on this
preparation path from normal current-member checkpoint advancement.

Use an internal verifier entry point with these exact inputs (not a public
unguarded alternate trust API):

```swift
func inspect(history: [AccountGroupEvent], binding: AccountSessionBinding,
             accountID: String, groupID: String, expectedGeneration: UInt64,
             expectedAnchorHash: Data,
             authorization: AccountGroupVerificationAuthorization) async throws
    -> AccountGroupSnapshot
```

It holds the verifier's existing admission until storage reads settle, validates
the caller-supplied independent anchor, replays the complete bounded history, and
checks any stored checkpoint's exact generation/anchor and sequence/hash prefix.
An absent checkpoint is permitted only for this nonmutating inspection; malformed
or inaccessible storage is not absence. It never calls storage.save. Existing
checkpoint acceptance and this inspection should share one pure replay routine,
not duplicated validation loops. Root tests require a counting fake storage with
zero writes for valid unpinned inspection, and rejection of rollback, fork,
cross-group/owner, invalid signatures and stale lifecycle authorization.

When preparing a member proposal, its independently trusted anchor hash can be
derived from history[0] only AFTER that same full history was accepted against
the existing checkpoint. An unverified discovery anchor never substitutes for
that check. Joining inspection verifies the pending draft's predecessor equals
the inspected head and its actor is a current exact-key member. After a committed
receipt, inspect the full journal under the retained independent anchor and
require the exact countersigned event at its sequence before installing a missing
pin and accepting current history. A later removal remains visible as removal.

Reuse AccountSessionController lifecycle revision and synchronous verification
authorization. Expose operation-specific expiring tickets, not access tokens or
raw signing closures, to UI. App views do not call service directly. Pending
controller must preserve exact account/session/device/audience bindings across
all awaits and before storage/signature/HTTP issuance. Session refresh invalidates
unfinished consent; do not quietly refresh and retry a five-minute request.

Joining intent is durable before Create HTTP, includes exact local identity/key,
requestUUID/account/group/generation/original session and binding, and cannot be
replaced on lost acknowledgment. Member proposal is durable before Propose HTTP,
and retains exact draft/digest and original session for resumable Commit. Storage
has the same ownership/bounds/check-after-await safeguards as bootstrap intent;
no clearing other account or current replacement attempt. Cancellation, logout,
account replacement and device removal synchronously invalidate local authority.

Read operations may restore status for display, but cannot automatically restore
an unconsumed UI consent ticket, sign, pin an anchor or create a request. Explicit
action is required after reconstruction before signing. Historical committed
receipts are hints to fetch journal, never snapshots of current membership.

## Independent trust verification

Member validates its existing checkpoint and current journal before preparing an
approval; candidate subject key is checked against joining device's verification
display. Joining device verifies the member-supplied group anchor through an
independent comparison/transfer, not a server response trusting its own anchor.
Use existing event canonical bytes and exact key representations. Neither a
server group display name nor matching account identity is a trust anchor.

Before implementation fix a single interoperable comparison format and test
vectors for the independent verification display/input. It must bind the request,
both identities, account/group/generation and anchor, be domain-separated, and
not use the old six-digit pairing code as a cryptographic fingerprint. For a QR
alternative carry the full expected anchor hash and bounded exact context, never
tokens/private keys; parsing or scanning alone does not authorize consent. Manual
entry must be possible if camera permissions are unavailable. No capability or
permission prompt may be silently added as an assumed setup step.

## Presentation and acceptance

Reuse existing Observable model style and small native Form/Section components;
selected request drives one sheet, with scoped ticket identity and no competing
booleans. At least44pt controls, dynamic text wraps without compressing comparison
strings, EN/ZH, iPhone393width and iPad834width including accessibility sizes.
Loading/error/waiting/expired/cancelled/rejected/removed states are explicit.
Refresh follows foreground view lifecycle with one coalesced operation, manual
refresh always available. No network task starts from body; no unbounded polling
or background receiving promise. Pending polling uses bounded backoff and must
respect existing60requests/minute source allowance for multiple devices. A
notification, when configured later, opens/refreshes inbox only and cannot approve.
Reject/cancel completion reflects returned terminal state; commit winning a race
must not be shown as successfully cancelled.

Model tests must use actual controller with gated dependencies for logout races,
late responses, duplicate taps, stale ticket callbacks and exact retained retries.
Unit tests additionally cover key/account/request/anchor substitution, server-only
selfpin attempts, rollback/fork/removedmember histories, original actor offline,
subject session rotation and zero trust mutations before both confirmations.
Native UI evidence must exercise real confirmation callback ordering, not only
inert screenshots. Final actual development-service two-device enrollment test
must prove which identities joined and compare committed journal receipts, while
preserving existing six-digit pairs and files. Source tests are not physical
acceptance and group membership alone is not transfer acceptance.
