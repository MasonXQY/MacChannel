import Foundation
import Network
import XCTest

@testable import MacChannelCore

final class MeshTransferOrchestrationTests: XCTestCase {
    func testConnectorAndIncomingSourceEstablishExactTransferOverProductionSecureChannel()
        async throws
    {
        let identities = try await TrustedMeshIdentities.make()
        let listenerTransport = TestMeshListenerTransport()
        let listener = MeshConnectionListener(transport: listenerTransport)
        try await listener.start()
        let opener = TransferLoopbackOpener(listener: listenerTransport)
        let candidates = StaticMeshCandidates([
            identities.left.id: .fixture(
                nodeID: "left-node",
                device: identities.left.id,
                host: "100.64.0.1"
            ),
            identities.right.id: .fixture(
                nodeID: "right-node",
                device: identities.right.id,
                host: "100.64.0.2"
            ),
        ])
        let routes = StaticMeshRoutes([
            "left-node": .direct,
            "right-node": .direct,
        ])
        let leftRegistry = MeshConnectionRegistry(trustRepository: identities.leftTrust)
        let rightRegistry = MeshConnectionRegistry(trustRepository: identities.rightTrust)
        let connector = MeshTransferConnector(
            identity: identities.left,
            trustRepository: identities.leftTrust,
            directory: candidates,
            routes: routes,
            opener: opener,
            registry: leftRegistry
        )
        let source = MeshTransferConnectionSource(
            listener: listener,
            identity: identities.right,
            trustRepository: identities.rightTrust,
            directory: candidates,
            routes: routes,
            registry: rightRegistry
        )
        let stream = await source.connections()
        let receiveTask = Task { () throws -> IncomingTransferConnection in
            var iterator = stream.makeAsyncIterator()
            guard let connection = try await iterator.next() else {
                throw MeshTransferConnectionError.unavailablePeer
            }
            return connection
        }
        let transferID = TransferID(rawValue: UUID())
        let outgoing = try await connector.connect(to: identities.right.id, transferID: transferID)
        let incoming = try await receiveTask.value

        XCTAssertEqual(outgoing.route, .directInternet)
        XCTAssertEqual(incoming.channel.route, .directInternet)
        XCTAssertEqual(incoming.source, identities.left.id)
        XCTAssertEqual(incoming.transferID, transferID)

        let payload = Data("mesh-transfer".utf8)
        try await outgoing.send(payload)
        var frames = incoming.channel.frames().makeAsyncIterator()
        let received = try await frames.next()
        XCTAssertEqual(received, payload)

        _ = try await outgoing.exportKey(label: "revocation-race", context: Data(), length: 32)
        _ = try await incoming.channel.exportKey(
            label: "revocation-race",
            context: Data(),
            length: 32
        )
        _ = try await identities.leftTrust.revoke(identities.right.id)
        _ = try await identities.rightTrust.revoke(identities.left.id)
        try await waitForMeshCondition {
            let left = await leftRegistry.entryCount()
            let right = await rightRegistry.entryCount()
            return left == 0 && right == 0
        }
        do {
            try await outgoing.send(Data("after-revoke".utf8))
            XCTFail("Revoked active channel must close")
        } catch {
            XCTAssertNotNil(error as? MeshSecureChannelError)
        }

        await outgoing.close()
        await incoming.channel.close()
        await source.stop()
        await leftRegistry.stop()
        await rightRegistry.stop()
    }

