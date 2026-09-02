import AppKit
import Security
import XCTest

@testable import MacChannelAppKit
@testable import MacChannelCore

final class AppRuntimeTests: XCTestCase {
    func testFailedInitialPublicConnectRetriesWithoutRebuildingLocalRuntime() async throws {
        let connector = SequencedPublicServiceConnector(connectResults: [false, true])
        let lifecycle = PublicServiceLifecycle(
            connectionFactory: { await connector.makeConnection() },
            backoff: .immediateForTests
        )

        await lifecycle.start()
        for _ in 0..<1_000 {
            if await connector.attemptCount() == 2,
                await lifecycle.currentState() == .online
            { break }
            await Task.yield()
        }

        let attempts = await connector.attemptCount()
        let state = await lifecycle.currentState()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(state, .online)
        await lifecycle.stop()
    }

    func testConcurrentReconnectRequestsNeverOverlapPublicConnectAttempts() async throws {
        let connector = SequencedPublicServiceConnector(connectResults: [true, true, true])
        let lifecycle = PublicServiceLifecycle(
            connectionFactory: { await connector.makeConnection() },
            backoff: .immediateForTests
        )
        await lifecycle.start()
        for _ in 0..<1_000 where await lifecycle.currentState() != .online {
            await Task.yield()
        }

        async let first: Void = lifecycle.reconnectNow()
        async let second: Void = lifecycle.reconnectNow()
        _ = await (first, second)
        for _ in 0..<1_000 where await connector.attemptCount() < 2 {
            await Task.yield()
        }

        let maximumConcurrentAttempts = await connector.maximumConcurrentAttempts()
        XCTAssertEqual(maximumConcurrentAttempts, 1)
        await lifecycle.stop()
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

    func testNormalLaunchUsesPackagedEndpointAndOnlyIsolatedLaunchCanOverrideIt() throws {
        let normal = try ProductionRuntimeConfiguration.current(
            environment: [
                "MACCHANNEL_RENDEZVOUS_URL": "wss://example.test/v1/ws",
            ],
            arguments: ["MacChannel"]
        )
        XCTAssertEqual(
            normal.rendezvousWebSocketURL?.absoluteString,
            "wss://channel.zensys-tech.com/v1/ws"
        )
        XCTAssertEqual(
            normal.rendezvousHTTPOrigin?.absoluteString,
            "https://channel.zensys-tech.com"
        )

        let marker = "/tmp/macchannel-endpoint-\(UUID().uuidString)"
        let isolated = try ProductionRuntimeConfiguration.current(
            environment: [
                "MACCHANNEL_RENDEZVOUS_URL": "wss://example.test/v1/ws",
                "MACCHANNEL_STUN_URLS": "stun:a.test, stun:b.test",
            ],
            arguments: ["MacChannel", "--production-launch-test", marker]
        )
        XCTAssertEqual(
            isolated.rendezvousWebSocketURL?.absoluteString, "wss://example.test/v1/ws")
        XCTAssertEqual(isolated.rendezvousHTTPOrigin?.absoluteString, "https://example.test")
        XCTAssertEqual(
            try isolated.endpoints().webSocketURL.absoluteString,
            "wss://example.test/v1/ws"
        )
        XCTAssertThrowsError(
            try ProductionRuntimeConfiguration.current(
                environment: ["MACCHANNEL_RENDEZVOUS_URL": "ws://example.test/v1/ws"],
                arguments: ["MacChannel", "--production-launch-test", marker]
            )
        )
    }

    func testIsolatedLaunchKeepsOutgoingRecoveryInsideItsRuntimeDirectory() throws {
        let marker = "/tmp/macchannel-storage-\(UUID().uuidString)"
        let configuration = try ProductionRuntimeConfiguration.current(
            environment: [:],
            arguments: ["MacChannel", "--production-launch-test", marker]
        )

        XCTAssertEqual(
            configuration.outgoingDirectory,
            configuration.dataDirectory.appendingPathComponent("Outgoing", isDirectory: true)
        )
    }

    func testPackagedConfigurationProvidesFixedOfficialEndpointWithoutEnvironment() throws {
        let configuration = try ProductionRuntimeConfiguration.current(environment: [:])

        XCTAssertEqual(
            configuration.rendezvousWebSocketURL?.absoluteString,
            "wss://channel.zensys-tech.com/v1/ws"
        )
        XCTAssertEqual(
            configuration.rendezvousHTTPOrigin?.absoluteString,
            "https://channel.zensys-tech.com"
        )
        XCTAssertEqual(
            try configuration.endpoints().webSocketURL.absoluteString,
            "wss://channel.zensys-tech.com/v1/ws"
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

        guard case let .startupError(message, canRetry) = host.status else {
            return XCTFail("expected error state")
        }
        XCTAssertTrue(message.contains("无法启动"))
        XCTAssertTrue(canRetry)
        XCTAssertFalse(receivedContainer)
    }

    @MainActor
    func testRuntimeHostRetriesAFailedBootstrapWithoutReplacingStoredIdentity() async {
        let runtime = RuntimeLifecycleSpy()
        let builder = SequencedRuntimeBuilder(
            results: [
                .failure(KeychainStoreError.operationFailed(errSecAuthFailed)),
                .success(AppRuntimeLaunch(runtime: runtime, status: .ready)),
            ]
        )
        let host = AppRuntimeHost(builder: builder)
        var installedContainer: AppContainer?
        host.onChange = { _, container in
            if let container { installedContainer = container }
        }

        await host.bootstrap()
        guard case let .startupError(message, canRetry) = host.status else {
            return XCTFail("expected recoverable keychain error")
        }
        XCTAssertTrue(message.contains("钥匙串"))
        XCTAssertTrue(canRetry)

        await host.bootstrap()

        XCTAssertEqual(host.status, .ready)
        XCTAssertEqual(builder.buildCount, 2)
        XCTAssertTrue(installedContainer === runtime.container)
    }

    @MainActor
    func testLiveRuntimeErrorDoesNotOfferABootstrapRetryThatCannotRun() {
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 30, height: 24)),
            devices: [],
            transferCoordinator: RuntimeTransferCoordinatorStub()
        )

