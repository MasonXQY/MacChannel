# Built-in Public Channel Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a public-service-only MacChannel client that preserves v1.0.1 data, never invokes Tailscale, pairs with a six-digit code plus approval on the old Mac, and presents a minimal native macOS UI.

**Architecture:** Keep the existing WebRTC, Bonjour, rendezvous, TURN, transfer, and keychain implementations. Collapse runtime selection to the public path, migrate legacy settings without deleting them prematurely, and adapt the existing bilateral signed pairing transaction so only the host performs an explicit approval while the joiner waits for the signed result.

**Tech Stack:** Swift 6, SwiftUI/AppKit, CryptoKit, WebRTC 150, XCTest, Swift Package Manager, macOS 14+

## Global Constraints

- Release builds must not install, detect, invoke, or configure Tailscale.
- Public users cannot edit the production rendezvous endpoint or select a connectivity mode.
- Preserve the keychain identity, trust snapshot, receive directory, history, TransferID, ResumeMap, and staging data from v1.0.1.
- Pairing codes are six digits, expire after five minutes, and are single-use.
- Only the old Mac shows an Allow/Reject decision; the new Mac waits for the signed authorization.
- Keep application-layer end-to-end encryption and LAN → Internet → TURN route order unchanged.
- SwiftUI views use focused subviews, initializer-injected feature services, plain-language copy, one primary action, and progressive disclosure.
- Every production behavior change follows RED → GREEN → REFACTOR, with the failing test output observed before implementation.
- A client phase is not complete until `swift test --no-parallel` and `Scripts/test-app-launch.sh` pass from a clean build.

---

### Task 1: Public-only settings migration

**Files:**
- Modify: `App/SettingsView.swift`
- Modify: `App/ProductionAppRuntime.swift`
- Replace tests: `Tests/MacChannelCoreTests/PersonalMeshRuntimeTests.swift`
- Modify: `Tests/MacChannelCoreTests/TransferSurfaceTests.swift`

**Interfaces:**
- Consumes: legacy JSON keys `connectivityMode`, `personalMeshEnabled`, and `rendezvousURL`.
- Produces: `SettingsSurfaceSnapshot(localDisplayName:defaultDirectory:autoReceive:launchAtLogin:devices:)` and `RuntimeSettingsStore` snapshots that expose only user-facing identity/receive/device preferences while decoding old files losslessly.

- [ ] **Step 1: Write failing migration and surface tests**

```swift
func testFreshSettingsUseBuiltInPublicChannelWithoutNetworkChoices() async throws {
    let store = try RuntimeSettingsStore(url: settingsURL, trustedDevices: [])
    let snapshot = await store.current()
    XCTAssertFalse(snapshot.localDisplayName.isEmpty)
    XCTAssertNil(snapshot.defaultDirectory)
    XCTAssertTrue(snapshot.autoReceive)
    XCTAssertFalse(snapshot.launchAtLogin)
    XCTAssertTrue(snapshot.devices.isEmpty)
}

func testLegacyPersonalMeshSettingsPreserveUserDataButDoNotSelectMesh() async throws {
    try legacyPersonalMeshJSON.write(to: settingsURL)
    let store = try RuntimeSettingsStore(url: settingsURL, trustedDevices: [peerID])
    let snapshot = await store.current()
    XCTAssertEqual(snapshot.defaultDirectory?.path, "/tmp/downloads")
    XCTAssertEqual(snapshot.devices.map(\.id), [peerID])
    XCTAssertFalse(String(data: try Data(contentsOf: settingsURL), encoding: .utf8)!.contains("personalMeshEnabled"))
}
```

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter PersonalMeshRuntimeTests --no-parallel`

Expected: FAIL because new snapshots still expose `.personalMesh`, persist legacy network keys, and default fresh installs to personal mesh.

- [ ] **Step 3: Implement the minimal migration**

```swift
struct SettingsSurfaceSnapshot: Equatable, Sendable {
    let localDisplayName: String
    let defaultDirectory: URL?
    let autoReceive: Bool
    let launchAtLogin: Bool
    let devices: [DeviceSetting]
}

private struct LegacyWire: Decodable {
    let connectivityMode: ConnectivityMode?
    let personalMeshEnabled: Bool?
    let rendezvousURL: String?
}

