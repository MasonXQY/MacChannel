# Opt-In Native Channel Authorization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in authorization-consumption path to the concrete WebRTC factory/channel so an exact existing `PeerAuthorizationLease` is checked and claimed before channel activation, then checked again whenever application work is admitted.

**Architecture:** Leave the existing `WebRTCChannelFactory` requirement, public factory call, concrete return type, manual callers, attempts/listener constructors, and production composition unchanged. Add a refining authorized-factory interface and an authorized concrete overload. The authorized channel owns a synchronous availability gate plus the existing `PeerAuthorizationRegistration`; invalidation marks the gate unavailable synchronously and then joins the channel's existing asynchronous close ownership. Provider wiring into attempts/listener and application/runtime composition are later, separately reviewed slices.

**Tech Stack:** Swift 6, Swift actors and `AsyncThrowingStream`, WebRTC data channels, XCTest, existing `PeerAuthorizationProviding`, `PeerAuthorizationLease`, and `PeerAuthorizationRegistration` APIs.

## Audit Result and Scope Boundary

At audited source revision `0426d47`, `WebRTCConnectionAttempts` and `WebRTCConnectionListener` authorize only through `TrustRepository.publicKey(for:)`, and `MobileForegroundRuntime` / `MobileProductionForegroundNetwork` have no account authorization consumer wiring. The reviewed producers therefore grant no production transport or app capability yet.

The controlling scope for the next slice is `.superpowers/sdd/native-channel-authorization-brief.md`:

- Modify only `Sources/MacChannelCore/Connectivity/WebRTCFactory.swift`, `Sources/MacChannelCore/Connectivity/WebRTCSecureChannel.swift`, and focused tests in `Tests/MacChannelCoreTests/WebRTCLoopbackTests.swift`.
- Do not modify current dirty identity, runtime, account, UI, directory, Mesh, endpoint, server, signing, or Store seams.
- Do not select an account freshness interval or activate account authorization in production. Freshness remains explicit configuration for a later whole-app composition gate.
- Do not change crypto material, handshake payloads, wire format, or route behavior.
- Do not use `PeerAuthorizationSnapshot` as authority and do not log keys, leases, proofs, credentials, or tokens.
- Do not claim account transfer readiness, full-app acceptance, reachable-service acceptance, signed-device acceptance, or online acceptance.

## Precise Linearization Contract

`requireCurrent()` defines **check-time admission**, not atomic revocation of transport effects. An application operation whose final check succeeds before withdrawal is admitted and may complete after withdrawal. In particular, withdrawal cannot retract bytes already handed to WebRTC/the network, erase a frame already delivered to a caller, or atomically undo a derived key already returned.

The implementation must ensure only that callbacks, iterations, sends, and exports reaching their admission check after withdrawal are denied. It must recheck after every relevant suspension to narrow the race window, then perform the immediate non-suspending admission action. It must not hold the authorization owner's lock while calling `sendData`, yielding a stream element, deriving/exporting a key, closing WebRTC, or executing any arbitrary transport/network callback. A stricter atomic check-and-consume guarantee would require a new owner-held bounded-admission API and is outside this slice.

---

## Task 1: Add behavioral RED tests for the opt-in channel path

**Files:**

- Test: `Tests/MacChannelCoreTests/WebRTCLoopbackTests.swift`

- [ ] Add an authorized loopback fixture that creates a real local WebRTC pair with an exact provider/lease, while leaving every existing fixture on the legacy factory call unchanged.
- [ ] Add deterministic barrier tests, with no sleeps as non-delivery proof, for:
  - peer/key mismatch or an already-invalid lease rejects before delegate/handshake activation;
  - withdrawal while authentication is pending fails the waiter and closes through existing close ownership;
  - withdrawal while send is backpressured causes the post-suspension check to deny before `sendData`;
  - a receive callback queued before withdrawal but admitted afterward cannot enqueue application work;
  - a frame buffered before withdrawal but iterated afterward is denied rather than returned;
  - key export attempted after withdrawal is denied;
  - a late authorized factory result cannot return an unguarded channel;
  - invalidation racing explicit close closes once, drains existing waiters, and releases the registration without a retain cycle;
  - removal of one identical manual/account source preserves the lease continuity, while final removal, expiry, or a conflicting key denies it.
