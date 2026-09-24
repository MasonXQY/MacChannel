# Standalone durable account login challenges — 2026-09-17

## Scope and implementation

Implemented Task 1 from `.superpowers/sdd/task-1-brief.md` in the existing
`feature/dropmesh-accounts` worktree. Starting plan revision: `d6e1403`;
coordinator-only documentation subsequently added `697d9c2` and `33c26c3`.

The component issues independent cryptographic 32-byte ID and nonce values,
returns canonical unpadded base64url, and stores only the ID's SHA-256 digest.
Configuration is cloned, with strict audience and canonical lowercase UUID
validation. UUID validation deliberately imposes no version or variant bits.
Entropy injection is private to package tests and protected by a mutex. Equal
ID/nonce values are refused, collision attempts are bounded at three, and
existing rows are never replaced.

Issuance uses a READ COMMITTED transaction and the distinct PostgreSQL advisory
lock domain `dropmesh:account-login-challenges:issue:v1`. After acquiring the
lock it samples database wall time once, removes expired challenge rows, and
enforces 10,000 global / 5 per-device pending records across all audiences and
service instances. The database enforces an exact five-minute lifetime.

Consumption locks the row with ID hash, authenticated device, and audience
bindings. Only after row acquisition does it sample `clock_timestamp()`, require
`created_at <= now < expires_at`, delete the row, validate the stored nonce
length, and commit. Nonce output is released only on successful commit. Wrong
bindings do not consume the rightful challenge. A later Apple exchange failure
requires a new challenge; this does not provide whole-login idempotency.

Both operations impose a five-second default context deadline while respecting
an earlier caller deadline. All failures return empty output and bounded generic
sentinels; database/entropy error strings, SQL, and inputs are not wrapped or
logged. Cancellation is represented by the unavailable sentinel. There is no
memory fallback or background cleanup goroutine.

Migration 008 creates only `account_login_challenges` and its device/expiry
indexes, idempotently. The constructor does not migrate. No deployed database
was contacted or migrated.

## TDD evidence

Before implementation, API/type/error scaffolding compiled and methods returned
the unavailable sentinel. The SQL RED test deliberately did not apply the yet
unwritten migration; it reached and failed the real Issue behavior assertion.
The database guard had already verified the isolated database name and socket
connection. This was an assertion failure, not a missing-symbol compilation
failure.

Working directory for all commands: `Services/rendezvous` in this worktree.
For the SQL commands only, the root-supplied synthetic fixture was set as:

```sh
export DROPMESH_ACCOUNT_TEST_DATABASE_URL='postgresql:///dropmesh_account_auth_test?host=/private/tmp/dropmesh-account-db.Kc5rQR&port=55447&sslmode=disable'
```

This URL contains no credentials and refers only to the temporary local test
server. Its path is ephemeral and will need a new root-provisioned fixture after
that server is removed. The implementer did not start or stop PostgreSQL.

Preimplementation RED command:

```sh
go test ./internal/accountauth -run 'TestLoginChallenge(Configuration|InvalidInputs|DurableOneUse)$' -count=1 -v
```

Observed exit 1:

```text
TestLoginChallengeDurableOneUse: issue: login challenge unavailable
TestLoginChallengeConfiguration: invalid config accepted: []
TestLoginChallengeInvalidInputs: device accepted "": login challenge unavailable
FAIL macchannel/rendezvous/internal/accountauth 0.827s
```

The initial behavior failures were followed by real implementation and expanded
SQL coverage. Additional deadline/commit-failure and exact-boundary checks were
added during self-review; they are verification coverage, not claimed as
separate preimplementation RED cycles. The timestamp predicate was extracted
without changing its behavior to permit exact-equality boundary assertions.

Final GREEN commands and observed results:

```text
go test ./internal/accountauth -run LoginChallenge -count=1 -v
PASS; 14 top-level tests, 2 nested commit-failure cases; 6.258s
ServerRestartProbe SKIP (explicit opt-in only)

go test -race ./internal/accountauth -count=1
PASS macchannel/rendezvous/internal/accountauth 7.908s

# Database environment absent for the default suite:
go test ./...
PASS all packages; accountauth 1.305s; other tested packages cached
```

The first two commands actually executed SQL tests against the isolated
PostgreSQL 16.15 fixture; they did not silently skip SQL acceptance. The default
full suite intentionally skipped opt-in SQL cases and therefore is not separate
database acceptance. No race detector findings or other test failures occurred.

## Coverage and fault injection

- Invalid/nil configuration; audience UTF-8, byte length, whitespace/control,
  duplicate and 1–16 count boundaries; allowlist cloning and exact membership.
