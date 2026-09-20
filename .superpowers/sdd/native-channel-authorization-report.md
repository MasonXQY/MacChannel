# Opt-in native channel authorization — implementation report

Date: 2026-09-20. Starting revision: `41fbbcae652f9af44af3680e69549c5c28ae3ea6`.
Scope controlled by `native-channel-authorization-brief.md`; consumer-seams plan
was read as its narrower implementation plan/audit. Root owns independent review
and any subsequent integration. This report accompanies the task-only commit.

## Result and boundary

Implemented and locally verified an opt-in factory/channel authorization path.
Final related verification: **158 XCTest, 0 failures, 0 skips**, exit 0.
This is NOT account-transfer readiness, full-package GREEN, shipping/device
acceptance, deployed enforcement, or Store acceptance. No application/runtime
calls the authorized overload. Provider-based attempts/listener wiring is still
future work. No configuration/default/freshness interval, endpoint, UI, server,
crypto/wire material, signing, installation, SQL or remote deployment was changed.
Root explicitly requested focused related regression instead of another unrelated
whole-package OCR run; the prior unresolved Localization OCR failure remains.

Exactly three source/test files plus this report:

- `Sources/MacChannelCore/Connectivity/WebRTCFactory.swift`
- `Sources/MacChannelCore/Connectivity/WebRTCSecureChannel.swift`
- `Tests/MacChannelCoreTests/WebRTCLoopbackTests.swift`

All three were clean at start. Existing dirty source, iPhone, metadata, project,
root HANDOFF/progress and other evidence files were preserved and not staged.
Root maintains the shared handoff; this bounded report is the implementation handoff.

## Implementation

- Added `AuthorizedWebRTCChannelFactory` refinement and distinct concrete overload
  carrying the exact provider and lease. The original public protocol requirement,
  initializer, legacy factory method and concrete channel return type remain.
- Exact requested peer/key equality, provider validation and continuity claim occur
  before driver/delegate construction. The retained gate holds the provider and
  registration; registrations hold only a weak gate callback. Initialization races
  reject a claim invalidated before installation. Pre-delegate, establishment and
  late-result checks prevent fallback to an unguarded result.
- Invalidation synchronously makes the lock-protected gate unavailable, then one
  callback initiates the existing asynchronous close ownership. It does not create
  a task per application frame or per failed admission check. Existing idempotent
  state transport-close/peer teardown tasks drain authentication, backpressure and
  signaling ownership. Terminal close cancels/disposes registration/provider.
- Current registration is checked at authentication entry/resumption/completion,
  handshake sends, queued receive entry/application enqueue, send entry/each
  backpressure resumption/final send, key export, and frame consumption.
- `frames()` remains exactly `AsyncThrowingStream<Data, Error>`. Its unfolding
  wrapper pulls from the existing bounded frame buffer, checking before and after
  `next()`. It adds no forwarding task or second application buffer.
- Same-key account/manual overlap preserves the original continuity; final removal
  or expiry denies. Different-key evidence for a hash-derived device is rejected
  by the existing owner producer validation; no test manufactures an impossible
  valid hash collision. Restoring a withdrawn source never revives the old gate.
- Added internal deterministic test seams alongside the existing `_testOnly`
  helpers: queued operation/receive admission result, post-read delivery barrier,
  and pre-authorized-factory-return barrier. None is public or used by production
  composition; actual WebRTC loopback remains the transport fixture.

## Linearization and compatibility

This is **check-time admission**, not atomic owner/network execution. A successful
registration check admits the immediately following operation. Withdrawal cannot
retract bytes already handed to WebRTC/network, erase a frame already delivered,
or undo a key already returned. The pre-withdrawal loopback frame remains valid;
the next operation is denied. No owner/gate lock is held while invoking WebRTC,
yielding frames, deriving keys, or closing transport. External provider/scheduler
object destruction also occurs outside the gate lock.

Legacy intentional behavior tightening required by the brief: after terminal
close, key export and buffered frame iteration now reject rather than returning
old material. Send remains unavailable. Original terminal receive errors are
preserved (including `messageTooLarge` for a late iterator), not flattened to
`transportClosed`. Existing cancellation/route/handshake tests pass unchanged.
An authorized late-return cancellation check additionally ensures cancellation
during the new final suspension cannot return a successful channel.

No guarantee of remote immediate erasure, atomic SQL/network revocation, or
bounded completion of arbitrary uncooperative external signaling implementations
is claimed. Existing transport cancellation/teardown owns such work. No broader
runtime integration or new timeout policy is included.

## Behavioral RED / GREEN and complete logs

All commands ran in this worktree with selected
`/Applications/Xcode-16.4.0.app/Contents/Developer`, Apple Swift 6.1.2.
Each invocation used `set -o pipefail` and `2>&1 | tee LOG`, retaining complete
stdout/stderr. No deprecated `--skip-update` was used.

1. Initial tests plus inert authorized-overload scaffold (forwarded legacy call,
   no authorization behavior):
   `swift test --disable-automatic-resolution --filter 'WebRTCLoopbackTests/testAuthorized'`
   - `/tmp/native-channel-authorization-red.log`: **3 tests / 4 assertion failures**,
     exit 1, 0.404s. Actual unauthorized send/key export succeeded after withdrawal;
     terminal channel could export. These were behavioral failures, not compile
     failures. The scaffold was then replaced by the real opt-in implementation.
   - `/tmp/native-channel-authorization-green-first.log`: **3 / 0**, exit 0, 0.146s.
     The initial continuity test was later accurately named
     `testAuthorizedPreWithdrawalAdmissionCompletesButNextOperationIsDenied`;
     separate actual buffered-frame tests were added.
