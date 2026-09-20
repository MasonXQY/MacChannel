# Account route connection owner and composite policy

Date: 2026-09-20. Worktree: `/Users/mason/Documents/ChatGPT/Deepseek/MacChannel/.worktrees/dropmesh-iphone`.
Requirements: `account-route-owner-brief.md`; linked `account-server-route-design.md` supplies provenance only. SQL admission `465930c` was independently approved before this task. Initial HEAD was `4c41d3eb6305b88d669a628e5d7c15c914b8928e`; the coordinator's intervening documentation commit moved HEAD to `0e05ab2688a4a6890137983b087c924c4ccb70b5` without changing this source. The final scoped implementation commit will contain this report and the six new files listed below.

## Result and scope

Implemented an **unwired** `internal/routeauth` package with a bounded connection/queue owner, manual-first composite signal policy and adapter to `PostgresStore.AdmitRoute`. No SQL read/write, listener, HTTP/hub integration, native change, service activation, schema/configuration change, new dependency or deployment occurred. The coordinator's unrelated new `accountauth/native_device_approval_interop_test.go` was not touched or included.

Owned new source/tests:

- `Services/rendezvous/internal/routeauth/connection_owner.go`
- `Services/rendezvous/internal/routeauth/connection_owner_test.go`
- `Services/rendezvous/internal/routeauth/policy.go`
- `Services/rendezvous/internal/routeauth/policy_test.go`
- `Services/rendezvous/internal/routeauth/account_gate.go`
- `Services/rendezvous/internal/routeauth/account_gate_test.go`

The queue owner validates exact P-256 public-key bytes and their derived canonical lowercase device ID. It supports both existing raw64 and SEC1-uncompressed65 representations without rewriting their byte-derived identity. Registration copies the key and returns an opaque handle containing private owner identity plus a monotonic nonzero generation. Duplicate live connections, foreign/stale handles, invalid identities and exhausted counters fail. Close/bind/unbind are exact-handle scoped; old cleanup cannot affect a replacement. Each account binding includes exact SessionActor, group ID and generation, and a separate revision rejects unbind/rebind back to the same values. Binding-version exhaustion retires the account binding and rejects further binding changes while preserving independent manual routing.

Bindings are trusted internal inputs for a future authenticated adapter, not client assertions or membership proofs. Register likewise assumes the future caller already authenticated possession of the key. No access tokens are stored. Handle/binding/owner/policy diagnostic formatting is redacted; bindings refuse JSON serialization. There is no account peer enumeration API.

Resource policy for this **not-enabled component**: constructor queue capacity must be explicit, from 1 through 16 frames; no deployment queue size is silently selected. At most 1024 live connections and 32 per supplied source label, using the existing signal frame maximum of 64 KiB. A global owner ceiling of 64 MiB queued payload applies across all destination queues. Fixed per-connection queue metadata is bounded by the explicit capacity. Rejected enqueue reserves nothing; dequeue transfers its payload and returns the byte budget; close discards its queue and returns its remaining budget. This queue bound is not a bound on arbitrary caller-created concurrent in-flight Route invocations; the future authenticated transport must bound inbound concurrency.

Manual graph authority is queried outside the owner lock and takes precedence over account state, including logout/unbind/account unavailability. Its existing transitive semantics are preserved as supplied by the graph. A valid manual decision followed by a busy/full/stale queue fails without invoking account fallback as a retry. If manual authority is absent/false, the policy snapshots both exact connections and complete bindings, requires equal account/group/generation, and invokes the AccountGate without holding the owner lock. Account grants are pairwise and never published into the legacy graph.

