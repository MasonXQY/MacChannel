# Stage B production inbound drain correction

2026-09-12. Dispatch base `932c880`; root documentation commit `cb079cb` was
present during verification. Scoped implementation in this report changes only
the Core WebRTC listener lifecycle, mobile production network composition and
one new focused mobile test file. Root owns HANDOFF and integrated regression.

## API and ownership

The narrowly additive Core API is:

```swift
public actor WebRTCConnectionListener {
    public func stop()                 // existing nonjoining cancellation request
    public func stopAndWait() async    // joins the same retained retirement
}
```

`stop()` marks stopped synchronously, cancels reader and acceptance tasks,
finishes delivery streams and retains their handles in one drain task before
returning. A preceding nonjoining stop cannot discard the work needed by a later
awaited stop. Concurrent/repeated awaited callers join the same task; there is
no cleanup deadline and no second close operation created by a second caller.
An acceptance remains owned through ICE retrieval, factory return, trust/stopped
checks and any late channel close. Existing trust checks and delivery capacity
bounds are unchanged.

Reader ownership now installs before suspending for `incomingOffers()`. The
owned task includes stream initialization and checks cancellation afterward,
preventing a reader from escaping the drain during actor re-entry. Concurrent
consumers therefore also cannot start duplicate initialization. Sequential
incoming-policy replacement still receives a fresh transfer stream.

`MobileProductionForegroundNetwork.stop()` invokes the awaited API. HTTP
invalidation starts immediately; listener, socket, Bonjour browser and advertiser
shutdown tasks all start before joining. Runtime's existing incoming drain starts
independently. This allows cancellation of dependencies to unblock acceptance
while the runtime's existing graph barrier retains the old generation.

An internal transport-injection initializer builds the real ConnectionCoordinator
and WebRTCConnectionListener with injected presence/signaling/ICE/factory/HTTP
owners. Production initialization delegates to it with the unchanged production
dependencies. No public mobile API, Mac caller, wire/security/routing/server,
keychain, native app, signing or release behavior changed.

## Regression evidence

`MobileProductionForegroundNetworkTests` contains four tests:

1. Existing nonjoining stop returns with a cancellation-insensitive factory
   gated; two concurrent awaited callers remain pending through factory return
   and an actual WebRTCSecureChannel's gated transport close. Close count is one.
2. Awaited stop remains pending through cancellation-insensitive ICE retrieval;
   releasing it never enters the channel factory after cancellation.
3. Stream setup is gated inside the memory signaling session across stop. Drain
   waits for setup return, the consumer ends and no post-stop offer is accepted.
4. A real MobileForegroundRuntime with a real temporary SQLite database builds
   actual MobileProductionForegroundNetwork instances. Socket close and HTTP
   invalidation are observed while factory acceptance is gated. Stop/re-entry
   stay pending, graph count remains one through the late close, then becomes
   two after release. No whole-network fake stop is used.

Continuation gates establish dependency entry and release; bounded 100 ms
observation windows detect an incorrectly completed drain. The channel fixture
constructs a local unopened RTC data channel and the actual secure-channel close
owner. It does not negotiate SDP, gather ICE, authenticate a peer or contact a
network. Memory signaling and a blocked fake socket replace external I/O only.

Behavioral RED was captured before the lifecycle fix using a test-local drain
adapter to the existing `stop()` API: `.build/mobile-drain-red.log`, exit 1,
3 tests / 5 assertion failures. This is behavioral evidence, not missing-API
compilation failure. After adding the API and switching the adapter to
`stopAndWait()`, `.build/mobile-drain-core-green.log` passes all 3, exit 0.

With actual production graph injection but its old nonjoining stop call still
in place, `.build/mobile-drain-graph-red.log` and the explicitly acknowledged
foreground-request rerun `.build/mobile-drain-graph-red-confirmed.log` both exit
1: graph stop returned while factory acceptance was held. Other re-entry
assertions did not fail in these recorded RED runs; do not overstate their RED
coverage. Changing the production call to `stopAndWait()` makes all four pass.

Final focused command:

```sh
swift test --disable-automatic-resolution --filter 'DropMeshMobileRuntimeTests|ConnectionCoordinatorTests'
```

`.build/mobile-drain-focused-final.log`: exit 0, **84 tests, zero failures,
zero skipped**, 3.029 seconds. This preserves all 58 previous mobile tests,
adds 4 tests, and runs all 22 ConnectionCoordinator tests including legacy
nonjoining/capacity and fresh/stopped stream behavior. No compiler warning or
deprecated resolution-flag warning. Local `swift test --help` confirms the
supported flag and both Package.resolved and cached workspace state exist.

## Build and source checks

Cached unsigned library build commands:

```sh
xcodebuild -scheme DropMeshMobileRuntime -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/iphone-simulator -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme DropMeshMobileRuntime -destination 'generic/platform=iOS' -derivedDataPath .build/iphone-device -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO build
bash Scripts/audit-privacy.sh --static-only
bash Scripts/check-sensitive-logging.sh Sources/DropMeshMobileRuntime/MobileProductionForegroundNetwork.swift Sources/MacChannelCore/Connectivity/ConnectionCoordinator.swift
bash Scripts/test-app-store-source-contract.sh
git diff --check
```

Both builds exit 0 and report **BUILD SUCCEEDED**, with no warning/error lines:
`.build/mobile-drain-simulator.log`, `.build/mobile-drain-device.log`.
Source/privacy checks all exit 0: `.build/mobile-drain-privacy.log`, `.build/mobile-drain-logging.log`,
`.build/mobile-drain-source-contract.log`. Whitespace check passes.

SHA-256 for core RED, confirmed graph RED, final focused tests, simulator,
device, privacy, logging and source contract, respectively:

```text
3e0fdd902e60c9f4d95acddc0b85a32de3f097eda319f11da2e5511a3ee67a14
4a0e8d7a12b75578598966d2eaecb232960ab51f41744183ffff22ec06336650
a8477d3c7bfade879dde3ca844251d34156c070ee61948dad1ab7e9f7cd601d1
30600021e55317aa8ffe68f516ce14139e6d4190e3907437588456905ce245d2
934d947970070e3c280c3cf16973389ba227b3c9e108f3dd0e185a8573e8a8aa
c70fe3e82bd7d662171b9f6c8502df55fd219b21a57b9f9ab4df3d84db7bc3ac
24e58ecd802aef8e61d74ae2b8a3925397b84d38e887a4965b967def6620843c
0d73bafcee23b9ac60277c93c3170e4a59d1e653dda44f4304e78540b81a3bb1
```

## Cleanup and remaining limits

The new production-runtime fixture has no send/publication/persistence workers;
after both graph owners drain it explicitly closes its temporary database and
removes only its generated `mobile-production-drain-UUID` root. The old runtime
fixtures deliberately exercise terminal persistence which can outlive ordinary
scene stop. Their broad teardown Minor remains deferred: there is no public
complete outbound quiescence seam, and adding production shutdown solely for
test cleanup would expand scope. No existing temporary root was deleted and no
production database close was introduced.

Coordinator must run the integrated full repository suite after both review
repairs; this agent did not repeat heavy full suites. Independent re-review is
pending. No installed app, physical device, authenticated cross-device transfer,
production service, signing, Store or public-release acceptance is claimed.