        controller.setRuntimeStatus(.error("请允许钥匙串访问，然后重试。"))

        let retry = controller.statusMenu.items.first { $0.title == "重试启动" }
        XCTAssertEqual(retry?.isHidden, true)
        XCTAssertTrue(retry?.isEnabled == false)
    }

    @MainActor
    func testMalformedStoredIdentityDoesNotOfferAFutileAuthorizationRetry() async {
        let host = AppRuntimeHost(
            builder: RuntimeBuilderStub(
                result: .failure(KeychainStoreError.unexpectedAttributes)
            )
        )
        await host.bootstrap()
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 30, height: 24)),
            devices: [],
            transferCoordinator: RuntimeTransferCoordinatorStub()
        )

        controller.setRuntimeStatus(host.status)

        let retry = controller.statusMenu.items.first { $0.title == "重试启动" }
        XCTAssertEqual(retry?.isHidden, true)
        XCTAssertTrue(retry?.isEnabled == false)
        XCTAssertFalse(host.status.localizedText.contains("允许钥匙串访问"))
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

    func testKeychainDenialThenRetryPreservesIdentityTrustAndSettings() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let secrets = IntermittentRuntimeSecretStore()
        let identity = try DeviceIdentity.loadOrCreate(keychain: secrets)
        let peer = try DeviceIdentity.ephemeral()
        let trustURL = root.appendingPathComponent("trust.json")
        let trustStore = AuthenticatedTrustSnapshotStore(url: trustURL, secrets: secrets)
        let repository = try await trustStore.load(identity: identity)
        _ = try await repository.issueAuthorization(
            subject: peer.id,
            subjectPublicKey: peer.publicKey.rawRepresentation,
            timestamp: Date()
        )
        try await trustStore.persistLatest(from: repository)
        let settingsURL = root.appendingPathComponent("settings.json")
        let settings = try RuntimeSettingsStore(url: settingsURL, trustedDevices: [peer.id])
        try await settings.updateLocalDisplayName("工作室 Mac")
        try await settings.updateAutoReceive(false)
        let storesBeforeDenial = secrets.storeCount

        secrets.denyNextRead()
        XCTAssertThrowsError(try DeviceIdentity.loadOrCreate(keychain: secrets))

        let reloadedIdentity = try DeviceIdentity.loadOrCreate(keychain: secrets)
        let reloadedTrust = try await trustStore.load(identity: reloadedIdentity)
        let reloadedSettings = try RuntimeSettingsStore(
            url: settingsURL,
            trustedDevices: [peer.id]
        )
        let settingsSnapshot = await reloadedSettings.current()
        let reloadedPeerKey = await reloadedTrust.publicKey(for: peer.id)

        XCTAssertEqual(reloadedIdentity.id, identity.id)
        XCTAssertEqual(reloadedPeerKey, peer.publicKey.rawRepresentation)
        XCTAssertEqual(settingsSnapshot.localDisplayName, "工作室 Mac")
        XCTAssertFalse(settingsSnapshot.autoReceive)
        XCTAssertEqual(secrets.storeCount, storesBeforeDenial)
    }

    @MainActor
    func testProductionSettingsServicePersistsEssentialPreferences() async throws {
        let fixture = try makeTrustedRuntimeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = ProductionDeviceSettingsService(
            store: fixture.settings,
            trustRepository: fixture.repository,
            trustStore: FailingTrustSnapshotPersister()
        )

        try await service.updateLocalDisplayName("工作室 Mac")
        try await service.updateAutoReceive(false)
        try await service.updateLaunchAtLogin(true)

        let snapshot = await fixture.settings.current()
        XCTAssertEqual(snapshot.localDisplayName, "工作室 Mac")
        XCTAssertFalse(snapshot.autoReceive)
        XCTAssertTrue(snapshot.launchAtLogin)
    }

    func testGlobalAutoReceiveGatesOtherwiseEnabledTrustedDevices() throws {
        let peer = DeviceID(rawValue: UUID())
        let snapshot = SettingsSurfaceSnapshot(
            defaultDirectory: nil,
            autoReceive: false,
            devices: [
                DeviceSetting(
                    device: DeviceSummary(
                        id: peer,
                        displayName: "书房 Mac",
                        availability: .internet
                    ),
                    autoAccept: true
                )
            ]
        )

        let policy = RuntimeReceivePolicy.make(
            snapshot: snapshot,
            trustedSources: [peer]
        )

        XCTAssertThrowsError(try policy.authorize(source: peer, aggregateBytes: 1)) { error in
            XCTAssertEqual(error as? ReceiveStoreError, .automaticReceiveDisabled)
        }
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

        let result = try await service.approve()

        let warning = try XCTUnwrap(result.warning)
        XCTAssertTrue(warning.contains("对端授权确认未完成"))
        XCTAssertTrue(warning.contains("本地信任记录未保存"))
        let isTrusted = await repository.isTrusted(peer.id)
        XCTAssertTrue(isTrusted)
        let snapshot = await settings.current()
        XCTAssertEqual(snapshot.devices.first?.id, peer.id)
    }

    @MainActor
    func testHostSettingsRecordPeerWhenBilateralTrustCommitsAfterApprovalReturns() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try DeviceIdentity.ephemeral()
        let peerIdentity = try DeviceIdentity.ephemeral()
        let peer = DeviceSummary(
            id: peerIdentity.id,
            displayName: "远端 Mac",
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
        let service = PersistingPairingSurfaceService(
            coordinator: DeferredProductionPairingCoordinator(
                repository: repository,
                peerIdentity: peerIdentity,
                peer: peer
            ),
            settings: settings,
            trustStore: RecordingTrustSnapshotPersister(),
            trustRepository: repository
        )

        _ = try await service.approve()
        let beforeCommit = await settings.current()
        XCTAssertTrue(beforeCommit.devices.isEmpty)

        _ = try await repository.issueAuthorization(
            subject: peer.id,
            subjectPublicKey: peerIdentity.publicKey.rawRepresentation,
            timestamp: Date()
        )
        for _ in 0..<100 {
            if !(await settings.current()).devices.isEmpty { break }
            await Task.yield()
        }

        let afterCommit = await settings.current()
        XCTAssertEqual(afterCommit.devices.first?.displayName, "远端 Mac")
    }

    func testSuccessfulReceivePublishesAfterHistoryRecording() async {
        let history = BlockingReceiveHistoryRecorder()
        let receiveEvents = RuntimeReceiveEventSource()
        let publisher = ReceiveEventPublisherRecorder()
        let stream = await receiveEvents.stream()
        let eventTask = Task { await stream.first(where: { _ in true }) }
        let onReceiveFinished = makeReceiveFinishedHandler(
            recordInboundResult: { result in await history.record(result) },
            publishReceiveEvent: { result in
                await publisher.publish(result)
                await receiveEvents.publish(result)
            }
        )
        let result = TransferReceiveResult(
            transferID: TransferID(rawValue: UUID()),
            receivedURLs: [URL(fileURLWithPath: "/tmp/report.pdf")]
        )

        await onReceiveFinished(nil)
        let completionTask = Task { await onReceiveFinished(result) }
        await history.waitUntilSuccessfulResultIsRecording()
        let eventsPublishedBeforeHistoryFinished = await publisher.publishedResults()
        XCTAssertTrue(eventsPublishedBeforeHistoryFinished.isEmpty)

        await history.releaseSuccessfulResult()
        await completionTask.value

        let eventResult = await eventTask.value
        XCTAssertEqual(eventResult, result)
        let recordedResults = await history.recordedResults()
        XCTAssertEqual(recordedResults, [nil, result])
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

private actor RecordingTrustSnapshotPersister: TrustSnapshotPersisting {
    func persistLatest(from repository: TrustRepository) async throws {}
}

private actor BlockingReceiveHistoryRecorder {
    private var results: [TransferReceiveResult?] = []
    private var isRecordingSuccessfulResult = false
    private var successfulResultWasReleased = false
    private var recordingContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func record(_ result: TransferReceiveResult?) async {
        results.append(result)
        guard result != nil else { return }
        isRecordingSuccessfulResult = true
        recordingContinuation?.resume()
        recordingContinuation = nil
        guard !successfulResultWasReleased else { return }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilSuccessfulResultIsRecording() async {
        guard !isRecordingSuccessfulResult else { return }
        await withCheckedContinuation { continuation in
            recordingContinuation = continuation
        }
    }

    func releaseSuccessfulResult() {
        successfulResultWasReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func recordedResults() -> [TransferReceiveResult?] {
        results
    }
}

private actor ReceiveEventPublisherRecorder {
    private var results: [TransferReceiveResult] = []

    func publish(_ result: TransferReceiveResult) {
        results.append(result)
    }

    func publishedResults() -> [TransferReceiveResult] {
        results
    }
}

private actor DeferredProductionPairingCoordinator: ProductionPairingCoordinating {
    private let repository: TrustRepository
    private let peerIdentity: DeviceIdentity
    private let peer: DeviceSummary

    init(repository: TrustRepository, peerIdentity: DeviceIdentity, peer: DeviceSummary) {
        self.repository = repository
        self.peerIdentity = peerIdentity
        self.peer = peer
    }

    func createCode() async throws -> String { throw RuntimeTestError.failed }
    func join(code: String) async throws -> PairingJoinResult { throw RuntimeTestError.failed }
    func approvePendingPairing() async throws -> SignedTrustRecord {
        try await repository.prepareAuthorization(
            subject: peer.id,
            subjectPublicKey: peerIdentity.publicKey.rawRepresentation,
            timestamp: Date()
        )
    }
    func rejectPendingPairing() async throws {}
    func awaitHostApproval() async throws -> SignedTrustRecord { throw RuntimeTestError.failed }
    func cancelPendingPairing() async throws {}
    func pendingPeerSummary() async -> DeviceSummary? { peer }
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
    func approvePendingPairing() async throws -> SignedTrustRecord {
        let authorization = try await repository.issueAuthorization(
            subject: peer.id,
            subjectPublicKey: peerIdentity.publicKey.rawRepresentation,
            timestamp: Date()
        )
        if throwsAfterMutation { throw RuntimeTestError.failed }
        return authorization
    }
    func rejectPendingPairing() async throws {}
    func awaitHostApproval() async throws -> SignedTrustRecord { throw RuntimeTestError.failed }
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
private final class SequencedRuntimeBuilder: AppRuntimeBuilding {
    private var results: [Result<AppRuntimeLaunch, Error>]
    private(set) var buildCount = 0

    init(results: [Result<AppRuntimeLaunch, Error>]) {
        self.results = results
    }

    func build() async throws -> AppRuntimeLaunch {
        buildCount += 1
        guard !results.isEmpty else { throw RuntimeTestError.failed }
        return try results.removeFirst().get()
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

private final class IntermittentRuntimeSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: Data] = [:]
    private var shouldDenyNextRead = false
    private var stores = 0

    var storeCount: Int { lock.withLock { stores } }

    func denyNextRead() {
        lock.withLock { shouldDenyNextRead = true }
    }

    func data(for account: String, policy: KeychainPolicy) throws -> Data? {
        try lock.withLock {
            if shouldDenyNextRead {
                shouldDenyNextRead = false
                throw KeychainStoreError.operationFailed(errSecAuthFailed)
            }
            return secrets[account]
        }
    }

    func store(_ data: Data, for account: String, policy: KeychainPolicy) throws {
        lock.withLock {
            secrets[account] = data
            stores += 1
        }
    }
}

private actor SequencedPublicServiceConnector {
    private var connectResults: [Bool]
    private var attempts = 0
    private var concurrentAttempts = 0
    private var maximumConcurrent = 0
    private var runWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    init(connectResults: [Bool]) { self.connectResults = connectResults }

    func makeConnection() -> PublicServiceConnection {
        let id = UUID()
        return PublicServiceConnection(
            connect: { try await self.connect() },
            run: { try await self.run(id: id) },
            stop: { await self.stop(id: id) }
        )
    }

    func attemptCount() -> Int { attempts }
    func maximumConcurrentAttempts() -> Int { maximumConcurrent }

    private func connect() throws {
        attempts += 1
        concurrentAttempts += 1
        maximumConcurrent = max(maximumConcurrent, concurrentAttempts)
        defer { concurrentAttempts -= 1 }
        guard !connectResults.isEmpty else { return }
        guard connectResults.removeFirst() else { throw RuntimeTestError.failed }
    }

    private func run(id: UUID) async throws {
        try await withCheckedThrowingContinuation { continuation in
            runWaiters[id] = continuation
        }
    }

    private func stop(id: UUID) {
        runWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

private actor RuntimeTransferCoordinatorStub: TransferCoordinating {
    func send(items: [URL], to device: DeviceID) async throws -> TransferID {
        TransferID(rawValue: UUID())
    }
    func pause(_ id: TransferID) async {}
    func resume(_ id: TransferID) async throws {}
    func cancel(_ id: TransferID) async -> TransferCancellationResult { .requested }
}
