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

---

## Final presence-refresh race remediation — 2026-08-26

### Status

Fixed the final Important presence race in commit `2733bfc` (`fix: serialize presence graph refreshes`). Targeted independent re-review approved the result with no remaining Critical or Important findings.

- Every graph query carries an epoch captured before the query and may apply only while that epoch is current.
- Global refresh, device refresh (including `Connect`), fail-closed invalidation, and disconnect are serialized through one transition lock.
- The transition remains ordered through presence delivery, so an older online batch cannot overtake the offline batch produced by revocation or fail-closed handling.
- An unrelated connection can register while a global refresh is blocked, but its device-local refresh queues behind the global security refresh and cannot cancel the remaining revoked-pair work.

### TDD RED evidence

The first regression reproduced the delayed-query reinstall before the epoch guard:

```bash
go test -race ./internal/presence \
  -run TestOlderBlockedGraphQueryCannotReinstallVisibilityAfterFailClosed \
  -count=1 -v
```

```text
=== RUN   TestOlderBlockedGraphQueryCannotReinstallVisibilityAfterFailClosed
    hub_test.go:129: unexpected stale presence event={Type:presence DeviceID:right Availability:internet}
--- FAIL: TestOlderBlockedGraphQueryCannotReinstallVisibilityAfterFailClosed
FAIL
```

The follow-up regression then exposed the device-local epoch preemption in the initial implementation:

```bash
go test -race ./internal/presence \
  -run TestUnrelatedConnectCannotPreemptGlobalRevocationRefresh \
  -count=1 -v
```

```text
=== RUN   TestUnrelatedConnectCannotPreemptGlobalRevocationRefresh
    hub_test.go:186: timed out waiting for offline presence for right
--- FAIL: TestUnrelatedConnectCannotPreemptGlobalRevocationRefresh (1.00s)
FAIL
```

### Final GREEN evidence

The two deterministic adversarial interleavings passed twenty consecutive race-enabled runs:

```bash
go test -race ./internal/presence \
  -run 'Test(OlderBlockedGraphQueryCannotReinstallVisibilityAfterFailClosed|UnrelatedConnectCannotPreemptGlobalRevocationRefresh)' \
  -count=20 -v
```

```text
PASS
ok   macchannel/rendezvous/internal/presence  5.571s
```

Full verification:

```bash
cd Services/rendezvous
go vet ./...
go test -race ./... -count=1
TEST_DATABASE_URL='postgresql://mason@localhost:5432/macchannel_task4_barrier_8266?sslmode=disable' \
  go test -race ./... -count=1
cd ../..
swift test
git diff --check
```

```text
go vet: exit 0, no output
memory Go race: all packages passed; httpapi 2.261s, presence 2.290s, signal 1.800s
PostgreSQL Go race: all packages passed; httpapi 4.639s, presence 2.484s, signal 1.709s
Swift: Executed 47 tests, with 0 failures (0 unexpected)
git diff --check: exit 0, no output
```

### Self-review

- Lock acquisition is consistently transition lock then hub state lock; no reverse-order path exists.
- Graph reads remain outside the hub state lock, while the transition lock prevents a narrower refresh or fail-closed operation from overtaking the query and its resulting event batch.
- `Connect` registers the client before its serialized device refresh. If a global refresh is already active, that device refresh queues and runs afterward without invalidating the global epoch.
- Production WebSocket sink writes are deadline-bounded, limiting the liveness cost of preserving event order through delivery.

### Concerns

No new concern from this remediation. The previously recorded PostgreSQL-version, Swift HTTP adapter, trusted reverse-proxy, and TLS deployment concerns remain unchanged.

---

# Task 4 addendum: Notification Settings and Transient Popovers

## Outcome

- Added a narrow `ReceiveNotificationServicing` seam to `AppSurfaceController` and adapted the existing `ReceiveNotificationController`.
- The app observes notification authorization snapshots for each installed surface controller and mirrors them into `SettingsSurfaceModel`.
- Settings show a compact native `接收通知` row: notification-capable states read `已允许`; unavailable states read `未允许`; only `.denied` exposes `打开系统设置`.
- All standard menu-bar popovers use `AppSurfaceController.standardPopoverBehavior == .transient`.
- `invalidate()` cancels the notification observer. `closeActiveSurface()` remains a `performClose(nil)` call only, with no transfer cancellation.

## RED evidence

The required tests were added before production code and run with fresh isolated scratch paths:

1. `swift test --scratch-path /tmp/macchannel-task4-red-popover.LgbkNa --filter TransferSurfaceTests.testMenuBarSurfacesUseTransientPopovers`
   - Exit 1, expected compile errors: missing `ReceiveNotificationServicing`, `AppSurfaceController.standardPopoverBehavior`, notification-service initializer, and settings notification snapshot/action.
   - No new residual `MacChannelPackageTests.xctest` PID.
