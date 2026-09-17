# Durable login challenge coordinator evidence

## Implementation under review

- Source commit: `7a1032d`; base plan `d6e1403`.
- New standalone challenge component and migration008 only; account routes and
  Apple exchange/session issuance are not integrated.
- Independent task review **Approved** at7a1032d; no Critical, Important or Minor
  change requests. Review scope is this standalone component, not full login.

## Isolated database

Root created `/private/tmp/dropmesh-account-db.Kc5rQR` via mktemp, owner-only.
PostgreSQL16.15 data directory is its `data` subdirectory; server listens only
on Unix socket in that parent directory, port55447; TCP listen address empty.
Synthetic database `dropmesh_account_auth_test`, no production connection or
credentials. Guard queried current_database and null inet_server_addr before
any migration/test fixture writes.

## Actual server restart acceptance

Root inspected the guarded restart test before invoking it. Implementer had
finished normal DB tests and explicitly confirmed no concurrent DB writes.

Commands from Services/rendezvous used synthetic
`DROPMESH_ACCOUNT_TEST_DATABASE_URL=postgresql:///dropmesh_account_auth_test?host=/private/tmp/dropmesh-account-db.Kc5rQR&port=55447&sslmode=disable`.

1. `DROPMESH_ACCOUNT_RESTART_PHASE=prepare go test ./internal/accountauth -run '^TestLoginChallengeServerRestartProbe$' -count=1 -v`: PASS0.895s. Through the actual component, issued two deterministic synthetic challenges and consumed one.
2. `/opt/homebrew/opt/postgresql@16/bin/pg_ctl -D /private/tmp/dropmesh-account-db.Kc5rQR/data -m fast -w restart`: exit0. Server stopped and restarted September17 at09:40:32+04, socket-only listening reconfirmed.
3. `DROPMESH_ACCOUNT_RESTART_PHASE=verify go test ./internal/accountauth -run '^TestLoginChallengeServerRestartProbe$' -count=1 -v`: PASS0.281s. Previously consumed challenge remained invalid; pending challenge returned its exact original nonce once; subsequent replay was invalid.

This is actual PostgreSQL restart plus independent test-process verification,
not merely reinitializing an in-memory store or reopening a handle. It is not
production service restart or a real Apple login.

## Coordinator final tests at7a1032d

- SQL-enabled `go test -race ./internal/accountauth -count=1`: PASS8.568s.
- Implementer separately reports default `go test ./...` passed with optional
  SQL cases skipped there; default suite is not the basis for SQL acceptance.

## Remaining boundaries

Challenge input device IDs must come from a verified request in the future
adapter. Consumption does not itself authenticate Apple identity, issue an
account session, or establish device trust. No native install, portal capability
change, deployment, production migration or review update occurred in this task.

## Final review and cleanup

Independent review confirmed atomic quota/single-use transactions, post-lock
expiry checks, commit-failure empty outputs, canonical bindings, bounded entropy
attempts and guarded SQL fixtures. Historical RED is recorded implementer
evidence, not independently recreated; root independently inspected production
source and restart probe and ran the actual restart/race checks above.

Root checked committed scope: no existing client/route/auth/transfer source in
task diff; `git diff --check d6e1403 7a1032d` clean. SubmittedIPA SHA256 still
`436ae5d4e20db6b14539d5a6e53e2f62ad9d21a19d1f52fb5d2a87d3698f0ab9`.

After review, root stopped the exact temporary cluster with pg_ctl fast shutdown
and verified `pg_ctl status` reports no server running. Owner-only fixture
directory retained for evidence; no production service was stopped or changed.

Next dependency: Apple code exchange tied to this consumed challenge and verified
subject/audience, then durable revocable device-bound account sessions. Native
Apple configuration and installed two-platform login remain later acceptance
gates. Keep feature branch/worktree intact; no merge, deployment or install.
