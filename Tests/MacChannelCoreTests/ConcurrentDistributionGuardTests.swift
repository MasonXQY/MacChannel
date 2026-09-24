import Foundation
import Darwin
import Network
import XCTest
@testable import MacChannelAppKit
@testable import MacChannelCore

@MainActor
final class ConcurrentDistributionGuardTests: XCTestCase {
    func testStopDuringReceiveConfigurationLoadCannotStartLateListener() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try DeviceIdentity.ephemeral()
        let trust = try TrustRepository(ownerIdentity: identity, trustStore: TrustStore(owner: identity.id), persistedGeneration: 0)
        let settings = PausedReceiveSettings(store: try RuntimeSettingsStore(url: root.appendingPathComponent("settings.json"), trustedDevices: []))
        let source = ReceiveConnectionProbe()
        let controller = IncomingRuntimeController(source: source, trustRepository: trust, settings: settings,
            database: try TransferDatabase(url: root.appendingPathComponent("transfers.sqlite3")),
            incomingDirectory: root.appendingPathComponent("Incoming"), ownerID: identity.id,
            onReceiveFinished: { _ in })
        let start = Task { await controller.start() }
        await settings.waitUntilLoading()
        var stopFinished = false
        let stop = Task { await controller.stop(); stopFinished = true }
        for _ in 0..<30 { await Task.yield() }
        XCTAssertFalse(stopFinished, "Stop must await the in-flight configuration load")
        await settings.release()
        await start.value
        await stop.value
        for _ in 0..<30 { await Task.yield() }
        let requests = await source.requests
        XCTAssertEqual(requests, 0, "A stale configuration load must not start a receive reader after stop")
    }

    func testExplicitRetryWaitsForReceiveObservationDrain() async {
        let builder = CoexistenceBuilder()
        let host = AppRuntimeHost(builder: builder)
        await host.bootstrap()
        var drainStarted = false
        var drainGate: CheckedContinuation<Void, Never>?
        host.onWillStop = {
            drainStarted = true
            await withCheckedContinuation { drainGate = $0 }
        }
        let stop = Task { await host.stopCurrentRuntime() }
        while !drainStarted { await Task.yield() }
        let retry = Task { await host.bootstrap() }
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(builder.count, 1)
        XCTAssertEqual(builder.runtimes[0].shutdowns, 0)
        drainGate?.resume()
        await stop.value
        await retry.value
        XCTAssertEqual(builder.count, 2)
        XCTAssertEqual(builder.runtimes[0].shutdowns, 1)
        await host.shutdown()
    }

    func testConflictStopTearsDownProductionResourcesBeforeReturning() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try DeviceIdentity.ephemeral()
        let trust = try TrustRepository(ownerIdentity: identity, trustStore: TrustStore(owner: identity.id), persistedGeneration: 0)
        let directory = DeviceDirectory(trust: .allowing(identity.id))
        let browser = BonjourPeerBrowser(directory: directory, trust: .allowing(identity.id))
        browser.startWithoutSystemBrowserForTesting()
        let advertiser = try BonjourPeerAdvertiser(device: identity.id, port: 59_843) { $0.cancel() }
        advertiser.start()
        let signals = CoexistenceSignalSession()
        let listener = WebRTCConnectionListener(directory: directory, identity: identity, trustRepository: trust,
                                               signaling: RendezvousWebRTCSignaling(session: signals),
                                               ice: ICEConfiguration(stunURLs: [], turnServers: []))
        let events = RuntimeReceiveEventSource()
        let stream = await events.stream()
        let database = try TransferDatabase(url: root.appendingPathComponent("transfers.sqlite3"))
        let settings = try RuntimeSettingsStore(url: root.appendingPathComponent("settings.json"), trustedDevices: [])
        let incoming = IncomingRuntimeController(source: listener, trustRepository: trust, settings: settings,
            database: database, incomingDirectory: root.appendingPathComponent("Incoming"),
            ownerID: identity.id, onReceiveFinished: { result in
                if let result { await events.publish(result) }
            })
        await incoming.start()
        let history = RuntimeHistorySource(database: database, settings: settings,
                                          outputLocator: try RuntimeOutputLocator(url: root.appendingPathComponent("outputs.json")))
        let pipe = Pipe()
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let persistence = Task {
            let updates = await trust.updates()
            for await _ in updates { if Task.isCancelled { break } }
            try? pipe.fileHandleForReading.close()
        }
        let runtime = ProductionAppRuntime(container: .localShell(), initialStatus: .ready,
            browser: browser, advertiser: advertiser, trustPersistenceTask: persistence,
            historySource: history, receiveEvents: events, statusSource: RuntimeStatusSource(),
            publicServiceLifecycle: nil, publicServiceStatusTask: nil, publicServiceTrustTask: nil,
            signalSession: nil, pairingTransport: nil, connectionListener: listener,
            incomingController: incoming, transferCoordinator: nil, trustRepository: trust,
            trustStore: CoexistenceTrustStore(), launchTestKeychain: nil, launchTestDataDirectory: nil)
        let apps = RunningAppsFixture()
        let host = AppRuntimeHost(builder: ProductionResourceBuilder(runtime: runtime),
            eligibility: ConcurrentDistributionGuard(conflictingBundleIdentifiers: ["com.mason.macchannel"], provider: apps))
        await host.bootstrap()
        apps.identifiers = ["com.mason.macchannel"]
        apps.notify()
        while host.status == .ready { await Task.yield() }
        await host.stopCurrentRuntime()
        XCTAssertEqual(browser.state(), .stopped)
        XCTAssertEqual(advertiser.state(), .stopped)
        XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
        var receiveIterator = stream.makeAsyncIterator()
        let received = await receiveIterator.next()
        XCTAssertNil(received)
        let stoppedConnections = await listener.connections()
        var connectionIterator = stoppedConnections.makeAsyncIterator()
        let connection = try await connectionIterator.next()
        XCTAssertNil(connection)
        let requestsBefore = await signals.streamRequests
        _ = await listener.connections()
        let requestsAfter = await signals.streamRequests
        XCTAssertEqual(requestsAfter, requestsBefore)
        await host.shutdown()
    }

    func testStoreDoesNotBootstrapWhileDirectRunsAndDirectNeverBlocks() async {
        let apps = RunningAppsFixture()
        apps.identifiers = ["com.mason.macchannel"]
        let guardMonitor = ConcurrentDistributionGuard(conflictingBundleIdentifiers: ["com.mason.macchannel"], provider: apps)
        let builder = CoexistenceBuilder()
        let host = AppRuntimeHost(builder: builder, eligibility: guardMonitor)
        await host.bootstrap()
        XCTAssertEqual(builder.count, 0)
        XCTAssertEqual(host.status, .startupFailure(.statusDistributionConflict, canRetry: true))
        let direct = AppRuntimeHost(builder: builder, eligibility: ConcurrentDistributionGuard(conflictingBundleIdentifiers: [], provider: apps))
        await direct.bootstrap()
        XCTAssertEqual(builder.count, 1)
        await host.shutdown()
        await direct.shutdown()
    }

    func testConflictAwaitsStopRejectsStaleEventsAndExplicitRetryBuildsOneFreshRuntime() async {
        let apps = RunningAppsFixture()
        let monitor = ConcurrentDistributionGuard(conflictingBundleIdentifiers: ["com.mason.macchannel"], provider: apps)
        let builder = CoexistenceBuilder()
        let host = AppRuntimeHost(builder: builder, eligibility: monitor)
        await host.bootstrap()
        let first = builder.runtimes[0]
        first.blockStop = true
        apps.identifiers = ["com.mason.macchannel"]
        apps.notify()
        await first.waitForStop()
        var stopped = false
        let stop = Task { await host.stopCurrentRuntime(); stopped = true }
        for _ in 0..<30 { await Task.yield() }
        XCTAssertFalse(stopped)
        first.statusContinuation.yield(.ready)
        for _ in 0..<30 { await Task.yield() }
        XCTAssertNotEqual(host.status, .ready)
        apps.identifiers = []
        apps.notify()
        apps.notify() // delayed notification must re-read state, never restart
        first.releaseStop()
        await stop.value
        XCTAssertEqual(first.shutdowns, 1)
        XCTAssertTrue(first.resourcesReleased)
        XCTAssertEqual(builder.count, 1)
        async let retry1: Void = host.bootstrap()
        async let retry2: Void = host.bootstrap()
        _ = await (retry1, retry2)
        XCTAssertEqual(builder.count, 2)
        XCTAssertFalse(builder.runtimes[0] === builder.runtimes[1])
        await host.shutdown()
    }

    func testConflictDuringCancellationInsensitiveBuildNeverPublishesLateRuntime() async {
        let apps = RunningAppsFixture()
        let monitor = ConcurrentDistributionGuard(conflictingBundleIdentifiers: ["com.mason.macchannel"], provider: apps)
        let builder = CoexistenceBuilder()
        builder.blockBuild = true
        let host = AppRuntimeHost(builder: builder, eligibility: monitor)
        var publishedRuntime = false
        host.onChange = { _, container in if container != nil { publishedRuntime = true } }
        let build = Task { await host.bootstrap() }
        while builder.count == 0 { await Task.yield() }
        apps.identifiers = ["com.mason.macchannel"]
        apps.notify()
        while host.status == .loading { await Task.yield() }
        builder.releaseBuild()
        await build.value
        await host.stopCurrentRuntime()
        XCTAssertFalse(publishedRuntime)
        XCTAssertEqual(builder.runtimes[0].shutdowns, 1)
        await host.shutdown()
    }
}