- [ ] Add a linearization test showing the documented boundary: an operation admitted before withdrawal is allowed to finish, while the next operation is denied. Do not assert retraction of bytes already handed to WebRTC.
- [ ] Keep legacy factory/channel/coordinator tests unchanged and green to prove source and behavior compatibility.

## Task 2: Add a source-compatible authorized factory overload

**Files:**

- Modify: `Sources/MacChannelCore/Connectivity/WebRTCFactory.swift`
- Test: `Tests/MacChannelCoreTests/WebRTCLoopbackTests.swift`

- [ ] Leave the existing `WebRTCChannelFactory.connect(...) -> WebRTCSecureChannel` requirement exactly source compatible. Existing conformers and callers must require no edits.
- [ ] Add a refinement such as `AuthorizedWebRTCChannelFactory: WebRTCChannelFactory` with a distinct overload carrying `authorizationProvider: any PeerAuthorizationProviding` and `authorizationLease: PeerAuthorizationLease`; make `WebRTCFactory` conform while retaining its legacy method.
- [ ] Before creating/activating the driver, require `authorizationLease.peer == remoteDevice`, `authorizationLease.publicKey == remotePublicKey`, and successful `authorizationProvider.validate(authorizationLease)`.
- [ ] Pass the exact provider and lease through driver/channel construction. The authorized overload must never fall back to the legacy unguarded method after authorization failure.
- [ ] Revalidate the lease after any factory suspension and before returning the late channel. On failure, use the existing owned close path and return the established authentication/transport error; never leak a usable result.
- [ ] Preserve the concrete `WebRTCSecureChannel` return type, cancellation, timeout, signaling, and driver lifetime behavior of the legacy API.

## Task 3: Claim continuity before delegate or handshake activation

**Files:**

- Modify: `Sources/MacChannelCore/Connectivity/WebRTCSecureChannel.swift`
- Test: `Tests/MacChannelCoreTests/WebRTCLoopbackTests.swift`

- [ ] Keep the current initializer/call path available for legacy callers. Add an internal authorized construction path rather than making authorization mandatory globally.
- [ ] Add a package-internal `WebRTCPeerAuthorizationGate` with an `NSLock`-protected unavailable flag and retained `PeerAuthorizationRegistration`.
- [ ] Claim the exact lease before assigning the RTC data-channel delegate or starting authentication. If claim/validation fails, construction fails without activating the channel.
- [ ] Avoid a retain cycle: the registration callback must not strongly retain the channel/state, and the gate/channel must release or cancel the registration on terminal close/deinitialization.
- [ ] Invalidation must synchronously mark the gate unavailable, then schedule/join the channel's single existing close owner to finish authentication and backpressure waiters, terminate frames, close RTC, and close the underlying transport.
- [ ] Do not create an unbounded task per frame or per failed check. Reuse the state actor and idempotent close task.
- [ ] `requireCurrent()` first reads the local unavailable flag, then calls `registration.requireCurrent()`. Never hold the gate or authorization-owner lock across actor suspension, WebRTC calls, stream yields, or arbitrary callbacks.

## Task 4: Fence actual application-work admission

**Files:**

- Modify: `Sources/MacChannelCore/Connectivity/WebRTCSecureChannel.swift`
- Test: `Tests/MacChannelCoreTests/WebRTCLoopbackTests.swift`

- [ ] On the authorized path, check current registration at authentication entry and again after authentication suspension before returning success.
- [ ] Check at the start of every queued `State.received(_:)` execution and immediately before application-frame enqueue.
- [ ] Check at send entry, after each backpressure suspension, and immediately before the non-suspending `sendData` call.
- [ ] Check key-export entry immediately before derivation/return, and handshake completion before making the channel externally usable.
- [ ] Gate buffered-frame consumption, not just receipt. The iterator returned by `frames()` must check immediately before and after awaiting its next buffered element and must not return that element if the later check fails.
- [ ] Preserve the linearization boundary: once the last check passes, the immediately following non-suspending operation is admitted even if withdrawal races afterward. Document this in the code/tests; do not promise atomic network retraction.
- [ ] After terminal channel closure, send, receive iteration, and key export remain unavailable even if an equivalent authorization source later reappears. A withdrawn continuity never revives.
- [ ] Preserve legacy error and cancellation behavior. For the opt-in path, authorization failure during establishment maps to the existing authentication failure; withdrawal after establishment maps to the existing terminal/transport-closed behavior.