private struct Wire: Codable {
    var schemaVersion: Int
    var localDisplayName: String
    var defaultDirectoryPath: String?
    var autoReceive: Bool
    var launchAtLogin: Bool
    var devices: [UUID: DeviceWire]
}
```

Decode current `Wire` first, fall back to a combined legacy decoder, write `schemaVersion: 2`, and carry forward only identity/receive/device fields. Default the local display name to `Host.current().localizedName ?? "Mac"`, global auto-receive to `true`, and login launch to `false`. Remove network-mutating methods from `DeviceSettingsServicing` and `SettingsSurfaceModel`; add `updateLocalDisplayName`, `updateAutoReceive`, and `updateLaunchAtLogin`.

- [ ] **Step 4: Run focused and neighboring tests**

Run: `swift test --filter PersonalMeshRuntimeTests --no-parallel && swift test --filter TransferSurfaceTests --no-parallel`

Expected: both suites PASS with no unexpected skips.

- [ ] **Step 5: Commit**

```bash
git add App/SettingsView.swift App/ProductionAppRuntime.swift Tests/MacChannelCoreTests/PersonalMeshRuntimeTests.swift Tests/MacChannelCoreTests/TransferSurfaceTests.swift
git commit -m "feat: migrate settings to built-in public channel"
```

### Task 2: Remove Tailscale from the production runtime

**Files:**
- Modify: `App/ProductionAppRuntime.swift`
- Modify: `App/AppContainer.swift`
- Modify: `App/MacChannelApp.swift`
- Modify: `App/Resources/RuntimeConfig.json`
- Create: `Scripts/test-no-tailscale-runtime.sh`
- Modify: `Scripts/build-app.sh`
- Test: `Tests/MacChannelCoreTests/AppRuntimeTests.swift`

**Interfaces:**
- Consumes: `ProductionRuntimeConfiguration` with a packaged Release endpoint and test-only environment overrides.
- Produces: a single `ProductionAppRuntime.bootstrap(configuration:)` path and a binary/source audit that fails if Release wiring references Tailscale.

- [ ] **Step 1: Write failing runtime and artifact-contract tests**

```swift
func testProductionConfigurationAlwaysUsesPackagedEndpointForNormalLaunch() throws {
    let config = try ProductionRuntimeConfiguration.current(environment: [
        "MACCHANNEL_RENDEZVOUS_URL": "wss://attacker.invalid/v1/ws"
    ], arguments: ["MacChannel"])
    XCTAssertEqual(config.rendezvousWebSocketURL?.host, ProductionEndpoint.host)
}

func testOfflinePublicServiceStillBuildsPairingAndSettingsSurfaces() async throws {
    let launch = try await builderWithUnavailablePresence.build()
    XCTAssertNotNil(launch.runtime.container.pairingSurfaceService)
    XCTAssertEqual(launch.status, .offline("互联网连接暂时不可用；同一网络仍可传输。"))
}
```

Shell contract:

```bash
if strings "$APP/Contents/MacOS/MacChannel" | grep -E 'tailscale|51337|Serve'; then
  echo "Release binary contains a personal-mesh runtime reference" >&2
  exit 1
fi
```

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter AppRuntimeTests --no-parallel && bash Scripts/test-no-tailscale-runtime.sh`

Expected: FAIL because runtime construction still branches on `ConnectivityMode`, creates `TailscaleCommandClient`, and the audit script does not exist yet.

- [ ] **Step 3: Implement one production path**

Delete `PersonalMeshSetupCoordinator`, `PersonalMeshInstallGuide`, `buildPersonalMesh`, mesh-only properties from `ProductionAppRuntime`, and `runtimeConnectivityMode` diagnostics. Keep test endpoint injection only when `--production-launch-test` is present. Use a fixed packaged endpoint for normal launches and start Bonjour regardless of remote service state.

```swift
enum ProductionEndpoint {
    static let packagedWebSocketURL = URL(string: RendezvousEndpointConfiguration.packagedDefault)!
    static var host: String { packagedWebSocketURL.host! }
}
```

Add `Scripts/test-no-tailscale-runtime.sh` and call it from the release build contract after creating the app bundle.

- [ ] **Step 4: Run focused tests and build contract**

Run: `swift test --filter AppRuntimeTests --no-parallel && bash Scripts/test-build-app-contract.sh && bash Scripts/test-no-tailscale-runtime.sh`

Expected: all commands exit 0; the production app contains no personal-mesh runtime strings or calls.

