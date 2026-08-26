# Task 4 report: authenticated rendezvous service

## Status

Implemented and committed Task 4. The Go rendezvous process now provides signed HTTP pairing, single-use bounded pairing sessions, nonce-authenticated WebSockets, two-phase trust-graph presence/signaling, PostgreSQL-backed restart durability, and the required schema. No private keys, pairing codes, file names, paths, file content, or transfer history are logged or stored.

## Files

- `Services/rendezvous/go.mod` and `go.sum`
  - Go 1.25 module metadata with Gorilla WebSocket and pgx dependencies; compatible with the plan's Go 1.24+ requirement.
- `Services/rendezvous/cmd/server/main.go`
  - HTTP process assembly, timeouts, graceful shutdown, PostgreSQL configuration, and an explicit bounded in-memory fallback when `DATABASE_URL` is absent.
- `Services/rendezvous/internal/auth/verifier.go`
  - P-256 signed-envelope validation, 60-second timestamp freshness, bounded fail-closed nonce replay storage, server-issued single-use challenges, Task 2 trust-record validation, Swift `DeviceID` JSON compatibility, monotonic issuer sequences, two-party authorization confirmation, unilateral revocation, graph calculation, and PostgreSQL trust-record restoration.
- `Services/rendezvous/internal/pairing/store.go`
  - SHA-256 code hashing, atomic single-use consumption, five-minute expiry, bounded session/tombstone/failure state, per-source/code/global attempt backstops, atomic source in-flight reservations, and PostgreSQL session persistence.
- `Services/rendezvous/internal/presence/hub.go`
  - Race-safe online/offline fanout restricted to the currently validated trust graph, including live authorization and revocation refresh.
- `Services/rendezvous/internal/signal/hub.go`
  - Opaque signaling relay capped at 64 KiB and restricted to online devices in the same trust graph.
- `Services/rendezvous/internal/httpapi/router.go`
  - `GET /healthz`, `POST /v1/pairing`, `POST /v1/pairing/{code}/join`, and `GET /v1/ws`; strict body limits, no-store/security headers, server-observed remote source, signed join-code binding, challenge-response authentication, and concurrent-write-safe WebSockets.
- `Services/rendezvous/internal/httpapi/router_test.go`
  - End-to-end HTTP/WebSocket, concurrency, expiry, spoofing, replay, wire compatibility, graph isolation, live revocation, bounded storage, sequence, two-phase authorization, and optional live PostgreSQL coverage.
- `Services/migrations/001_devices.sql`
  - `pairing_sessions`, `device_authorizations`, and `device_revocations`, with expiry/subject indexes and no file or transfer metadata columns.

## TDD evidence

### Initial RED

Command:

```bash
cd Services/rendezvous && go test ./...
```

Observed output (exit 1, after adding the test dependency so the failure reached the missing implementation):

```text
FAIL macchannel/rendezvous/internal/httpapi [setup failed]
# macchannel/rendezvous/internal/httpapi
internal/httpapi/router_test.go:25:2: package macchannel/rendezvous/internal/auth is not in std
FAIL
```

### Security RED cycles

Two-party authorization:

```bash
go test ./internal/httpapi -run TestAuthorizationRequiresIssuerAndSubjectPresentation -count=1
```

```text
--- FAIL: TestAuthorizationRequiresIssuerAndSubjectPresentation (0.00s)
    router_test.go:548: issuer unilaterally connected an unconsenting subject
FAIL
```

Live trust/revocation presence refresh:

```bash
go test ./internal/httpapi -run TestTrustUpdatesRefreshPresenceAndRevocationsHidePeers -count=1
```

```text
--- FAIL: TestTrustUpdatesRefreshPresenceAndRevocationsHidePeers (2.01s)
    router_test.go:596: read tcp 127.0.0.1:57948->127.0.0.1:57947: i/o timeout
FAIL
```

Signed join-code binding:

```bash
go test ./internal/httpapi -run 'TestSignedJoinCannotBeRedirectedToAnotherCode|TestPairingCodeIsSingleUse' -count=1
```

```text
--- FAIL: TestPairingCodeIsSingleUse (0.00s)
    router_test.go:280: join status = 400, want 200, body = {"error":"invalid_request"}
--- FAIL: TestSignedJoinCannotBeRedirectedToAnotherCode (0.00s)
    router_test.go:352: join status = 400, want 200, body = {"error":"invalid_request"}
FAIL
```

