# Native attempts/listener authorization implementation

2026-09-20. Bounded opt-in component implementation; independent review and root-owned shipping build pending. Final focused regression: **177 tests, 0 failures, 0 skips**. This is not runtime activation or real account/device transfer acceptance.

## Scope and revision

Requirements: `native-attempts-authorization-seams.md`, accepted by root, including its eight test groups. Implementation began at `6b95c03cc266d982fceece96613caffbf14386a9`; frozen commit parent is `549f5626703f1e49a75c5ff59fb28d941bef9fdb` (intervening root documentation commits). Only these three source/test files and this report are included:

- `Sources/MacChannelCore/Connectivity/ConnectionCoordinator.swift`
- `Tests/MacChannelCoreTests/ConnectionCoordinatorTests.swift`
- `Tests/MacChannelCoreTests/WebRTCLoopbackTests.swift`

Other dirty worktree files were preserved. The loopback file changes only two helper declarations from private to test-module internal for reuse. No production test-only API was added. Root explicitly authorized this scoped commit; index was empty before staging.

## Implemented behavior

Attempts/listener retain all public repository initializers and concrete factory/channel types. Additive provider initializers accept only `AuthorizedWebRTCChannelFactory`, with static/dynamic ICE forms. A paired internal authority enum prevents mismatched dependencies or legacy fallback. No coordinator convenience API was needed.

Each authorized attempt acquires one exact peer lease before suspension. Cancellation and that same lease are checked after LAN lookup and ICE, before factory dispatch, and after factory return. The exact provider, lease, key, route, role and connection/transfer ID reach only the authorized factory overload. Regrant cannot replace a suspended lease. ICE/factory error paths preserve cancellation, otherwise revalidate before propagating transport errors, preventing revoked timeout fallback. Rejected concrete results are closed with an awaited call.

Inbound acceptance stays inside existing tracked tasks. Stop/cancellation/authorization are checked at suspension boundaries and inside actor-owned publication immediately before yield without another await. Late results close before acceptance retirement and `stopAndWait` completion. Existing 8-global/2-peer caps, reader startup ownership, shared drain, legacy 32-object buffer, zero-buffer transfer stream, no-consumer closure and dropped/terminated closure remain. Authorized inbound diagnostics use fixed text rather than provider/error descriptions.

## Test matrix

19 new provider tests plus 22 existing coordinator tests cover:

1. Provider-only outbound/inbound absent repository membership; existing repository APIs and factories remain exercised unchanged.
2. Exact provider object, immutable lease, peer/key, UUID/transfer ID, route and offerer/answerer propagation; denied and wrong-peer leases never call factory.
3. Withdrawal and deterministic account expiry during blocked ICE, released with success and error; no factory or unauthorized fallback.
4. Real late channel after cancellation/withdrawal; outbound closure before rejection, both inbound consumer modes reject; withdrawn factory timeout is terminal.
5. Real owner manual/account overlap preserves a suspended lease; final removal closes; same-key remove/regrant rejects the old lease. Existing owner regressions retain conflict-evidence coverage.
6. Stop during ICE/factory/offer-reader startup, cancellation-ignoring factory, nonjoining stop then repeated/joining stop; explicit barrier and drain completion, late close, 8/2 caps and capacity recovery.
7. Bounded actual zero-buffer delivery smoke, absent/terminated reader closure, and 33 real channels exercising legacy buffer overflow while preserving the earlier 32 buffered objects.
8. Combined unchanged coordinator, owner, withdrawal, real loopback and transfer lifecycle regressions.

The delivery smoke's task-start marker does **not** establish that the underlying zero-buffer iterator has registered its waiter. Root reviewed and accepted this limitation; the test is named/commented as a bounded delivery smoke, not deterministic waiter-ready proof. Delivery waits have a two-second bound; the listener is stopped before joining the receiver so a drop cannot hang the test. Failure paths release the barrier, cancel/join the reader, stop the listener and close both real channels. No sleep was introduced to mask scheduling.

## Actual RED/GREEN and retained logs