    func testOnlyTrustedFreshMatchingCandidateCanOpen() async throws {
        let identities = try await TrustedMeshIdentities.make()
        let candidate = MeshPeerCandidate.fixture(
            nodeID: "right-node",
            device: identities.right.id,
            host: "100.64.0.2"
        )
        let candidates = SequencedMeshCandidates([candidate, nil])
        let routes = StaticMeshRoutes(["right-node": .direct])
        let connection = RecordingMeshByteConnection()
        let opener = RecordingTransferOpener(connection: connection)
        let registry = MeshConnectionRegistry(trustRepository: identities.leftTrust)
        let connector = MeshTransferConnector(
            identity: identities.left,
            trustRepository: identities.leftTrust,
            directory: candidates,
            routes: routes,
            opener: opener,
            registry: registry
        )
        do {
            _ = try await connector.connect(
                to: identities.right.id,
                transferID: TransferID(rawValue: UUID())
            )
            XCTFail("Changed endpoint must fail before handshake")
        } catch {
            XCTAssertEqual(error as? MeshTransferConnectionError, .staleEndpoint)
        }
        let opens = await opener.openCount()
        let closes = await connection.closeCount()
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(closes, 1)
        await registry.stop()

        let unknown = try DeviceIdentity.ephemeral()
        let unknownOpener = RecordingTransferOpener(connection: RecordingMeshByteConnection())
        let unknownConnector = MeshTransferConnector(
            identity: identities.left,
            trustRepository: identities.leftTrust,
            directory: StaticMeshCandidates([:]),
            routes: routes,
            opener: unknownOpener,
            registry: MeshConnectionRegistry(trustRepository: identities.leftTrust)
        )
        do {
            _ = try await unknownConnector.connect(
                to: unknown.id,
                transferID: TransferID(rawValue: UUID())
            )
            XCTFail("Untrusted peer must fail before opening")
        } catch {
            XCTAssertEqual(error as? MeshTransferConnectionError, .untrustedPeer)
        }
        let unknownOpens = await unknownOpener.openCount()
        XCTAssertEqual(unknownOpens, 0)
    }

    func testRouteEvidenceMapsDirectAndRelaysButRejectsUnknown() throws {
        XCTAssertEqual(try MeshTransferConnector.connectionRoute(for: .direct), .directInternet)
        XCTAssertEqual(try MeshTransferConnector.connectionRoute(for: .derp), .relay)
        XCTAssertEqual(try MeshTransferConnector.connectionRoute(for: .peerRelay), .relay)
        XCTAssertThrowsError(try MeshTransferConnector.connectionRoute(for: .unknown)) {
            XCTAssertEqual($0 as? MeshTransferConnectionError, .unknownRoute)
        }
    }

    func testRevocationAtomicallyDetachesAndClosesEveryOwnedConnection() async throws {
        let identities = try await TrustedMeshIdentities.make()
        let registry = MeshConnectionRegistry(trustRepository: identities.leftTrust)
        let counter = CloseCounter()
        let ownerships: [MeshConnectionOwnership] = [
            .handshake, .queuedTransfer, .activeTransfer, .handshake,
            .queuedTransfer, .activeTransfer, .handshake, .activeTransfer,
        ]
        for ownership in ownerships {
            _ = try await registry.claim(device: identities.right.id, ownership: ownership) {
                await counter.record()
            }
        }
        let retained = await registry.entryCount(for: identities.right.id)
        XCTAssertEqual(retained, 8)

        _ = try await identities.leftTrust.revoke(identities.right.id)
        try await waitForMeshCondition { await counter.activeValue() == 4 }
        let detachedBeforeClose = await registry.entryCount(for: identities.right.id)
        XCTAssertEqual(detachedBeforeClose, 0)
        await counter.releaseAll()
        try await waitForMeshCondition {
            let closed = await counter.value()
            let remaining = await registry.entryCount(for: identities.right.id)
            return closed == 8 && remaining == 0
        }
        let maximum = await counter.maximumConcurrent()
        XCTAssertEqual(maximum, 4)
        await registry.stop()
    }

    func testProductionCandidateExpiresAtExactRefreshBoundary() async throws {
        let identity = try DeviceIdentity.ephemeral()
        let clock = MutableMeshDate(Date(timeIntervalSince1970: 1_000))
        let status = SingleMeshStatus(
            peer: TailscalePeer(
                nodeID: "peer-node",
                addresses: ["100.64.0.2"],
                online: true,
                connectionKind: .direct
            )
        )
        let directory = MeshPeerDirectory(
            status: status,
            prober: SingleMeshProber(device: identity.id),
            now: { clock.value }
        )
        _ = try await directory.refresh()
        let fresh = await directory.candidate(for: identity.id)
        XCTAssertNotNil(fresh)
        clock.advance(15)
        let expired = await directory.candidate(for: identity.id)
        XCTAssertNil(expired)
    }
}

private struct TrustedMeshIdentities {
    let left: DeviceIdentity
    let right: DeviceIdentity
    let leftTrust: TrustRepository
    let rightTrust: TrustRepository