Other focused RED checks also covered replay-cache saturation, out-of-order issuer sequences, Swift trust/device wire shapes, expired-session capacity release, and atomic source reservations. Each failed for the missing behavior before its implementation.

## GREEN verification

Exact required command:

```bash
cd Services/rendezvous && go test -race ./...
```

Final output (exit 0, no race report):

```text
?    macchannel/rendezvous/cmd/server             [no test files]
?    macchannel/rendezvous/internal/auth           [no test files]
ok   macchannel/rendezvous/internal/httpapi        1.597s
?    macchannel/rendezvous/internal/pairing        [no test files]
?    macchannel/rendezvous/internal/presence       [no test files]
?    macchannel/rendezvous/internal/signal         [no test files]
```

Additional verification:

```bash
go vet ./...
swift test
git diff --cached --check
```

Observed output:

```text
go vet: exit 0, no output
Swift: Executed 47 tests, with 0 failures (0 unexpected)
git diff --cached --check: exit 0, no output
```

PostgreSQL verification:

- Applied `Services/migrations/001_devices.sql` with `psql -v ON_ERROR_STOP=1` to a clean local PostgreSQL 16.15 cluster: all three tables and indexes were created successfully.
- Started the committed server with `DATABASE_URL` against that cluster and received `HTTP/1.1 200 OK` plus `{"status":"ok"}` from `/healthz`.
- Ran `TestPostgresTrustRegistryPersistsTwoPhaseAuthorization` with `TEST_DATABASE_URL`; it passed and proved one-sided records stay isolated while mutually confirmed records survive registry reconstruction.

## Self-review

- Pairing codes are generated with rejection-sampled cryptographic randomness and only SHA-256 hashes enter storage.
- Code consumption is atomic in both memory and PostgreSQL; concurrent HTTP tests prove exactly one successful join.
- The join message includes the URL code inside the signed payload, preventing cross-code redirection.
- Rate-limit source is taken from `RemoteAddr`; `Forwarded` and `X-Forwarded-For` are intentionally ignored.
- Fresh nonce evidence is never evicted to admit new requests; cache saturation fails closed. Challenge and replay state are bounded and expiring.
- Authorization needs presentation by both issuer and subject before an edge becomes routable. Revocation needs the issuer only and immediately removes presence/signaling access.
- Replayed trust records are idempotent; new records require strictly increasing issuer sequences, including across PostgreSQL restart.
- Signaling frames remain opaque and are size-bounded. The service does not define or persist file-related fields.
- PostgreSQL writes use transactions, row/advisory locks, idempotent record confirmation, expiry indexes, and atomic consumed-time updates.

## Commit

- `85e2da6c915ccd83457f9e9f6cae8674924b019d` — `feat: add authenticated rendezvous service`

## Concerns

- Production must apply the migration and set `DATABASE_URL`; the deliberately explicit in-memory fallback is bounded but does not survive restart.
- The server currently expects direct peer addresses. If deployed behind a reverse proxy, all clients will share the proxy's observed source until a narrowly configured trusted-proxy mechanism is added; untrusted forwarding headers must not be accepted.
- TLS certificate/termination configuration belongs to the later infrastructure/deployment task. The service should not be exposed directly over plaintext HTTP on an untrusted network.
- The planned runtime is PostgreSQL 17; the available local executable was PostgreSQL 16.15. Schema and persistence behavior passed there, but the Task 13 stack should repeat this evidence on PostgreSQL 17.
- Git auto-selected committer identity `Mason Xu <mason@MasondeMac-Studio.local>`; repository policy may require confirming it.

---

## Review remediation — 2026-08-26

### Status

Fixed all 2 Critical and 5 Important findings, plus all 3 practical Minor findings, in commit `dcc6dbcb56c7d583ab0bed7fadc7cf3d0ff770e6` (`fix: harden rendezvous durability and isolation`).