Commands use `set -o pipefail; swift test --disable-automatic-resolution --filter 'FILTER' 2>&1 | tee LOG` under the worktree. Toolchain: selected Xcode 16.4, Swift 6.1.2. No deprecated `--skip-update`.

| Log under `/tmp/` | Filter/result |
| --- | --- |
| `native-attempts-initial-red.log` | `ConnectionCoordinatorTests/testProviderOnly`: 2 tests, 12 assertion failures, exit 1, 2.322s. Behavioral RED: temporary inert overload scaffolding forwarded to the repository path; provider-only peers were rejected and authorized factory was not invoked. No compiler failure. Scaffolding was replaced by implementation. |
| `native-attempts-initial-green.log` | Same filter: 2 tests, 0 failures, exit 0, 0.005s. |
| `native-attempts-outbound-matrix.log` | `ConnectionCoordinatorTests/testProvider`: 8 tests, 0 failures, exit 0, 0.127s. |
| `native-attempts-inbound-matrix.log` | Compiler diagnostic: async task value inside `XCTUnwrap` autoclosure. Corrected by awaiting a local first. Not behavioral RED. |
| `native-attempts-inbound-matrix-corrected.log` | Compiler diagnostic: non-Sendable XCTest self captured by task assertion helper. Corrected with inline assertion, no unsafe sendability. Not behavioral RED. |
| `native-attempts-inbound-matrix-sendable-corrected.log` | Provider filter: 14 tests, 0 failures, exit 0, 0.171s. |
| `native-attempts-complete-matrix.log` | Provider filter: 19 tests, 0 failures, exit 0, 0.594s. |
| `native-attempts-final-combined.log` | Combined filter below: 177 tests, 0 failures, exit 0, 9.108s. Superseded by final bounded-cleanup run. |
| `native-attempts-final-bounded-combined.log` | Final source: 177 tests, 0 failures, 0 skips, exit 0; build 4.01s, tests 9.278s. Includes bounded smoke cleanup, exact-provider assertion and cap recovery supplement. |

Final combined filter:

```text
ConnectionCoordinatorTests|WebRTCLoopbackTests|PeerAuthorizationOwnerTests|PeerWithdrawalTests|TransferCoordinatorTests
```

Final suite counts: ConnectionCoordinator 41; PeerAuthorizationOwner 21; PeerWithdrawal 2; TransferCoordinator 80; WebRTCLoopback 33. No warning/error/skipped lines in final log. Supplemental matrix cases were first observed GREEN against the implementation; they are not represented as independent RED cycles. `git diff --check` passed. No active swift-test, package test or xcodebuild process remained at freeze.

SHA-256 of final tested source:

```text
04c6015b41f44c1384882231fb4a70ee74818ee6e35dacf0a69c16f5212b0bf6  Sources/MacChannelCore/Connectivity/ConnectionCoordinator.swift
37e0f0e754059329aeb56aa3ddafbea92b1c269a1a5b8583627ec3d054abd685  Tests/MacChannelCoreTests/ConnectionCoordinatorTests.swift
b3ce298ae722bc947aa23535771600c73f17c65768bebea17869477b4a129963  Tests/MacChannelCoreTests/WebRTCLoopbackTests.swift
```

## Limits and handoff

- No app/runtime call site is switched to these overloads. No freshness defaults, endpoints, presence, server, signing, deployment or installation changes.
- Forwarding factory spies return already-authenticated real local LAN channels for late-result/close/handoff tests. Route/role propagation is separately asserted; this does not prove TURN/relay/internet operation or shipping same-account transfer.
- Channel lifetime admission is provided by the previously reviewed authorized factory/channel component; no second lifetime registry was introduced here.
- An uncooperative ICE/factory may keep `stopAndWait` pending until it returns. Owned late cleanup is proven, not synchronous abortion of arbitrary dependency code.
- Admission before withdrawal may complete. Previously buffered legacy channel objects remain buffered; stream finish does not erase them. Channel-level authorization governs actual work.
- Full-package OCR tests were intentionally not rerun because of the unrelated documented capture failure. This task claims focused GREEN only. No shipping build was run by this agent; root owns that next check.
- After this scoped commit, Swift/Xcode caches and index are released to root for independent review/build. Further activation requires its separate gate.