The gate callback uses TryLock, checks BOTH exact handles and BOTH complete bindings/revisions, and performs one nonblocking ring insertion. No SQL/network I/O or waiting occurs in that callback. Payload is copied before authority work and owned by the queued frame. Callback reuse/retention after return is defensively rejected; the gate contract still requires synchronous invocation under authority and forbids retaining it. A callback that already inserted a frame cannot be made retryable by cleanup failure or even an inconsistent post-insertion gate error. The result contains only the already-enqueued authority source and a redacted cleanup-failed flag. All ordinary Route failures map to the same `ErrDenied` (`route unavailable`).

Close never closes a channel and the package creates no worker/drain goroutines. Transports explicitly call TryDequeue, which reports ready/empty/busy/closed. A frame admitted before later account revocation may still drain. Closing a connection instead discards its queued frames.

## TDD and exact commands

Commands ran in `Services/rendezvous`; piped runs used `set -o pipefail`. No database environment variable or SQL fixture was used by this task.

1. Owner tests were written against a minimal failing API stub. `go test ./internal/routeauth -run '^TestOwnerRegistrationAndExactCleanup$' -count=1 -v 2>&1 | tee /tmp/account-route-owner-red.log` exited 1: a valid explicit queue capacity could not create/register the owner (`invalid queue capacity`). After implementation, `go test ./internal/routeauth -run '^TestOwner' -count=1 -v 2>&1 | tee /tmp/account-route-owner-green-initial.log` exited 0, all owner cases passed, 0.795s.
2. Policy tests preceded policy implementation. `go test ./internal/routeauth -run '^TestPolicyManualSurvivesAccountState$|^TestPolicyAccountOnlyOwnsExactRequestAndPayload$' -count=1 -v 2>&1 | tee /tmp/account-route-policy-red.log` exited 1: all five valid manual modes were denied and the account admission gate was never entered (7 failed test entries including parent entries, zero skips). After implementation, `/tmp/account-route-policy-green.log` captured the full then-current package passing, 1.146s.
3. Adapter tests preceded its implementation. `go test ./internal/routeauth -run '^TestAccountGate' -count=1 -v 2>&1 | tee /tmp/account-route-adapter-red.log` exited 1 with `adapter lost admission {false <nil>} route unavailable 0 0`. After implementation the same command writing `/tmp/account-route-adapter-green.log` exited 0, 6 passing entries/0 failures/0 skips, 0.318s.
4. A focused new fail-closed assertion found binding-version exhaustion retained an existing account binding. `go test ./internal/routeauth -run '^TestOwnerBindingValidationAndVersions$' -count=1 -v 2>&1 | tee /tmp/account-route-binding-exhaustion-red.log` exited 1: `exhausted binding version retained account authority`. Clearing/retiring the binding on exhaustion produced `/tmp/account-route-binding-exhaustion-green.log`, exit 0, 12 passing entries, zero failures/skips, 0.314s.
5. Added remaining resource, independent-owner, same-session replacement and scheduling cases. `go test ./internal/routeauth -count=1 -v 2>&1 | tee /tmp/account-route-owner-focused.log` passed with 99 test entries, 21 top-level tests, no failures/skips, 1.511s.
6. Focused race detector ran **once** for this new package: `go test -race ./internal/routeauth -count=1 -v 2>&1 | tee /tmp/account-route-owner-race.log`. Exit 0, 99 passing entries (21 top-level + 78 named subtests), no failures/skips or race reports, 1.933s. This includes concurrent close/registration and close/enqueue/dequeue. After this race run, only source comments/import grouping and a stronger test assertion (replacing a connection while preserving the same exact account session/binding) changed; production behavior was unchanged.
7. Final source/test verification: `gofmt -w internal/routeauth/*.go`; `go test ./internal/routeauth ./internal/signal -count=1 -v 2>&1 | tee /tmp/account-route-owner-final.log`. Exit 0. routeauth: **99 passing entries, 21 top-level + 78 subtests, 89 leaf cases, zero failures/skips**, 0.501s. Existing signal: **1 passed, zero failures/skips**, 0.367s. No tests access PostgreSQL in this slice.
8. Before staging, `git diff -- Services/rendezvous/internal/signal Services/rendezvous/go.mod Services/rendezvous/go.sum` was empty. Scoped staged diff whitespace verification is performed before commit. Process inspection `ps -axo pid,ppid,command | rg '[g]o test|[r]outeauth.test'` returned no matching test child (rg status 1 means no match).