- **C1 — complete pre-trust pairing transport:** Added authenticated participant-bound host polling, stable authorization reservation, idempotent commit, and one-use joiner retrieval endpoints. Encrypted join and authorization blobs remain opaque. PostgreSQL retains each phase across service reconstruction, the reservation outlives the original pairing TTL under its independent 15-minute mailbox TTL, pre-commit retrieval is pending, response-loss retries are idempotent, conflicting retries fail, and retrieval is one-use.
- **C2 — issuer-directional trust:** Each issuer owns an independent `(issuer, subject)` action and sequence. Adjacency exists only while both latest directional actions authorize. Restore sorts by issuer sequence and deterministically applies the latest direction. A sequence-100 A authorization cannot override B's sequence-1 revocation; only B's later authorization restores that direction.
- **I1 — durable replay evidence:** Challenges and HTTP nonce evidence use PostgreSQL unique keys, atomic insert/delete, expiry, global/per-source/per-device quotas, and global advisory locks. Separate verifier instances reject the same nonce and consume a challenge once. A 16-replica concurrency test proves a global capacity of four admits exactly four.
- **I2 — bounded identities/connections:** Empty self-signed WebSocket authentication no longer permanently registers an identity in the trust registry. Authenticated connections, presence clients, and signal clients are bounded globally/per source/per device. Presence refresh uses stored trust adjacency rather than an all-pairs scan. WebSockets send pings, require pong/read progress, use write deadlines, and have a 24-hour maximum lifetime.
- **I3/I4 — partitioned durable abuse controls:** Pairing creation is limited per server-observed source and device. Join failures and in-flight reservations are persisted by hashed source, code hash, and authenticated device. Per-source, per-code, and per-device locks make reservation/count checks atomic without the former global 100-miss lockout. Expired rows are cleaned periodically.
- **I5 — fail-closed storage mode:** Production startup now requires `DATABASE_URL`. Non-durable storage is available only with explicit `MACCHANNEL_DEV_IN_MEMORY=true`, and startup logs only the selected mode.
- **Minor hardening:** Added `MaxHeaderBytes`, `http.MaxBytesReader`, trailing-JSON rejection coverage, parsed exact WebSocket origin allow-listing through `MACCHANNEL_ALLOWED_WS_ORIGINS`, and periodic pairing/auth expiry cleanup.

No private keys, plaintext pairing codes, filenames, paths, file contents, transfer history, or decrypted signaling payloads are stored or logged.

### Files

- `Services/migrations/001_devices.sql` — fresh-install session mailbox, replay, and partitioned-rate schema.
- `Services/migrations/002_rendezvous_hardening.sql` — one-way upgrade from the original Task 4 schema; safe to reapply without deleting new-format sessions.
- `Services/rendezvous/cmd/server/main.go` and `main_test.go` — fail-closed mode selection, durable verifier wiring, server limits, cleanup, and startup tests.
- `Services/rendezvous/internal/auth/verifier.go` — durable replay store and issuer-directional trust adjacency.
- `Services/rendezvous/internal/pairing/store.go` — complete memory/PostgreSQL pre-trust protocol and durable partitioned quotas.
- `Services/rendezvous/internal/httpapi/router.go` and `router_test.go` — new pairing endpoints, exact origins/body bounds, connection lifecycle, end-to-end/restart/concurrency tests.
- `Services/rendezvous/internal/presence/hub.go`, `internal/signal/hub.go`, and their tests — bounded clients and adjacency-based presence refresh.

### TDD RED evidence

Pre-trust pairing route and mailbox:

```bash
cd Services/rendezvous
go test ./internal/httpapi -run TestPreTrustPairingAuthorizationMailboxLifecycle -count=1
```

```text
--- FAIL: TestPreTrustPairingAuthorizationMailboxLifecycle
    router_test.go:383: join response did not contain a session ID
FAIL
```

Directional issuer state:

```bash
go test ./internal/httpapi -run TestDirectionalTrustSequencesRemainIndependentAcrossRestart -count=1
```

```text
--- FAIL: TestDirectionalTrustSequencesRemainIndependentAcrossRestart
    router_test.go:829: reciprocal directional authorizations did not create a route
FAIL
```

Durable/partitioned replay API:

```bash
go test ./internal/httpapi -run 'Test(ReplayCapacityIsPartitionedByObservedSource|PostgresReplayEvidenceIsSharedAcrossVerifierInstances)' -count=1
```

```text
internal/httpapi/router_test.go:684:3: unknown field ReplayPerSourceCapacity in struct literal of type auth.VerifierConfig
internal/httpapi/router_test.go:690:21: verifier.VerifyHTTPFrom undefined
internal/httpapi/router_test.go:715:84: undefined: auth.NewPostgresReplayStore
FAIL
```

Pairing creation/source partitioning:

```bash
go test ./internal/httpapi -run TestPairingCreationAndFailuresUsePartitionedQuotas -count=1
```

```text
--- FAIL: TestPairingCreationAndFailuresUsePartitionedQuotas
    router_test.go:651: same-source create error = <nil>, want rate limit
FAIL
```

