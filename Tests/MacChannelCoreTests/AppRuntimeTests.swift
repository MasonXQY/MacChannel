import AppKit
import XCTest

@testable import MacChannelAppKit
@testable import MacChannelCore

final class AppRuntimeTests: XCTestCase {
    func testIsolatedLaunchCanExerciseBothConnectivityModesWithoutProductionOverride() throws {
        let marker = "/tmp/macchannel-mode-\(UUID().uuidString)"
        let personal = try ProductionRuntimeConfiguration.current(
            environment: ["MACCHANNEL_LAUNCH_TEST_CONNECTIVITY_MODE": "personalMesh"],
            arguments: ["MacChannel", "--production-launch-test", marker]
        )
        let publicMode = try ProductionRuntimeConfiguration.current(
            environment: ["MACCHANNEL_LAUNCH_TEST_CONNECTIVITY_MODE": "publicService"],
            arguments: ["MacChannel", "--production-launch-test", marker]
        )
        let ignored = try ProductionRuntimeConfiguration.current(
            environment: ["MACCHANNEL_LAUNCH_TEST_CONNECTIVITY_MODE": "publicService"],
            arguments: ["MacChannel"]
        )

        XCTAssertEqual(personal.isolatedConnectivityMode, .personalMesh)
        XCTAssertEqual(publicMode.isolatedConnectivityMode, .publicService)
        XCTAssertNil(ignored.isolatedConnectivityMode)
    }
    func testLaunchModeUsesProductionUnlessShellIsExplicit() {
        XCTAssertEqual(AppLaunchMode.resolve(arguments: [], environment: [:]), .production)
        XCTAssertEqual(
            AppLaunchMode.resolve(
                arguments: ["MacChannelApp", "--smoke-test", "/tmp/marker"], environment: [:]),
            .localShell
        )
        XCTAssertEqual(
            AppLaunchMode.resolve(
                arguments: [], environment: ["MACCHANNEL_RUNTIME": "local-shell"]),
            .localShell
        )
        XCTAssertEqual(
            AppLaunchMode.resolve(
                arguments: ["MacChannelApp", "--production-launch-test", "/tmp/marker"],
                environment: [:]
            ),
            .production
        )
    }

    func testProductionConfigurationRequiresWSSAndDerivesHTTPSPairingOrigin() throws {
        XCTAssertThrowsError(
            try ProductionRuntimeConfiguration.current(
                environment: ["MACCHANNEL_RENDEZVOUS_URL": "ws://example.test/v1/ws"]
            )
        )

        let configuration = try ProductionRuntimeConfiguration.current(
            environment: [
                "MACCHANNEL_RENDEZVOUS_URL": "wss://example.test/v1/ws",
                "MACCHANNEL_STUN_URLS": "stun:a.test, stun:b.test",
            ]
        )

        XCTAssertEqual(
            configuration.rendezvousWebSocketURL?.absoluteString, "wss://example.test/v1/ws")
        XCTAssertEqual(configuration.rendezvousHTTPOrigin?.absoluteString, "https://example.test")
        XCTAssertEqual(
            try configuration.endpoints(persistedURL: "wss://persisted.test/v1/ws")
                .webSocketURL.absoluteString,
            "wss://example.test/v1/ws"
        )
    }

    func testPackagedConfigurationProvidesSecureLocalStackDefaultWithoutEnvironment() throws {
        let configuration = try ProductionRuntimeConfiguration.current(environment: [:])

        XCTAssertEqual(
            configuration.rendezvousWebSocketURL?.absoluteString,
            "wss://localhost:8443/v1/ws"
        )
        XCTAssertEqual(
            configuration.rendezvousHTTPOrigin?.absoluteString,
            "https://localhost:8443"
        )
        XCTAssertEqual(
            try configuration.endpoints(persistedURL: "wss://relay.example/v1/ws")
                .webSocketURL.absoluteString,
            "wss://relay.example/v1/ws"
        )
    }