    static func make() async throws -> TrustedMeshIdentities {
        let left = try DeviceIdentity.ephemeral()
        let right = try DeviceIdentity.ephemeral()
        let leftTrust = try TrustRepository(
            ownerIdentity: left,
            trustStore: TrustStore(owner: left.id),
            persistedGeneration: 0
        )
        let rightTrust = try TrustRepository(
            ownerIdentity: right,
            trustStore: TrustStore(owner: right.id),
            persistedGeneration: 0
        )
        let leftAuthorization = try SignedTrustRecord.authorizing(
            right,
            signedBy: left,
            timestamp: Date(timeIntervalSince1970: 10_000)
        )
        let rightAuthorization = try SignedTrustRecord.authorizing(
            left,
            signedBy: right,
            timestamp: Date(timeIntervalSince1970: 10_000)
        )
        try await leftTrust.commitBilateralPairing(
            localAuthorization: leftAuthorization,
            peerAuthorization: rightAuthorization
        )
        try await rightTrust.commitBilateralPairing(
            localAuthorization: rightAuthorization,
            peerAuthorization: leftAuthorization
        )
        return TrustedMeshIdentities(
            left: left,
            right: right,
            leftTrust: leftTrust,
            rightTrust: rightTrust
        )
    }
}

extension MeshPeerCandidate {
    fileprivate static func fixture(nodeID: String, device: DeviceID, host: String)
        -> MeshPeerCandidate
    {
        MeshPeerCandidate(
            nodeID: nodeID,
            endpoint: .hostPort(host: NWEndpoint.Host(host), port: 51_337),
            probeNonce: Data(repeating: 1, count: 32),
            deviceIDHash: MeshPeerDirectory.deviceIDHash(for: device),
            displayName: nodeID
        )
    }
}

private actor StaticMeshCandidates: MeshPeerCandidateProviding {
    let values: [DeviceID: MeshPeerCandidate]
    init(_ values: [DeviceID: MeshPeerCandidate]) { self.values = values }
    func candidate(for device: DeviceID) -> MeshPeerCandidate? { values[device] }
}

private actor SequencedMeshCandidates: MeshPeerCandidateProviding {
    private var values: [MeshPeerCandidate?]
    init(_ values: [MeshPeerCandidate?]) { self.values = values }
    func candidate(for device: DeviceID) -> MeshPeerCandidate? {
        guard !values.isEmpty else { return nil }
        return values.removeFirst()
    }
}

private actor StaticMeshRoutes: MeshRouteEvidenceProviding {
    let values: [String: TailscaleConnectionKind]
    init(_ values: [String: TailscaleConnectionKind]) { self.values = values }
    func connectionKind(to nodeID: String) throws -> TailscaleConnectionKind {
        values[nodeID] ?? .unknown
    }
}

private actor RecordingTransferOpener: MeshTransferConnectionOpening {
    private let connection: any MeshByteConnection
    private var count = 0
    init(connection: any MeshByteConnection) { self.connection = connection }
    func open(endpoint: NWEndpoint) -> any MeshByteConnection {
        count += 1
        return connection
    }
    func openCount() -> Int { count }
}

private actor RecordingMeshByteConnection: MeshByteConnection {
    private var closes = 0
    func send(_ bytes: Data) throws { throw MeshWireError.connectionClosed }
    func receive(minimum: Int, maximum: Int) throws -> Data { throw MeshWireError.connectionClosed }
    func close() { closes += 1 }
    func closeCount() -> Int { closes }
}

private actor TestMeshListenerTransport: MeshListenerTransport {
    private var callback: (@Sendable (any MeshByteConnection) -> Void)?
    func start(
        binding: MeshListenerBinding,
        onConnection: @escaping @Sendable (any MeshByteConnection) -> Void
    ) {
        callback = onConnection
    }
    func stop() { callback = nil }
    func inject(_ connection: any MeshByteConnection) {
        callback?(connection)
    }
}

