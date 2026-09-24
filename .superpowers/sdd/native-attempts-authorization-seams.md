# Native attempts/listener authorization seam audit

Read-only source audit, 2026-09-20. Observed HEAD
`b9ae1046993808970374f978e4cafa82f54f7c84`; authorized factory/channel implementation
is `e4730ce`. No implementation, tests, build, cache, index or HEAD changes made
by this task. Only this new document is written. This is a bounded proposal for
root's next brief, not permission to activate runtime/account/server behavior.

## Current seams and smallest compatible change

In `Sources/MacChannelCore/Connectivity/ConnectionCoordinator.swift`:

- `WebRTCConnectionAttempts.connect(...connectionID:)` (line 622) checks LAN
  endpoint, reads repository key, awaits ICE, calls the legacy factory, then awaits
  a second repository key lookup. It has no provider/lease path.
- `WebRTCConnectionListener.accept(_:)` (line 816) does the analogous
  repository checks, then checks `stopped` and publishes to one selected consumer.
- Existing coordinator fallback terminates on authentication failure/cancellation/
  peer-unavailable/trust-forbidden, but retries other errors on later routes.
- `PeerAuthorizationProviding` offers synchronous acquire/validate/claim.
  `AuthorizedWebRTCChannelFactory` retains the concrete channel return and adds
  an exact provider/lease overload; its channel already claims continuity and
  guards actual send/receive/export admission. No second lifetime authority or
  snapshot-driven cancellation reader is needed here.

Recommended minimal source scope: `ConnectionCoordinator.swift` and focused tests
in `ConnectionCoordinatorTests.swift` (plus a loopback test/helper only if needed).
Add provider-based initializers to **attempts and listener**, with the existing
`ice` and `iceProvider` forms. Replace the `trustRepository:` parameter in the NEW
overloads with `authorizationProvider: any PeerAuthorizationProviding`, and require
`factory: any AuthorizedWebRTCChannelFactory = WebRTCFactory()`. Keep every current
repository initializer, concrete-return contract and existing factory conformer.

Internally use a paired mode enum, e.g. legacy(repository, legacyFactory) versus
authorized(provider, authorizedFactory), rather than unrelated optional fields,
runtime casts or a fallback to unguarded `connect`. Public provider calls must not
accept a factory implementing only the legacy protocol. Account-only provider
authorization must not additionally require repository membership.

`ConnectionCoordinator(attempts:)` already composes the new attempts; no new
coordinator convenience initializer is required for the smallest slice. An additive
provider convenience is harmless but not needed to prove the seam. Replacing all
repository constructors or teaching TrustRepository account membership is rejected:
it expands scope and loses source provenance.

## Exact authorized outbound flow

1. Check task cancellation; acquire **one** lease for the requested peer before
   the first suspension. Require lease peer equality; use only its public key.
   Map acquisition/validation denial to `ConnectionAttemptError.authenticationFailed`.
2. For LAN, await the existing directory endpoint lookup. Recheck cancellation and
   the same lease even when the endpoint is absent, then return routeUnavailable
   if absent. Do not relax LAN discovery or synthesize endpoints from snapshots.
3. Await fresh route-specific ICE. On successful resumption, recheck cancellation
   and the same lease immediately before the authorized factory call.
4. Call ONLY the authorized overload, with unchanged identity, route, offerer role,
   signaling, and UUID/transferID mapping. Never reacquire a replacement lease
   within this attempt, even if the same key is later reauthorized.
5. After factory suspension, check cancellation and validate the same lease before
   returning. Once a concrete channel exists, every rejected exit must **await**
   its close before throwing; do not place close in an unowned detached task or
   throwing defer. No suspension between the final checks and successful return.
6. Error paths matter: if ICE/factory throws, preserve CancellationError first,
   otherwise validate the old lease before propagating a transport error. A revoked
   attempt must become terminal authentication failure, not timeout/transportClosed
   that causes coordinator fallback to acquire a new continuity. If lease remains
   valid, preserve existing transport/fallback classifications.

Each separately started route obtains its own lease. This does not claim one lease
for the entire coordinator or forever bar later genuinely authorized connections.
Provider errors should be mapped to fixed error cases before existing diagnostic
paths; never log lease/key/provider descriptions or new account evidence.