    func testRendezvousURLValidationRejectsCredentialsAndNormalizesHTTPSOrWSS() throws {
        XCTAssertThrowsError(try RendezvousEndpointConfiguration.parse("http://localhost:8443"))
        XCTAssertThrowsError(
            try RendezvousEndpointConfiguration.parse("wss://user:secret@localhost:8443/v1/ws"))
        XCTAssertThrowsError(
            try RendezvousEndpointConfiguration.parse("wss://localhost:8443/v1/ws?token=secret"))
        XCTAssertThrowsError(
            try RendezvousEndpointConfiguration.parse("wss://localhost:8443/v1/ws#fragment"))
        XCTAssertThrowsError(
            try RendezvousEndpointConfiguration.parse("wss://localhost:8443/another-path"))

        let https = try RendezvousEndpointConfiguration.parse("https://relay.example:8443")
        XCTAssertEqual(https.webSocketURL.absoluteString, "wss://relay.example:8443/v1/ws")
        XCTAssertEqual(https.httpOrigin.absoluteString, "https://relay.example:8443")
        let wss = try RendezvousEndpointConfiguration.parse("wss://relay.example:8443/v1/ws")
        XCTAssertEqual(wss, https)
    }

    @MainActor
    func testOfflineRuntimeStatusIsVisibleAndSpokenWithAnIcon() {
        let button = StatusItemButton(frame: NSRect(x: 0, y: 0, width: 30, height: 24))
        let controller = StatusItemController(
            button: button,
            devices: [],
            transferCoordinator: RuntimeTransferCoordinatorStub()
        )

        controller.setRuntimeStatus(.offline("安全中继暂时不可用；本地设置仍可使用。"))

        XCTAssertEqual(controller.statusMenu.items.first?.title, "安全中继暂时不可用；本地设置仍可使用。")
        XCTAssertNotNil(controller.statusMenu.items.first?.image)
        XCTAssertEqual(
            button.accessibilityValue() as? String,
            "空闲，安全中继暂时不可用；本地设置仍可使用。"
        )
    }

    @MainActor
    func testRuntimeHostPublishesLoadingThenOfflineAndShutsDownInOrder() async {
        let runtime = RuntimeLifecycleSpy()
        let builder = RuntimeBuilderStub(
            result: .success(
                AppRuntimeLaunch(
                    runtime: runtime,
                    status: .offline("安全中继未配置；局域网发现和本地设置仍可使用。")
                )
            )
        )
        let host = AppRuntimeHost(builder: builder)
        var states: [AppRuntimeStatus] = []
        host.onChange = { status, _ in states.append(status) }

        await host.bootstrap()
        await host.shutdown()

        XCTAssertEqual(
            states,
            [
                .loading,
                .offline("安全中继未配置；局域网发现和本地设置仍可使用。"),
            ])
        XCTAssertEqual(runtime.shutdownCount, 1)
        XCTAssertEqual(host.status, .offline("安全中继未配置；局域网发现和本地设置仍可使用。"))
    }

    @MainActor
    func testRuntimeHostPublishesChineseErrorWithoutFakeReadyContainer() async {
        let host = AppRuntimeHost(
            builder: RuntimeBuilderStub(result: .failure(RuntimeTestError.failed))
        )
        var receivedContainer = false
        host.onChange = { _, container in receivedContainer = receivedContainer || container != nil
        }

        await host.bootstrap()

        guard case let .error(message) = host.status else {
            return XCTFail("expected error state")
        }
        XCTAssertTrue(message.contains("无法启动"))
        XCTAssertFalse(receivedContainer)
    }

