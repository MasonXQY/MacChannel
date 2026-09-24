# Pending device approval lifecycle — implementation outline

Status: next-stage outline, not a dispatched task brief. Before implementation,
resolve exact API contracts against the accepted draft codec and existing SQL
mutation helpers. Product scope is the already approved account-device design.

## Outcome

An existing trusted device can approve a same-account joining device after
verification. The joining device independently confirms the group and countersigns
the exact proposal. Only a committed, verified journal event grants membership.

## Required lifecycle

`requested → proposed → countersigned → committed`

Terminal alternatives: rejected, cancelled, expired, invalidated. A changed group
head requires fresh proposal and signatures, never editing signed bytes. Reads of
terminal requests must not resurrect them. Historical commit retries return their
original identity, not a new assertion of current membership.

### Storage boundary

- Add an incremental pending table; no startup migration. Persist immutable
  account/group/generation/request ID, exact joining device/key, exact joining
  session/audience, server creation/expiry and idempotency binding.
- Approval adds the exact approving session/device, canonical draft bytes and
  digest. Subject countersign adds only its proof over identical payload.
- Authenticate every request before store access and recheck exact sessions inside
  the transaction. `account_sessions.session_id` rotates on refresh: do not
  silently rebind old consent to the new session. Return a restart-required state.
  Original session IDs are immutable historical values, not session-row foreign
  keys: ON UPDATE CASCADE would silently rebind consent; restrictive FKs would
  block legitimate refresh.
- Preserve lock order: account group advisory lock, account lifecycle lock,
  pending row/current journal. Sample database time after locks and before commit.
  Never add an account-lock-to-group-lock callback. Removal that also revokes
  sessions must take its required exclusive account lock initially, not upgrade
  after holding a shared lock.
- Final event insertion and pending consumption share the same transaction. Do
  not call low-level Append followed by a second pending-state update.
- On finalization recheck both sessions, account active, group generation/head,
  actor current membership, subject not already a member, expiry and exact proof.
- Separate historical committed-receipt reads from fresh finalization: authenticate
  the current requester and exact receipt binding, then return only immutable
  request/event identity. Do not reapply membership or reject a historical receipt
  merely because the subject joined or was subsequently removed. Fresh commit
  still requires both original sessions and all current-state checks above.
- Limit active pending requests; enforce idempotency/account/session binding and
  avoid leaking foreign account existence via guessed request/group IDs.
- Persist terminal expiry/invalidation before returning its status; do not roll
  back the status update merely to return a domain error and leave quota occupied.
  Same-key retries cannot extend expiry, replace signed bytes/actor, revive a
  terminal row or change bindings. Event identity is the payload digest, not
  signature bytes.

### Consent and native boundary

- Creating a pending request never joins a group or pins discovery metadata.
- Trusted member explicitly compares verification data before signing a proposal.
- Joining device confirms an independent group anchor/verification value, verifies
  complete journal and current approving membership, and checks retained local
  intent before countersigning. Server metadata cannot validate itself.
- Cancellation, sign-out, account change and removed membership invalidate local
  operation authority before stale asynchronous responses can persist anything.
- Show waiting/expired/retry states plainly; neither a proposal nor a successful
  server response alone displays Joined. Joined derives from verified history.

### Required proofs

Cross-account/device/session requests reject; two concurrent actors cannot commit
conflicting approvals; commit vs cancel/expiry/logout/removal resolves atomically;
DB commit failure produces no grant; restart and lost acknowledgements stay
idempotent; changed-head signatures reject; new session cannot inherit old consent;
both sides must explicitly confirm before membership is applied. Read/list exposes
only this account's authorized pending data. Use isolated SQL guards and scoped
fixture cleanup, including unrelated sentinels.
Include actor removal after countersign, another request admitting the subject,
commit versus removal, and historical receipt reads after either participant is
removed. Test that pending session bindings neither block refresh nor follow it.

## Following integration

Expose strict authenticated endpoints only behind the existing group capability,
then shared native transport/controller and native EN/ZH approvals UI. Verify
physical iPad/iPhone approval with the isolated service before changing transfer
trust. Group-derived relationships must have their own provenance so revoking them
does not erase independent six-digit pairs. Cross-account invitations remain a
separate recipient-selected-device flow and do not inherit to new group members.