- [ ] **Step 5: Commit**

```bash
git add App Scripts Tests/MacChannelCoreTests/AppRuntimeTests.swift
git commit -m "feat: make the public channel the only production runtime"
```

### Task 3: Host-approved pairing state machine

**Files:**
- Modify: `Sources/MacChannelCore/Pairing/PairingModels.swift`
- Modify: `Sources/MacChannelCore/Pairing/PairingCoordinator.swift`
- Modify: `Sources/MacChannelCore/Pairing/PairingTransport.swift`
- Modify: `Sources/MacChannelCore/Pairing/RendezvousPairingTransport.swift`
- Modify: `Tests/MacChannelCoreTests/PairingTests.swift`
- Modify: `Tests/MacChannelCoreTests/GoRendezvousInteropTests.swift`

**Interfaces:**
- Produces: `PairingState.approvalRequested(DeviceSummary)`, `PairingState.awaitingHostApproval(DeviceSummary)`, `approvePendingPairing()`, and `rejectPendingPairing()`.
- Preserves: signed ephemeral transcript, channel tags, bilateral authorization delivery, atomic trust commit, expiry, cancellation, and single-use code behavior.

- [ ] **Step 1: Write failing coordinator tests**

```swift
func testJoinerWaitsUntilHostApprovesAndOnlyThenBothTrust() async throws {
    let code = try await host.createCode()
    async let joined = joiner.join(code: code)
    try await hostState.wait(for: .approvalRequested(joinerSummary))
    XCTAssertFalse(await host.isTrusted(joinerID))
    XCTAssertFalse(await joiner.isTrusted(hostID))
    try await host.approvePendingPairing()
    _ = try await joined
    XCTAssertTrue(await host.isTrusted(joinerID))
    XCTAssertTrue(await joiner.isTrusted(hostID))
}

func testHostRejectionLeavesBothSidesUntrusted() async throws {
    let code = try await host.createCode()
    async let result = joiner.join(code: code)
    try await hostState.wait(for: .approvalRequested(joinerSummary))
    try await host.rejectPendingPairing()
    await XCTAssertThrowsErrorAsync(try await result)
    XCTAssertFalse(await host.isTrusted(joinerID))
    XCTAssertFalse(await joiner.isTrusted(hostID))
}
```

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter PairingTests/testJoinerWaitsUntilHostApprovesAndOnlyThenBothTrust --no-parallel`

Expected: compile FAIL because the approval states and methods do not exist.

- [ ] **Step 3: Implement host-only approval without weakening the transcript**

```swift
public enum PairingState: Equatable, Sendable {
    case idle
    case displayingCode(expiresAt: Date)
    case joining
    case approvalRequested(DeviceSummary)
    case awaitingHostApproval(DeviceSummary)
    case committing(DeviceSummary)
    case confirmed(DeviceSummary)
    case failed(MacChannelError)
}
```

Replace UI-driven fingerprint confirmation with host approval. The host signs and commits its authorization only after `approvePendingPairing()`. The joiner remains suspended in the bilateral transport until it receives and verifies the host authorization, then signs its reciprocal record and completes the existing two-record transaction. Rejection resolves the delivery as rejected and clears all pending state.

- [ ] **Step 4: Run pairing, interop, and shutdown tests**

Run: `swift test --filter PairingTests --no-parallel && swift test --filter GoRendezvousInteropTests --no-parallel && swift test --filter RendezvousPairingShutdownTests --no-parallel`

Expected: all suites PASS; replay, expiry, cancellation, invalid signature, and bilateral atomicity cases remain green.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacChannelCore/Pairing Tests/MacChannelCoreTests/PairingTests.swift Tests/MacChannelCoreTests/GoRendezvousInteropTests.swift
git commit -m "feat: approve pairing from the trusted Mac"
```

### Task 4: Minimal pairing and settings UI

**Files:**
- Modify: `App/PairingView.swift`
- Modify: `App/SettingsView.swift`
- Modify: `App/AppSurfaceController.swift`
- Create: `App/LoginItemController.swift`
- Modify: `Tests/MacChannelCoreTests/TransferSurfaceTests.swift`
- Modify: `Tests/MacChannelCoreTests/StatusItemAppKitTests.swift`

**Interfaces:**
- Consumes: Task 1 minimal settings snapshot and Task 3 approval states.
- Produces: a two-choice pairing start, a host approval view, a joiner waiting view, and settings containing only receive/device controls.

