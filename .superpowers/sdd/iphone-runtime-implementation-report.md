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
  origins. Production supervisor creates `URLSessionPresenceWebSocket` using the
  foreground owner's supplied URLSession. The test seam replaces only transport
  and clock; every supervisor test executes real core authentication/presence.

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
    session: foregroundURLSession,
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
The supervisor does not invalidate URLSession; the foreground owner does that
after all foreground consumers drain. Never reuse a stopped supervisor/bridge.

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
