# iPhone foreground transfer runtime — stage B

Implemented on 2026-09-12; library and owner tests locally verified. The final
full repository regression is **not clean**: existing asynchronous core test
assertions failed in two final runs, detailed below. No physical-device,
production-service, installed-app or Store acceptance is claimed.

Worktree: `/Users/mason/Documents/ChatGPT/Deepseek/MacChannel/.worktrees/dropmesh-iphone`.
Dispatch base: `5328e4b`. Implementation commit:
`33d8f1bbedea6db85c51b72e21c25c6f7227e37d`.
Root independently committed native/documentation changes through `3806a55`;
they are not part of this implementation. This report is committed separately.

Binding scope: `iphone-runtime-stage-b-brief.md`, `iphone-foreground-brief.md`,
`iphone-late-send-audit.md`. Stage-A connector, signal bridge and presence
supervisor are reused; no Stage-A production source was changed.

## Public native integration API

```swift
public enum MobileRuntimeState: Equatable, Sendable {
    case inactive, starting, online, reconnecting, stopping
    case failed(MobileRuntimeFailure)
}
public enum MobileRuntimeFailure: Error, Equatable, Sendable {
    case storage, authentication, network, receive, trustPersistence
}
public enum MobileRuntimeError: Error, Equatable, Sendable {
    case notForeground, notReady, interrupted, sendFailed
}
public struct MobileRuntimeSnapshot: Sendable {
    public let state: MobileRuntimeState
    public let foregroundRequested: Bool
    public let devices: [DeviceSummary]
    public let transfers: [TransferSnapshot]
    public let received: [TransferReceiveResult]
    public let localNetworkAvailable: Bool
    public let failure: MobileRuntimeFailure?
}
public actor MobileForegroundRuntime {
    public init<Secrets: SecretStore & Sendable>(
        context: MobileIdentityContext<Secrets>
    ) throws
    public func currentSnapshot() -> MobileRuntimeSnapshot
    public func snapshots() -> AsyncStream<MobileRuntimeSnapshot>
    public func startForeground() async throws
    public func stopForeground() async
    public func retryConnection() async
    public func refreshTrust() async throws
    public func setLocalDiscoveryEnabled(_ enabled: Bool) async
    public func send(items: [URL], to device: DeviceID) async throws -> TransferID
    public func pause(_ id: TransferID) async throws
    public func resume(_ id: TransferID) async throws
    public func cancel(_ id: TransferID) async -> TransferCancellationResult
}
```

Construct once after `MobileIdentityContext.load` succeeds. The initializer opens
the single private database and does not start networking. Retain this runtime
for the process; scene changes must not create another one. `startForeground`
joins graph setup and starts authentication; return does not guarantee online.
Observe snapshots for actual `.online` or `.reconnecting`. Cancelling the start
call is not a background request: call `stopForeground` on actual background.
Concurrent lifecycle calls reconcile the latest desired foreground state.

Each subscriber receives an initial snapshot and a buffering-newest-8 stream.
Subscribers survive scene changes. `foregroundRequested` distinguishes a pending
re-entry from a final stop while both display `.stopping`. `received` is bounded
to 200 actual process-session completions and **is not durable history**.
`failure` provides coarse receive/trust errors independently of presence state.
URLs occur only in intentional receive results, never diagnostics. Device
availability comes from core `DeviceDirectory`; the local identity is excluded.
The presence supervisor does not provide a detailed authentication-failure
classification, so reconnecting is reported without inventing such a reason.

Stage imported inputs through `MobileImportStager` while picker security scope
is held. Public `send` stays pending until its retained core call and accounting
finish, including caller cancellation. Import copies may be released after it
returns or throws. The cancellation handler uses a locked flag: cancellation
wins when recorded before result finalization takes that lock. Cancellation
after that point can lose, including to irreversible receiver publication.
It cannot undo a completed transfer. Backgrounded/cancelled IDs require a fresh
send; `resume` retains core paused-only behavior.

