# Account Route Router Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the smallest opt-in HTTP/WebSocket integration that binds an authenticated account session to one exact authenticated socket generation and routes signal frames through the existing composite account/manual policy in an isolated candidate, without changing legacy or production behavior.

**Architecture:** Reuse `routeauth.ConnectionOwner`, `routeauth.Policy`, `routeauth.PostgresAccountGate`, and `accountgroup.PostgresStore.AdmitRoute` as the only route-authority path, but expose owner/policy operations to HTTP through one opaque `ConnectionRouter` constructed with the same owner. Add an optional router configuration: when absent, `/v1/ws`, `signal.Hub`, and `presence.Hub` behave byte-for-byte as today; when present, the router registers the exact device-proof key and socket generation, accepts a nonce owned by that exact socket generation, binds an exact account session, and drains that connection's bounded route queue. This first integration slice routes signals only; account presence, TURN, production command composition, and remote deployment require separate reviews.

**Tech Stack:** Go, Gorilla WebSocket, existing rendezvous `auth`, `accountauth`, `accountgroup`, `routeauth`, `signal`, and `httpapi` packages, PostgreSQL-backed account/group tests.

## Global Constraints

- [ ] Preserve all existing constructors, interfaces, frame behavior, manual graph semantics, trust publication, presence behavior, and deployed command configuration when the new option is nil.
- [ ] The candidate is additive and default-off. Do not change `Services/rendezvous/cmd/server`, `Services/rendezvous/cmd/accountserver`, production ports, launch agents, images, databases, DNS, secrets, or live processes in this slice.
- [ ] A device-proof-authenticated socket is not account-authorized until a fresh bind succeeds for that exact socket device/key and exact active account session.
- [ ] Never cache a positive Boolean authorization. `ConnectionOwner.Bind` stores identity/session/group coordinates only; every account signal invokes `Policy.Route` and `PostgresStore.AdmitRoute` for fresh two-endpoint SQL admission.
- [ ] Manual authority remains independent and is tried first by the existing composite policy. Account database failure, missing bind, logout, refresh, expiry, or group removal must not deny a valid manual route.
- [ ] Never place access tokens, session IDs, account IDs, group IDs, membership keys, or proofs in logs, peer frames, URLs, WebSocket subprotocols, trust records, or presence events.
- [ ] Admission linearizes only at the existing bounded in-memory queue insertion. A frame admitted before later revocation may drain; subsequent frames must re-enter SQL admission and deny. Do not claim atomic SQL/network delivery.
- [ ] No account presence, account TURN, native client activation, cross-instance signal transport, production deployment, or online acceptance is included.

---

## Existing Reusable APIs

| Existing path | Reuse without redesign |
| --- | --- |
| `internal/routeauth/connection_owner.go` | `NewConnectionOwner`, `Register`, `Bind`, `Unbind`, `Close`, `TryDequeue`, opaque `ConnectionHandle`, generation/binding-version ABA checks, bounded queue and byte ceilings. |
| `internal/routeauth/policy.go` | `NewCompositePolicy` and `Policy.Route`; manual-first behavior, fresh account gate call, exact connection/binding recheck in the SQL callback, uniform `ErrDenied`, no retry after an admitted enqueue. |
| `internal/routeauth/account_gate.go` | `NewPostgresAccountGate`; direct adapter to the reviewed SQL admission primitive. |
| `internal/accountgroup/route_admission.go` | `PostgresStore.AdmitRoute`; validates both exact `SessionActor`s, current group generation/member keys, expiry/revocation, and invokes one bounded enqueue while locks remain held. |
| `internal/accountauth/http.go`, `sessions.go` | Narrowly reuse `AccountSessions.Authenticate(ctx, accessToken, device, audience) (AccountSession, error)` to derive account/session identity from the bearer token instead of trusting caller-supplied IDs. |
| `internal/auth/verifier.go` | `IssueChallengeFor` and `VerifyChallengeFrom` provide replay-store enforcement, but source binding alone is not socket binding. The router must additionally own the nonce in one exact socket-generation state and consume that local ownership before verification. |
| `internal/httpapi/router.go` | Existing signed device challenge, `authenticatedSessions.acquire` handover, connection limiter, strict JSON decoding, `webSocketPeer` serialized writer, trust-record delivery, and legacy signal/presence registrations stay in place. |
| `internal/signal/hub.go` | Retain `Register` and `Deliver` for legacy routing and trust-record fanout. In opt-in mode only the incoming `signal` admission call changes to `routeauth.Policy.Route`; no second send is allowed. |
| `internal/presence/hub.go` | Retain unchanged manual graph visibility. It has no account-pair admission seam and is deliberately not adapted in this slice. |