Fail-closed production storage:

```bash
go test ./cmd/server -run TestConfiguredStores -count=1
```

```text
cmd/server/main_test.go:11:31: assignment mismatch: 5 variables but configuredStores returns 3 values
cmd/server/main_test.go:23:52: assignment mismatch: 5 variables but configuredStores returns 3 values
FAIL
```

Connection/adjacency bounds and exact configured origins also began with compile failures for the deliberately absent `newConnectionLimiter`, `RefreshDevice`, bounded `Register`, and `AllowedWebSocketOrigins` APIs before their implementations.

### Final GREEN evidence

Always-on race suite, live PostgreSQL race suite, and vet:

```bash
cd Services/rendezvous
go test -race -count=1 ./...
TEST_DATABASE_URL='postgresql://localhost:5432/macchannel_task4_review_8261?sslmode=disable' go test -race -count=1 ./...
go vet ./...
```

```text
ok   macchannel/rendezvous/cmd/server             1.294s
?    macchannel/rendezvous/internal/auth          [no test files]
ok   macchannel/rendezvous/internal/httpapi       2.361s
?    macchannel/rendezvous/internal/pairing       [no test files]
ok   macchannel/rendezvous/internal/presence      1.410s
ok   macchannel/rendezvous/internal/signal        1.818s
ok   macchannel/rendezvous/cmd/server             1.216s
?    macchannel/rendezvous/internal/auth          [no test files]
ok   macchannel/rendezvous/internal/httpapi       2.215s
?    macchannel/rendezvous/internal/pairing       [no test files]
ok   macchannel/rendezvous/internal/presence      1.552s
ok   macchannel/rendezvous/internal/signal        1.715s
go vet: exit 0, no output
```

Swift regression suite and diff check:

```bash
swift test
git diff --check
```

```text
Test Suite 'All tests' passed
Executed 47 tests, with 0 failures (0 unexpected)
git diff --check: exit 0, no output
```

PostgreSQL 16.15 evidence:

- Applied the updated `001_devices.sql` to a clean database.
- Applied `002_rendezvous_hardening.sql` over the exact schema from commit `85e2da6`; six required rendezvous tables were present afterward.
- Reapplied `002` after inserting a new-format pairing session; the session count remained `1`, proving the conditional legacy cleanup does not erase current sessions.
- Live tests covered restart at create, host-pending, join, reservation, pre-commit retrieval, commit, response-loss retry, conflicting retry, retrieval, and post-retrieval phases.
- Started the committed server with PostgreSQL and received `HTTP/1.1 200 OK` and `{"status":"ok"}` from `/healthz`.

### Concerns

- The upgrade migration intentionally invalidates only pre-hardening in-flight pairing rows because those rows have no authenticated host identity and cannot be safely upgraded. New-format rows are preserved on reapplication.
- Local database evidence used PostgreSQL 16.15; the deployment task should repeat it on the planned PostgreSQL 17 image.
- Direct peer addresses remain the authority for source quotas. A future reverse-proxy deployment needs a narrowly configured trusted-proxy boundary; arbitrary forwarding headers must remain ignored.
- TLS termination/certificate deployment remains infrastructure scope. Do not expose the service over plaintext on an untrusted network.
- Git again used the repository machine's auto-selected committer identity `Mason Xu <mason@MasondeMac-Studio.local>`.

---

## Second review remediation — 2026-08-26

### Status

Fixed the second review's 2 Critical and 3 Important findings in commit `1d3ec4b` (`fix: align rendezvous with pairing transport`).

- **C1:** Added every authenticated durable Task 3 transport phase: client-supplied-code publish, lookup, join submission, host join poll, host response commit, joiner response poll, stable authorization reservation, status, idempotent delivery, one-use retrieval, idempotent cancellation, and host-bound removal. The Swift-equivalent Go test follows this exact order and checks outsider rejection.
- **C2:** The one host-signed authorization routes only after host and subject present that same record. Issuer counters remain independent. Either participant's valid revoke establishes a durable pair barrier; only a new authorization later presented by both parties can cross it.
- **I1:** A successful join gets a fresh five-minute `session_expires_at`, independent of remaining code life. Reservation and committed-mailbox TTLs remain independently fifteen minutes.
- **I2:** Replay expiry is `max(receipt time, envelope timestamp) + freshness window`, with exact past-boundary rejection, including PostgreSQL restart coverage.
- **I3:** Trust state is compact and quota-partitioned per issuer. Route checks refresh durable versions. Startup uses version-before/load/version-after snapshot retry, preventing stale rows from being paired with a newer database version.

