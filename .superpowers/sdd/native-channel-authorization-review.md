# Native channel authorization — independent review

## Spec compliance

- ✅ Spec compliant. The authorized overload claims and validates the exact provider lease against the requested peer and public key before peer/delegate construction, while the original factory protocol and legacy overload remain source-compatible (`Sources/MacChannelCore/Connectivity/WebRTCFactory.swift:106-129,185-217`; `Sources/MacChannelCore/Connectivity/WebRTCSecureChannel.swift:33-53`).
- ✅ Registration continuity is retained for the gate/channel lifetime, invalidation synchronously closes admission under the gate lock, external registration/provider destruction occurs outside that lock, and exact termination releases both (`WebRTCSecureChannel.swift:23-100,208-215`). The callback holds the gate weakly and the driver callback holds peer state weakly, avoiding an owner/channel/registration cycle (`WebRTCSecureChannel.swift:42`; `WebRTCFactory.swift:326-328`).
- ✅ Application admission is rechecked at send entry and after every backpressure suspension, immediately before `sendData`, at exporter admission, at receive callback consumption/enqueue, and both before and after buffered frame suspension (`WebRTCSecureChannel.swift:183-197,439-520,556-580`). Withdrawal therefore cannot newly admit queued or buffered application work; an operation whose final check already succeeded may complete, matching the documented check-time linearization (`WebRTCSecureChannel.swift:21-22`).
- ✅ Authentication and factory return are rechecked across suspension boundaries; cancellation and a late invalid result close/abort rather than returning an unguarded channel (`WebRTCFactory.swift:219-254,420-464`; `WebRTCSecureChannel.swift:439-446,703-777`).
- ✅ Invalidation joins existing close ownership, finishes authentication/backpressure/frame waiters, and uses one bounded close task rather than spawning work per frame (`WebRTCSecureChannel.swift:588-600,755-798`). Ordered callback work remains capacity-bounded with one drain owner (`WebRTCSecureChannel.swift:272-313`).
- ✅ Same-key manual/account overlap preserves continuity, while final source removal, expiry, stale leases, and conflicting evidence deny (`Tests/MacChannelCoreTests/WebRTCLoopbackTests.swift:183-215,245-268`). No snapshot is accepted as channel authority.
- ✅ Legacy behavior and errors remain compatible except for the brief-required terminal tightening: raw legacy construction uses an inert gate, the original factory signature/return type is unchanged, original terminal receive errors are retained, and closed send/export/buffered iteration reject (`WebRTCSecureChannel.swift:31,122-165,755-798`; `WebRTCFactory.swift:185-198`; `WebRTCLoopbackTests.swift:270-299`).
- ⚠️ Runtime evidence was not rerun during this cache-free review. Root reports the focused related run as 158 XCTest with 0 failures and 0 skips, plus an Xcode 27 unsigned shipping main-and-Share build and embedded-privacy check both passing. These are test/compile evidence only; this review does not claim whole-package, installed-device, deployment, provider-wiring, or account-transfer readiness.

## Strengths

- The factory handles the subtle claim-installation race: a callback that invalidates during `claim` makes installation reject, and an invalidation between initial validation and handler installation immediately runs the handler (`WebRTCSecureChannel.swift:39-62`).
- `frames()` wraps the existing bounded stream directly, adds no forwarding task or second buffer, and rechecks after a suspended `next()` before returning data (`WebRTCSecureChannel.swift:183-197`).
- The implementation preserves precise terminal errors by storing the gate error before finishing the stream, while ordinary authorization withdrawal maps established channels to `transportClosed` and pending authentication to `authenticationFailed` (`WebRTCSecureChannel.swift:85-98,755-798`).
- Deterministic tests cover withdrawal after pre-admission, backpressure, already-buffered frames, queued callback admission, pending authentication, stale/mismatched lease, late result/cancellation, registration disposal, explicit-close races, same-key overlap, expiry, legacy errors, and post-read suspension (`WebRTCLoopbackTests.swift:7-318`).

## Issues

### Critical

None.

### Important

None.

### Minor

None.

## Assessment

**Task quality:** Approved

**Reasoning:** The opt-in path implements exact, check-time authorization without broad activation or false atomicity claims. Its synchronous gate, bounded actor/queue ownership, terminal cleanup, legacy compatibility, and adversarial loopback coverage satisfy the controlling brief with no actionable findings in the frozen delta.