The native app must aggregate scenes, subscribe on its UI owner, call
`refreshTrust` after successful durable pairing, and explicitly enable optional
local discovery. A UIKit background assertion can assist cleanup but must not
replace or bypass a pending drain. History, importer leases, pickers and UI
integration are the coordinator's next scoped tasks, not implemented here.

## Ownership and shutdown

- `MobileForegroundRuntime` retains one `TransferDatabase`, restores one real
  `TransferCoordinator`, and retains its snapshot observer through all scene
  transitions. The database is never closed and `shutdownForRestart` is never
  called during mobile lifecycle changes. Core terminal persistence/package work
  can finish later under this same owner. Observer tasks are cancelled at deinit.
- One retained reconcile task serializes desired lifecycle, trust-policy refresh
  and discovery changes despite actor suspension. Stop closes public admission
  and retires its epoch synchronously before its first await. Stale callbacks
  cannot publish readiness or install another incoming owner.
- A process-lifetime Stage-A connector proxy is disabled before cancellation and
  graph cleanup. Stop reads a fresh core snapshot, including queued/paused/active
  durable IDs, rather than relying on the lagging UI snapshot cache.
- Every admitted public send registers a retained worker in the admission actor
  turn. Its record stays present through required cancellation accounting.
  Caller task cancellation never drops that worker or its input lifetime.
  Both old network/incoming drains and **all unresolved send results** hold the
  re-entry barrier. A hidden initial-persistence ID therefore cannot acquire a
  new foreground connector, including while result accounting is deliberately
  suspended. No timeout licenses replacement.
- Once an identified ID's cancellation request returns, re-entry does not wait
  for terminal persistence/cleanup. Core's claimed phase remains authoritative.
  Already completed/failed/too-late results are not rewritten as cancelled.
- Stop initiates retained incoming and network drain tasks immediately, even
  when the reconcile task is awaiting trust persistence or an older receive
  drain. Network stop initiates WebRTC stop, presence stop, browser stop and
  advertiser stop before joining them, and immediately cancels TURN HTTP.
  Incoming stop is joined separately; every retained drain must actually return.
  Old core connection attempts retain their captured connector dependencies and
  remain fenced by the disabled proxy/core cancellation after graph retirement.
- The production graph uses one `MobilePresenceSupervisor` and its stable
  bridge, one `RendezvousWebRTCSignaling`, `RefreshingICEConfigurationProvider`,
  `ConnectionCoordinator` and `WebRTCConnectionListener`. Presence reconnect
  replaces only its owned socket attempt, never the transfer coordinator or
  incoming consumer. TURN HTTP has its own ephemeral session; Stage A creates a
  separate ephemeral session for each socket. No session is shared across them.

## Trust, inbound and discovery composition

Repository updates are observed for the process, persisted through the supplied
identity context, and synchronized into the directory. Immutable incoming policy
is rebuilt only after the old `IncomingTransferListener.stop()` really drains.
The latest trusted set is read after that await, subtracting self; concurrent
changes coalesce through the revision loop. Authenticated presence receives
current trust via the Stage-A supervisor. Initial authentication already reads
current trust and does not require a redundant successful update.

Incoming uses the actual core listener/database, receive policy and hardened
receive session/store. Publication is `layout.receiveDirectory`, i.e.
`Documents/DropMesh`; incoming staging is private `state/incoming`, separate from
picker `state/staging`. Only non-nil `onReceiveFinished` values are appended.
An actual publication that wins a stop race remains a real completion; nil or
failed receives add no fictitious result.

Optional Bonjour uses core browser/advertiser, `_macchannel._tcp`, and port
45873; accepted TCP connections are immediately cancelled (discovery only).
Both actual lifecycle observations must be ready before the graph reports local
availability. Failure/disable/stop clears it independently from internet state.
This boolean is not evidence that iOS granted permission. No Bonjour system
permission operation or physical discovery was exercised by the runtime fixtures.

