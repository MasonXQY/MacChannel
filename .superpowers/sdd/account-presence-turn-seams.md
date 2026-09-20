# Account presence and TURN: next integration seams

Date: 2026-09-20

Read-only design audit against the current approved account-route implementation. No Go test, SQL command, build, index operation, deployment, or live-service action was performed. This note does not activate either capability and does not expand the product beyond account-authorized presence and relay issuance already identified in `account-server-route-design.md`.

## Decision

Implement presence and TURN as two later, separately reviewed opt-in slices behind the existing default-off `AccountRouteConfig`. Reuse the exact socket/session/group coordinates already owned by `routeauth.ConnectionRouter` and fresh `accountgroup` pair admission. Do not write account membership into `auth.TrustRegistry`, do not add account edges to `presence.TrustGraph`, and do not turn a successful check into a cached Boolean.

The deployable isolated candidate remains later work. Neither slice changes `cmd/server`, `cmd/accountserver`, production configuration, native activation, DNS, credentials, or relay processes.

## Current constraints found in source

- `routeauth.Policy.Route` snapshots both opaque connection generations and bindings, invokes `AccountGate.Admit` for every account-only frame, then performs one nonblocking exact-generation enqueue inside the gate callback. This is the authority pattern to preserve.
- `ConnectionOwner` has fixed connection, per-source, queue-count, and global queued-byte bounds. Its snapshot/enqueue methods are private, so a new consumer cannot safely reconstruct generation fencing outside the coherent router.
- `presence.Hub` computes one symmetric `visible` graph from `TrustGraph.DevicesInGraph`, emits directly to sinks after releasing its mutex, and has only global `FailClosed`. It has no source ownership, exact connection handle, bounded account-event reservation, or asynchronous pair-admission seam.
- `presence.TrustGraph` is the manual transitive graph. Feeding account membership into it would incorrectly make manual A-B plus account B-C discoverable as A-C and would publish account state through manual trust/presence paths.
- `turnCredentials` accepts only the legacy strict payload `turn-credentials-v1`, authenticates a signed HTTP envelope, requires `registry.IsEstablishedDevice`, and calls `turn.Mint` for a fixed ten-minute credential. It has no exact target, account binding, target socket, or session deadline.
- Coturn REST credentials are reusable until their encoded expiry. The rendezvous process has no allocation identifier or coturn control connection. Account/session revocation can stop later issuance, but cannot recall a credential already issued or instantly terminate an allocation created with it.
- `PostgresStore.AdmitRoute` already validates exact source and destination sessions, account status, journal generation, current membership keys, database time, and connection-generation callback while following the established SQL-to-local-lock order. Its current result does not expose the minimum session-validity deadline needed to cap a TURN credential.

## Slice A: source-aware account presence

### Do not bolt account state onto the graph

Account presence must remain a direct-pair source. The manual graph continues to own its current transitive semantics. A separate account poller must not call `TrustGraph.DevicesInGraph`, publish trust records, modify `trust_pair_states`, or call global `presence.Hub.FailClosed`. An account database outage withdraws only the account source; any manual source for the same pair remains visible.

Running an independent second presence hub is also incorrect: an account-only `offline` event could hide a still-valid manual pair, and each hub would lack the other's source state. The minimal compatible change is source-aware union state inside the existing hub, with the legacy constructor and `Connect` behavior preserved.

### Minimal interfaces

Add an opaque presence connection token without changing legacy callers:

```go
// internal/presence; fields remain private and generation-scoped.
type ConnectionHandle struct { /* hub, device, generation */ }

func (h *Hub) ConnectOwned(deviceID, source string, sink Sink) (
    ConnectionHandle, func(), error,
)

// Existing Connect delegates to ConnectOwned and discards the handle.
func (h *Hub) Connect(deviceID, source string, sink Sink) (func(), error)
```

Replace the single Boolean pair entry internally with source bits (`manual`, `account`) while keeping wire `presence` events unchanged. Manual refresh updates only the manual bit. The account adapter updates only the account bit. Emit `internet` only when the union changes from no source to at least one source, and `offline` only when the final source disappears.

The SQL callback cannot perform network writes. Add a private, bounded reservation method used only by the coherent account-presence adapter:

```go
// Internal/private contract; names illustrative.
reserveAccountPair(left, right presence.ConnectionHandle, visible bool) (
    commit func() []presence.Delivery, ok bool,
)
```

`reserveAccountPair` must use a nonblocking hub lock, recheck both exact handle generations, reserve both symmetric event slots or neither, and update the account source atomically. The returned deliveries drain only after the account gate returns and all SQL/hub locks are released. Do not expose an arbitrary callback, sink, client map, or reusable `CanSee` result.