## Task 5: Verify only the bounded channel slice

**Files:**

- Evidence/report update only if separately authorized by the task owner; do not modify production composition reports as part of this slice.

- [ ] Run the focused `WebRTCLoopbackTests` RED/GREEN sequence and the existing focused factory/channel/coordinator regression tests.
- [ ] Save complete command output with exact revision, commands, counts, failures/skips, and deterministic probe results.
- [ ] If requested after focused review, run the package suite and unsigned shipping build; describe the latter as compile evidence only.
- [ ] Obtain independent spec and quality review before dispatching provider-based attempts/listener wiring.
- [ ] Report explicitly that no application/runtime consumer calls the authorized overload yet.

## Future Protected Integration Seams — Audit Only, Not Authorized in This Slice

### Provider-based attempts/listener overloads

Future review should cover `Sources/MacChannelCore/Connectivity/ConnectionCoordinator.swift` and `Tests/MacChannelCoreTests/ConnectionCoordinatorTests.swift`. Add source-compatible provider-based overloads alongside the existing repository constructors; do not replace or break existing Mac/manual callers or factory conformers. Each route/offer would acquire one lease, validate after ICE and other suspensions, call only an `AuthorizedWebRTCChannelFactory`, validate the late result, and close on failure. The existing repository paths remain until every caller is explicitly mapped and reviewed.

### Identity/account production composition

Future review should separately cover `Sources/MacChannelCore/Identity/AuthenticatedTrustSnapshotStore.swift`, `Sources/DropMeshMobileRuntime/MobileIdentityContext.swift`, and `iPhone/App/ProductionMobileAppDependencies.swift`. That slice must decide the account freshness value/configuration explicitly, prove default-off behavior, and create one shared owner for manual/account producers. No freshness default or app activation is selected here, and these currently dirty/protected files must not be changed by the channel slice.

### Foreground runtime policy and withdrawal

Future review should separately cover `Sources/DropMeshMobileRuntime/MobileProductionForegroundNetwork.swift`, `Sources/DropMeshMobileRuntime/MobileForegroundRuntime.swift`, `Tests/DropMeshMobileRuntimeTests/MobileProductionForegroundNetworkTests.swift`, and `Tests/DropMeshMobileRuntimeTests/MobileForegroundRuntimeTests.swift`. That slice must distinguish authorization updates from manual trust persistence, keep snapshots as coarse policy projections only, preserve listener/network drain ownership, and prevent repository-only cancellation from rejecting account-only peers. It must not change Bonjour/manual discovery until the corresponding app-routing scope is approved.

## Acceptance Checklist for the Next Slice

- [ ] Existing public factory calls, protocol conformers, manual callers, concrete channel return type, and coordinator tests remain source compatible.
- [ ] The opt-in factory path carries and claims the exact provider/lease before delegate or handshake activation.
- [ ] Post-withdrawal callbacks/iterations cannot newly admit send, receive delivery, or key export work.
- [ ] Buffered frames are checked when consumed, and suspended sends are checked again after resumption.
- [ ] Same-key independent-source survival retains continuity; final removal, expiry, conflict, or terminal close denies it.
- [ ] Tests and code state the check-time admission boundary and do not claim atomic retraction of prior WebRTC/network effects.
- [ ] No owner lock is held during arbitrary channel/network callbacks and no per-frame unbounded task is introduced.
- [ ] No attempts/listener, identity, account, runtime, UI, endpoint, Mesh, server, or app activation is included.
- [ ] Evidence remains bounded to channel/factory verification and does not claim account transfer or full-app acceptance.
