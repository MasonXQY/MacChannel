# Account route connection owner and composite queue policy

Next bounded implementation of account-server-route-design.md after independently
Approved SQL admission465930c. Read that design for provenance and manual boundaries;
only the scope below is authorized now. No HTTP/socket wire activation in this task.

## Owned scope

New Services/rendezvous/internal/routeauth package: connection_owner.go, policy.go,
account_gate.go and focused corresponding tests. No changes to existing hubs,
router, native sources, SQL schema, deployed commands or configuration. Preserve
all unrelated dirty files. No new dependencies, raw access tokens or credentials.

## Contract

Build the actual bounded in-memory destination queue owner needed by the approved
SQL callback. Owner handles exact authenticated device ID, exact owned canonical
public key bytes and opaque monotonically changing connection handle. Reject
duplicate live registration, malformed/mismatched identity, stale handles and
counter exhaustion. Existing capacities1024 global/32 per source and64KiB signal
payload ceiling can be reused from signal package where exported; queue capacity
must be explicit constructor input, strictly positive and bounded by documented
resource policy. Do not silently select a deployment queue size.

Account binding is internal trusted composition state, not proof from a client:
exact SessionActor plus group ID/generation, supplied only by a future authenticated
adapter. An attached binding itself grants nothing. Never store access tokens.
Bind/unbind/close are exact-handle scoped; old cleanup cannot clear replacement
connections. Validate/copy keys and binding inputs, keep diagnostic output redacted.
Server restart has no connections/bindings. No account peer enumeration API.

Composite signal admission takes the exact source handle, target ID and copied
bounded payload. Try independent manual graph authority first; valid manual route
must survive account unavailable/logout/unbind. If manual fails, snapshot exact
source/target connection contexts, require same account/group/generation, then use
an AccountGate adapter to PostgresStore.AdmitRoute. The callback uses a nonblocking
owner lock, atomically rechecks BOTH connection handles and BOTH complete account
bindings (including session replacement), and nonblocking-enqueues the frame to
the exact target queue. No DB calls or network IO under owner lock; no owner lock
held while entering SQL. Changes between snapshot and callback reject. A failed
TryLock/full queue inserts nothing. The queue owns its payload; no later mutation.

Admitted cleanup error is diagnostic only and must never invoke a second enqueue
or automatic fallback/retry. Do not expose a detached Boolean capability. Uniform
external denied/unavailable errors must not disclose account/group membership or
peer inventory. Manual Deliver/trust publication and transitive graph behavior
remain untouched; do not insert account edges into the legacy graph. New package
has no default activation or caller until separately reviewed and composed.

Connection close must not race channel send/close or leak drain goroutines. Prefer
explicit nonblocking dequeue/closed state owned by this package rather than an
unbounded worker; future transport owns network draining. An already admitted frame
may drain after later revocation; no claim of instantaneous remote delivery teardown.
Document SQL session-failure limitation inherited from the approved admission gate.

## Tests and handoff

TDD focused RED/GREEN for exact handles/replacement, capacity/full/busy queue,
input ownership, stale bind/unbind/cleanup, malformed identities, manual-only,
account-only, overlap/manual fallback, no account transitivity, same-account/group
checks, session or binding replacement while gate awaits, no callback/no enqueue
when gate denies, at-most-once on admitted cleanup failure, and independent owners.
Use deterministic scheduler barriers, no sleep-based race proof. Production owner
callback must remain nonblocking; test-only pauses can emulate scheduling outside
the actual enqueue. Cover close/registration race with focused race detector once.

Injected gates may prove owner semantics; distinguish that from actual SQL routing
integration. Existing SQL admission already has real PostgreSQL evidence, but its
future composite/HTTP harness remains a separate required gate. No SQL fixture
ownership is needed for this task. Run focused routeauth and existing signal tests.

Report .superpowers/sdd/account-route-owner-report.md with commands/counts/logs,
RED/GREEN, exact source revision and limitations. Commit only owned new files after
root grants index slot. You own Go cache only; Swift cache belongs to another agent.
Ask before any scope expansion. Independent review precedes HTTP/hub integration.
