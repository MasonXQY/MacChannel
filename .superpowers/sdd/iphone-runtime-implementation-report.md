# Mobile foreground networking stage A

Implemented and locally verified on 2026-09-12. This is the agreed bounded
networking stage, **not the full foreground runtime**. Binding scoped acceptance:
`iphone-network-stage-brief.md`; lifecycle contract: `iphone-foreground-brief.md`.
The original `iphone-runtime-implementation-brief.md` deliverable continues in
stage B after independent review. No new user approval is required for that work.

Worktree: `/Users/mason/Documents/ChatGPT/Deepseek/MacChannel/.worktrees/dropmesh-iphone`.
Dispatch base: `9ef3642`; root independently committed documentation at `51ea7aa`
and `0dd271a`. Implementation: **`f6483b577ded29f30250626e374b5e9cb7cae7e7`**.
Only four new mobile source files and three new mobile test files are in that
implementation commit. This report is a separate scoped documentation commit.

## Implemented ownership

- `MobileForegroundConnector`: process-lifetime actor proxy implementing all
  three core connector overloads, retaining transfer ID and failed route.
  Install/disable advance a generation. Inactive calls fail immediately; late
  success closes its channel, and late failure becomes cancellation. No old
  attempt waits for a subsequent foreground graph.
- `MobileSignalBridge`: one stable `RendezvousSignalSession` per foreground
  generation. Monotonic socket tokens gate frame/error delivery and send
  completion. Queues are bounded to 128 frames and 64 errors. Overflow returns
  failure to the supervisor, which closes the socket. Disconnected signals fail
  immediately and are never queued for replay. Final stop finishes both streams.
- `MobilePresenceSupervisor`: one retained loop owns socket creation, actual
  `AuthenticatedPresenceSession.connect/run`, forwarding tasks and cleanup.
  Concurrent early closes share one task. Final cleanup joins that task, closes
  again after late connect/run return, and joins forwarders before replacement.
  This ordering protects the directory that core presence mutates directly.
  A non-cooperative connect/close keeps drain pending. Repeated start/stop do not
  create another owner. Retry during authentication cannot publish old online.
  Retry backoff is 1, 2, 4, 8, then 15 seconds, capped thereafter. Explicit retry
  interrupts the current attempt or delay. Cancellation does not retry.
- Trust refresh uses current repository authentication records. Initial connect
  includes these records; no redundant trust update is required for online.
  Failed trust sending stops the attempt and reconnect authenticates with the
  latest records. Persistence and immutable receive-policy refresh remain stage B.
- `MobileRuntimeConfiguration` fixes the existing production WebSocket and HTTP
  origins. Each production presence attempt creates and owns a fresh ephemeral
  URLSession, because core invalidates that session when its socket closes. TURN
  keeps a different foreground HTTP session. The test seam replaces only the
  final socket builder or transport and clock; supervisor tests still execute
  real core authentication/presence.

No core, protocol, App, iPhone, Package, server, signing or Store files changed.
No diagnostics were added containing raw errors, identities, URLs or payloads.

## Integration API for stage B

There is **no new public app API yet**. These internal APIs live in the mobile
target for its upcoming `MobileForegroundRuntime` actor:

```swift
let connector = MobileForegroundConnector() // retain for process lifetime
await connector.install(connectionCoordinator) // each foreground graph
await connector.disable() // before background cancellation

let presence = MobilePresenceSupervisor(
    identity: identity, repository: repository, directory: directory,
    onState: { state in /* update runtime through its foreground token */ }
)
let signaling = RendezvousWebRTCSignaling(session: presence.bridge)
await presence.start() // begins connecting; does not wait for online
await presence.retryConnection()
await presence.refreshTrust()
await presence.stop() // joins actual ownership; may remain pending
```

`MobilePresenceState` is inactive/connecting/online/reconnecting/stopping/stopped.
The state callback must be short, check the runtime's foreground token inside
that actor, and must not synchronously call and await supervisor lifecycle work:
it executes on the retained loop whose drain lifecycle calls join. The runtime
should publish snapshots there and schedule its own transition separately.
The owner sets its own stopping state immediately when background is requested.
Each presence attempt's socket close invalidates only that attempt's ephemeral
URLSession. The stage-B foreground owner separately owns and invalidates the TURN
HTTP session after its consumers drain. Never reuse a stopped supervisor/bridge.

## Verification and RED/GREEN evidence

Initial tests were written before their missing production types:

- `.build/mobile-network-red.log`: expected missing connector/bridge diagnostics.
  `.build/mobile-network-green.log`: first 6 boundary tests passed.