2. `swift test --scratch-path /tmp/macchannel-task4-red-denied.hFuyld --filter TransferSurfaceTests.testDeniedNotificationPermissionOffersSystemSettingsAction`
   - Exit 1 with the same expected missing-feature compile errors.
   - No new residual `MacChannelPackageTests.xctest` PID.

## GREEN and full-suite evidence

- `swift test --scratch-path /tmp/macchannel-task4-green-surface.GDE50N --filter TransferSurfaceTests`
  - Exit 0; 46 tests, 0 failures; no new residual test PID.
- `swift test --scratch-path /tmp/macchannel-task4-green-status.GAKNjD --filter StatusItemAppKitTests`
  - Exit 0; 19 tests, 0 failures; no new residual test PID.
- `swift test --scratch-path /tmp/macchannel-task4-full-verified.T93z5j`
  - Exit 0; 628 tests, 3 skipped, 0 failures; no new residual test PID.
  - Final suite log confirmed the direct-LAN integrity harness also passed.

Existing PIDs 38136, 49361, 80713, 82338, 25679, 28690, and 29145 were not touched. The final residual-process check contained only the pre-existing 25679, 28690, and 29145 test processes.

## Changed files

- `App/AppSurfaceController.swift`
- `App/MacChannelApp.swift` (narrow wiring of the already-owned notification controller into the new surface seam)
- `App/SettingsView.swift`
- `Tests/MacChannelCoreTests/TransferSurfaceTests.swift`

## Self-review

- The notification row is independent of the device-settings availability gate and has no custom notification toggle.
- The system settings action is guarded by `.denied`; authorized/provisional/ephemeral states have no action.
- `configuredPopover()` is the common factory for transfer, pairing, and settings surfaces, so all three receive `.transient`.
- No animation was added; the pre-existing accessibility-respecting popover animation setting is unchanged.
- `closeActiveSurface()` contains only the popover close action; it has no transfer cancellation call.
- `git diff --check` passed before commit preparation.

## Concerns

No blocker. This task intentionally does not add a new status-bar icon, branding, distribution work, or any transfer cancellation behavior.

---

# Task 4 reviewer remediation: notification authorization refresh

## Outcome

- Added `ReceiveNotificationController.refreshAuthorizationState()`, which re-queries the system notification adapter and publishes the resulting snapshot to active observers.
- Added the narrow async `ReceiveNotificationServicing.refreshReceiveNotifications()` seam and invoke it whenever the DropMesh Settings popover is presented.
- Added focused coverage for both external permission transitions: denied to authorized and authorized to denied.
- Strengthened the observer-lifecycle test with retained, controllable stream continuations: after invalidate, rebind, and re-observe, yielding through the old continuation cannot mutate the current settings model; the current continuation can.
- No app-activation observer was added because this app currently has no focused activation lifecycle hook; presentation-time refresh is the narrow existing-architecture integration point.

## RED evidence

```bash
swift test --scratch-path /tmp/macchannel-task4-review-red2.b6uUlW \
  --filter ReceiveNotificationControllerTests.testRefreshingAuthorizationRequeriesTheSystemAndPublishesExternalChanges
```

- Exit 1, as expected before implementation. The compiler reported missing `ReceiveNotificationController.refreshAuthorizationState()` and `AppSurfaceController.refreshReceiveNotifications()`.
- The unrelated test-autoclosure mistake from the first RED attempt was corrected before this recorded RED run.
- No new `MacChannelPackageTests.xctest` process remained. The only observed PIDs were pre-existing 25679, 28690, and 29145; baseline PIDs 38136, 49361, 80713, 82338, 25679, 28690, and 29145 were not touched.

## GREEN evidence

```bash
swift test --scratch-path /tmp/macchannel-task4-review-green-receive.LoNT6N \
  --filter ReceiveNotificationControllerTests
swift test --scratch-path /tmp/macchannel-task4-review-green-surface.rRxQOE \
  --filter TransferSurfaceTests
```

- Both commands exited 0 with no new residual test process.
- `ReceiveNotificationControllerTests`: 9 tests, 0 failures.
- `TransferSurfaceTests`: 47 tests, 0 failures.
- The residual-process checks again showed only the pre-existing 25679, 28690, and 29145 test processes.

## Changed files

- `App/ReceiveNotificationController.swift`
- `App/AppSurfaceController.swift`
- `Tests/MacChannelCoreTests/ReceiveNotificationControllerTests.swift`
- `Tests/MacChannelCoreTests/TransferSurfaceTests.swift`

## Concerns

No blocker. Permission status is refreshed whenever Settings is opened; it is not continuously polled while Settings remains open.

---

# Task 4 second reviewer remediation: stale refresh isolation

## Outcome

- Replaced the untracked Settings refresh task with an `AppSurfaceController`-owned task.
- Each new refresh cancels the preceding refresh and advances a generation token; `invalidate()` also advances the token, cancels the task, and clears its reference.
- `ReceiveNotificationController` now applies authorization results only when the query is still current and its task was not cancelled. A late older query therefore cannot overwrite a newer result or publish into a replacement surface observing the shared controller.
- Settings still refresh notification permission every time the Settings popover opens. The denied/authorized presentation and transient popover behavior are unchanged.