## Verification and RED/GREEN evidence

New tests use the real coordinator with a real temporary SQLite database and
continuation-gated persistence; the network seam replaces transport only. The
incoming owner is always the real core listener. Fixture send/receive uses real
`SendSession`/`ReceiveSession` and actual destination publication.

Sixteen owner tests cover initial snapshots/inactive admission; hidden initial
writes; held result accounting; caller cancellation/input lifetime; multiple
hidden sends released out of order; stop/start/stop ordering; active/queued/paused
cancellation; restored paused package; cancellation persistence that remains
blocked across re-entry; fresh sends using only the new connector; core send
failure/pre-admission cancellation; actual receive completion/failure; latest
revocation after old receive drain; prompt network shutdown during policy drain;
prompt incoming close during stalled trust persistence; independent local
discovery unavailability; stale start completion; and retry after graph failure.

The list groups related assertions within tests; it is not a claim of a separate
test for each phrase. The restored-package case seeds an actual durable package
and paused database row; it is not a second OS process. Database retention and a
single restore are verified through the production owner seam, not a mirrored
fake coordinator. Physical cross-device authentication/transport is unverified.

Retained development evidence:

- `.build/mobile-runtime-b-red.log`: first tests could not compile because the
  new runtime/network API was absent. Initial fixture ID-label errors were also
  corrected; this is missing-API evidence, not behavioral RED.
- `.build/mobile-runtime-b-green.log`: first three owner tests passed.
- `.build/mobile-runtime-b-trust-stop-red.log`: behavioral RED, incoming close
  did not start while trust persistence was suspended. Fixed by the immediately
  retained incoming drain. The same regression passes in final runs.
- `.build/mobile-runtime-b-retry-red.log`: behavioral RED, graph construction
  failure was mislabeled storage and retry did nothing (three assertions).
  Fixed by explicit restore-error classification and retrying the retained
  reconcile owner when the foreground graph is absent.
- `.build/mobile-runtime-b-mobile.log`: initial full mobile run had 11 new owner
  tests passing but the existing Stage-A backoff test timed out. The fixture
  `failReceive()` only resumes an already-present waiter, while online is
  published before `run` enters receive. Its test now waits `waitingForFrame`
  before injecting the failure. Supervisor production behavior is unchanged.
  Isolated unchanged rerun passed; subsequent full mobile rerun passed 53 tests.

Final commands on the implementation source:

```sh
swift test --skip-update --filter DropMeshMobileRuntimeTests
swift test --skip-update
xcodebuild -scheme DropMeshMobileRuntime -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/iphone-simulator -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme DropMeshMobileRuntime -destination 'generic/platform=iOS' -derivedDataPath .build/iphone-device -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO build
bash Scripts/audit-privacy.sh --static-only
bash Scripts/check-sensitive-logging.sh Sources/DropMeshMobileRuntime/MobileForegroundRuntime.swift Sources/DropMeshMobileRuntime/MobileProductionForegroundNetwork.swift
bash Scripts/test-app-store-source-contract.sh
git diff --cached --check
```

Both iOS library builds exited 0, **BUILD SUCCEEDED**, with no warning/error
lines: `.build/mobile-runtime-b-simulator.log`, `.build/mobile-runtime-b-device.log`.
Static privacy audit passed (the default scanner includes all `Sources`);
final scoped source scan and App Store source contract passed. Logs:
`.build/mobile-runtime-b-privacy-static.log`,
`.build/mobile-runtime-b-scoped-logging.log`,
`.build/mobile-runtime-b-source-contract-final.log`.
SwiftPM emits only its existing `--skip-update` deprecation warning.

The final focused mobile run at `33d8f1b` passed **58 tests, zero failures,
zero skipped** in 3.191 seconds (exit 0):
`.build/mobile-runtime-b-focused-final.log`. This comprises the existing 42
mobile tests and 16 new owner tests.