- `.build/mobile-presence-red.log`: expected missing supervisor/configuration
  diagnostics. Fixture compile fixes corrected the existing TrustStore API label
  and async assertion autoclosures. First execution also corrected the fixture's
  auth expectation: real authentication uses a signed envelope, not type=auth.
- `.build/mobile-presence-close-red.log`: behavioral RED, overlapping close
  allowed factory count 2 while old close remained pending (expected 1). Fixed
  by retained early-stop and final-drain ownership.
- `.build/mobile-network-cancellation-red.log`: behavioral RED, stale connector
  error escaped as retryable failure; cancelled socket creation repeatedly
  retried. Both fail closed after the fix.
- `.build/mobile-presence-retry-red.log`: behavioral RED, delayed old auth after
  manual retry published online twice (expected once). Fixed with attempt-stop
  checks around authentication/activation/run.
- Additional coverage exercises signal overflow cleanup and current trust in
  reauthentication. These supplement the initial tests and behavioral REDs.

Final exact-source commands:

```sh
swift test --skip-update --filter DropMeshMobileRuntimeTests
xcodebuild -scheme DropMeshMobileRuntime -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/iphone-simulator -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme DropMeshMobileRuntime -destination 'generic/platform=iOS' -derivedDataPath .build/iphone-device -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO build
git diff --cached --check
```

- Final mobile tests: **36 tests, zero failures, zero skipped**. Existing 19
  identity/pairing/import tests preserved; 17 new tests (4 connector, 3 bridge,
  10 supervisor). Test runtime 0.561 seconds. Log:
  `.build/mobile-network-stage-final-tests.log`.
- Both cached full library targets: **BUILD SUCCEEDED**. Logs:
  `.build/mobile-network-stage-simulator-final.log` and
  `.build/mobile-network-stage-device-final.log`.
- SwiftPM emits one warning that `--skip-update` is deprecated. No Swift compiler
  warnings in final test output; no `warning:` lines in either final Xcode log.
  App Intents extraction notes report no relevant symbols; these are not failures.
- Diff whitespace check passes. No full repository test rerun in this stage.
  Earlier full-suite evidence is not claimed as this revision's verification.

SHA-256 of retained final logs, in the above order:

```text
9366d0d569b477a586a208f8be5299af35e96aefe24c5e7c74a68af1f7544e18
bc03b6365fd14c2a3f69eac1be4172c803b25abf2f5c0a4f20c1128052e1e748
77bd35c00cde8a1aab243885b91b699fdf204da48b7bcbfd18409a4331fdb3d9
```

## Required continuation and limits

Stage B still must implement public runtime/snapshots and the serialized desired
foreground state machine; retain one database/coordinator and restore once;
cancel queued/paused/active work on background; cancel late public send results;
compose ICE/connection/listener owners; receive into Documents/DropMesh; persist
and observe trust and drain/replace immutable incoming policy; optional Bonjour.
Use private `state/incoming` for receive staging, separate from picker import
`state/staging`. Do not call shutdownForRestart or close the database on background.

The current proxy itself cannot prevent a caller from installing a new graph
before its owner drains: stage B must own that contract. There is no test yet
of one coordinator restore, late persistence/send result, incoming receive-policy
refresh, Bonjour state, actual receive publication or mobile process restart.
Those acceptance cases belong to the missing runtime composition, not this stage.

No production network, real WebRTC channel, physical iPhone, Mac interoperability,
UI integration, installation, signing or store acceptance occurred. Socket tests
use in-memory data and ephemeral fixture identities. Builds establish compilation,
not installed or end-to-end behavior. Root must independently review this stage
before composing the remaining runtime.

## Independent-review corrections — 2026-09-12

Resolved all three findings from `iphone-network-stage-review.md` within the
stage-A source/test boundary:

- Production presence no longer accepts or shares the future TURN HTTP session.
  `MobileRuntimeConfiguration.makePresenceSocket` creates a fresh ephemeral
  URLSession per attempt and passes it only to that core socket. The narrow test
  builder observes two distinct sessions without starting production networking;
  invalidating the first therefore cannot affect the second or TURN.
- Manual retry, receive/run error, trust failure and bridge overflow disconnect
  the attempt's sender and publish `reconnecting` before awaiting socket close.
  Delayed-close coverage verifies state is non-online, outgoing signals fail and
  no replacement is created until the old close returns. A retained retry flag
  prevents an explicit retry requested during this newly visible drain state from
  being lost before backoff exists.
- Outgoing bridge sends fence both success and failure. Late throwing sends after
  socket replacement, final finish or caller cancellation now fail with
  `CancellationError`; a genuine current-socket transport error is preserved.

TDD evidence:

- `.build/mobile-network-review-red.log`: 18 focused tests executed with four
  expected behavioral failures: delayed close remained `online`, and stale
  throwing sends leaked their old error after replacement, finish and caller
  cancellation.