## Missing Bounded Seams

1. `ConnectionOwner` has no wake-up/lifecycle signal for a router-owned queue drainer. Polling `TryDequeue` would add latency and nondeterminism; routing directly to `webSocketPeer` would violate the reviewed bounded queue admission boundary.
2. Separate `ConnectionOwner` and `Policy` injection can be misconfigured: a policy may enqueue into owner A while the HTTP drainer waits on owner B. An opaque constructor must make that mismatch unrepresentable.
3. `httpapi.Config` cannot receive the resulting route component/session authenticator, and `Router.webSocket` does not retain a `routeauth.ConnectionHandle`.
4. The WebSocket protocol has no socket-generation-owned account bind nonce. `IssueChallengeFor(..., source)` binds only the observed source, so two sockets at the same source require an additional exact local ownership check.
5. No current presence API can run asynchronous two-endpoint SQL admission and atomically reserve symmetric visibility events. Account presence is not a safe part of the signal integration slice.

## Task 1: Add deterministic queue-drain notification without changing admission

**Files:**

- Modify: `Services/rendezvous/internal/routeauth/connection_owner.go`
- Create: `Services/rendezvous/internal/routeauth/connection_router.go`
- Test: `Services/rendezvous/internal/routeauth/connection_owner_test.go`
- Test: `Services/rendezvous/internal/routeauth/connection_router_test.go`

**Interfaces:**

- Produces: `func (o *ConnectionOwner) Notifications(h ConnectionHandle) (<-chan struct{}, error)`
- Produces: `func (o *ConnectionOwner) Dequeue(h ConnectionHandle) (signal.Frame, QueueState)`
- Produces: `func NewCompositeConnectionRouter(capacity int, graph signal.TrustGraph, gate AccountGate) (*ConnectionRouter, error)`
- Preserves: `TryDequeue`, `Register`, `Bind`, `Unbind`, `Close`, and all queue limits.

- [ ] Write failing tests proving `Notifications` rejects a foreign/stale handle, emits after the first enqueue, coalesces multiple queued frames without blocking admission, and closes when the exact handle closes.
- [ ] Write a failing ABA test: close generation N, register replacement N+1 for the same device, and prove the old notification closes while the new notification receives only N+1 work.
- [ ] Add one capacity-1 notification channel to each registered connection. Under the existing owner lock, successful enqueue performs a nonblocking notification send; `Close` discards frames and closes only that generation's notification channel.
- [ ] Add `Dequeue` as the blocking-lock counterpart of `TryDequeue`. It may hold only the short local owner mutex while removing/copying one frame; it must release the mutex before the caller performs JSON/network I/O.
- [ ] When `Dequeue` leaves frames queued, re-arm the coalesced notification before unlocking so a drainer cannot strand work. Return `QueueClosed` for stale/closed handles.
- [ ] Add opaque `ConnectionRouter` holding an unexported owner plus the policy constructed from that same owner. Its methods delegate `Register`, `Bind`, `Unbind`, `Close`, `Notifications`, `Dequeue`, and `Route`; expose neither underlying pointer and accept no independently constructed `Policy`.
- [ ] Test construction coherence by routing through `ConnectionRouter` and draining the same registered handle. Compilation/API shape must make an owner-A/policy-B pair impossible; nil graph/gate retains the existing constructors' fail-closed behavior.
- [ ] Run `go test ./internal/routeauth -count=1`; expect all routeauth tests to pass with no goroutine, queue, or byte leak.