Wire mappings and opaque Task 3 inner fields are documented in `Services/rendezvous/README.md`. No private keys or file metadata are exposed to the service.

### Files

- `Services/rendezvous/README.md` — Task 3 endpoint/wire contract.
- `Services/rendezvous/internal/httpapi/router.go`, `router_test.go` — transport endpoints and Swift-ordered/participant/restart regressions.
- `Services/rendezvous/internal/pairing/store.go` — durable response, cancellation/removal, independent expiries, lookup controls, and idempotency.
- `Services/rendezvous/internal/auth/verifier.go` — replay boundary, compact trust/revocation state, issuer quotas, durable refresh, and consistent snapshots.
- `Services/migrations/001_devices.sql` through `004_compact_trust_state.sql` — fresh/additive durable schema.

### TDD RED evidence

```bash
cd Services/rendezvous
go test ./internal/httpapi -run TestSwiftPairingTransportStateSequence -count=1
```

```text
--- FAIL: TestSwiftPairingTransportStateSequence
    router_test.go:480: create status = 400, body = {"error":"invalid_request"}
FAIL
```

```bash
go test ./internal/httpapi -run TestTask3HostSignedAuthorizationNeedsTwoPresentationsAndLaterReauthorization -count=1
```

```text
--- FAIL: TestTask3HostSignedAuthorizationNeedsTwoPresentationsAndLaterReauthorization
    router_test.go:1280: Task 3 subject could not present host authorization: invalid trust record
FAIL
```

```bash
go test ./internal/httpapi -run TestFutureSkewedReplayEvidenceCoversEntireAcceptanceWindow -count=1
```

```text
--- FAIL: TestFutureSkewedReplayEvidenceCoversEntireAcceptanceWindow
    router_test.go:1037: replay one second before acceptance boundary = <nil>, want repeated nonce
FAIL
```

```bash
go test ./internal/httpapi -run TestTrustQuotasArePerIssuerAndCompactRepeatedPairUpdates -count=1
TEST_DATABASE_URL='postgresql://localhost:5432/macchannel_task4_rereview_8263?sslmode=disable' go test ./internal/httpapi -run TestPostgresTrustStateCompactsAndRefreshesAcrossReplicas -count=1
```

```text
undefined: auth.NewTrustRegistryWithConfig
undefined: auth.TrustRegistryConfig
undefined: auth.ErrTrustRateLimit
ERROR: relation "trust_pair_states" does not exist
FAIL
```

```bash
go test ./internal/httpapi -run TestPersistentTrustRegistryLoadsAConsistentVersionSnapshot -count=1
```

```text
--- FAIL: TestPersistentTrustRegistryLoadsAConsistentVersionSnapshot
    router_test.go:1614: registry paired stale state with a newer durable version
FAIL
```

Exact Swift aliases also failed before implementation with `400 invalid_request` for the client-supplied publish code and `empty reservation ID` when reading `PairingDeliveryReservation.id`.

### Final GREEN evidence

```bash
cd Services/rendezvous
go test -race -count=1 ./...
TEST_DATABASE_URL='postgresql://mason@localhost:5432/macchannel_task4_final_18347?sslmode=disable' go test -race -count=1 ./...
go vet ./...
git diff --check
```

```text
ok   macchannel/rendezvous/cmd/server        2.050s
?    macchannel/rendezvous/internal/auth     [no test files]
ok   macchannel/rendezvous/internal/httpapi  3.389s
?    macchannel/rendezvous/internal/pairing  [no test files]
ok   macchannel/rendezvous/internal/presence 2.240s
ok   macchannel/rendezvous/internal/signal   3.075s
ok   macchannel/rendezvous/cmd/server        1.339s
?    macchannel/rendezvous/internal/auth     [no test files]
ok   macchannel/rendezvous/internal/httpapi  3.261s
?    macchannel/rendezvous/internal/pairing  [no test files]
ok   macchannel/rendezvous/internal/presence 1.610s
ok   macchannel/rendezvous/internal/signal   1.893s
go vet: exit 0, no output
git diff --check: exit 0, no output
```

```bash
swift test
```

```text
Test Suite 'All tests' passed
Executed 47 tests, with 0 failures (0 unexpected)
```

PostgreSQL/runtime evidence:

- Applied migrations `001`–`004` to fresh database `macchannel_task4_final_18347`, then reapplied additive `002`–`004` successfully.
- Reapplied `004` after trust events; version stayed monotonic: `trust_state_version before=51 after=51`.
- Started in PostgreSQL durable mode and received `HTTP/1.1 200 OK` with `{"status":"ok"}` from `/healthz`.

### Self-review

- Published code/session/reservation IDs are bound in authenticated payloads and URL paths; quotas use only the server-observed connection address.
- Unpaired joiners use the durable pre-trust route and never require trust-graph signaling.
- Cancellation, response commit, authorization delivery, and removal are idempotent; conflicting committed bytes fail closed; retrieval is one-use.
- Per-issuer counters are never compared. Server event order only decides whether a new two-party authorization followed the pair's latest revocation.
- Route checks poll compact durable trust versions and fail closed on database errors.
- Migrations contain no filename, directory, transfer-history, plaintext-code, private-key, or decrypted-payload columns.

### Concerns

- Durable verification used PostgreSQL 16.15; deployment should repeat on the planned PostgreSQL 17 image.
- This task defines/verifies the Go wire protocol but does not add a Swift HTTP `PairingTransport` adapter; client integration must use the documented opaque mapping.
- A reverse proxy requires an explicitly trusted source boundary; forwarding headers remain ignored.
- TLS termination remains deployment scope.
- Git used auto-selected committer identity `Mason Xu <mason@MasondeMac-Studio.local>`.

---

## Third review remediation — 2026-08-26

### Status

Fixed the third review's 1 Critical, 5 Important, and 1 Minor findings, plus all Critical/Important issues found by the independent follow-up review, in commit `85c0519` (`fix: linearize durable trust and pairing state`). The final targeted review reported no remaining Critical or Important findings.

- **C1:** PostgreSQL trust mutations now lock the singleton durable version row before assigning event order. The transaction-returned monotonic version is the accepted order, so commit and published-version order cannot invert across replicas.
- **I1:** Join submission creates a bounded pending handshake. Only the atomic host-response commit starts the canonical five-minute session. Migration `005` safely backfills pre-upgrade live sessions.
- **I2:** A committed authorization mailbox takes precedence over an expired reservation. Stable reserve/status/identical-redelivery retries remain valid until the independent mailbox expiry, including across restart.
- **I3:** Trust has global and per-issuer durable caps. Unconfirmed new authorizations expire and are cleaned periodically. Unilateral revocations cannot allocate permanent rows; only an already-established unordered pair may add a revocation barrier. Expired reauthorization presentations become compact tombstones that retain the revocation/high-water barrier and reject late presentation.
- **I4:** Reciprocal issuer-confirmed legacy trust is represented by an explicit compatibility barrier without creating or altering signatures. One-way legacy rows remain unroutable, acquire bounded expiry, and the next signed mutation replaces compatibility state. Forward migration `005` handles databases whose ledger already recorded `004`.
- **I5:** Active routers poll durable trust version once per interval. A remote revocation refreshes connected presence; a database error clears cached visibility on every failed poll and revalidates it after recovery.
- **M1:** Removal documentation now states that retry idempotency is bounded by retained session/tombstone cleanup.

### Files

- `Services/rendezvous/internal/auth/verifier.go` — linearizable durable ordering, compact admission state, global bounds, expiry/tombstone cleanup, forward-compatible legacy state, and tri-state durable refresh.
- `Services/rendezvous/internal/pairing/store.go` — pending-handshake and response-derived session lifetime plus committed-mailbox-first idempotency.
- `Services/rendezvous/internal/httpapi/router.go` — handshake wire fields and cross-replica trust watcher with fail-closed presence.
- `Services/rendezvous/internal/presence/hub.go` — cached visibility invalidation.
- `Services/rendezvous/internal/httpapi/router_test.go` — memory, restart, migration, concurrency, capacity, outage, and cross-replica regressions.
- `Services/rendezvous/cmd/server/main.go` — periodic compact trust cleanup.
- `Services/migrations/001_devices.sql` through `004_compact_trust_state.sql` — fresh-schema support.
- `Services/migrations/005_trust_and_handshake_upgrade.sql` — forward upgrade/backfill for already-migrated deployments.
- `Services/rendezvous/README.md` — corrected handshake/session wire lifetime and bounded idempotency contract.

### TDD RED evidence

