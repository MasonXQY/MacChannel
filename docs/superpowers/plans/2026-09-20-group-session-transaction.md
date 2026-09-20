# Session-fenced group mutation implementation plan

> **For agentic workers:** Use subagent-driven-development and test-driven-development within the approved account feature scope.

**Goal:** A group bootstrap cannot commit on an account session revoked or replaced before its mutation transaction obtains authority.
**Architecture:** Carry the authenticated session identity, not its bearer token, across the HTTP/store boundary. Revalidate that identity under the account row lock already shared by journal mutation and session lifecycle operations; preserve the lock through commit.
**Tech Stack:** Existing Go accountauth/accountgroup and PostgreSQL; no new dependencies or migrations.

## Global Constraints

- Apple login alone grants no group membership or transfer authority.
- Preserve legacy pairing, transfer protocol, submitted builds, production services and unrelated work.
- No deployment, real credentials, UI, installation or default server assembly enablement.
- No bearer tokens in group persistence or logs. No changes to journal signatures, hash chain, checkpoint or idempotent historical retry semantics.
- Tests use only synthetic sessions and the named Unix-socket `dropmesh_account_group_test` database.

### Task 1: Transactional session-bound bootstrap and HTTP wiring

**Files:** narrowly modify `Services/rendezvous/internal/accountgroup/postgres.go`; create `session_mutation.go` and `session_mutation_test.go` in that directory; modify `Services/rendezvous/internal/accountauth/group_enrollment_http.go` and `group_enrollment_http_test.go`. Existing journal/session tests may receive only required interface compatibility adjustments. No session login/logout algorithm changes.

**Interfaces:** retain the low-level Actor and existing Bootstrap/Append behavior for existing internal journal callers. Add a distinct authenticated mutation API; HTTP must require it and cannot silently fall back to the low-level method.

```go
type SessionActor struct {
    AccountID string
    SessionID string
    DeviceID string
    Audience string
}
var ErrGroupSessionInvalid = errors.New("invalid account group session")
func (s *PostgresStore) BootstrapAuthenticated(ctx context.Context, actor SessionActor, event Event) error

// In accountauth; replaces Bootstrap in this optional dependency contract.
type AccountGroupEnrollment interface {
    Discover(context.Context, accountgroup.Actor) ([]accountgroup.Event, error)
    BootstrapAuthenticated(context.Context, accountgroup.SessionActor, accountgroup.Event) error
}
```

- [ ] Write a behavioral failing test: seed active account, session family and current session; retain SessionActor; revoke family; call BootstrapAuthenticated with a valid self-signed bootstrap. Expect ErrGroupSessionInvalid and zero groups/events. Also prove a live exact session succeeds.
- [ ] Implement strict canonical UUID validation for all three IDs, nonempty valid UTF-8 bounded audience matching the session contract. Use the existing five-second mutation context. Refactor the single existing mutate transaction narrowly to accept an optional authenticated actor without duplicating journal replay/append logic. The authenticated wrapper always supplies it; low-level callers remain explicitly documented as caller-authorized journal primitives.
- [ ] After advisory group lock and `activeAccount(..., true)` obtain the exact session under that account FOR SHARE lock. Session lifecycle methods already hold the same row FOR UPDATE before changing sessions/families. Query uses all bindings and samples database time AFTER lock acquisition:

```sql
SELECT se.created_at,se.access_expires_at,f.created_at,f.absolute_expires_at,
       f.revoked_at,clock_timestamp()
FROM account_sessions se
JOIN account_session_families f ON f.family_id=se.family_id
WHERE se.session_id=$1::uuid AND f.account_id=$2::uuid
  AND f.device_id=$3::uuid AND f.audience=$4
```

Reject absent/revoked/current or family timestamps in future/access or family expiry at-or-before database time. Database errors return ErrGroupUnavailable, not authentication rejection. Recheck this same session/expiry immediately before both normal commit and historical retry commit; retain the account lock throughout. Failure rolls back every insert and emits no success. No check outside the transaction can substitute for this.
- [ ] HTTP builds SessionActor from the already validated Authenticate result; event actor still must match signed-envelope device. Map ErrGroupSessionInvalid to generic401 `authentication_failed`, unchanged group409 and unavailable503. Discovery and optional dependency404 remain unchanged. Add real signed-envelope tests asserting all four fields passed exactly and session rejection mapping; dependency that only implements old Bootstrap is not a valid enrollment dependency.
- [ ] SQL tests cover wrong account/device/audience/session, missing/revoked/rotated session, deleting account, access/family expiry and future creation, exact historical retry after revocation rejected, valid retry no duplicate, unavailable/cancelled context with no output. Use synthetic hashes/IDs, never real credentials.
- [ ] Exercise two real DB connection orderings with bounded observed lock waits (not fixed sleeps): lifecycle transaction holds account FOR UPDATE, mutation waits, lifecycle revokes/rotates/deletes/expires and commits => no append; mutation holds account FOR SHARE through event insertion, lifecycle UPDATE waits until mutation commits => first authorized mutation succeeds and later replay fails. A test-scoped trigger/advisory gate may block insertion to expose the second ordering; clean it with t.Cleanup. Verify timeout cancellation rolls back. Test access expiry while blocked and after initial authorization before commit using the gate. All helper connections and goroutines must join/close.
- [ ] Coordinate fixture lifecycle with root. Run focused behavioral RED then GREEN; run `go test -race ./internal/accountgroup ./internal/accountauth -count=1` with the named local DSN and existing required migration fixture. Run `go test ./...` once. Record which SQL tests ran versus skips.
- [ ] Scoped commit; report `.superpowers/sdd/group-session-transaction-report.md` with exact changes, RED/GREEN commands/counts/logs, remaining boundaries and released processes. Root performs independent review before default assembly or live mutations.

## Next integration

Real Swift-Go enrollment, explicit native UI and signed physical-device acceptance remain required. Subsequent-device pending approvals must use the same transactional session authority principle for both parties; this task does not claim those workflows or invitations complete.