## Task 2: Add a default-off router composition contract

**Files:**

- Modify: `Services/rendezvous/internal/httpapi/router.go`
- Create: `Services/rendezvous/internal/httpapi/account_route.go`
- Test: `Services/rendezvous/internal/httpapi/account_route_test.go`

**Interfaces:**

```go
type AccountRouteSessions interface {
    Authenticate(context.Context, string, string, string) (accountauth.AccountSession, error)
}

type AccountRouteConfig struct {
    Routes   *routeauth.ConnectionRouter
    Sessions AccountRouteSessions
}
```

- [ ] Add `AccountRoutes *AccountRouteConfig` to `httpapi.Config` and a private validated equivalent on `Router`. Nil keeps the existing signal path and creates no routeauth registration, challenge, goroutine, or response field.
- [ ] Reject a non-nil but partially populated option with an immediate constructor panic (`"invalid account route configuration"`). `NewRouter` has no error return, and silently disabling a requested security path would produce a misleading candidate. Nil remains the only legacy/default-off value. Add an exact panic-message test.
- [ ] After successful device challenge and `authenticatedSessions.acquire`, call `Routes.Register(deviceID, authentication.Envelope.PublicKey, source)`. Registration failure returns the existing generic capacity protocol error and never affects the legacy hubs.
- [ ] Retain the returned `ConnectionHandle` for that WebSocket only. Defer `Routes.Close(handle)` using its exact-handle check; close already discards that connection's binding and queue, and a stale disconnect must not clear or close a replacement generation.
- [ ] Start one bounded drainer owned by the WebSocket lifetime. It waits on `Routes.Notifications(handle)`, repeatedly calls `Routes.Dequeue(handle)` until `QueueEmpty`, then calls `peer.SendJSON(frame)` only after all owner locks are released. On write failure it closes the WebSocket. On connection teardown, close the route handle and join the drainer before returning.
- [ ] Keep `signals.Register` and `presence.Connect` unchanged. They still own trust-record delivery and manual presence; the account queue does not publish trust or presence data.
- [ ] Add lifecycle tests for registration failure, queue saturation, writer failure, connection replacement, stale cleanup, and teardown joining. Use deterministic channels/barriers; no sleeps as non-delivery proof.

## Task 3: Bind one exact account session to one exact socket generation

**Files:**

- Modify: `Services/rendezvous/internal/httpapi/account_route.go`
- Modify: `Services/rendezvous/internal/httpapi/router.go`
- Test: `Services/rendezvous/internal/httpapi/account_route_test.go`

**Wire messages:**

```go
// Client request; no credentials.
struct { Type string `json:"type"` } // type = "account-route-bind-challenge"

// Server response, sent only to the requesting socket.
struct {
    Type      string `json:"type"` // "account-route-bind-challenge"
    Nonce     []byte `json:"nonce"`
    ExpiresAt int64  `json:"expiresAt"`
}

// Client request. Envelope payload strictly decodes accountRouteBindPayload.
struct {
    Type     string        `json:"type"` // "account-route-bind"
    Envelope auth.Envelope `json:"envelope"`
}

type accountRouteBindPayload struct {
    Type        string `json:"type"` // "account-route-bind-v1"
    AccessToken string `json:"accessToken"`
    Audience    string `json:"audience"`
    GroupID     string `json:"groupID"`
    Generation  uint64 `json:"generation"`
}
```