- Canonical UUID shape, invalid challenge length/padding/alphabet/noncanonical
  tail bits, nil receiver/context, canceled context, and empty failure outputs.
- Canonical independent ID/nonce encoding, hash-only ID storage, nonce storage,
  exact TTL, entropy failure/short read, equal values and bounded collision
  rejection while preserving the original row.
- Fresh migration and repeated migration preserving a live record; schema
  checks reject invalid hash/nonce lengths, audience byte counts and TTL.
- Thirty-two consumers across two service objects and independent pools:
  exactly one returns the correct nonce, all others return invalid and empty.
- Concurrent issuance across pools: exactly five admitted, including multiple
  audiences sharing the device quota; 10,000-row global capacity; consuming or
  expiring rows frees capacity, and issuance purges only the challenge table.
- Wrong device/audience, replay, expiration, future creation, unrelated-record
  preservation and exact expiry equality through the production pure predicate.
- Actual PostgreSQL advisory and row-lock contention, observed through
  `pg_stat_activity` without timing sleeps: canceled lock waits roll back;
  issuance samples time after lock acquisition; a row expired by the lock owner
  is rejected after waiting consumers acquire it.
- Five-second default operation timeout and earlier caller deadline. Canceled
  row-lock wait releases no nonce and leaves the live challenge usable.
- Closed handles fail generically; reopening independent handles proves pending
  rows survive and consumed rows do not return.
- Real COMMIT failures are induced using temporary deferred constraints solely
  on the new synthetic table: unique nonce for Issue and a self-referencing
  nonce/hash foreign key for Consume. Each fixed-name fixture constraint is
  removed through immediately registered cleanup. Failed Issue returns no
  challenge and persists no extra row; failed Consume releases no nonce and the
  failed deletion rolls back. These are test-only fault injections, not schema
  or production behavior changes.

Every SQL test checks `current_database() = 'dropmesh_account_auth_test'` and
`inet_server_addr() IS NULL` before migration or mutation. Tests execute
serially, touch no existing table, and perform no broad schema resets. Guard,
migration, fixture mutation, and wait observation use bounded contexts.

## Actual server restart gate

`TestLoginChallengeServerRestartProbe` is implemented but intentionally excluded
from ordinary runs. The coordinator owns the real server lifecycle and runs:

```sh
DROPMESH_ACCOUNT_RESTART_PHASE=prepare go test ./internal/accountauth -run '^TestLoginChallengeServerRestartProbe$' -count=1 -v
# Coordinator restarts exactly the synthetic PostgreSQL server.
DROPMESH_ACCOUNT_RESTART_PHASE=verify go test ./internal/accountauth -run '^TestLoginChallengeServerRestartProbe$' -count=1 -v
```

Prepare uses deterministic test-only entropy to issue two synthetic challenges,
consumes one, and leaves the other pending. Verify requires the consumed one to
remain invalid and the pending one to return its exact stored nonce once, then
rejects replay. It does not expose fixture values in logs. Handle reopen is
proven above; actual server restart is not claimed by the implementer and must
be recorded separately by the coordinator.

## Self-review and integration limits

Reviewed final code against all brief sections, transaction ordering, output
release points, migration scope, lock domains, and generic failure paths.
`git diff --check` passed. No unresolved implementation finding was identified.
The test file remains one focused PostgreSQL integration suite as requested;
no dependencies or unrelated abstractions were introduced.

The future coordinator must derive `authenticatedDeviceID` from authenticated
device possession. This component validates shape and binding only. Only a
successful `Consume.Nonce` may supply `AppleIdentityValidator`'s server-owned
expected nonce; never accept an expected nonce from the caller. Existing Apple
identity and key-provider source files are unchanged.

This is a locally verified standalone component, not an installed account
login flow. No production route, existing device authentication, pairing,
transfer, session, device grant, native client, Apple capability, portal,
production deployment, real Apple token or private key was changed or accessed.
The dirty client/release work was preserved. Runtime Apple login, installed
native behavior, code exchange and sessions remain unproven/out of scope.

Owned files:

- `Services/rendezvous/internal/accountauth/login_challenges.go`
- `Services/rendezvous/internal/accountauth/login_challenges_postgres.go`
- `Services/rendezvous/internal/accountauth/login_challenges_test.go`
- `Services/rendezvous/internal/accountauth/login_challenges_postgres_test.go`
- `Services/migrations/008_account_login_challenges.sql`
- `docs/acceptance/account-login-challenges-20260917.md`