- [ ] **Step 1: Write failing model and rendered-copy tests**

```swift
func testJoinerMovesToWaitingCopyWithoutFingerprintConfirmation() async {
    let model = PairingSurfaceModel(entryCode: "123456")
    await model.join(using: HostApprovalPairingService())
    XCTAssertEqual(model.state, .awaitingHostApproval(hostSummary))
    XCTAssertNil(model.actionError)
}

func testHostApprovalCallsServiceOnce() async {
    let service = HostApprovalPairingService()
    let model = PairingSurfaceModel(state: .approvalRequested(joinerSummary))
    await model.approve(using: service)
    XCTAssertEqual(service.approvalCount, 1)
}

func testLoginItemChangeRollsBackWhenSystemRegistrationFails() async {
    let loginItems = StubLoginItemRegistration(result: .failure(TestError.denied))
    let model = SettingsSurfaceModel(launchAtLogin: false)
    await model.updateLaunchAtLogin(true, loginItems: loginItems, using: service)
    XCTAssertFalse(model.launchAtLogin)
    XCTAssertEqual(model.actionError, "无法设置登录时启动，请在系统设置中允许后重试。")
}
```

Add source contract assertions that `PairingView.swift` and `SettingsView.swift` do not contain “指纹”、
“Tailscale”、“连接方式” or an editable `rendezvousURL`.

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter TransferSurfaceTests --no-parallel && swift test --filter StatusItemAppKitTests --no-parallel`

Expected: FAIL because views still expose mesh peer selection, fingerprint confirmation, connectivity mode, and rendezvous URL.

- [ ] **Step 3: Implement focused SwiftUI composition**

Use one local enum to own the idle choice and small state-specific subviews:

```swift
private enum PairingStartChoice { case none, showCode, enterCode }

private struct PairingApprovalContent: View {
    let peer: DeviceSummary
    let approve: () -> Void
    let reject: () -> Void
}

private struct PairingWaitingContent: View {
    let host: DeviceSummary
}
```

The primary settings flow is linear: local display name, default receive directory, global auto-receive, paired devices, login item. Hide diagnostic information behind one disclosure row. `LoginItemController` wraps `SMAppService.mainApp.status/register/unregister`; inject the wrapper into the model so tests never modify the developer Mac's login items. Preserve 40-point minimum controls, keyboard cancel/default actions, VoiceOver labels, and deterministic view state. Keep legacy per-device receive limits in storage and runtime policy, but remove them from the ordinary UI; the global auto-receive switch gates all automatic inbound acceptance.

- [ ] **Step 4: Run UI-model tests and build the app**

Run: `swift test --filter TransferSurfaceTests --no-parallel && swift test --filter StatusItemAppKitTests --no-parallel && swift build --product MacChannelApp`

Expected: all commands PASS with no compiler warnings introduced by these views.

- [ ] **Step 5: Commit**

```bash
git add App/PairingView.swift App/SettingsView.swift App/AppSurfaceController.swift App/LoginItemController.swift Tests/MacChannelCoreTests/TransferSurfaceTests.swift Tests/MacChannelCoreTests/StatusItemAppKitTests.swift
git commit -m "feat: simplify pairing and settings"
```

### Task 5: Resilient public-service lifecycle

**Files:**
- Create: `App/PublicServiceLifecycle.swift`
- Modify: `App/ProductionAppRuntime.swift`
- Modify: `App/MacChannelApp.swift`
- Test: `Tests/MacChannelCoreTests/AppRuntimeTests.swift`

**Interfaces:**
- Produces: `PublicServiceLifecycle` with one reconnect loop and `AsyncStream<PublicServiceState>` where state is `connecting`, `online`, `degraded`, or `offline`.
- Consumes: an injected clock/backoff strategy and a session factory so lifecycle tests use real state transitions without sleeping.

- [ ] **Step 1: Write failing lifecycle tests**

```swift
func testFailedInitialConnectRetriesWithoutRebuildingLocalRuntime() async throws {
    let connector = SequencedPresenceConnector([.failure(testError), .success(())])
    let lifecycle = PublicServiceLifecycle(connector: connector, backoff: .immediateForTests)
    await lifecycle.start()
    try await states.wait(for: .online)
    XCTAssertEqual(await connector.attemptCount, 2)
}

