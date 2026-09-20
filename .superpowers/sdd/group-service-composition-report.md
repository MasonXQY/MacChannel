# Optional group service composition report

Date: 2026-09-20

## Scope and revision

- Starting revision: `24a9882`
- Worktree: `/Users/mason/Documents/ChatGPT/Deepseek/MacChannel/.worktrees/dropmesh-iphone`
- Scope: default-off group composition in the isolated `cmd/accountserver` executable only.
- No accountauth/accountgroup API changes, startup migrations, deployment, Apple credentials/capabilities, remote operations, native toggles, signing, installation, or production data access.

## Implementation

- Added strict `DROPMESH_ACCOUNT_GROUPS_ENABLED` parsing: empty/`0` is disabled, exact `1` is enabled, all other values fail with the existing generic configuration error.
- Preserved the whole-service disabled short circuit before reading the group flag or any other environment/configuration.
- Preserved the login-only default. The three exact group paths are registered only when enabled; no prefix route was added.
- Group-enabled startup read-only checks `public.account_groups` and `public.account_group_events` in addition to the unchanged base schema list.
- Group-enabled assembly constructs exactly one real `accountgroup.PostgresStore` and supplies it as both `Groups` and `Enrollment` to the existing account HTTP handler.
- Updated the README with default behavior, exact flag/routes, migration 010 prerequisite, and explicit non-claims.
- One narrow `ingress_test.go` call-site update was approved by the coordinator because the exact `newServiceMux` signature changed; no ingress behavior changed.

## TDD evidence

Observed RED before each production behavior:

1. Config tests failed to compile because `groupCapability` and `config.groupsEnabled` did not exist.
2. Mux tests failed to compile because `newServiceMux` lacked the required capability argument.
3. Before migration 010, guarded SQL acceptance showed login-only assembly started while group-enabled assembly incorrectly started despite absent group tables.

GREEN results:

- Strict flag table and config propagation passed while `TestDisabledConfigDoesNotReadFiles` retained its panic-on-further-read assertion.
- Disabled/enabled route matrix passed for discover/bootstrap/events alongside existing login, health, and unknown-route behavior.
- Group table checks and real store composition passed the guarded route lifecycle.

During test development, the first synthetic cleanup used a parameterized multi-statement pgx call and failed before mutation; it was corrected to individually checked statements. The first family seed used a one-day absolute lifetime and correctly failed migration 009's 90-day constraint; the fixture was corrected to the real schema contract.

## SQL proof

Fixture supplied and owned by the coordinator:

- Socket directory: `/private/tmp/dropmesh-group-db.igBdYS`
- Port: `55459`
- Database: `dropmesh_account_auth_test`

Before every test mutation, `guardedGroupDatabase` asserts `current_database() = 'dropmesh_account_auth_test'` and `inet_server_addr() IS NULL`. An independent pre-migration psql check returned `dropmesh_account_auth_test|t`.

Missing-schema proof ran before migration 010 while both group tables were absent: login-only build succeeded and enabled build failed generically. After applying the existing `Services/migrations/010_account_groups.sql` to this disposable fixture, the repeatable test uses reversible table renames with cleanup to prove the same boundary without dropping tables or erasing unrelated rows.

The real `buildService` route test uses a synthetic active account/session, opaque token hashes, an ephemeral P-256 device identity, a signed bootstrap Event, and a fresh signed HTTP envelope per request. It proves:

- discovery returns exact `absent` before enrollment;
- bootstrap records the signed anchor;
- discovery returns the exact persisted anchor and pin;
- events returns the exact signed proof and head;
- service reconstruction plus identical-event retry remains one durable SQL event;
- revoking the actual session family makes a fresh-envelope bootstrap return generic HTTP 401 and leaves the event count at one.

No Apple provider request is made because the test pre-seeds the synthetic session.

## Commands and results

RED command:

```sh
go test ./cmd/accountserver -run 'Test.*(GroupCapability|DisabledConfig)' -count=1
```