@MainActor
private final class ProductionResourceBuilder: AppRuntimeBuilding {
    let runtime: ProductionAppRuntime
    init(runtime: ProductionAppRuntime) { self.runtime = runtime }
    func build() async throws -> AppRuntimeLaunch { AppRuntimeLaunch(runtime: runtime, status: .ready) }
}

private actor CoexistenceTrustStore: TrustSnapshotPersisting {
    func persistLatest(from repository: TrustRepository) async throws {}
}

private actor CoexistenceSignalSession: RendezvousSignalSession {
    private(set) var streamRequests = 0
    private let frames = AsyncStream<RendezvousSignalFrame>.makeStream()
    private let errors = AsyncStream<RendezvousProtocolError>.makeStream()
    func signalFrames() -> AsyncStream<RendezvousSignalFrame> {
        streamRequests += 1
        return frames.stream
    }
    func protocolErrors() -> AsyncStream<RendezvousProtocolError> { errors.stream }
    func sendSignal(_ payload: Data, to device: DeviceID) async throws {}
}

private actor PausedReceiveSettings: RuntimeReceiveSettingsProviding {
    let store: RuntimeSettingsStore
    private var loading = false
    private var gate: CheckedContinuation<Void, Never>?
    init(store: RuntimeSettingsStore) { self.store = store }
    func current() async -> SettingsSurfaceSnapshot {
        loading = true
        await withCheckedContinuation { gate = $0 }
        return await store.current()
    }
    func downloadDirectory() async -> DownloadDirectory { await store.downloadDirectory() }
    func waitUntilLoading() async { while !loading { await Task.yield() } }
    func release() { gate?.resume(); gate = nil }
}

