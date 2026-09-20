# Account route admission implementation report

Date: 2026-09-20. Worktree: `/Users/mason/Documents/ChatGPT/Deepseek/MacChannel/.worktrees/dropmesh-iphone`.
Starting revision: `ae3023e5405e215360e346763efaf37e20b76c12`.
Binding scope: `account-route-admission-brief.md` and `account-route-first-slice.md`.
Implementation is an unwired SQL-to-callback primitive; this does not activate account routing.

## Owned files and contract

- `Services/rendezvous/internal/accountgroup/route_admission.go`: `AdmitRoute`, exact authenticated endpoint tuples/public keys/connection generations, expected group/generation, typed already-enqueued outcome.
- `Services/rendezvous/internal/accountgroup/route_admission_test.go`: disposable PostgreSQL integration tests and bounded socket-owner queue fixture.
- `Services/rendezvous/internal/accountgroup/session_mutation.go`: narrow tuple/deadline extraction. Existing `activeGroupSession` signature, nil-session handling, exact tuple matching, and active-time semantics remain intact; its current-time sample is now a separate query after the tuple read.
- This report. No Swift, HTTP, hub, migration, configuration, service, or deployment changes.

Order: READ COMMITTED transaction (not SQL ReadOnly because FOR SHARE is required), existing account-group advisory lock, accounts FOR SHARE, both exact session tuples, complete signed journal replay, exact group generation/member keys, one final `clock_timestamp()` sample checking BOTH endpoints' access/family deadlines, one nonblocking callback, cleanup. No authority is inferred from Discover.

The callback contract requires an atomic check of both connection generations plus a bounded enqueue, true iff enqueued, no network I/O or database reentry, and no blocking. The fixture uses `TryLock` and a nonblocking bounded channel. Both public-key buffers are copied. A `RouteAdmissionOutcome{Admitted:true}` describes an enqueue already performed, not a capability or permission for a later send. SQL cleanup errors are in `CleanupError` with a nil ordinary error, and never cause an internal retry.

Request cancellation is forwarded into a separately controlled transaction context during SQL work. After the final time sample, cancellation propagation must stop successfully and the bounded request context must still be live before callback entry. The callback interval is protected against database/sql's automatic cancellation rollback. Propagation resumes before commit/cleanup; all exit paths cancel the transaction context before deferred rollback, including the stop-success/cancellation race and a broken callback panic. SQL work retains the five-second bound. The callback itself must honor its nonblocking contract.

## Actual RED/GREEN evidence

All commands below ran from `Services/rendezvous`. Tests use only this exact disposable socket fixture:

```sh
export DROPMESH_GROUP_TEST_DATABASE_URL='postgres://mason@/dropmesh_account_group_test?host=/private/tmp/dropmesh-approval-interop.oczZ2o&port=55461&sslmode=disable'
set -o pipefail
```

Before any test write, direct psql validation returned:

```text
SELECT current_database(), inet_server_addr() IS NULL, current_setting('server_version');
dropmesh_account_group_test|t|16.15 (Homebrew)
```

Every reset also runs the existing `groupDB` guard: exact `dropmesh_account_group_test` database name and `inet_server_addr() IS NULL`, then truncates only synthetic tables in this dedicated database. No older cluster was accessed.