Expected compile failure observed for missing `groupCapability`/`groupsEnabled`, then PASS after implementation.

Focused SQL/race command (PASS, `ok macchannel/rendezvous/cmd/accountserver 2.332s`):

```sh
DROPMESH_ACCOUNT_TEST_DATABASE_URL='postgres://mason@/dropmesh_account_auth_test?host=/private/tmp/dropmesh-group-db.igBdYS&port=55459&sslmode=disable' \
  go test -race ./cmd/accountserver -count=1 -v
```

Default full module command (PASS, exit 0):

```sh
go test ./... -count=1
```

The default run intentionally skipped the opt-in SQL assembly tests because `DROPMESH_ACCOUNT_TEST_DATABASE_URL` was unset; all packages passed. Command output was captured in the task console; no separate log file was created. The coordinator owns the already-running disposable database and its shutdown.

Actual SQL race output excerpt retained from the task result:

```text
--- PASS: TestGroupAssemblyRequiresSchemaOnlyWhenEnabled (0.02s)
--- PASS: TestGroupAssemblySQLRoutesPersistAndHonorRevocation (0.04s)
--- PASS: TestIsolatedSQLAssemblyDurablyRejectsSignedEnvelopeReplay (0.02s)
PASS
ok  macchannel/rendezvous/cmd/accountserver  2.332s
```

Actual default-suite output excerpt retained from the task result:

```text
ok  macchannel/rendezvous/cmd/accountserver       0.567s
ok  macchannel/rendezvous/internal/accountauth    14.835s
ok  macchannel/rendezvous/internal/accountgroup   1.263s
ok  macchannel/rendezvous/internal/auth           0.582s
ok  macchannel/rendezvous/internal/ingress        0.802s
ok  macchannel/rendezvous/internal/turn           8.688s
```

Because the default command omitted `-v`, Go did not print individual skip lines. The three guarded accountserver tests `TestGroupAssemblyRequiresSchemaOnlyWhenEnabled`, `TestGroupAssemblySQLRoutesPersistAndHonorRevocation`, and the pre-existing `TestIsolatedSQLAssemblyDurablyRejectsSignedEnvelopeReplay` took their explicit no-DSN skip paths in that run.

## Review fixes

Frozen-diff review found two test isolation defects. The original two-step schema rename registered cleanup only after both renames and discarded an emergency restore error; the route fixture also deleted every durable replay nonce. The corrections are test-only:

- schema hiding/restoration now uses checked atomic transactions;
- a forced second-rename collision proves the first rename rolls back;
- a subprocess deliberately fails an assertion after a successful rename, and its parent verifies cleanup restored both real table names;
- route acceptance no longer deletes replay state and proves an unrelated unexpired replay sentinel survives the complete lifecycle.

Focused review-fix command (PASS) and durable log:

```sh
DROPMESH_ACCOUNT_TEST_DATABASE_URL='postgres://mason@/dropmesh_account_auth_test?host=/private/tmp/dropmesh-group-db.igBdYS&port=55459&sslmode=disable' \
  go test -race ./cmd/accountserver -run '^TestGroupAssembly' -count=1 -v
```

Log: `/tmp/group-service-composition-fix-race.log`

```text
--- PASS: TestGroupAssemblyRequiresSchemaOnlyWhenEnabled (0.02s)
--- PASS: TestGroupAssemblySchemaCleanupRegression (0.03s)
    --- PASS: TestGroupAssemblySchemaCleanupRegression/partial_rename_rolls_back (0.00s)
--- PASS: TestGroupAssemblySQLRoutesPersistAndHonorRevocation (0.05s)
PASS
ok  macchannel/rendezvous/cmd/accountserver  1.644s
```

## Acceptance limits

This is local source and guarded-runtime verification, not deployment or native acceptance. Groups remain default-off. The three routes do not grant transfer trust and do not implement approved-device workflows, invitation issuance/acceptance, native account deletion, public activation, or phone installation. Those remain separately approved and tested stages.