private actor ReceiveConnectionProbe: IncomingTransferConnectionSource {
    private(set) var requests = 0
    func connections() -> AsyncThrowingStream<IncomingTransferConnection, Error> {
        requests += 1
        return AsyncThrowingStream { $0.finish() }
    }
}

@MainActor
private final class RunningAppsFixture: RunningApplicationProviding {
    var identifiers: Set<String> = []
    var runningBundleIdentifiers: Set<String> { identifiers }
    private var continuations: [AsyncStream<Void>.Continuation] = []
    func changes() -> AsyncStream<Void> {
        let pair = AsyncStream<Void>.makeStream()
        continuations.append(pair.continuation)
        return pair.stream
    }
    func notify() { continuations.forEach { $0.yield(()) } }
}

@MainActor
private final class CoexistenceBuilder: AppRuntimeBuilding {
    var count = 0
    var runtimes: [CoexistenceRuntime] = []
    var blockBuild = false
    private var buildGate: CheckedContinuation<Void, Never>?
    func build() async throws -> AppRuntimeLaunch {
        count += 1
        let runtime = CoexistenceRuntime()
        runtimes.append(runtime)
        if blockBuild { await withCheckedContinuation { buildGate = $0 } }
        return AppRuntimeLaunch(runtime: runtime, status: .ready)
    }
    func releaseBuild() { buildGate?.resume(); buildGate = nil }
}

@MainActor
private final class CoexistenceRuntime: AppRuntimeLifecycle {
    let container = AppContainer.localShell()
    let statusStream: AsyncStream<AppRuntimeStatus>
    let statusContinuation: AsyncStream<AppRuntimeStatus>.Continuation
    var blockStop = false
    var shutdowns = 0
    var resourcesReleased = false
    private var stopGate: CheckedContinuation<Void, Never>?
    init() {
        (statusStream, statusContinuation) = AsyncStream<AppRuntimeStatus>.makeStream()
    }
    func statusUpdates() -> AsyncStream<AppRuntimeStatus>? { statusStream }
    func shutdown() async {
        shutdowns += 1
        if blockStop { await withCheckedContinuation { stopGate = $0 } }
        statusContinuation.finish()
        resourcesReleased = true
    }
    func waitForStop() async { while shutdowns == 0 { await Task.yield() } }
    func releaseStop() { stopGate?.resume(); stopGate = nil }
}