- [ ] Extend the private WebSocket input union with only the three new frame shapes: bind-challenge, bind, and `account-route-unbind`. Keep strict decoding and the existing maximum body/read limit.
- [ ] Give each WebSocket loop a private `pendingAccountRouteChallenge` containing copied nonce bytes, expiry, and its exact `ConnectionHandle`. Never store this by source IP or device ID, and never share it through `Router`.
- [ ] For bind-challenge, reject the request while an unexpired pending challenge already exists; otherwise call `IssueChallengeFor(request.Context(), source)`, copy nonce/expiry into that socket-local slot with the current handle, and return only nonce/expiry. Clear the slot on disconnect/replacement.
- [ ] For bind, first compare the envelope nonce in constant time with the socket-local pending nonce, confirm its stored handle equals the current handle, and check expiry. A mismatch (including the same device/key on another socket at the same source) returns generic denial **without calling** `VerifyChallengeFrom`, so it cannot consume or steal the owner socket's replay-store challenge.
- [ ] On a local match, atomically take-and-clear the pending slot **before** signature, device/key, payload, or session validation. Then call `VerifyChallengeFrom` and require the envelope device ID and public-key bytes to equal the socket's initial authenticated envelope exactly. A wrong-key/device/payload attempt on the owning socket therefore burns its one local use even if verifier validation fails before consuming the replay-store entry; the leftover global challenge is unusable because no socket retains local ownership and expires normally.
- [ ] Strictly decode the signed payload and validate canonical group UUID, nonzero generation, bounded token/audience lengths, and exact purpose.
- [ ] Call `Sessions.Authenticate(ctx, accessToken, deviceID, audience)`. Construct `accountgroup.SessionActor` exclusively from its returned `AccountSession`; require returned device/audience to equal the socket/payload. Never accept account ID or session ID from wire input.
- [ ] Call `Routes.Bind(handle, routeauth.AccountBinding{Actor: actor, GroupID: payload.GroupID, Generation: payload.Generation})`. The binding is coordinates, not authority; do not call or cache a membership Boolean. Every later account signal still goes through `AdmitRoute`.
- [ ] Erase references to the decoded token after the synchronous authenticate call and never include authentication errors or binding fields in logs/responses. Return only `{"type":"account-route-bind-ok"}` or `{"type":"account-route-bind-error","code":"unavailable"}`.
- [ ] `account-route-unbind` clears the pending nonce, calls `Routes.Unbind(handle)`, and returns a generic success. It does not disconnect the socket or alter manual signal/presence.
- [ ] Tests must deny wrong signing key/device, replayed/foreign challenge, malformed/oversized payload, wrong returned device/audience, invalid group/generation, expired/revoked token, binding theft, stale handle, and old access token after refresh. Rebind with a newly authenticated session replaces only this exact handle's binding.
- [ ] Add the explicit theft matrix: socket A and socket B share observed source; A's nonce submitted on B is denied without consuming A's challenge; B's nonce signed with the wrong key consumes B's local slot; retrying the correct signature on B is denied until B obtains a new challenge; replacement/disconnect makes the old nonce unusable even for the same device/key.

## Task 4: Route opt-in signal frames through the existing composite policy

**Files:**

- Modify: `Services/rendezvous/internal/httpapi/router.go`
- Test: `Services/rendezvous/internal/httpapi/account_route_test.go`
- Test: `Services/rendezvous/internal/httpapi/account_route_postgres_test.go`

**Interfaces:**

- Consumes: `ConnectionRouter.Route(ctx, handle, target, payload) (routeauth.RouteOutcome, error)`
- Consumes: `PostgresStore.AdmitRoute` through `routeauth.NewPostgresAccountGate`.

- [ ] When `AccountRoutes == nil`, retain the exact existing `signals.Route(deviceID, target, payload)` branch and its current error mapping.
- [ ] When configured, validate signal target/payload shape, then call `Routes.Route` exactly once with the current handle. Do not call `signals.Route` before or after it; a successful account/manual enqueue must never be duplicated.
- [ ] For the opt-in path expose `invalid_frame` only for local payload-size/empty validation and `unavailable` for every policy/target/account denial. Do not reveal offline target, missing bind, group mismatch, session expiry, database outage, or queue saturation.
- [ ] Add WebSocket tests proving manual-only, account-only, and overlapping authority. Removing either overlapping source preserves the other; removing the final source denies the next signal. Manual A-B plus account B-C must never route A-C.
- [ ] Add exact socket-generation tests: replace the destination after policy snapshot, rebind either endpoint, or disconnect during SQL validation; the callback must enqueue nothing to the stale generation.
- [ ] Add the real PostgreSQL router test under `DROPMESH_GROUP_TEST_DATABASE_URL`: seed two active sessions and one validated group, bind both actual WebSockets, route once, commit member removal/logout, then prove the next route returns uniform denial and no frame. Use the existing `PostgresStore`, `PostgresAccountGate`, and database barriers; a fake gate alone is insufficient evidence.
- [ ] Add DB failure coverage showing a valid manual route still succeeds because `Policy` tries manual first, while an account-only route fails closed without enqueue.

