# Native device approval continuation outline

Status: design-to-code integration notes within approved account-device scope;
not yet an implementation task. Resolve exact controller interfaces after native
pending transport review. Do not enable/install a partial workflow.

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
