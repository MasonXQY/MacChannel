# Protected account session verification

Source: initial `4af4132`, security correction `c3c5e22`, restart-test correction `25bca6d`. Independent final task review: Approved, no remaining findings. These are local components, not phone account login.

## Root checks

- Initial full SQL-enabled accountauth race at4af4132: PASS24.804s. Independent review nevertheless found absolute-family expiry and issuance-collision defects; this run was not accepted as final.
- First corrected-source restart prepare1.072s / actual PostgreSQL stop/start / verify0.273s passed. Reviewer identified that its all-negative probe could pass after losing rows; explicitly superseded by the following check.
- At25bca6d: `DROPMESH_ACCOUNT_SESSION_RESTART_PHASE=prepare go test ./internal/accountauth -run '^TestAccountSessionServerRestartProbe$' -count=1 -v` PASS0.587s.
- Actual `/opt/homebrew/opt/postgresql@16/bin/pg_ctl -D /private/tmp/dropmesh-account-db.Kc5rQR/data -m fast -w stop`, then start with Unix socket `/private/tmp/dropmesh-account-db.Kc5rQR`, port55447, empty listen_addresses. Both exited0.
- At25bca6d: same probe with `DROPMESH_ACCOUNT_SESSION_RESTART_PHASE=verify` PASS0.367s. Requires two persisted families with exactly one already revoked; active access authenticates and refreshes; consumed-token replay revokes its successor; separate already-revoked access stays invalid. Missing rows now fail.
- Fresh final `go test -race ./internal/accountauth -count=1` with guarded test SQL: PASS24.942s.

All SQL commands set `DROPMESH_ACCOUNT_TEST_DATABASE_URL=postgresql:///dropmesh_account_auth_test?host=/private/tmp/dropmesh-account-db.Kc5rQR&port=55447&sslmode=disable`. This is the dedicated named local Unix-socket fixture; no production database was touched. Default suite evidence and meaningful REDs are in `.superpowers/sdd/account-sessions-task-10-report.md`.

## Boundaries

No Apple portal writes, real Apple keys, deployment, phone installation or existing trust/transfer mutation. Physical Mason00008140-001A6CE63082201C was rechecked connected. Test database remains running for subsequent local integration. Task11 HTTP implementation continues fromBASE25bca6d; native client plan isb9d28ca. Specific Apple capability approval remains pending. Real device login requires native code, capability/profile, server key custody and approved reachable HTTPS test configuration; current review IPA remains out of scope.
