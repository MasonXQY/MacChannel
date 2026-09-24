# Task 3 durable group journal

Base: `38235b0`. Implemented additive migration 010 and standalone accountgroup
PostgresStore. No HTTP, server assembly, native, trust, credentials, deployment,
or production database changes. Fixture lifecycle remains root-owned and running.

## Contract and self-review

- Actor is explicitly a caller-authenticated device-bound session/envelope value;
  storage does not authenticate sessions, owner consent, or fingerprints.
- ReadCommitted writes serialize per account with the specified domain-separated
  transaction advisory lock and active-account FOR SHARE check. Bootstrap pins
  and its proof commit atomically. Only exact canonical retries succeed.
- Reads use account/group-filtered pins and ReadOnly RepeatableRead; all proof
  rows are strictly decoded and replayed through State before committed results.
  Any corruption returns only ErrGroupUnavailable and no partial output.
- Every operation has a five-second context bound; journal max is 8192 with
  an 8193-row overflow probe. No reset, trimming, mutable membership cache, or
  new trust-grant API. Input buffers are copied and returned proofs are owned.
- Schema migration uses IF NOT EXISTS with UUID/FK, positive sequence/generation,
  exact hash size, bounded proof size, and uniqueness constraints.

An explicitly approved scope amendment also changes `state.go`: remove redundant
Validate immediately before Digest in NewState/Apply. Digest still performs the
same complete structure and signature validation before success or mutation.
No signature bypass or Event API change. Store replay compares each SQL row hash
to the State-validated Snapshot head digest instead of validating a third time.
Independent review should check this equivalence expressly.

## Verification

Working directory for Go commands: `Services/rendezvous`.
All SQL test writes require current_database() = dropmesh_account_group_test AND
inet_server_addr() IS NULL before migrations, synthetic seeding, or truncation.
No production credentials were read. Local DSN used for SQL runs:

```text
host=/private/tmp/dropmesh-group-db.igBdYS port=55459 dbname=dropmesh_account_group_test user=mason sslmode=disable
```

- Initial RED: TestPostgresGroupRoundTrip reached Bootstrap API stub and failed
  with account group unavailable. GREEN established exact bootstrap/add/remove
  proof roundtrip after constructing a new store, old approval retry stays
  removed, and fresh dual-sign rejoin succeeds.
- Additional meaningful RED/GREEN: wrong group plus corrupt owned journal
  initially returned unavailable; moving requested-group filtering into the
  SQL pin lookup correctly returns the same invalid sentinel as absent groups.
- Two separate sql.DB pools prove one concurrent genesis winner and one distinct
  same-head append winner. Deferred PostgreSQL constraint triggers prove failed
  bootstrap and append COMMIT roll back with no success/partial rows.
- Read COMMIT transport fault wraps the actual PostgreSQL driver only at commit,
  asserts the commit was reached, and verifies nil events + unavailable error.
- SQL cases cover account/device mismatch, invalid proof before SQL, deleting/
  absent account, alternate genesis, exact canonical re-sign retry, malformed/
  unknown/trailing JSON, sequence/hash/key/pin corruption, empty journal, nil
  safety, cancellation, five-second lock deadline, idempotent migration and
  migrated constraints, 8192 cap and 8193 corruption.
- Initial race cap failure retained: fixed five-second deadline expired; after
  store duplicate validation removal, read-only timing measured 8192 events at
  5.028845084 seconds under race. This justified the approved State amendment.
- Final `DROPMESH_GROUP_TEST_DATABASE_URL='<DSN above>' go test -race ./internal/accountgroup -count=1`
  PASS 32.859s, including every existing Event/State signature test and all SQL
  cap tests, without relaxed deadlines or skipped capacity coverage.
- Final `DROPMESH_GROUP_TEST_DATABASE_URL='<DSN above>' go test ./internal/accountgroup -run TestPostgresGroup -count=1`
  PASS 13.533s.
- Final `go test ./...` PASS; accountgroup 0.949s, other packages cached. SQL
  cases explicitly skip without the opt-in variable; SQL evidence is above.

## Root restart acceptance

Run only the named test, with no other SQL suite between prepare and verify:

```sh
DROPMESH_GROUP_TEST_DATABASE_URL='host=/private/tmp/dropmesh-group-db.igBdYS port=55459 dbname=dropmesh_account_group_test user=mason sslmode=disable' DROPMESH_GROUP_RESTART_MODE=prepare go test ./internal/accountgroup -run '^TestPostgresGroupRestart$' -count=1 -v
```

Root then stops and starts its actual PostgreSQL fixture and runs:

```sh
DROPMESH_GROUP_TEST_DATABASE_URL='host=/private/tmp/dropmesh-group-db.igBdYS port=55459 dbname=dropmesh_account_group_test user=mason sslmode=disable' DROPMESH_GROUP_RESTART_MODE=verify go test ./internal/accountgroup -run '^TestPostgresGroupRestart$' -count=1 -v
```

Prepare creates synthetic bootstrap/approval/removal and validates old retry.
Verify never migrates, truncates, seeds, appends, or bootstraps. It reads the
stored three-proof chain and verifies removed membership remains removed.
Implementer ran prepare alone: PASS 0.915s; fixture retains those three events.
Actual process restart is not claimed by this implementer report; root owns it.

Limit: this standalone storage is not a complete two-device phone flow. HTTP
authentication/bounds, native independent pins/confirmation, and routing remain
future integration work. Account deletion must account for the new FK-backed
journal within its separately designed lifecycle; no delete API was added.