    @MainActor
    func testRuntimeHostShutdownWaitsForCancelledBuildAndStopsLateRuntimeExactlyOnce() async {
        let runtime = RuntimeLifecycleSpy()
        let builder = DelayedRuntimeBuilder(runtime: runtime)
        let host = AppRuntimeHost(builder: builder)
        let bootstrap = Task { await host.bootstrap() }
        await builder.waitUntilStarted()

        let completion = AsyncCompletionProbe()
        let shutdown = Task {
            await host.shutdown()
            await completion.finish()
        }
        await Task.yield()
        let finishedEarly = await completion.isFinished()
        XCTAssertFalse(finishedEarly)

        builder.release()
        await shutdown.value
        await bootstrap.value

        let finished = await completion.isFinished()
        XCTAssertTrue(finished)
        XCTAssertEqual(runtime.shutdownCount, 1)
    }

    @MainActor
    func testBootstrapCleanupRunsStartedResourcesInReverseOrderOnlyOnce() async {
        var events: [String] = []
        let cleanup = RuntimeBootstrapCleanup()
        cleanup.push { events.append("browser") }
        cleanup.push { events.append("advertiser") }
        cleanup.push { events.append("presence") }

        await cleanup.run()
        await cleanup.run()

        XCTAssertEqual(events, ["presence", "advertiser", "browser"])
    }

    @MainActor
    func testPresenceShutdownClosesCancellationInsensitiveReceiveBeforeAwaitingTask() async {
        let socket = CancellationInsensitivePresenceGate()
        let task = Task { await socket.receiveUntilClosed() }
        await socket.waitUntilReceiving()

        await RuntimePresenceShutdown.cancelCloseAndWait(task) {
            await socket.close()
        }

        let closed = await socket.wasClosed()
        let returned = await socket.didReturn()
        XCTAssertTrue(closed)
        XCTAssertTrue(returned)
    }

    func testInboundCompletionRefreshesHistoryWithDurableActualOutputURL() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let peer = DeviceID(rawValue: UUID())
        let transfer = TransferID(rawValue: UUID())
        let database = try TransferDatabase(url: root.appendingPathComponent("transfers.sqlite3"))
        let settings = try RuntimeSettingsStore(
            url: root.appendingPathComponent("settings.json"),
            trustedDevices: [peer]
        )
        let locatorURL = root.appendingPathComponent("received-outputs.json")
        let locator = try RuntimeOutputLocator(url: locatorURL)
        let history = RuntimeHistorySource(
            database: database,
            settings: settings,
            outputLocator: locator
        )
        let updates = await history.stream()
        let observation = Task { () -> TransferSurfaceItem? in
            var iterator = updates.makeAsyncIterator()
            _ = await iterator.next()
            return await iterator.next()?.first { $0.id == transfer }
        }
        let actualOutput = root.appendingPathComponent("Downloads/report (2).pdf")
        try await database.record(
            TransferSnapshot(
                id: transfer,
                peer: peer,
                phase: .completed,
                completedBytes: 10,
                totalBytes: 10,
                route: .lan
            ),
            displayFilename: "report.pdf",
            direction: .inbound
        )

        await history.recordInboundResult(
            TransferReceiveResult(transferID: transfer, receivedURLs: [actualOutput])
        )
        let observed = await observation.value
        let item = try XCTUnwrap(observed)
        XCTAssertEqual(item.outputURL, actualOutput)