- `.build/mobile-network-review-green-focused.log`: the same 18 focused tests
  passed after the fixes.
- `.build/mobile-network-review-final-tests.log`: full mobile suite, **41 tests,
  zero failures, zero skipped**. This preserves the previous 36 and adds one
  production session-ownership regression plus four bridge send regressions.
- `.build/mobile-network-review-simulator.log` and
  `.build/mobile-network-review-device.log`: cached unsigned iOS simulator and
  device library builds both report **BUILD SUCCEEDED**. Neither is an app install
  or physical-device networking test.
- `--skip-update` emits its existing deprecation warning. Final test output has no
  Swift compiler warnings; both Xcode logs have no `warning:` or `error:` lines.

SHA-256, in RED, focused GREEN, full mobile, simulator and device order:

```text
47de76ee861e8d7e4217baf6ac05f9a7718183713c310f1bfc9b4ffed63c2571
87cdf2c62c7584d6d61c6069c1c26386ca89c2b358ca829aa166fe09bb770258
3cc4f032f69998323b6eebee60d6e028d1993d97370883f2f3e81b7635da1cfe
6cd421eaf3d97685ef921f4dce0a442a48bddc4d277d3d7d142e91d52a39eeae
459cfcdb954222aa7f78ea0348d5e079b5e6d68a6df276d122ac1db16dab38ab
```

## Retry retirement reentrancy correction — 2026-09-12

Addressed the remaining P2 in the a9fb191 re-review. `beginDraining` now
records the retired socket token synchronously before its first actor hop.
Authentication entry/completion, bridge activation completion, online publication,
run entry, trust refresh and both forwarding paths check that the attempt is
still active. Duplicate drain requests do not republish the retired attempt's
state. After bridge disconnect, state publication also revalidates the current
token. Retry captures its original token and the early-close helper checks that
token before joining or initiating close, so a suspended old callback cannot
close a replacement. The sole loop retains final-drain/forwarder ownership;
per-attempt production sessions and callback lifecycle constraints are unchanged.

The deterministic regression holds the first reconnecting callback, releases
late authentication, permits the loop to install a replacement while that
callback remains suspended, then resumes the old retry. On unmodified production
source it failed all three assertions: old run started, online count was two,
and the old retry closed the replacement. The fixed source passes all three.
The test fixture initially needed Swift async-autoclosure syntax corrections;
the retained RED log is the subsequent behavioral reproduction.

Executed commands and evidence on the final source:

```sh
swift test --skip-update --filter MobilePresenceSupervisorTests/testRetryRetiresAttemptBeforeSuspendedStateCallbackAndCannotCloseReplacement
swift test --skip-update --filter MobilePresenceSupervisorTests
swift test --skip-update --filter DropMeshMobileRuntimeTests
xcodebuild -scheme DropMeshMobileRuntime -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/iphone-simulator -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme DropMeshMobileRuntime -destination 'generic/platform=iOS' -derivedDataPath .build/iphone-device -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO build
git diff --check
```

- Behavioral RED: `.build/mobile-retry-retirement-red.log`, 1 test, 3 expected failures.
- Focused GREEN: `.build/mobile-retry-retirement-focused.log`, 12 tests, zero failures.
- Full mobile: `.build/mobile-retry-retirement-full.log`, 42 tests, zero failures,
  zero skipped, exit 0 (0.557 seconds test runtime).
- Cached simulator/device library builds: `.build/mobile-retry-retirement-simulator.log`
  and `.build/mobile-retry-retirement-device.log`, both BUILD SUCCEEDED, exit 0.
- Only the existing SwiftPM `--skip-update` deprecation warning; neither Xcode
  log has warning/error lines. Whitespace check passes.

SHA-256 in RED, focused, full mobile, simulator, device order:

```text
6dee87c8b8d97a8fb8b91df9ba3187d892a60c8c1143b77aad24ffa1b86a7f31
28cfb7fdf4d4a94c59ef0ce3d5bdf9f0e10e17b602cd44d4aaa2240c36e585a9
9ee10b18bfefe52d8b8e3356edaaa0934c720fd7f59aae3aab658a475e4a17e9
101d5a182b8d8b6586a4d0f77075894bd217402dadf02e5c519a246fb79c4225
addd921ce879f64d9a41f0f178361f827467f3a6435065659b3b9488d7c5ed7f
```

Only supervisor source/tests and this appended report changed for the fix.
Root-owned HANDOFF/readiness edits are excluded. No core/protocol changes,
full-runtime implementation, production networking, installation, physical-device
interoperability, signing or Store acceptance is implied by these checks.