## Exact authorized inbound flow and stop ownership

- Keep `beginAccepting` admission caps (8 global through existing capacity constant,
  2 per device) and install each task token before any await. Do not spawn a second
  untracked acceptance task for provider work.
- At accept entry, require not stopped/not cancelled, acquire one exact offer-peer
  lease; recheck stopped/cancelled/lease after LAN lookup and ICE. No factory call
  may start after a resumed acceptance discovers stop or withdrawal.
- After factory returns, the acceptance owns the channel until successful yield.
  Recheck stopped, task cancellation and that exact lease; on any rejection await
  channel.close inside the owned acceptance. Immediately yield through the current
  consumer without another await. Preserve missing-consumer, dropped and terminated
  closure behavior for both concrete `channels()` and transfer `connections()`.
- Preserve stop's first transition, cancellation of reader/acceptance tasks, captured
  owners and shared `drainTask`. `stopAndWait` must join that same retirement even
  after prior/concurrent stop. A cancellation-ignoring factory returning late must
  have its result closed before the acceptance completes and drain returns.
- Do not remove an acceptance token before its channel-close work finishes. Token
  completion must not retire another acceptance. Preserve reader ownership before
  `incomingOffers()` suspension and no restart after stop.
- No new lifetime claim/updates task is required before the factory: withdrawal
  during blocked ICE is denied when that await resumes; it is not promised to
  synchronously abort an uncooperative ICE dependency. Existing stop/drain keeps
  ownership. The factory/channel handles active channel invalidation.

Check-time boundary remains: publication admitted before withdrawal may complete;
already handed-off channels are closed/fenced by their own gate. The existing
legacy-channel stream buffers 32 objects; `finish()` does not retract them.
The transfer stream uses zero-buffer handoff. Do not claim either stream erases
prior results. This slice need not change consumer-replacement semantics or create
a new established-channel registry; stronger stream-retraction policy would be
a separate requirement. It must prevent a new post-stop/post-withdrawal admission.

## Focused behavioral test matrix for the next implementation

Use a forwarding authorized factory spy (legacy overload fails if called), real
PeerAuthorizationOwner and existing real channel loopback for successful/late
results. Keep the concrete factory return type; do not introduce a fake
SecureChannel return solely to simplify tests. Test doubles may hold ICE/factory
completion with deterministic barriers; always release in cleanup and await owners.

1. Existing repository initializers/factory conformers compile and all current
   coordinator tests pass unchanged. Provider-only peer absent from repository
   succeeds through the authorized overload, for outbound and inbound roles.
2. Exact provider/lease, peer/key, route and connectionID propagate; transfer retry
   preserves transferID. Denied or wrong-peer lease reaches no factory.
3. Withdraw/expire during blocked ICE; release with success AND error. No factory
   call; outbound terminal authentication failure prevents route fallback.
4. Hold a real late channel result; withdraw or cancel, then release. Channel is
   closed before outbound throws/inbound acceptance retires; no new publication.
   Also cover factory throwing ordinary timeout after withdrawal (no fallback).
5. Same-key manual/account source removal leaves the lease valid and succeeds;
   final removal denies. Remove/regrant same key while suspended never substitutes
   a new lease. Conflict evidence remains fail-closed under existing owner rules.
6. Stop during ICE, factory, and offer-reader startup; nonjoining stop followed by
   stopAndWait, repeated/concurrent stop, and a factory ignoring cancellation.
   Observe explicit barrier/drain completion and late-channel closure, not sleeps
   as proof of nondelivery. Preserve caps and capacity recovery after rejection.
7. Exercise both listener consumer modes: waiting zero-buffer receiver, no receiver/
   terminated consumer, and legacy queue overflow; rejected handoffs own close.
   Check old buffered object semantics separately from application-frame admission.
8. Regression: unchanged coordinator fallback/ICE freshness, listener restart rules,
   signal mailbox replacement, WebRTCLoopbackTests and relevant transfer coordinator
   stop/drain tests. Save actual RED before implementation and full focused logs.

No full app/runtime composition, freshness default, presence/directory changes,
Mesh behavior, endpoint/server edits, signing or deployment belongs to this slice.
Independent review remains required before any subsequent runtime activation.
