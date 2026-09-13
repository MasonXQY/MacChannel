import Foundation
import XCTest
@preconcurrency import WebRTC
@testable import MacChannelCore
@testable import DropMeshMobileRuntime

final class MobileProductionForegroundNetworkTests: XCTestCase {
    func testProductionGraphReentryWaitsForAcceptanceAndLateCloseAfterSocketAndHTTPShutdown() async throws {
        let fixture = try await DrainFixture.make()
        let roots = FileManager.default.temporaryDirectory.appendingPathComponent("mobile-production-drain-\(UUID())")
        let layout = MobileStorageLayout(applicationSupport: roots.appendingPathComponent("Support"),
            documents: roots.appendingPathComponent("Documents"))
        try layout.prepare()
        let database = try TransferDatabase(url: layout.stateDirectory.appendingPathComponent("transfers.sqlite3"))
        let graphs = DrainGraphs(fixture: fixture)
        let runtime = MobileForegroundRuntime(identity: fixture.identity, repository: fixture.repository,
            layout: layout, database: database, persistence: database, persistTrust: { },
            makeNetwork: { directory, state, sync, discovery in
                try await graphs.make(directory: directory, state: state, sync: sync, discovery: discovery)
            })
        try await runtime.startForeground()
        await graphs.socketEntered.wait()
        try await fixture.offer()
        await fixture.factory.entered.wait()
        let stopDone = DrainGate(), restartDone = DrainGate()
        let stopping = Task { await runtime.stopForeground(); await stopDone.open() }
        await graphs.socketClosed.wait()
        await graphs.httpInvalidated.wait()
        let restarting = Task { try await runtime.startForeground(); await restartDone.open() }
        for _ in 0..<1_000 {
            if await runtime.currentSnapshot().foregroundRequested { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        await assertPending(stopDone)
        await assertPending(restartDone)
        let countBeforeFactory = await graphs.count
        XCTAssertEqual(countBeforeFactory, 1)
        let snapshot = await runtime.currentSnapshot()
        XCTAssertEqual(snapshot.state, .stopping)
        await fixture.factory.release.open()
        await fixture.factory.closeEntered.wait()
        await assertPending(restartDone)
        let countBeforeClose = await graphs.count
        XCTAssertEqual(countBeforeClose, 1)
        await fixture.factory.closeRelease.open()
        await stopping.value; try await restarting.value
        let countAfterClose = await graphs.count
        XCTAssertEqual(countAfterClose, 2)
        await runtime.stopForeground()
        await fixture.session.finish()
        // This fixture never sends or publishes: all network and receive owners
        // are joined, and no outbound terminal persistence owns these paths.
        try await database.close()
        try FileManager.default.removeItem(at: roots)
    }

    func testPriorNonjoiningStopRetainsFactoryAndLateCloseForConcurrentDrains() async throws {
        let fixture = try await DrainFixture.make()
        _ = await fixture.listener.connections()
        try await fixture.offer()
        await fixture.factory.entered.wait()
        // Existing Mac stop must still return with the factory unresolved.
        await fixture.listener.stop()
        let firstDone = DrainGate(), secondDone = DrainGate()
        let first = Task { await drain(fixture.listener); await firstDone.open() }
        let second = Task { await drain(fixture.listener); await secondDone.open() }
        await assertPending(firstDone)
        await assertPending(secondDone)
        await fixture.factory.release.open()
        await fixture.factory.closeEntered.wait()
        await assertPending(firstDone)
        await assertPending(secondDone)
        await fixture.factory.closeRelease.open()
        await first.value; await second.value
        let closes = await fixture.factory.closes
        XCTAssertEqual(closes, 1)
        await fixture.session.finish()
    }

    func testDrainWaitsForCancellationInsensitiveICE() async throws {
        let ice = DrainICE()
        let fixture = try await DrainFixture.make(ice: ice)
        _ = await fixture.listener.connections()
        try await fixture.offer()
        await ice.entered.wait()
        let done = DrainGate()
        let stopping = Task { await drain(fixture.listener); await done.open() }
        await assertPending(done)
        await ice.release.open()
        await stopping.value
        let factoryEntered = await fixture.factory.entered.isOpen
        XCTAssertFalse(factoryEntered, "Cancelled ICE must not launch a factory")
        await fixture.session.finish()
    }

    func testReaderSetupCrossingStopRemainsOwnedUntilSetupReturns() async throws {
        let fixture = try await DrainFixture.make(blockReader: true)
        let reading = Task { await fixture.listener.connections() }
        await fixture.session.readerEntered.wait()
        let done = DrainGate()
        let stopping = Task { await drain(fixture.listener); await done.open() }
        await assertPending(done)
        await fixture.session.readerRelease.open()
        let stream = await reading.value
        await stopping.value
        var iterator = stream.makeAsyncIterator()
        let next = try await iterator.next()
        XCTAssertNil(next)
        try await fixture.offer()
        await assertPending(fixture.factory.entered)
        await fixture.session.finish()
    }

    private func assertPending(_ gate: DrainGate, file: StaticString = #filePath, line: UInt = #line) async {
        // Gates establish entry into the blocking dependency. This bounded window
        // gives an incorrectly completed drain time to expose its completion.
        try? await Task.sleep(for: .milliseconds(100))
        let completed = await gate.isOpen
        XCTAssertFalse(completed, "Drain returned while its owner was gated", file: file, line: line)
    }
}

private func drain(_ listener: WebRTCConnectionListener) async { await listener.stopAndWait() }

private actor DrainGate {
    private(set) var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters; waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private final class DrainHTTPDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let invalidated: DrainGate
    init(_ invalidated: DrainGate) { self.invalidated = invalidated }
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        Task { await invalidated.open() }
    }
}

private actor DrainSocket: PresenceWebSocket {
    let entered: DrainGate, closed: DrainGate
    private var receiver: CheckedContinuation<Data, Error>?
    private var stopped = false
    init(entered: DrainGate, closed: DrainGate) { self.entered = entered; self.closed = closed }
    func send(_ data: Data) { }
    func ping() { }
    func receive() async throws -> Data {
        await entered.open()
        if stopped { throw CancellationError() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func close() async {
        stopped = true
        receiver?.resume(throwing: CancellationError()); receiver = nil
        await closed.open()
    }
}

private actor DrainGraphs {
    let fixture: DrainFixture
    let socketEntered = DrainGate(), socketClosed = DrainGate(), httpInvalidated = DrainGate()
    private(set) var count = 0
    init(fixture: DrainFixture) { self.fixture = fixture }
    func make(directory: DeviceDirectory,
              state: @escaping @Sendable (MobilePresenceState) async -> Void,
              sync: @escaping @Sendable (PresenceTrustSyncState) async -> Void,
              discovery: @escaping @Sendable (Bool) async -> Void) throws -> any MobileForegroundNetwork {
        count += 1
        let socket = DrainSocket(entered: socketEntered, closed: socketClosed)
        let presence = MobilePresenceSupervisor(identity: fixture.identity, repository: fixture.repository,
            directory: directory, makeSocket: { socket }, sleep: { try await Task.sleep(for: $0) }, onState: state,
            onTrustSyncState: sync)
        let session = URLSession(configuration: .ephemeral, delegate: DrainHTTPDelegate(httpInvalidated), delegateQueue: nil)
        let signaling = count == 1 ? fixture.signaling : RendezvousWebRTCSignaling(session: presence.bridge)
        return try MobileProductionForegroundNetwork(identity: fixture.identity, repository: fixture.repository,
            directory: directory, presence: presence, signaling: signaling,
            iceProvider: StaticICEConfigurationProvider(ICEConfiguration(stunURLs: [], turnServers: [])),
            factory: fixture.factory, session: session, onDiscovery: discovery)
    }
}

private actor DrainSession: RendezvousSignalSession {
    let readerEntered = DrainGate(), readerRelease = DrainGate()
    let frames = AsyncStream<RendezvousSignalFrame>.makeStream()
    let errors = AsyncStream<RendezvousProtocolError>.makeStream()
    let blockReader: Bool
    private var payload: Data?
    init(blockReader: Bool) { self.blockReader = blockReader }
    func signalFrames() async -> AsyncStream<RendezvousSignalFrame> {
        await readerEntered.open()
        if blockReader { await readerRelease.wait() }
        return frames.stream
    }
    func protocolErrors() -> AsyncStream<RendezvousProtocolError> { errors.stream }
    func sendSignal(_ payload: Data, to device: DeviceID) { self.payload = payload }
    func deliver(from device: DeviceID) throws {
        frames.continuation.yield(.init(from: device, payload: try XCTUnwrap(payload)))
    }
    func finish() { frames.continuation.finish(); errors.continuation.finish() }
}

private actor DrainICE: ICEConfigurationProviding {
    let entered = DrainGate(), release = DrainGate()
    func configuration(for route: ConnectionRoute) async throws -> ICEConfiguration {
        await entered.open(); await release.wait()
        return ICEConfiguration(stunURLs: [], turnServers: [])
    }
}

private actor DrainFactory: WebRTCChannelFactory {
    let entered = DrainGate(), release = DrainGate()
    let closeEntered = DrainGate(), closeRelease = DrainGate()
    private(set) var closes = 0
    func connect(localIdentity: DeviceIdentity, remoteDevice: DeviceID,
                 remotePublicKey: Data, connectionID: UUID, role: WebRTCRole,
                 route: ConnectionRoute, ice: ICEConfiguration,
                 signaling: any WebRTCSignalTransport) async throws -> WebRTCSecureChannel {
        await entered.open(); await release.wait()
        // A local unopened RTC data channel: no SDP, ICE gathering or network.
        let factory = RTCPeerConnectionFactory()
        let peer = try XCTUnwrap(factory.peerConnection(with: RTCConfiguration(),
            constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: nil))
        let data = try XCTUnwrap(peer.dataChannel(forLabel: "drain-fixture", configuration: RTCDataChannelConfiguration()))
        return WebRTCSecureChannel(connectionID: connectionID, role: role, route: route,
            channel: data, localIdentity: localIdentity, remoteDevice: remoteDevice,
            remotePublicKey: remotePublicKey, closeTransport: {
                await self.closing()
                peer.close()
                _ = factory
            }, testOnlyGenerateLocalCandidate: { })
    }
    private func closing() async {
        closes += 1
        await closeEntered.open(); await closeRelease.wait()
    }
}

private struct DrainFixture {
    let identity: DeviceIdentity, remote: DeviceIdentity
    let repository: TrustRepository
    let directory: DeviceDirectory
    let session: DrainSession
    let signaling: RendezvousWebRTCSignaling
    let factory: DrainFactory
    let listener: WebRTCConnectionListener
    static func make(ice: (any ICEConfigurationProviding)? = nil, blockReader: Bool = false) async throws -> Self {
        let identity = try DeviceIdentity.ephemeral(), remote = try DeviceIdentity.ephemeral()
        let repository = try TrustRepository(ownerIdentity: identity,
            trustStore: TrustStore(owner: identity.id), persistedGeneration: 0)
        _ = try await repository.issueAuthorization(subject: remote.id,
            subjectPublicKey: remote.publicKey.rawRepresentation, timestamp: Date())
        let directory = DeviceDirectory(trust: await repository.currentTrustStore())
        let session = DrainSession(blockReader: blockReader)
        let signaling = RendezvousWebRTCSignaling(session: session), factory = DrainFactory()
        let listener = WebRTCConnectionListener(directory: directory, identity: identity,
            trustRepository: repository, signaling: signaling,
            iceProvider: ice ?? StaticICEConfigurationProvider(ICEConfiguration(stunURLs: [], turnServers: [])), factory: factory)
        return Self(identity: identity, remote: remote, repository: repository,
            directory: directory, session: session, signaling: signaling, factory: factory, listener: listener)
    }
    func offer() async throws {
        try await signaling.send(.offer(sdp: "v=0\r\n", route: .relay), to: remote.id, connectionID: UUID())
        try await session.deliver(from: remote.id)
    }
}