## Task 5: Regression and isolated-candidate handoff

**Files:**

- Test: `Services/rendezvous/internal/httpapi/router_test.go`
- Documentation/evidence: only the task-specific report approved by the task owner.

- [ ] Run focused routeauth, accountgroup admission, and httpapi tests first; record exact commands, counts, skips, and the database fixture used.
- [ ] Run `go test ./internal/routeauth ./internal/accountgroup ./internal/httpapi -count=1`, then `go test ./... -count=1` from `Services/rendezvous`.
- [ ] Prove a nil `AccountRoutes` option preserves all legacy WebSocket authentication, signal error mapping, trust-update delivery, presence, pairing, and TURN tests.
- [ ] Build an `httptest` candidate from `httpapi.NewRouter` using `NewCompositeConnectionRouter(capacity, registry, NewPostgresAccountGate(groups))` and the same `PostgresSessions` used by the account handler. This is the acceptance composition for this slice; no separate owner/policy values exist to mismatch.
- [ ] Obtain independent spec/security and quality reviews before adding a runnable candidate command or touching the existing host.
- [ ] For the later approved isolated deployment, use a distinct process/service label, port, endpoint, account test database/schema, replay store, manual registry/store, and candidate credentials. Do not reuse or replace the production rendezvous listener, production account listener, production manual database, production coturn secret, or production launch unit. That operational plan must include rollback and exact health/WebSocket probes.

## Explicitly Deferred Seams

- **Account presence:** `presence.Hub` currently accepts a synchronous `TrustGraph` and performs direct sink delivery. It cannot reuse `AdmitRoute` safely without a source-aware, symmetric bounded reservation API. Keep it manual-only; design account visibility separately.
- **TURN:** existing `/v1/turn-credentials` requires `TrustRegistry.IsEstablishedDevice`. Account relay issuance and allocation-revocation limitations remain a separate reviewed slice.
- **Production composition:** neither deployed command receives `AccountRouteConfig` in this slice. A new candidate command/service is preferable to silently adding account DB access to the legacy rendezvous process.
- **Native activation:** no native client emits bind frames or selects a candidate route endpoint yet. Server tests do not establish end-to-end account transfer readiness.
- **Cross-instance routing:** `ConnectionOwner` is process-local. The candidate supports only sockets connected to the same instance; no cached remote authorization Boolean or best-effort forwarding may substitute for the SQL-held local enqueue boundary.

## Acceptance Checklist

- [ ] Nil configuration is behavior-compatible and production remains unchanged.
- [ ] Bind authority is exact to signed socket device/key, authenticated account session, and opaque connection generation.
- [ ] A bind nonce is locally owned by one exact socket generation, one-use even on wrong-key failure, expired/cleared on teardown, and cannot be consumed by another socket sharing source/device/key.
- [ ] HTTP configuration receives one coherent opaque route component; an owner/policy mismatch is not representable.
- [ ] Every account-only signal performs fresh two-endpoint SQL admission and one bounded exact-generation enqueue.
- [ ] No positive Boolean, group snapshot, or bind success is reusable as route authority.
- [ ] Manual signal and presence remain independent when account state fails or is withdrawn.
- [ ] Queue draining performs no network I/O under SQL or owner locks and joins on teardown.
- [ ] Real-PostgreSQL router evidence covers bind, route, revocation, and subsequent denial.
- [ ] Presence, TURN, runnable deployment command, remote operations, and native activation remain explicitly unclaimed.
