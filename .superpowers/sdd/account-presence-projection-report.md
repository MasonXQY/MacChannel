# Account presence candidate projection

Implemented the bounded authenticated source projection prerequisite. This does
not activate account presence, signaling, TURN, or automatic pairing. No hub,
router, schema, deployment, app installation, index, or commit changes were made.

Working tree: `/Users/mason/Documents/ChatGPT/Deepseek/MacChannel/.worktrees/dropmesh-iphone`.
Inspected HEAD: `cae2f5c65b6e06a4ee07fbe6c8e708efb828e1ed`; changes remain uncommitted.
Existing unrelated dirty files were preserved. Root owns HANDOFF integration.

## Contract and implementation

`ProjectPresenceCandidates` validates the source's exact `SessionActor`, parsed
public key bytes, canonical group ID and positive signed-64-bit generation.
It copies the bounded source key. Within a five-second transaction it follows
the existing group advisory lock -> account SHARE lock ordering, reuses
`activeAccount`, `readGroupSession`, and `loadGroup`, and matches source member
ID/key and requested generation against the fully replayed journal. A final
`clock_timestamp()` check after all locks and replay rejects session/family
expiry, revocation and future creation dates. Failed cleanup returns no result.

Returned fields are group, generation, sequence and a newly owned, sorted list
of peer device IDs, excluding the source. The existing validated state enforces
64 total members, hence at most 63 candidates. Terminal empty groups fail source
membership validation. A projection is explicitly never authority; SQL tests
show a projected target without a session and a subsequently removed target
both fail fresh pair admission. Every later pair still needs its own gate.

## Verification and test-first evidence

- Wrote API stub and rejecting-input tests before implementation. Actual no-SQL
  RED: 12 validation assertions failed because the stub returned success.
  `/tmp/account-presence-projection-red.log` (exit 1).
- Wrote initial real-SQL tests before implementation. Root ran actual SQL RED
  against that same stub: 3 top-level tests failed (bounded owned projection,
  invalid source, and projection not pair authority).
  `/tmp/account-presence-projection-sql-red.log` (exit 1, 1.071 s).
- Implemented production method, then actual no-SQL package GREEN:
  `env -u DROPMESH_GROUP_TEST_DATABASE_URL GOCACHE=/tmp/dropmesh-projection-gocache.r6HMef go test ./internal/accountgroup -count=1`
  from `Services/rendezvous`; exit 0, 1.274 s.
  `/tmp/account-presence-projection-green.log`.
- Root ran actual SQL GREEN with `go test ./internal/accountgroup -run
  '^TestPresenceProjection' -count=1 -v`: 5 top-level tests passed, no SQL skips,
  exit 0, 2.803 s. Includes all 16 invalid-source cases and both account-lock
  and journal-lock expiry barriers, with blocking proven by PostgreSQL itself.
  `/tmp/account-presence-projection-sql-green.log`.
- Added two supplementary boundary tests after implementation: terminal empty
  membership plus replacement generation, and failed COMMIT returning no IDs.
  Root ran these against real SQL: both passed, no skips, exit 0, 0.455 s.
  `/tmp/account-presence-projection-sql-extra.log`.
- Final local focused compile/test run passed; SQL-dependent cases intentionally
  skipped without the environment variable. This is not SQL acceptance evidence.
  `/tmp/account-presence-projection-focused-green.log` (exit 0, 1.110 s).
- `gofmt` applied; `git diff --check` passed. Agent directly inspected all three
  root RED/GREEN/extra log files after receiving root results.

Root alone operated the fresh disposable Unix-socket PostgreSQL fixture:
`/private/tmp/dropmesh-presence-sql.rjUENJ`, port 55463,
database `dropmesh_account_group_test`, migrations 001..011. This agent did not
start SQL or run SQL-enabled tests. Tests use the existing exact variable
`DROPMESH_GROUP_TEST_DATABASE_URL` and existing named Unix-socket database guard.
New fixtures insert unique accounts, groups, sessions and token hashes without
truncation or schema changes. The replacement-generation test replaces only its
own newly created terminal journal; it is not a production rebuild implementation.
No old fixture was touched. Root manages cluster shutdown and preservation.

## Exact owned files and SHA-256

- `Services/rendezvous/internal/accountgroup/presence_projection.go`
  `88395f7885597d6ebba280572719d8261d518c331156f21a6aceed301ebd4914`
- `Services/rendezvous/internal/accountgroup/presence_projection_test.go`
  `b6856a54d53817ee4f524b951aaaf77d381d65177145eb9a05b14b5a9ff62705`
- `Services/rendezvous/internal/accountgroup/presence_projection_postgres_test.go`
  `23640f64f08c2058213ad41c470df3065dd272e09c4abc1697495abbb43a58e2`
- This report: `.superpowers/sdd/account-presence-projection-report.md`.

Source/tests frozen for independent review. Go cache is idle and no agent-owned
test processes remain. Remaining work belongs to subsequent presence-hub and
coherent adapter slices, followed separately by TURN and candidate deployment.
