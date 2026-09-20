# Pending approval store implementation plan

> Use subagent-driven-development and test-driven-development; independently review this transactional component before HTTP/native integration.

**Goal:** Persist and atomically complete a same-account, bilateral device approval.
**Architecture:** Extend the existing accountgroup PostgreSQL store, reuse signed draft/final event codecs and exact session guards. Pending state and journal mutation share one transaction. No endpoint or feature activation in this task.
**Tech Stack:** Go, PostgreSQL, existing accountgroup proofs.

## Global Constraints

- Existing manual pairing, transfer protocol, installed apps and live services remain unchanged.
- Pending requests and actor-only drafts grant no membership. Only a fully signed, committed journal transition does.
- Bind immutable exact device keys and original session IDs; never normalize keys or transfer consent across session refresh.
- Preserve group-advisory-lock then account-lifecycle-lock order. No new reverse ordering.
- No startup migrations, real device keys, remote deployment or phone installation.
- SQL tests require the named dropmesh_account_group_test database over a Unix socket before writes; preserve unrelated fixture rows.

### Task 1: Authenticated pending lifecycle and atomic group commit

**Files:** create `Services/migrations/011_account_group_pending.sql`; create `Services/rendezvous/internal/accountgroup/pending.go`, `pending_postgres.go`, `pending_postgres_test.go`; narrow refactor `postgres.go`, `session_mutation.go` to share transaction-local validation/insertion and actor validation. Additional focused `pending_commit.go`/`pending_lifecycle_test.go` permitted if needed to keep responsibilities small. No HTTP, Swift or UI edits.

**Interfaces:** methods on existing PostgresStore. Use these public names and shapes:

```go
type JoinIntent struct {
    RequestID, GroupID string
    Generation uint64
    PublicKey []byte
}
type PendingJoin struct {
    RequestID, AccountID, GroupID string
    Generation uint64
    DeviceID string
    PublicKey []byte
    Status string // requested, proposed, countersigned, committed, rejected, cancelled, expired, invalidated
    CreatedAt, ExpiresAt time.Time
    Draft *WireApprovalDraft
    Event *WireEvent
    EventHash []byte // committed historical receipt only
}
// Every call requires an authenticated current SessionActor from the HTTP layer.
CreateJoin(context.Context, SessionActor, JoinIntent) (PendingJoin, error)
GetJoin(context.Context, SessionActor, string) (PendingJoin, error)
ListJoins(context.Context, SessionActor) ([]PendingJoin, error)
ProposeJoin(context.Context, SessionActor, string, ApprovalDraft) (PendingJoin, error)
CountersignJoin(context.Context, SessionActor, string, []byte, []byte) (PendingJoin, error) // requestID, payload digest, subject signature
CommitJoin(context.Context, SessionActor, string, []byte) (PendingJoin, error) // requestID, digest
CancelJoin(context.Context, SessionActor, string) (PendingJoin, error)
RejectJoin(context.Context, SessionActor, string) (PendingJoin, error)
```

Use existing ErrGroupInvalid/Unavailable/SessionInvalid for uniform failures;
terminal valid statuses return owned records, not errors that undo status writes.
No session IDs/tokens in returned PendingJoin. Public-key proof is validated by
the existing identity derivation matching SessionActor.DeviceID; future HTTP must
also require matching authenticated envelope identity.

- [ ] RED: real guarded SQL test of create→propose→countersign→commit, asserting group remains one member before commit, then two members and exactly one approval event after commit. Build synthetic two-session account fixture with fresh keys and identifiers, never personal identities. Observe missing implementation failure, then implement schema/types/store in stages.
- [ ] Schema stores immutable request/account/group/generation, subject key/device/session/audience, created/expiry/status; nullable actor session/device/audience and exact draft/final wire bytes/digest. Original session IDs are historical values, not restrictive or cascading FKs to rotating account_sessions.session_id. Add indexes for account/status/expiry and unique request ID. Use bound queries, size/status constraints, no raw credentials.
- [ ] Create: current active session, existing group/generation, subject not currently a member, exact key identity. Server clock fixes five-minute expiry. RequestID is caller-retained random UUID/idempotency key. Same immutable input and same original session retry returns existing record without extending expiry. Different binding or reused foreign ID rejects uniformly. Limit32 active requests/account and256 creations/account/rolling24h; expire/invalidate stale rows before capacity checks. Request creates no group event.
- [ ] Reads: current members list active requests for own account; joining device can Get its own request. Current members may Get own account requests. Terminal receipt may be read by original actor/subject device in the same account with a currently authenticated session, even if later removed; it only reports original receipt, never present membership. No foreign-account enumeration or session metadata in outputs.
- [ ] Proposal: exact current original subject session still valid, actor is current member and different device, actor authenticated exact key in draft; draft account/group/generation/subject matches immutable row and seq/head equals current journal+1. Persist original actor session and exact bytes. Proposal timestamp within five minutes of DBnow and at most30seconds future. Different actors/proposals cannot overwrite an accepted proposal. Valid exact-payload retry is idempotent; signatures never redefine event identity.
- [ ] Countersign: caller is exact original subject session; expected digest matches stored draft. Finalize using existing codec; validate current actor membership/head and both original sessions. Save completed exact event without inserting journal or changing membership.
- [ ] Commit: caller is exact original actor session; require countersigned state and expected digest. Under one transaction revalidate active account, both original sessions/expiry, group/generation/head, actor member and subject absent; validate final event, insert journal event and mark committed together. Factor transaction-local helpers from mutate; NEVER call Append then update pending in another transaction. Recheck DBwall-clock/session validity immediately before commit. Failures must not leave partial journal/member/receipt effects.
- [ ] Historical committed retry: authenticate current requester, require original actor device/account and matching request/digest, return immutable receipt before fresh-transition checks. No new event or membership, including after subject/actor removal. New sessions may read committed receipts but cannot resume unfinished consent.
- [ ] Cancel is subject-only; Reject requires current member. Group lock serializes commit/cancel/reject. Terminal rows never revive. Detected expiry/session rotation/head changes mark expired/invalidated durably when possible; final transaction failure must roll back membership, and subsequent authorized Get/Create must materialize stale terminal state so quotas cannot stay occupied. Never commit an invalidated journal event merely to preserve a status update.
- [ ] RED/GREEN adversarial SQL: wrong account/device/audience/session; either session refreshed/revoked/expired; deleting account; tampered draft/digest/signatures; proposal overwrite; head movement and actor removal after countersign; subject admitted by another request; cancel/expiry/logout/removal vs commit; repeated original commit after removal; duplicate input changed binding; quota cleanup; independent store reconstruction/retry; forced commit failure; no session FK blocking refresh; unrelated sentinel rows survive cleanup. Use barriers/locks for race tests rather than sleeps where possible.
- [ ] Run focused new tests while iterating; one SQL-enabled accountgroup package race suite after integration, with root-owned fixture lifecycle. Existing reset helper must not be used concurrently with pending tests. If existing reset helper needs pending-table cleanup for its own fixtures, keep it scoped to named disposable DB and explain compatibility change.
- [ ] Inspect diff, commit only owned files, report `.superpowers/sdd/pending-approval-store-report.md` with exact APIs/schema, RED/GREEN commands and durable logs, acceptance bounds, source revision and released test/cache ownership. No native/deployed completion claims.