private actor TransferLoopbackOpener: MeshTransferConnectionOpening {
    let listener: TestMeshListenerTransport
    init(listener: TestMeshListenerTransport) { self.listener = listener }
    func open(endpoint: NWEndpoint) async -> any MeshByteConnection {
        let link = TransferMeshLink()
        let endpoints = await link.endpoints()
        await listener.inject(endpoints.right)
        return endpoints.left
    }
}

private actor TransferMeshLink {
    private var buffers: [Bool: Data] = [false: Data(), true: Data()]
    private var waiters: [Bool: [TransferMeshWaiter]] = [false: [], true: []]
    private var closed: Set<Bool> = []

    func endpoints() -> (left: TransferMeshConnection, right: TransferMeshConnection) {
        (
            TransferMeshConnection(side: false, link: self),
            TransferMeshConnection(side: true, link: self)
        )
    }

    func send(_ data: Data, side: Bool) throws {
        guard !closed.contains(side), !closed.contains(!side) else {
            throw MeshWireError.connectionClosed
        }
        let target = !side
        buffers[target, default: Data()].append(data)
        if let waiter = waiters[target]?.first {
            waiters[target]?.removeFirst()
            waiter.continuation.resume(returning: take(side: target, maximum: waiter.maximum)!)
        }
    }

    func receive(side: Bool, maximum: Int) async throws -> Data {
        if let value = take(side: side, maximum: maximum) { return value }
        return try await withCheckedThrowingContinuation {
            waiters[side, default: []].append(.init(maximum: maximum, continuation: $0))
        }
    }

    func close(side: Bool) {
        guard closed.insert(side).inserted else { return }
        for target in [false, true] {
            let current = waiters[target, default: []]
            waiters[target] = []
            for waiter in current {
                waiter.continuation.resume(throwing: MeshWireError.connectionClosed)
            }
        }
    }

    private func take(side: Bool, maximum: Int) -> Data? {
        guard !buffers[side, default: Data()].isEmpty else {
            return closed.contains(side) || closed.contains(!side) ? Data() : nil
        }
        let count = min(maximum, buffers[side, default: Data()].count)
        let value = Data(buffers[side, default: Data()].prefix(count))
        buffers[side]?.removeFirst(count)
        return value
    }
}

private struct TransferMeshWaiter {
    let maximum: Int
    let continuation: CheckedContinuation<Data, Error>
}

private final class TransferMeshConnection: MeshByteConnection, @unchecked Sendable {
    let side: Bool
    let link: TransferMeshLink
    init(side: Bool, link: TransferMeshLink) {
        self.side = side
        self.link = link
    }
    func send(_ bytes: Data) async throws { try await link.send(bytes, side: side) }
    func receive(minimum: Int, maximum: Int) async throws -> Data {
        try await link.receive(side: side, maximum: maximum)
    }
    func close() async { await link.close(side: side) }
}

private actor CloseCounter {
    private var count = 0
    private var active = 0
    private var maximum = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func record() async {
        active += 1
        maximum = max(maximum, active)
        if !released { await withCheckedContinuation { waiters.append($0) } }
        count += 1
        active -= 1
    }
    func value() -> Int { count }
    func activeValue() -> Int { active }
    func maximumConcurrent() -> Int { maximum }
    func releaseAll() {
        released = true
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume() }
    }
}

private final class MutableMeshDate: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    var value: Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) {
        lock.withLock { date = date.addingTimeInterval(seconds) }
    }
}

private struct SingleMeshStatus: TailscaleStatusProviding {
    let peer: TailscalePeer
    func status() async throws -> TailscaleStatus { TailscaleStatus(peers: [peer]) }
}

private struct SingleMeshProber: MeshPeerProbing {
    let device: DeviceID
    func probe(
        nodeID: String,
        endpoint: NWEndpoint,
        nonce: Data,
        timeout: Duration,
        maximumResponseBytes: Int
    ) async throws -> MeshPeerProbeResponse {
        MeshPeerProbeResponse(
            version: 1,
            nonce: nonce,
            deviceIDHash: MeshPeerDirectory.deviceIDHash(for: device),
            displayName: "Mac"
        )
    }
}

private func waitForMeshCondition(
    timeout: Duration = .seconds(2),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            while !(await condition()) { await Task.yield() }
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw MeshTransferConnectionError.unavailablePeer
        }
        _ = try await group.next()
        group.cancelAll()
    }
}