        try await settings.updateDefaultDirectory(root.appendingPathComponent("Different"))
        let reloadedLocator = try RuntimeOutputLocator(url: locatorURL)
        let reloadedHistory = RuntimeHistorySource(
            database: database,
            settings: settings,
            outputLocator: reloadedLocator
        )
        let reloadedStream = await reloadedHistory.stream()
        var reloadedIterator = reloadedStream.makeAsyncIterator()
        let reloaded = await reloadedIterator.next()?.first
        let reloadedItem = try XCTUnwrap(reloaded)
        XCTAssertEqual(reloadedItem.outputURL, actualOutput)
    }

    func testStaleHistoryRetentionCannotDeleteNewerInboundOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transfer = TransferID(rawValue: UUID())
        let locator = try RuntimeOutputLocator(
            url: root.appendingPathComponent("received-outputs.json"))
        let staleRevision = await locator.retentionRevision()
        let actualOutput = root.appendingPathComponent("Downloads/newer.pdf")

        try await locator.record(
            TransferReceiveResult(transferID: transfer, receivedURLs: [actualOutput])
        )
        try await locator.retain([], ifUnchangedSince: staleRevision)

        let retained = await locator.outputURL(for: transfer)
        XCTAssertEqual(retained, actualOutput)
    }

    func testRendezvousURLPersistsInRuntimeSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.json")
        let settings = try RuntimeSettingsStore(url: url, trustedDevices: [])

        try await settings.updateRendezvousURL("wss://relay.example:8443/v1/ws")

        let reloaded = try RuntimeSettingsStore(url: url, trustedDevices: [])
        let snapshot = await reloaded.current()
        XCTAssertEqual(snapshot.rendezvousURL, "wss://relay.example:8443/v1/ws")
    }

    @MainActor
    func testProductionRevokeReportsCommittedWarningAfterTrustMutationPersistenceFailure()
        async throws
    {
        let fixture = try makeTrustedRuntimeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = ProductionDeviceSettingsService(
            store: fixture.settings,
            trustRepository: fixture.repository,
            trustStore: FailingTrustSnapshotPersister()
        )

        let result = try await service.revoke(fixture.peer.id)

        XCTAssertNotNil(result.warning)
        let remainsTrusted = await fixture.repository.isTrusted(fixture.peer.id)
        XCTAssertFalse(remainsTrusted)
        let settings = await fixture.settings.current()
        XCTAssertFalse(settings.devices.contains { $0.id == fixture.peer.id })
    }

    @MainActor
    func testProductionPairingCombinesAuthorizationAndPersistenceWarningsAfterTrustCommit()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try DeviceIdentity.ephemeral()
        let peerIdentity = try DeviceIdentity.ephemeral()
        let peer = DeviceSummary(
            id: peerIdentity.id,
            displayName: "书房 Mac",
            availability: .internet
        )
        let repository = try TrustRepository(
            ownerIdentity: owner,
            trustStore: TrustStore(owner: owner.id),
            persistedGeneration: 0
        )
        let settings = try RuntimeSettingsStore(
            url: root.appendingPathComponent("settings.json"),
            trustedDevices: []
        )
        let coordinator = MutatingProductionPairingCoordinator(
            repository: repository,
            peerIdentity: peerIdentity,
            peer: peer,
            throwsAfterMutation: true
        )
        let service = PersistingPairingSurfaceService(
            coordinator: coordinator,
            settings: settings,
            trustStore: FailingTrustSnapshotPersister(),
            trustRepository: repository
        )

        let result = try await service.confirmFingerprint("ABCD")

        let warning = try XCTUnwrap(result.warning)
        XCTAssertTrue(warning.contains("对端授权确认未完成"))
        XCTAssertTrue(warning.contains("本地信任记录未保存"))
        let isTrusted = await repository.isTrusted(peer.id)
        XCTAssertTrue(isTrusted)
        let snapshot = await settings.current()
        XCTAssertEqual(snapshot.devices.first?.id, peer.id)
    }

    private func makeTrustedRuntimeFixture() throws -> TrustedRuntimeFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let owner = try DeviceIdentity.ephemeral()
        let peerIdentity = try DeviceIdentity.ephemeral()
        let peer = DeviceSummary(
            id: peerIdentity.id,
            displayName: "办公室 Mac",
            availability: .lan
        )
        var trust = TrustStore(owner: owner.id)
        let authorization = try SignedTrustRecord.authorizing(peerIdentity, signedBy: owner)
        try trust.authorize(authorization)
        _ = try trust.snapshot(signedBy: owner)
        let repository = try TrustRepository(
            ownerIdentity: owner,
            trustStore: trust,
            persistedGeneration: trust.persistedGeneration
        )
        let settings = try RuntimeSettingsStore(
            url: root.appendingPathComponent("settings.json"),
            trustedDevices: [peer.id]
        )
        return TrustedRuntimeFixture(
            root: root, peer: peer, repository: repository, settings: settings)
    }
}