1. Test-first initial contract, with a minimal deny-all API stub: `go test ./internal/accountgroup -run '^TestRouteAdmission' -count=1 -v 2>&1 | tee /tmp/account-route-red.log`. Exit 1. Eight failing test entries (four top-level plus four nested), 42 passing entries, zero skips. Useful failures: valid authority never enqueued, valid queue rejection never called the callback, reconstructed-store setup never enqueued, and cleanup-failure outcome never reported admitted. The deny-all stub passing negative cases is not represented as negative-check RED evidence.
2. Implemented admission, then initial GREEN: same command with `/tmp/account-route-green-initial.log`. Exit 0, 50 passing entries, zero failures/skips, 1.637s package duration.
3. Added concurrency/cancellation coverage. Initial concurrency run `/tmp/account-route-concurrency-initial.log` had two fixture errors: separate `clock_timestamp()` evaluations violated the existing exact 90-day family constraint. Changed only fixture construction to a common `now()` sample. This was a fixture error, not a claimed behavioral RED.
4. Deterministic real cancellation bug RED: `go test ./internal/accountgroup -run '^TestRouteAdmissionConcurrencyCancellationInsideCallbackHoldsLocks$' -count=1 -v 2>&1 | tee /tmp/account-route-cancellation-red.log`. Exit 1. With BeginTx bound directly to the request context, the callback was suspended using a TEST-ONLY channel scheduler barrier; cancellation caused actual PostgreSQL rollback and a competing FOR UPDATE revocation committed before enqueue. Exact failure: `request cancellation released SQL authority during callback; revoke committed before enqueue`. The callback performs no SQL/network I/O; the external test connection observes `pg_blocking_pids`. The coordinator explicitly approved this test-only pause to simulate scheduling preemption; the normal queue callback remains nonblocking.
5. Controlled cancellation fix GREEN: `/tmp/account-route-green.log`, exit 0, package duration 10.802s. The competing SQL revocation remains blocked after request cancellation until the callback barrier releases. Pre-callback cancellation has zero callbacks. Five-second SQL timeout releases authority locks and a later fresh call can succeed.
6. Additional negative mutation probe (not portrayed as initial TDD): temporarily replaced ONLY the final `clock_timestamp()` with `transaction_timestamp()`. `go test ./internal/accountgroup -run '^TestRouteAdmissionConcurrencyFinalCommonDeadline$' -count=1 -v 2>&1 | tee /tmp/account-route-deadline-mutant-red.log` failed all four endpoint/deadline leaves with `Admitted:true` where rejection was required. The final source immediately restored `clock_timestamp()`; final GREEN below covers the restored source.
7. Final owned-source focused verification after the deferred-cleanup refactor: `go test ./internal/accountgroup -run '^TestRouteAdmission' -count=1 -v 2>&1 | tee /tmp/account-route-green-final.log`. Exit 0, 84 passing test entries (14 top-level + 70 named subtests; 77 leaf cases), zero failures, zero skips, 16.414s.
8. Final race verification is restricted to the new concurrency slice: `go test -race ./internal/accountgroup -run '^TestRouteAdmissionConcurrency' -count=1 -v 2>&1 | tee /tmp/account-route-race.log`. Exit 0, 26 passing test entries (8 top-level + 18 named subtests; 22 leaf cases), zero failures/skips, no race reports, 15.824s. This was repeated after the final deferred-cleanup refactor; the earlier race run was also green.
9. Existing accountgroup and manual-routing regressions were run once: `go test ./internal/accountgroup ./internal/signal ./internal/presence -count=1 -v 2>&1 | tee /tmp/account-route-regression.log`. Exit 0. accountgroup: 281 passing entries, 75 top-level passes, 0 failures, 3 explicit opt-in diagnostic skips, 41.278s. signal: 1/0/0, 1.054s. presence: 3/0/0, 0.799s. The three opt-in skips are `TestNativeGroupInterop`, `TestPostgresGroupReplayTiming`, and `TestPostgresGroupRestart`; this run is not native interop or database-process-restart evidence. The broad run preceded only the route-specific deferred cancellation cleanup refactor; the shared session helper and all existing components were unchanged afterward. Final focused/race checks cover the final route source.
10. `gofmt -w internal/accountgroup/route_admission.go internal/accountgroup/route_admission_test.go internal/accountgroup/session_mutation.go`; `git diff --check -- Services/rendezvous/internal/accountgroup` (from worktree root) passed.

## Coverage and SQL ordering

Exact account/session/device/audience bindings, malformed fields, cross-account and self rejection, missing/wrong group, zero/wrong/overflow generation, inactive account, malformed journal, removed member, both public keys, both access/family deadlines and future creation times, revoked/refreshed/missing sessions, zero connection generation, full/busy queue, source/destination connection replacement while SQL waits, owned key buffers, at-most-once callback, nil/cancelled/unavailable inputs, retained-session/store reconstruction revalidation, admitted cancellation/commit-error semantics are covered.