```bash
TEST_DATABASE_URL='postgresql://mason@localhost:5432/macchannel_task4_final_18347?sslmode=disable' \
  go test ./internal/httpapi -run TestPostgresTrustMutationCommitOrderIsLinearizableAcrossReplicas -count=1 -v
```

```text
first commit=revocation, want serialized authorization before later revocation
FAIL
```

```bash
go test ./internal/httpapi -run TestCanonicalSessionStartsOnlyWhenHostResponseCommits -count=1 -v
```

```text
reservation before host response error=<nil>, want pending
FAIL
```

```bash
go test ./internal/httpapi -run TestCommittedMailboxRetriesIgnoreExpiredReservationUntilMailboxExpiry -count=1 -v
```

```text
reserve retry after reservation expiry={...} err=pairing gone
FAIL
```

```bash
go test ./internal/httpapi -run TestTrustGlobalCapExpiresUnconfirmedSybilStateAndAllowsEstablishedUpdates -count=1
```

```text
undefined: auth.TrustRegistryConfig.GlobalPairs
undefined: auth.TrustRegistryConfig.UnconfirmedTTL
FAIL
```

```bash
TEST_DATABASE_URL='postgresql://mason@localhost:5432/macchannel_task4_final_18347?sslmode=disable' \
  go test ./internal/httpapi -run TestMigrationPreservesOnlyReciprocalLegacyTrustUntilNextMutation -count=1 -v
```

```text
reciprocal routable legacy trust was lost during compaction
FAIL
```

```bash
TEST_DATABASE_URL='postgresql://mason@localhost:5432/macchannel_task4_final_18347?sslmode=disable' \
  go test ./internal/httpapi -run TestPostgresRevocationRefreshesPresenceOnAnotherRouter -count=1 -v
```

```text
read tcp 127.0.0.1:...: i/o timeout
FAIL
```

The independent review then supplied adversarial RED cases. Before the admission fix, `TestUnilateralRevocationsCannotConsumeTrustCapacity` failed with `unilateral revocation admission error=<nil>, want invalid trust`. Before the forward migration, `TestMigration005UpgradesInFlightSessionAndExpiresOneSidedTrust` failed because `005_trust_and_handshake_upgrade.sql` did not exist. The database-outage presence test timed out before fail-closed invalidation was added.

### Final GREEN evidence

Fresh PostgreSQL schema and reapply:

```bash
dropdb --if-exists macchannel_task4_third_final_8266
createdb macchannel_task4_third_final_8266
# apply 001-005, then reapply additive 002-005 with psql -v ON_ERROR_STOP=1
```

```text
exit=0
trust compact-state upgrade columns=4
pairing handshake upgrade columns=1
```

Go race suites and static analysis:

```bash
cd Services/rendezvous
go vet ./...
go test -race ./... -count=1
TEST_DATABASE_URL='postgresql://mason@localhost:5432/macchannel_task4_third_final_8266?sslmode=disable' go test -race ./... -count=1
```

```text
go vet: exit 0, no output
ok   macchannel/rendezvous/cmd/server        2.051s
?    macchannel/rendezvous/internal/auth     [no test files]
ok   macchannel/rendezvous/internal/httpapi  3.540s
?    macchannel/rendezvous/internal/pairing  [no test files]
ok   macchannel/rendezvous/internal/presence 2.348s
ok   macchannel/rendezvous/internal/signal   2.043s
ok   macchannel/rendezvous/cmd/server        1.334s
?    macchannel/rendezvous/internal/auth     [no test files]
ok   macchannel/rendezvous/internal/httpapi  4.195s
?    macchannel/rendezvous/internal/pairing  [no test files]
ok   macchannel/rendezvous/internal/presence 2.029s
ok   macchannel/rendezvous/internal/signal   2.435s
```

Swift regressions and diff check:

```bash
swift test
git diff --check
```

```text
Test Suite 'All tests' passed
Executed 47 tests, with 0 failures (0 unexpected)
git diff --check: exit 0, no output
```

Runtime health:

```bash
DATABASE_URL='postgresql://mason@localhost:5432/macchannel_task4_third_final_8266?sslmode=disable' \
  RENDEZVOUS_ADDR='127.0.0.1:18087' go run ./cmd/server
curl --fail --silent --show-error http://127.0.0.1:18087/healthz
```

```text
rendezvous storage mode: PostgreSQL durable
rendezvous listening on 127.0.0.1:18087
{"status":"ok"}
```

### Self-review