private struct TrustedRuntimeFixture {
    let root: URL
    let peer: DeviceSummary
    let repository: TrustRepository
    let settings: RuntimeSettingsStore
}

private actor FailingTrustSnapshotPersister: TrustSnapshotPersisting {
    func persistLatest(from repository: TrustRepository) async throws {
        throw RuntimeTestError.failed
    }
}

private actor MutatingProductionPairingCoordinator: ProductionPairingCoordinating {
    private let repository: TrustRepository
    private let peerIdentity: DeviceIdentity
    private let peer: DeviceSummary
    private let throwsAfterMutation: Bool

    init(
        repository: TrustRepository,
        peerIdentity: DeviceIdentity,
        peer: DeviceSummary,
        throwsAfterMutation: Bool = false
    ) {
        self.repository = repository
        self.peerIdentity = peerIdentity
        self.peer = peer
        self.throwsAfterMutation = throwsAfterMutation
    }

    func createCode() async throws -> String { throw RuntimeTestError.failed }
    func join(code: String) async throws -> PairingJoinResult { throw RuntimeTestError.failed }
    func confirmForSurface(_ fingerprint: String) async throws {
        _ = try await repository.issueAuthorization(
            subject: peer.id,
            subjectPublicKey: peerIdentity.publicKey.rawRepresentation,
            timestamp: Date()
        )
        if throwsAfterMutation { throw RuntimeTestError.failed }
    }
    func cancelPendingPairing() async throws {}
    func pendingPeerSummary() async -> DeviceSummary? { peer }
}

private actor CancellationInsensitivePresenceGate {
    private var receiveContinuation: CheckedContinuation<Void, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var receiving = false
    private var closed = false
    private var returned = false

    func receiveUntilClosed() async {
        receiving = true
        startedContinuation?.resume()
        startedContinuation = nil
        if !closed {
            await withCheckedContinuation { continuation in
                receiveContinuation = continuation
            }
        }
        returned = true
    }

    func waitUntilReceiving() async {
        if receiving { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func close() {
        closed = true
        receiveContinuation?.resume()
        receiveContinuation = nil
    }

    func wasClosed() -> Bool { closed }
    func didReturn() -> Bool { returned }
}

@MainActor
private final class RuntimeLifecycleSpy: AppRuntimeLifecycle {
    let container = AppContainer.localShell()
    private(set) var shutdownCount = 0

    func shutdown() async {
        shutdownCount += 1
    }
}

@MainActor
private final class RuntimeBuilderStub: AppRuntimeBuilding {
    let result: Result<AppRuntimeLaunch, Error>

    init(result: Result<AppRuntimeLaunch, Error>) {
        self.result = result
    }

    func build() async throws -> AppRuntimeLaunch {
        try result.get()
    }
}

@MainActor
private final class DelayedRuntimeBuilder: AppRuntimeBuilding {
    private let runtime: RuntimeLifecycleSpy
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var started = false
    private var released = false

    init(runtime: RuntimeLifecycleSpy) {
        self.runtime = runtime
    }

    func build() async throws -> AppRuntimeLaunch {
        started = true
        startedContinuation?.resume()
        startedContinuation = nil
        if !released {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        return AppRuntimeLaunch(runtime: runtime, status: .ready)
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor AsyncCompletionProbe {
    private var finished = false
    func finish() { finished = true }
    func isFinished() -> Bool { finished }
}

private enum RuntimeTestError: Error { case failed }

private actor RuntimeTransferCoordinatorStub: TransferCoordinating {
    func send(items: [URL], to device: DeviceID) async throws -> TransferID {
        TransferID(rawValue: UUID())
    }
    func pause(_ id: TransferID) async {}
    func resume(_ id: TransferID) async throws {}
    func cancel(_ id: TransferID) async -> TransferCancellationResult { .requested }
}