Concurrency uses separate real connection pools and PostgresStore instances where a second store operation is involved. Group-writer removal first blocks admission on the same advisory lock. Admission first blocks removal and session revocation through callback completion. Both source and destination expiry are tested after account-lock waiting and after BOTH session tuples have been read but journal replay is blocked. PostgreSQL table/advisory/row lock barriers and database-current-time conditions establish ordering; no arbitrary sleeps establish ordering. The helper's short poll timer only polls observable SQL predicates.

Commit-failure injection wraps the real pgx transaction, checks READ COMMITTED and non-read-only mode, executes actual PostgreSQL reads/commit, then returns a synthetic lost COMMIT reply. It is transport cleanup failure coverage, not a mocked authorization database.

## Remaining gates and limitations

- Independent spec and quality review is required before any caller is wired.
- No live activation, listener, service, HTTP route, socket owner, control message, TURN, or visibility-refresh integration was added. Manual trust publication and defaults are unchanged.
- The primitive assumes authenticated endpoint inputs, a well-behaved nonblocking queue owner, and all account/session/group writers using the existing SQL lock protocol. A callback violating the contract can block; the API cannot safely preempt arbitrary in-process callback code and simultaneously preserve locks through its enqueue.
- A database server/session failure can release SQL locks independently of the process. This is not distributed atomic commit between PostgreSQL and an in-memory queue. The implementation prevents the observed request-cancellation release race; it does not promise the lock guarantee under arbitrary database/network/process failure.
- Final database-current-time validation is one sample immediately before callback entry. No production freshness interval or future-send authorization guarantee is introduced. Scheduling delay and eventual network delivery are separate later integration decisions.
- Full restart with reconstruction is not exercised by the opt-in database-process restart tool; the new test reconstructs independent stores/pools against persisted SQL state and proves no prior admitted outcome can bypass changed membership.
- Logs are local `/tmp/account-route-*.log` artifacts. No real user tokens, Apple credentials, or personal data were used.

## Final race, fixture and ownership handoff

Final read-only inspection used `psql "$DROPMESH_GROUP_TEST_DATABASE_URL" -X -Atc` with:

```sql
SELECT current_database(),inet_server_addr() IS NULL;
SELECT 'accounts',count(*) FROM accounts
UNION ALL SELECT 'sessions',count(*) FROM account_sessions
UNION ALL SELECT 'families',count(*) FROM account_session_families
UNION ALL SELECT 'groups',count(*) FROM account_groups
UNION ALL SELECT 'events',count(*) FROM account_group_events;
SELECT 'other_client_connections',count(*) FROM pg_stat_activity
WHERE datname=current_database() AND pid<>pg_backend_pid() AND backend_type='client backend';
SELECT 'other_transactions',count(*) FROM pg_stat_activity
WHERE datname=current_database() AND pid<>pg_backend_pid() AND xact_start IS NOT NULL;
SELECT 'test_functions',count(*) FROM pg_proc
WHERE pronamespace='public'::regnamespace AND proname LIKE '%test%';
SELECT 'noninternal_triggers',count(*) FROM pg_trigger WHERE NOT tgisinternal;
```

Actual results:

```text
dropmesh_account_group_test|t
accounts|1
sessions|2
families|2
groups|1
events|2
other_client_connections|0
other_transactions|0
test_functions|0
noninternal_triggers|0
```

The final test intentionally leaves only synthetic fixture rows (including revoked families), not a pristine empty database. No custom test trigger/function or active transaction remains. `ps -axo pid,ppid,command | rg '[g]o test|[a]ccountgroup.test'` found no Go test child. All command sessions completed. Root owns database stop and subsequent guarded interop fixture preparation. No old fixture cleanup was attempted.

Final SHA-256 source identities, before the scoped commit:

```text
4d35c8b0bd2bb1b9d81f8a8d5e3f23c325920e756daba9fd6aaed1403b05a8a1  route_admission.go
d009590d94e86aecbc463518f0adf2844d0a5f6b1f408020bfe6fcd58a02421b  route_admission_test.go
6a4157c15e71336535589a0e881eaa617b599561127c37976c4c38af15886a15  session_mutation.go
```

Coordinator granted the scoped commit slot after final verification. On commit completion, Go source/cache, SQL fixture and git index ownership return to root; no additional test or SQL process remains running. Reported commit contains only the three owned Go files and this report. Root will record the resulting commit ID in its integration handoff.
