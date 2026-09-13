# Task 1: consistent durable trust snapshot

Implemented against source baseline d23bc69 in the existing dropmesh-iphone worktree.
Coordinator committed independent plan documents during implementation. This report
and four auth Go files are the implementer's only owned changes.

## Changes

- Optional `LoadIssuerHighWater(context.Context) (map[string]uint64, error)` keeps
  existing record-only stores source compatible.
- Startup and refresh share snapshot loading and validation. Five bounded version
  brackets include both record and issuer metadata reads. Metadata errors fail closed.
- PostgreSQL loads existing `trust_issuer_states`; UUID-shaped identifiers and uint64
  values are validated, including overflow. No schema or dependency changes.
- Replay barriers are max(record-derived, persisted metadata), with current barriers
  retained on refresh. Metadata does not fabricate keys, records, or authorization.
- A local successful confirmation increments a mutation generation. A snapshot
  captured before that mutation cannot install; refresh returns an explicit retry
  error so authentication does not proceed claiming refresh success. No new lock
  spans network reads or introduces a lock order.
- Tests cover startup/refresh highwater10 with surviving record1, rejected5/10,
  admissible11, metadata-only state, failures/malformed IDs, metadata version change,
  bounded continuous-change failure, and concurrent local confirmation.
- Real PostgreSQL regression covers cleanup/restart, exact expired proof rejection,
  established duplicate idempotency, newer sequence11, revocation/restart replay
  rejection, uint64 maximum, and overflow.

## Commands and actual results

All Go commands run from `Services/rendezvous`. Database URL below is only the
explicitly authorized local synthetic database, with no production credentials.

Start the existing isolated instance:

```sh
pg_ctl -D /private/tmp/dropmesh-auth-repro.oA04vz/data -l /private/tmp/dropmesh-auth-repro.oA04vz/server.log -o '-p 55439 -h 127.0.0.1 -k /private/tmp/dropmesh-auth-repro.oA04vz' start
```

Output: `waiting for server to start.... done`, `server started`; exit0.

Initial RED, before implementation:

```sh
DROPMESH_AUTH_REPRO_DATABASE_URL='postgres://mason@127.0.0.1:55439/dropmesh_auth_repro?sslmode=disable' go test ./internal/auth -run 'Test.*TrustSnapshot|TestPersistenceReproExpiredHigherSequence' -count=1
```

Exit1. Real DB: `restored memory must reject old issuer sequence, got <nil>`.
Startup and refresh: `highwater=1, want10`. Metadata-only barrier lost;
metadata reads0/water1; old refresh did not bracket snapshot.

Additional concurrency RED using the earlier silent-success conflict branch:

```sh
go test ./internal/auth -run TestTrustSnapshotStaleRefreshCannotUndoConfirmation -count=1
```

Exit1: `discarded snapshot must report refresh failure`. Restored explicit error
and verified the final test also retains the locally confirmed record and succeeds
on a subsequent refresh.

Final focused GREEN: same initial RED command, exit0:

```text
ok  macchannel/rendezvous/internal/auth  0.587s
```

Final full race GREEN:

```sh
DROPMESH_AUTH_REPRO_DATABASE_URL='postgres://mason@127.0.0.1:55439/dropmesh_auth_repro?sslmode=disable' go test ./... -race -count=1
```

Exit0:

```text
?   macchannel/rendezvous/cmd/runner-lock [no test files]
ok  macchannel/rendezvous/cmd/secret-launcher 1.942s
ok  macchannel/rendezvous/cmd/server 2.141s
ok  macchannel/rendezvous/cmd/stack-secrets 34.813s
ok  macchannel/rendezvous/cmd/turn-probe 1.713s
ok  macchannel/rendezvous/internal/auth 2.611s
ok  macchannel/rendezvous/internal/httpapi 4.421s
ok  macchannel/rendezvous/internal/pairing 3.378s
ok  macchannel/rendezvous/internal/presence 3.873s
ok  macchannel/rendezvous/internal/signal 3.997s
ok  macchannel/rendezvous/internal/turn 13.652s
```

`git diff --check` passed. Both snapshot callers and all optional-interface references
were inspected. Synthetic PostgreSQL stopped with:

```sh
pg_ctl -D /private/tmp/dropmesh-auth-repro.oA04vz/data stop -m fast
pg_ctl -D /private/tmp/dropmesh-auth-repro.oA04vz/data status
```

Stop exit0 (`server stopped`); status exit3 (`no server running`). Synthetic fixture
data remains in its original temporary directory for reproducibility.

## Limitations and handoff

Locally verified server task only. No production database, device, private key,
deployment, installation, migration or protocol change. Other optional PostgreSQL
integration suites requiring their own environment were not enabled; the required
real auth reproducer ran without a skip. Coordinator owns HANDOFF/progress and
independent review/integration. Client-state and installed interoperability tasks
remain separate approved program work.