SHA-256 of final focused mobile, final full, serial full, simulator, device,
static privacy, scoped logging and final source-contract logs, respectively:

```text
ff2f93e5f805a13ad8be847a2ee59f2413094e85009f47c5448e968791aeaa08
cad26dd229f9c863b909737c581120b2e7fdf78811d746a45ea8b7c200de040b
33215a435456aa95fa386995a67490571fa56d35ee76a0ed919af83c0c4b3c5f
6f1dd7702d177af6ccf328a8b33ed4c411fb6d350d90d067ccb9048946d1537e
b2f266c5524a4834bf0d7743d10b578c48e2d9661a893c8c61f164b21fba915c
c70fe3e82bd7d662171b9f6c8502df55fd219b21a57b9f9ab4df3d84db7bc3ac
24e58ecd802aef8e61d74ae2b8a3925397b84d38e887a4965b967def6620843c
0d73bafcee23b9ac60277c93c3170e4a59d1e653dda44f4304e78540b81a3bb1
```

### Full repository regression limitation

The earlier run before the final retry test/fix passed **940 tests, 5 skipped,
zero failures** (`.build/mobile-runtime-b-full-regression.log`). This is not
represented as the final exact-source result.

The final source run executed **941 tests, 5 skipped, one failure**
(`.build/mobile-runtime-b-full-final.log`, exit 1):
`MeshConnectionListenerTests.testTransferHandoffRetainsExactlyThirtyFourFIFOAndClosesThirtyFifth`,
line 117, close count 0 rather than 1. The fixture waits for `readCount > 0`, then
immediately asserts asynchronous close completion. Isolated unchanged rerun
passed (`.build/mobile-runtime-b-mesh-isolated.log`).

A serial full rerun without concurrent library builds also executed **941 tests,
5 skipped, one failure**, in 252.015 seconds
(`.build/mobile-runtime-b-full-serial-final.log`, exit 1):
`DeviceDirectoryTests.testBonjourBrowserPolicyDeniedWaitingEndsOwnedSessionAndRetryReachesReady`,
line 85, availability `.lan` rather than `.internet`. The fixture waits for the
browser's failed state, while `BonjourPeerBrowser.failOnQueue` publishes that
state before scheduling the asynchronous directory-session removal task
(`BonjourPeerBrowser.swift:363–370`). No core source or tests were changed.

Both failures occurred **before** the new runtime tests began in the same
process: error line 577 versus runtime-suite line 703 in the first final run;
error line 259 versus runtime-suite line 698 in the serial run. Thus earlier
execution of these new tests cannot explain those failures. The source ordering
supports existing test synchronization races; it is not a claim that every
possible core issue has been excluded. All sixteen runtime tests passed in both
final full runs. Further full-suite retries were stopped rather than hiding the
failures behind an eventual passing run. Independent review should assess these
existing synchronization risks separately.

Five existing skipped cases remain: live Go-router wrapper, two opt-in native
render captures, Internet server-reflexive ICE, and forced-relay 1 GiB resume.
Local in-process and LAN fixture regression is not public-service/physical
interoperability evidence.

## Remaining acceptance

Independent review is pending. Native retained-runtime ownership, security-scoped
picker/import lifetime, durable history/index, scene/background assertion wiring,
and UI integration remain next tasks. Required installed real iPhone-to-Mac 1.3.0
send/receive, Mac-generated-code JOIN pairing, reconnect, foreground interruption,
local permission and real Internet/relay acceptance have not been performed.

Only two new mobile source files, one new mobile test file, the narrow Stage-A
fixture synchronization change and this report are authored here. No core, App,
iPhone, Package, protocol, server, signing, installation, upload or Store changes
were made by this implementation. No production service or real private keys
were accessed; test identities and payloads are synthetic and locally owned.