Each refresh attempt also carries a private monotonically increasing pair/source epoch plus the two expected binding versions. A successful admission or a denial may apply only if that epoch, both presence handles, both route handles, and both binding versions are still current. Admission denial/DB failure has no SQL callback, so account-source withdrawal is a separate local exact-epoch operation; it never needs authority to remove authority. This prevents a slow failed refresh from erasing a newer successful rebind and prevents a slow success from publishing after a later withdrawal.

Keep composition coherent by adding account-presence operations to `routeauth.ConnectionRouter` (or an opaque sibling constructed in the same constructor with the same owner). Do not inject a separate owner/policy pair. The router supplies exact route handles/bindings and calls the existing `AccountGate.Admit` with a `RouteAdmissionRequest`; the callback performs only the bounded presence reservation. The adapter never inserts a signal frame and never treats a previous presence success as signal authority.

### Refresh and withdrawal

- Immediate bounded refresh triggers: successful bind/rebind, unbind, connection registration/close, and local account-source state change.
- Periodic cleanup is allowed only as an explicitly configured candidate value; do not silently make the earlier proposed 250 ms interval a production default.
- Candidate enumeration must be bounded. Snapshot at most the existing connection maximum, group candidates by exact account/group/generation coordinates, cap pair checks per pass, retain a cursor for later passes, and limit concurrent SQL admissions. Never launch an unbounded goroutine per pair. Worst-case pair work must be measured before choosing cadence.
- Every candidate pair receives fresh two-endpoint gate admission. Missing binding, different account/group/generation, removed member, revoked/expired session, DB error, stale handle, reservation saturation, or cancellation clears/retains no account authority.
- A revocation that commits before admission produces no new online reservation. A reservation admitted first may emit once; the next refresh withdraws the account bit. This is the same honest linearization limit as signal routing, not instantaneous distributed revocation.
- Disconnect emits offline only to peers for which the union loses its final source. Old-generation cleanup cannot alter a replacement token. Account refresh failure must not call manual `FailClosed`.

### Bounds

Use explicit fixed limits for: connected principals (reuse 1024/32 source limits), account candidate checks per pass, concurrent SQL admissions, per-connection pending presence events, total pending presence events, and refresh work duration. Symmetric event reservation is all-or-none. Saturation fails closed for the account source and schedules bounded retry; it never blocks SQL while waiting for a sink. Network writes retain existing deadlines and occur after locks.

## Slice B: account-authorized TURN issuance

### Preserve the legacy endpoint

The exact legacy `turn-credentials-v1` payload, manual `IsEstablishedDevice` decision, response shape, ten-minute `turn.Mint`, and public error mapping remain unchanged when account routing is absent or when the legacy purpose is used. Add a distinct strict purpose such as `account-turn-credentials-v1` with one canonical `targetDeviceID`; do not add optional account fields to the legacy variant.

The source must already have a current account-bound WebSocket connection whose exact device/key matches the signed HTTP envelope, and the target must be a current bound connection. The request supplies no account ID, session ID, group ID, generation, or target key. Those coordinates come only from the two current owner snapshots. If the product later decides account TURN need not require the source WebSocket to be online, that is a new authority contract and is outside this seam.

### Required pair/deadline gate

TURN needs the same pair checks as routing plus a validity deadline. Factor the SQL validation inside `accountgroup` so route admission and relay admission share one implementation and lock order, then add a narrow result/callback rather than copying queries:

```go
type RelayAdmissionRequest = RouteAdmissionRequest // or a shared PairAdmissionRequest

type RelayAdmission struct {
    Admitted     bool
    ValidUntil   time.Time // minimum of both exact sessions/families
    CleanupError error
}

func (s *PostgresStore) AdmitRelay(
    ctx context.Context,
    request RelayAdmissionRequest,
    reserve func(validUntil time.Time) bool,
) (RelayAdmission, error)
```

The callback runs synchronously at most once after the final database-current-time check and while the same authority locks remain held. It performs only a nonblocking exact-generation/binding-version recheck and reserves one bounded HTTP result slot; it does not mint, write HTTP, call coturn, or reenter SQL. If reservation fails, issue nothing. Cleanup uncertainty after reservation is diagnostic and must not cause a second credential.

Add the corresponding private `ConnectionRouter.AdmitRelay` method so HTTP code cannot combine one owner's snapshot with another policy. It tries manual authorization first using the unchanged legacy path. The account purpose uses only direct account-pair admission and returns one uniform unavailable/forbidden response for offline target, missing bind, invalid membership, DB outage, or saturation.

### Credential lifetime

Keep `turn.Mint` untouched for manual clients. Add a narrow account helper such as:

```go
func MintUntil(deviceID string, now, validUntil time.Time,
    maximumLifetime time.Duration, secret []byte) (Credential, error)
```

Expiry is the earliest of `validUntil` and the explicitly configured account maximum lifetime. Reject nonpositive/overflowing lifetimes. Preserve the opaque HMAC-derived username and never include device/account/session/group/target identifiers in the username, logs, or error body. The earlier 30-second value remains a proposed candidate setting, not a production default; configuration must be explicit and separately accepted.

Most importantly, expiry limits authentication for new TURN use; it does **not** guarantee that coturn destroys an allocation at that instant. The current rendezvous/coturn design has no allocation revocation channel. Logout, group removal, credential expiry, or account unbind therefore stops new issuance and eventually prevents new authenticated relay use, but cannot instantly retract an already authenticated allocation. Do not claim immediate relay teardown or an upper bound on an existing allocation's lifetime without a separate coturn control/allocation design and real relay evidence.

## Composition order for the isolated candidate

1. Land and independently review source-aware presence union/reservation with fake-gate barriers and existing manual regressions. Keep it default-off.
2. Land and independently review relay pair/deadline admission plus `MintUntil`, preserving the manual endpoint byte-for-byte. Keep it default-off.
3. Compose both only in `httptest` with the existing coherent `ConnectionRouter`, `PostgresAccountGate`/store, `PostgresSessions`, actual presence hub, and TURN credential verifier. No deployed command yet.
4. After code review, use a fresh disposable PostgreSQL cluster and a separate test coturn instance/secret. Only then consider a dedicated isolated candidate process/port under a separate operational plan.

## Required test matrix

### Presence

- Nil option: all existing manual presence tests and wire events remain unchanged.
- Manual-only, account-only, and overlap: withdrawing either overlap source preserves online; withdrawing the last source emits one symmetric offline transition.
- Manual transitive A-B-C remains manual behavior; manual A-B plus account B-C never exposes or authorizes A-C. Account membership never appears in trust records or manual graph APIs.
- Bind/rebind/unbind, source and destination disconnect/replacement, stale cleanup, revoked/expired/refreshed session, removed member, generation rebuild, inactive account, cancellation, and DB outage.
- Barrier races: revoke wins before reservation -> no online; reservation wins -> at most one online and later account withdrawal; binding/connection generation changes while SQL is paused -> no stale event.
- Symmetric reservation saturation, hub-lock contention, per-source/global capacity, writer failure, slow writer, joined teardown, bounded retry/cursor, and no SQL/network work under the hub/owner lock.
- Cross-instance limitation is explicit: each process reveals only its locally connected peers; no cached remote presence authority.

### TURN

- Legacy payload, status codes, response fields, ten-minute expiry, and manual trust behavior are unchanged with the option nil and enabled.
- Strict account purpose rejects extra/cross-variant fields, malformed/uppercase target, self-target, absent/offline target, missing/stale bind, wrong socket key, different account/group/generation, old refreshed token/session, removed member, inactive account, DB error, cancellation, and result-slot saturation with uniform public errors.
- Manual-valid/account-unavailable still mints through the manual branch. Account-only calls fresh pair admission on every request; no earlier presence/signal/relay success is reusable.
- Source/target replacement, unbind, or rebind while the gate is paused prevents reservation. Callback twice/late, cleanup uncertainty, and retry cannot mint twice.
- `MintUntil` uses the earlier session deadline and explicit cap, preserves opaque username/HMAC verification, rejects expired bounds, and never logs raw credentials or proofs.
- Real disposable SQL barriers cover logout/removal/expiry ordering. A separate real coturn test records: credential works before expiry, new authentication fails after expiry, and any already-created allocation behavior is measured and reported without claiming instant revocation.

### End-to-end candidate harness

With disposable SQL and test relay only: bind two exact sockets -> account presence online -> account signal -> account TURN issuance -> logout/remove -> later signal and issuance deny -> account presence withdraws, while an overlapping manual pair remains online/routable/relay-eligible. This is isolated candidate acceptance, not native, deployed, cross-instance, or production acceptance.

## Explicit non-goals and open acceptance decisions

- No account-derived manual trust, transitive graph edge, directory/list-members API, invitation flow, background native activation, or cross-instance broker.
- No production refresh cadence or account TURN lifetime is chosen here. Both require load/UX/relay evidence and explicit configuration.
- No promise of instantaneous peer-channel or TURN-allocation closure. Native consumption-time channel checks remain required, and relay allocation revocation would require a separate approved control-plane design.
- No deployment topology decision is made. The current account server and transfer rendezvous remain separate until the isolated candidate composition and operational review are approved.