- Singleton row locking, event order assignment, durable mutation, and version publication occur in one PostgreSQL transaction. The forced blocking test uses concurrent pool connections and proves the later revocation wins after replica refresh.
- Revocation admission is defended both in memory and again inside the locked PostgreSQL transaction. Legacy revocations are never garbage-collected as if they were unconfirmed authorizations.
- Pending reauthorization expiry retains the prior revocation order and issuer high-water, rejects the expired record after restart, and accepts only a fresh higher-sequence authorization presented by both participants.
- Migration `005` is additive/reapplicable and backfills nullable live-session and old compact-trust state without forging a trust signature.
- Presence polling makes one durable-version check per active router interval; unchanged state avoids a global presence scan. Durable errors clear visibility rather than leaving stale peers online.
- Service schemas and logs contain no private keys, file paths, filenames, transfer history, or decrypted pairing payloads.

### Concerns

- Durable verification used local PostgreSQL 16; deployment should repeat migrations and concurrency tests on the planned PostgreSQL 17 image.
- This task defines and verifies the Go wire protocol but does not add a Swift HTTP `PairingTransport` adapter; client integration must use the documented opaque mapping.
- A reverse proxy requires an explicitly trusted source boundary; arbitrary forwarding headers remain ignored.
- TLS termination remains deployment scope.
- Git used auto-selected committer identity `Mason Xu <mason@MasondeMac-Studio.local>`.

---

## Formal final-review barrier remediation — 2026-08-26

### Status

Fixed the final Important migration finding in commit `4d52798` (`fix: preserve migrated revocation barriers`). Targeted independent re-review approved the migration/runtime cleanup with no remaining Critical or Important findings.

- Migration `005` immediately converts every incomplete authorization carrying `revocation_order > 0` into a non-expiring `pending_expired` tombstone.
- Neither migration backfill nor runtime cleanup assigns ordinary unconfirmed-authorization expiry to a revocation-bearing compact row.
- SQL deletion requires `action = 'authorize'`, `revocation_order = 0`, and no established-pair marker. Memory cleanup applies the same barrier rule.
- The compact row and `trust_issuer_states.high_water` survive cleanup and restart. An older signed authorization remains rejected; recovery requires a higher issuer sequence and presentation by both participants.

### TDD RED evidence

```bash
TEST_DATABASE_URL='postgresql://mason@localhost:5432/macchannel_task4_third_final_8266?sslmode=disable' \
  go test ./internal/httpapi -run TestMigration005PreservesRevocationBarrierThroughIncompleteReauthorization -count=1 -v
```

```text
upgraded tombstone rows=0 revocation=0 expired=false issuerRows=0
FAIL
```

### Final GREEN evidence

```bash
TEST_DATABASE_URL='postgresql://mason@localhost:5432/macchannel_task4_barrier_8266?sslmode=disable' \
  go test -race ./internal/httpapi -run 'TestMigration005PreservesRevocationBarrierThroughIncompleteReauthorization|TestPostgresExpiredReauthorizationRetainsRevocationAcrossRestart' -count=1 -v
```

```text
--- PASS: TestPostgresExpiredReauthorizationRetainsRevocationAcrossRestart
--- PASS: TestMigration005PreservesRevocationBarrierThroughIncompleteReauthorization
PASS
ok   macchannel/rendezvous/internal/httpapi  2.135s
```

Fresh PostgreSQL and reapply evidence:

```bash
dropdb --if-exists macchannel_task4_barrier_8266
createdb macchannel_task4_barrier_8266
# applied migrations 001-005, then reapplied additive migrations 002-005 with ON_ERROR_STOP=1
```

```text
exit=0
trust compact-state upgrade columns=4
```

Full verification:

```bash
cd Services/rendezvous
go vet ./...
go test -race ./... -count=1
TEST_DATABASE_URL='postgresql://mason@localhost:5432/macchannel_task4_barrier_8266?sslmode=disable' go test -race ./... -count=1
cd ../..
swift test
git diff --check
```

```text
go vet: exit 0, no output
memory Go race: all packages passed
PostgreSQL Go race: exit=0; httpapi 4.166s, presence 1.875s, signal 2.155s
Swift: Executed 47 tests, with 0 failures
git diff --check: exit 0, no output
```

### Concerns

Unchanged from the preceding report: local durable validation used PostgreSQL 16 rather than the planned PostgreSQL 17 deployment image; Swift HTTP adapter, trusted reverse-proxy configuration, and TLS termination remain later integration/deployment scope.