## RED evidence

The controlled-delay regressions were added first and run with an isolated scratch path:

```bash
swift test --scratch-path /tmp/dropmesh-task4-red.x0vRfL \
  --filter 'ReceiveNotificationControllerTests.testOutOfOrderAuthorizationRefreshPublishesOnlyNewestResult|TransferSurfaceTests.testInvalidatingSurfaceCancelsInFlightNotificationRefresh|TransferSurfaceTests.testNewNotificationRefreshCancelsEarlierInFlightRefresh'
```

- All three selected tests failed for the intended reasons before production changes:
  - the older denied result overwrote the newer authorized result;
  - invalidation did not cancel the in-flight refresh;
  - a later refresh did not cancel the preceding refresh.
- A separate process check immediately afterward showed only the pre-existing test PIDs 25679, 28690, and 29145.

## GREEN evidence

```bash
swift test --scratch-path /tmp/dropmesh-task4-green.KBXHDT \
  --filter 'ReceiveNotificationControllerTests|TransferSurfaceTests'
swift test --scratch-path /tmp/dropmesh-task4-green.KBXHDT
```

- Focused suites: 60 tests, 0 failures.
  - `ReceiveNotificationControllerTests`: 11 tests, including explicit cancelled-late-result and out-of-order-result coverage.
  - `TransferSurfaceTests`: 49 tests, including invalidation and consecutive-refresh cancellation.
- Full Swift suite: 634 tests, 3 Docker-only skips, 0 failures.
- The direct-LAN integrity harness passed with identical source/destination SHA-256 values.
- Both commands exited normally. Final residual-process checks showed only pre-existing PIDs 25679, 28690, and 29145. Protected PIDs 38136, 49361, 80713, 82338, 25679, 28690, and 29145 were not signalled or killed.
- `git diff --check` passed.

## Changed files

- `App/AppSurfaceController.swift`
- `App/ReceiveNotificationController.swift`
- `Tests/MacChannelCoreTests/ReceiveNotificationControllerTests.swift`
- `Tests/MacChannelCoreTests/TransferSurfaceTests.swift`

## Concerns

No blocker. The query generation is process-local by design; notification authorization remains the system source of truth and is re-queried on every Settings presentation.

---

# Task 4 third reviewer remediation: authorization request and refresh serialization

## Outcome

- Added a shared in-flight authorization request to `ReceiveNotificationController`. Every concurrent `prepare()` or Settings refresh now waits for the same system authorization result instead of launching a competing read-only query.
- The request completion publishes its authoritative result before waiting notification flows resume, and advances the existing query generation so any older read-only refresh cannot overwrite it.
- Preserved the existing refresh-vs-refresh latest-result guard, task-cancellation guard, and `AppSurfaceController.invalidate()` generation isolation.
- Added a controlled interleaving regression that pauses both the initial authorization query and the system authorization request, starts a Settings refresh during the request, and proves the refresh does not suppress the first notification or its authorized snapshot.

## RED evidence

```bash
swift test --scratch-path /tmp/dropmesh-task4-fix3-red.Ac7jYL \
  --filter ReceiveNotificationControllerTests.testRefreshDuringAuthorizationRequestCannotSuppressFirstNotification
```

- Exit 1 before the production change, with four expected failures.
- The refresh launched a second authorization query, no notification was delivered, and the final snapshot remained `.notDetermined` after the authorized request result was discarded.
- No new residual test process remained after the run.

## GREEN evidence

```bash
swift test --scratch-path /tmp/dropmesh-task4-fix3-green.BYJ7uV \
  --filter 'ReceiveNotificationControllerTests|TransferSurfaceTests'
swift test --scratch-path /tmp/dropmesh-task4-fix3-green.BYJ7uV
```

- Focused suites: 61 tests, 0 failures (`ReceiveNotificationControllerTests` 12/12 and `TransferSurfaceTests` 49/49).
- Full Swift suite: 635 tests, 3 Docker-only skips, 0 failures.
- The direct-LAN integrity harness passed with identical source and destination SHA-256 values.
- The new controlled concurrency regression also passed 20 consecutive `--skip-build` runs.
- `git diff --check` passed. Final residual-process checks showed only the pre-existing UE PIDs 25679, 28690, and 29145. Protected PIDs 38136, 49361, 80713, 82338, 25679, 28690, and 29145 were not signalled or killed.

## Changed files

- `App/ReceiveNotificationController.swift`
- `Tests/MacChannelCoreTests/ReceiveNotificationControllerTests.swift`

## Concerns

No blocker. The system authorization prompt remains single-shot per process, and notification authorization remains system-owned; subsequent Settings presentations continue to refresh the external state.
