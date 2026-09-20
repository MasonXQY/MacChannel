### Spec Compliance

- ❌ Issues found. The opaque `ConnectionRouter`, copied/default-off configuration, exact socket-local nonce ownership, fresh SQL-backed route admission, bounded coalesced queue, and real PostgreSQL revocation path are present. However, the shared WebSocket input change is not nil-mode wire compatible (`Services/rendezvous/internal/httpapi/router.go:849-858`), and the required router-level lifecycle/adversarial acceptance matrix is substantially absent (`Services/rendezvous/internal/httpapi/account_route_test.go:42-260`).
- ⚠️ Evidence limitation: the implementer report documents that an earlier run destructively truncated the preserved synthetic fixture and then overwrote the failed log (`.superpowers/sdd/account-route-router-report.md:57-65`). The later root-owned fresh-cluster serialized runs replace the functional SQL evidence, but they do not undo the fixture-preservation failure. No production data was involved, and both clusters were reported stopped.

### Strengths

- `Services/rendezvous/internal/httpapi/router.go:133-140` validates partial opt-in configuration and copies the two-field configuration, so later mutation of the caller's struct cannot silently disable or swap the route components.
- `Services/rendezvous/internal/httpapi/account_route.go:99-143` keeps nonce ownership on the exact socket handle, checks a foreign nonce before touching the replay verifier, consumes a locally matching nonce before signature/session checks, derives actor identity through `Authenticate`, and stores no access token in the binding.
- `Services/rendezvous/internal/routeauth/connection_owner.go:149-166` and `Services/rendezvous/internal/routeauth/connection_owner.go:182-190` scope close and notification lifetime to the opaque generation; `Services/rendezvous/internal/httpapi/account_route.go:69-97` drains outside the owner lock and joins the single drainer on teardown.
- `Services/rendezvous/internal/routeauth/connection_router.go:16-64` constructs policy and owner together and exposes only opaque-handle operations, making owner-A/policy-B composition unavailable through this API.
- Focused external contract check for cached-authority risk: unchanged `Services/rendezvous/internal/routeauth/policy.go:76-108` invokes `AccountGate.Admit` for every account-authorized frame and permits one synchronous exact-generation enqueue; unchanged `Services/rendezvous/internal/routeauth/account_gate.go:26-30` delegates each call directly to `PostgresStore.AdmitRoute`. No reusable membership Boolean or group snapshot was introduced.
- `Services/rendezvous/internal/httpapi/account_route_postgres_test.go:164-223` uses actual WebSockets and actual Postgres session/group components, proves the refreshed token succeeds after the old access token is rejected, delivers once, revokes the family, then observes uniform denial and no destination frame.

### Issues

#### Critical (Must Fix)

None.

#### Important (Should Fix)

1. `Services/rendezvous/internal/httpapi/router.go:849-858` — Adding `Envelope auth.Envelope` to the common frame struct changes decoding even when `AccountRoutes == nil`. A legacy `signal` or `trust-update` frame containing an unrelated `"envelope"` value such as a string was ignored at the base revision because the field was unknown; the head now tries to decode it as `auth.Envelope`, fails `ReadJSON`, and disconnects the socket. That contradicts the brief's exact default-off compatibility contract. The existing compatibility test uses a well-typed envelope and therefore misses the regression (`Services/rendezvous/internal/httpapi/account_route_test.go:51-70`). Preserve the envelope as `json.RawMessage` (or decode a legacy union first) and decode it only for enabled `account-route-bind`; add a nil-config regression with an invalidly typed/opaque `envelope` on a legacy frame. For enabled account frames, validate the selected variant strictly so extra cross-variant fields are rejected as required rather than silently accepted by the broad union.

2. `Services/rendezvous/internal/httpapi/account_route_test.go:42-260` — The task's required WebSocket/router acceptance matrix is not implemented. The seven tests cover partial config, one nil-mode case, basic manual/account delivery, nonce ownership/expiry, and replacement nonce rejection, but omit router-level registration failure, queue saturation, writer failure, stale-cleanup behavior, deterministic teardown joining, malformed/oversized bind payloads, wrong returned device/audience, invalid group/generation, rebind semantics, overlapping authority removal/no-transitive routing, exact-generation replacement/rebind/disconnect during SQL validation, and DB-failure manual-survival behavior. `connection_owner_test.go` and prior policy tests cannot establish WebSocket registration/error mapping, drainer/writer lifetime, or router composition behavior; the brief explicitly requires these router-level tests. Add deterministic barrier/channel tests in `internal/httpapi` for the listed lifecycle and authorization cases, including an intentionally failing writer and proof that teardown does not return before its drainer exits.

#### Minor (Nice to Have)

None.

### Assessment

**Task quality:** Needs fixes

**Reasoning:** The authority path and opaque bounded queue composition are well structured, but default-off compatibility is observably broken by typed decoding in the shared frame union. The missing router-level lifecycle and adversarial tests also leave the most failure-prone integration behavior unverified despite explicit acceptance requirements. No tests were rerun during this read-only review; `git diff --check 9406924..8ae6148` was clean.