The initial deny-all stubs naturally passed negative cases; those are not represented as negative RED evidence. The exhaustion case is an actual observed state-retention defect with its own behavioral RED/GREEN. The nonblocking owner callback is never paused in production tests: channel barriers pause the injected gate before its callback, while lifecycle changes run through the normal owner methods. Tests use no sleep-based ordering proof. Timeouts only bound test failure waits.

## Evidence coverage and limitations

Covered: exact handles and identical-session replacements on BOTH endpoints; duplicate live registrations; key/UUID/binding validation and input ownership; stale bind/unbind/close; global/per-source connection ceilings and counter exhaustion; full/busy/ring queues; global byte-budget sharing and exact refund after dequeue/close/failed admission; maximum payload and ownership; close/registration/enqueue/dequeue concurrency; manual-only/account-only/overlap/unbind/logout/unavailable modes; independent manual fallback; same-account/group/generation preconditions; direct-only account authority with no mixed transitivity; complete session/account/audience/group/generation changes and same-binding ABA during a gate wait; denied gate/no callback; one enqueue after cleanup error; repeated/retained callbacks; isolated owner incarnations and fresh bindings after owner reconstruction; redacted diagnostics and forbidden binding JSON.

Injected gates prove owner/policy semantics. The adapter test checks exact typed forwarding, synchronous callback and preserved admitted cleanup outcome using an injected store seam; a compile-time assertion verifies `*accountgroup.PostgresStore` satisfies that seam. These tests are **not actual PostgreSQL or HTTP routing integration**. Prior SQL admission evidence belongs to `account-route-admission-report.md` and is not rerun here. Actual composite SQL/HTTP/socket composition, authenticated bind controls, visibility refresh, TURN, native routing and service/topology decisions remain separate gates. Existing legacy hubs, manual Deliver/trust publication, presence and graph storage were untouched.

The SQL gate's database-session-failure limitation is inherited: a server/session failure may release SQL locks independently of the process. There is no claim of distributed atomicity between SQL and an in-memory queue or instantaneous remote teardown. A trusted AccountGate must invoke its callback synchronously while holding authority; a malicious/asynchronous implementation is outside that contract. Manual graph lookup retains the injected graph's existing availability/timing semantics. No runtime input proves login/session/membership until the real gate validates it.

Independent spec and quality review must complete before wiring a caller. No service activation is implied by constructor availability.

## Frozen files and handoff

Final SHA-256 source/test identities:

```text
4050d31b0681cebdeda905c4fd54dd4ee3fea5a5dce54a65f499b6406c808523  account_gate.go
2ad6eb9b926b18b4dbbe7ae9221d3f71d42ff6e6600b920e1512b0a221d63f2b  account_gate_test.go
1ae5e726f710b5d3672db9e24409081c9b9dd65109f80a30805434e7c059ee4e  connection_owner.go
35a31e3e8049e349904d60530e3ef48a6579e0048e147c190769f931f91bb149  connection_owner_test.go
302adfdd6ccb134b9865c94dde8fe1bd46e3d48ac1a9ee2c1ae7478f1298f1d6  policy.go
2ed3758bf002b339ce505053645e7da5a2ced1a560ad14c199d809f2e0d2b449  policy_test.go
```

Coordinator granted the scoped commit slot after final verification. The index was initially empty; the staged file list contains exactly the six owned new Go files plus this report, and `git diff --cached --check` passed. On scoped commit completion, Go source/cache and git index ownership return to root. SQL was never owned or accessed in this task. All tests have exited; no worker/service/child process is left running. Existing dirty native files and root's interop fixture remain outside this commit.