func testConcurrentWakeAndNetworkEventsDoNotCreateDuplicateConnects() async throws {
    await lifecycle.start()
    async let first: Void = lifecycle.reconnectNow()
    async let second: Void = lifecycle.reconnectNow()
    _ = await (first, second)
    XCTAssertEqual(await connector.maximumConcurrentAttempts, 1)
}
```

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter AppRuntimeTests/testFailedInitialConnectRetriesWithoutRebuildingLocalRuntime --no-parallel`

Expected: compile FAIL because `PublicServiceLifecycle` does not exist.

- [ ] **Step 3: Implement the lifecycle actor**

```swift
actor PublicServiceLifecycle {
    private var runTask: Task<Void, Never>?
    func start() { guard runTask == nil else { return }; runTask = Task { await runLoop() } }
    func reconnectNow() { reconnectSignal.yield(()) }
    func stop() async { runTask?.cancel(); await runTask?.value; runTask = nil }
}
```

The loop emits `.connecting`, attempts the authenticated session, emits `.online`, and on failure emits the plain-language degraded state before waiting on either jittered backoff or an explicit reconnect signal. Stopping cancels socket, timer, and waiters exactly once.

- [ ] **Step 4: Run lifecycle tests and launch smoke**

Run: `swift test --filter AppRuntimeTests --no-parallel && bash Scripts/test-app-launch.sh`

Expected: PASS; the launch test proves an unavailable public service does not remove the menu icon or disable local settings.

- [ ] **Step 5: Commit**

```bash
git add App/PublicServiceLifecycle.swift App/ProductionAppRuntime.swift App/MacChannelApp.swift Tests/MacChannelCoreTests/AppRuntimeTests.swift
git commit -m "feat: reconnect the built-in public service automatically"
```

### Task 6: Client-phase integration gate

**Files:**
- Modify: `Scripts/test-app-launch.sh`
- Modify: `Scripts/audit-privacy.sh`
- Modify: `README.md`
- Modify: `docs/operations/deployment.md`

**Interfaces:**
- Consumes: Tasks 1–5.
- Produces: repeatable evidence that the app starts without Tailscale, preserves legacy data, exposes the simplified UI, and keeps sensitive content out of diagnostics.

- [ ] **Step 1: Add failing release-contract assertions**

```bash
rg -q 'Tailscale|个人网络|连接方式|安全中继地址' App/SettingsView.swift && {
  echo "Legacy network configuration is still user-visible" >&2
  exit 1
}
test "$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")" = "1.1.0"
```

Add an upgrade fixture launch that starts once with v1.0.1-shaped settings, records the identity public-key digest, starts the new runtime, and asserts the digest and user preferences are unchanged.

- [ ] **Step 2: Run the gate and verify RED**

Run: `bash Scripts/test-app-launch.sh && bash Scripts/audit-privacy.sh`

Expected: FAIL until version metadata, source contracts, and migration fixture assertions are updated.

- [ ] **Step 3: Update scripts and user documentation**

Document the five-step user flow only: install on both Macs, open the menu icon, show a code on the old Mac, enter it on the new Mac, approve and drag a file. Remove Tailscale installation/configuration from the primary README and keep developer-only local stack instructions under operations docs.

- [ ] **Step 4: Run the complete client gate**

Run: `swift test --no-parallel && bash Scripts/test-build-app-contract.sh && bash Scripts/test-app-launch.sh && bash Scripts/audit-privacy.sh && bash Scripts/test-no-tailscale-runtime.sh`

Expected: Swift reports 0 failures; every script exits 0; only explicitly environment-dependent Docker tests may report their documented skips.

- [ ] **Step 5: Commit**

```bash
git add Scripts README.md docs/operations/deployment.md
git commit -m "test: gate the built-in public channel client"
```

## Follow-on plans

Before touching each independent subsystem, write and commit a focused plan:

1. `2026-08-30-multi-mac-membership-sync.md` for signed group membership events, client persistence, rendezvous storage/API, offline catch-up, conflicts, and revocation.
2. `2026-08-30-public-service-production.md` for production DNS/TLS, immutable images, PostgreSQL/coturn secrets, monitoring, backups, rollback, load/abuse tests, and endpoint packaging.
3. `2026-08-30-v1.1.0-release-acceptance.md` for universal signing, notarization, public GitHub release, fresh-download verification, and the required two/three-real-Mac matrix.