2. Deterministic callback/buffer/pending-auth/late-return and mismatch coverage:
   same authorized filter.
   - `/tmp/native-channel-authorization-barriers.log`: **8 / 0**, exit 0, 0.164s.
     Supplemental tests were GREEN on the first implementation; they are not
     falsely described as independently observed pre-implementation RED.
3. First legacy/authorized regression:
   `swift test --disable-automatic-resolution --filter 'WebRTCLoopbackTests|WebRTCFactoryTests|ConnectionCoordinatorTests'`
   - `/tmp/native-channel-authorization-regression-first.log`: **46 / 0**, exit 0,
     1.459s. Actual suites: Loopback 24, ConnectionCoordinator 22. There is no
     separate matching WebRTCFactoryTests suite; factory behavior is in these.
4. Additional lifecycle/error-preservation reproducer:
   `swift test --disable-automatic-resolution --filter 'WebRTCLoopbackTests/testAuthorized|WebRTCLoopbackTests/testLegacy'`
   - `/tmp/native-channel-authorization-lifecycle-red.log`: **15 / 1**, exit 1,
     0.501s. New late iterator test observed `transportClosed` instead of original
     `messageTooLarge`. Fixed the gate to retain the first terminal error.
   - `/tmp/native-channel-authorization-lifecycle-green.log`: **15 / 0**, exit 0,
     0.221s. No assertion relaxation.
5. Late cancellation and suspended iterator probes:
   `swift test --disable-automatic-resolution --filter 'WebRTCLoopbackTests/testAuthorizedLateFactoryCancellation|WebRTCLoopbackTests/testAuthorizedSuspendedIterator'`
   - `/tmp/native-channel-authorization-late-cancellation-probe.log`: **2 / 1**,
     exit 1, 0.406s. Cancellation at the final factory barrier actually returned
     a channel. Added final cancellation check; suspended-iterator test was GREEN.
6. Final verification after all source/test fixes:
   `swift test --disable-automatic-resolution --filter 'WebRTCLoopbackTests|ConnectionCoordinatorTests|PeerAuthorizationOwnerTests|PeerWithdrawalTests|TransferCoordinatorTests'`
   - `/tmp/native-channel-authorization-final-focused.log`: **158 / 0 / 0 skips**,
     exit 0, 8.981s test duration, 3.34s build. No warnings/errors in this log.
   - ConnectionCoordinator 22, PeerAuthorizationOwner 21, PeerWithdrawal 2,
     TransferCoordinator 80, WebRTCLoopback 33 (17 new, 16 unchanged).
   - Includes real local offer/answer, exact-key handshake, ordered frame transfer,
     exporter/MITM, 1 MiB transfer, message caps, callback/pressure capacity,
     candidate/signaling teardown, route fallbacks and transfer regressions.

## Deterministic evidence and limitations

- Queued receive test holds the actual ordered callback queue, inserts application
  receive behind the barrier, withdraws, then releases and observes `admitted=false`.
- Buffered test waits for actual actor enqueue acknowledgement before withdrawing
  and starting iteration. Suspended-consumption test uses a real loopback frame,
  pauses after underlying `next`, withdraws, then verifies no frame is returned.
- Backpressure test waits for the existing actor waiter count and verifies withdrawal
  itself finishes the waiter before explicit close; pending auth test waits for
  the real offer and verifies failure without explicit close.
- Late factory tests hold an authenticated result before its final admission,
  then independently withdraw or cancel. Barrier releases are deferred and task
  cancellation/drain is owned. XCTest timeouts bound positive probes; no new sleep
  is used as proof of non-delivery. Existing waiter polling observes a positive
  actor count; old unrelated tests retain their original sleeps.
- Registration weak-reference disposal and weak channel release are checked after
  invalidation/explicit-close convergence. Existing close/signaling-drain regressions
  remain unchanged and green; no claim of kernel-level close-call instrumentation.
- Exact-key source overlap is tested both directly on real owner/gate and through
  actual loopback channel use. Expiry is tested with the existing deterministic
  owner clock (no wall-clock sleep or default account freshness chosen).
- No shipping build requested or performed in this bounded slice. No full suite
  repeat, real devices, internet/TURN, HTTP/SQL, active accounts or deployed server
  were used as acceptance evidence.

## Frozen source integrity and handoff

SHA-256 of verified source/test files:

```
83730c74a42e3d141e0444c65831de4d374860fa84940090ed7562299511b1a3  WebRTCFactory.swift
d75c9e998375b01c29da0983f287a5e9288fe1899d5d8b92dc903507a305f582  WebRTCSecureChannel.swift
46f544e4958653f69a9113f151ff6f0fd16207e0a24af6abb04725edd42b075e  WebRTCLoopbackTests.swift
```

Scoped `git diff --check` passed. Production-source search found only the new
factory declaration/overload, no consumer call site. Process check after final
run found no `swift-test`, `MacChannelPackageTests`, or `xcodebuild` process.
Root granted the scoped index slot for these four files only. Independent spec
and quality review is still required before any attempts/listener integration;
root coordinates it. Cache/index ownership is released with the commit handoff.
