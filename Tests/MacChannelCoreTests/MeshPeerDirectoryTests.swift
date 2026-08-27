import CryptoKit
import Foundation
import Network
import XCTest

@testable import MacChannelCore

final class MeshPeerDirectoryTests: XCTestCase {
    func testRefreshCapsInputConcurrencyTimeoutAndResponseSize() async throws {
        let status = MutableMeshStatusProvider(peers: makePeers(count: 12))
        let prober = ControlledMeshPeerProber(blocked: true)
        let directory = MeshPeerDirectory(status: status, prober: prober)

        let refresh = Task { try await directory.refresh() }
        try await peerWaitUntil { await prober.maximumActiveCount() == 8 }
        let maximumActive = await prober.maximumActiveCount()
        XCTAssertEqual(maximumActive, 8)
        await prober.releaseAll()
        let peers = try await refresh.value

        XCTAssertEqual(peers.count, 12)
        let observations = await prober.observations()
        XCTAssertTrue(observations.allSatisfy { $0.timeout == .seconds(2) })
        XCTAssertTrue(observations.allSatisfy { $0.maximumResponseBytes == 8 * 1_024 })
    }

    func testNonceIsFreshAndExactlyThirtyTwoBytesAcrossRefreshes() async throws {
        let status = MutableMeshStatusProvider(peers: makePeers(count: 2))
        let prober = ControlledMeshPeerProber()
        let directory = MeshPeerDirectory(status: status, prober: prober)

        _ = try await directory.refresh()
        _ = try await directory.refresh()

        let nonces = await prober.observations().map(\.nonce)
        XCTAssertEqual(nonces.count, 4)
        XCTAssertTrue(nonces.allSatisfy { $0.count == 32 })
        XCTAssertEqual(Set(nonces).count, 4)
    }

    func testConflictingDeviceHashesAreDroppedAndEndpointsExpireOnEveryRefresh() async throws {
        let initial = makePeers(count: 3)
        let status = MutableMeshStatusProvider(peers: initial)
        let conflictHash = Data(repeating: 9, count: 32)
        let prober = ControlledMeshPeerProber(
            responseHashes: [initial[0].nodeID: conflictHash, initial[1].nodeID: conflictHash]
        )
        let directory = MeshPeerDirectory(status: status, prober: prober)

        let first = try await directory.refresh()
        XCTAssertEqual(first.map(\.nodeID), [initial[2].nodeID])

        await status.replace(peers: [initial[1]])
        let second = try await directory.refresh()
        XCTAssertEqual(second.map(\.nodeID), [initial[1].nodeID])
        XCTAssertFalse(second.contains { $0.nodeID == initial[2].nodeID })
    }

    func testMalformedResponseIsDroppedWithoutFailingHealthyPeers() async throws {
        let peers = makePeers(count: 3)
        let status = MutableMeshStatusProvider(peers: peers)
        let prober = ControlledMeshPeerProber(malformedNodeIDs: [peers[1].nodeID])
        let directory = MeshPeerDirectory(status: status, prober: prober)

        let result = try await directory.refresh()

        XCTAssertEqual(result.map(\.nodeID), [peers[0].nodeID, peers[2].nodeID])
        XCTAssertTrue(result.allSatisfy { $0.displayName.hasPrefix("Mac ") })
    }

    func testOlderConcurrentRefreshCannotRestoreExpiredEndpoint() async throws {
        let oldPeer = makePeers(count: 1)[0]
        let newPeer = TailscalePeer(
            nodeID: "node-new",
            addresses: ["100.64.1.1"],
            online: true,
            connectionKind: .direct
        )
        let status = SequencedMeshStatusProvider(snapshots: [[oldPeer], [newPeer]])
        let prober = OldBlockingMeshPeerProber(blockedNodeID: oldPeer.nodeID)
        let directory = MeshPeerDirectory(status: status, prober: prober)

        let oldRefresh = Task { try await directory.refresh() }
        try await peerWaitUntil { await prober.isBlocked() }
        let newResult = try await directory.refresh()
        XCTAssertEqual(newResult.map(\.nodeID), [newPeer.nodeID])

        await prober.release()
        let supersededResult = try await oldRefresh.value
        XCTAssertEqual(supersededResult.map(\.nodeID), [newPeer.nodeID])
    }

    func testPeriodicRefreshUsesFifteenSecondsAndStopAwaitsWorker() async throws {
        let status = MutableMeshStatusProvider(peers: [])
        let prober = ControlledMeshPeerProber()
        let sleeper = ControlledMeshRefreshSleeper()
        let directory = MeshPeerDirectory(status: status, prober: prober, sleeper: sleeper)

        await directory.start()
        try await peerWaitUntil { await status.callCount() == 1 }
        try await peerWaitUntil { await sleeper.requestedDurations().count == 1 }
        let durations = await sleeper.requestedDurations()
        XCTAssertEqual(durations, [.seconds(15)])

        await sleeper.advance()
        try await peerWaitUntil { await status.callCount() == 2 }
        await directory.stop()
        let isRefreshing = await directory.isRefreshingPeriodically()
        XCTAssertFalse(isRefreshing)
    }

    func testProbeCodecRejectsOversizeWrongNonceHashAndUnsafeDisplayName() throws {
        let nonce = Data(repeating: 1, count: 32)
        let valid = MeshPeerProbeResponse(
            version: 1,
            nonce: nonce,
            deviceIDHash: Data(repeating: 2, count: 32),
            displayName: "Office Mac"
        )
        XCTAssertNoThrow(try MeshPeerProbeCodec.validate(valid, expectedNonce: nonce))
        XCTAssertThrowsError(try MeshPeerProbeCodec.validate(valid, expectedNonce: Data(repeating: 3, count: 32)))
        XCTAssertThrowsError(
            try MeshPeerProbeCodec.validate(
                MeshPeerProbeResponse(version: 1, nonce: nonce, deviceIDHash: Data([1]), displayName: "Mac"),
                expectedNonce: nonce
            )
        )
        XCTAssertThrowsError(
            try MeshPeerProbeCodec.validate(
                MeshPeerProbeResponse(
                    version: 1,
                    nonce: nonce,
                    deviceIDHash: Data(repeating: 2, count: 32),
                    displayName: "Mac\nsecret"
                ),
                expectedNonce: nonce
            )
        )
        XCTAssertThrowsError(
            try MeshPeerProbeCodec.decode(
                Data(repeating: 0, count: 8 * 1_024 + 1),
                expectedNonce: nonce
            )
        )
    }
}

private actor MutableMeshStatusProvider: TailscaleStatusProviding {
    private var peers: [TailscalePeer]
    private var calls = 0

    init(peers: [TailscalePeer]) { self.peers = peers }
    func status() -> TailscaleStatus {
        calls += 1
        return TailscaleStatus(peers: peers)
    }
    func replace(peers: [TailscalePeer]) { self.peers = peers }
    func callCount() -> Int { calls }
}

private actor SequencedMeshStatusProvider: TailscaleStatusProviding {
    private var snapshots: [[TailscalePeer]]

    init(snapshots: [[TailscalePeer]]) { self.snapshots = snapshots }
    func status() throws -> TailscaleStatus {
        guard !snapshots.isEmpty else { throw MeshPeerDirectoryError.invalidProbeResponse }
        return TailscaleStatus(peers: snapshots.removeFirst())
    }
}

private struct MeshProbeObservation: Sendable {
    let nodeID: String
    let nonce: Data
    let timeout: Duration
    let maximumResponseBytes: Int
}

private actor ControlledMeshPeerProber: MeshPeerProbing {
    private let blocked: Bool
    private let responseHashes: [String: Data]
    private let malformedNodeIDs: Set<String>
    private var active = 0
    private var maximumActive = 0
    private var records: [MeshProbeObservation] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    init(
        blocked: Bool = false,
        responseHashes: [String: Data] = [:],
        malformedNodeIDs: Set<String> = []
    ) {
        self.blocked = blocked
        self.responseHashes = responseHashes
        self.malformedNodeIDs = malformedNodeIDs
    }

    func probe(
        nodeID: String,
        endpoint: NWEndpoint,
        nonce: Data,
        timeout: Duration,
        maximumResponseBytes: Int
    ) async throws -> MeshPeerProbeResponse {
        active += 1
        maximumActive = max(maximumActive, active)
        records.append(
            MeshProbeObservation(
                nodeID: nodeID,
                nonce: nonce,
                timeout: timeout,
                maximumResponseBytes: maximumResponseBytes
            )
        )
        if blocked, !released { await withCheckedContinuation { waiters.append($0) } }
        active -= 1
        if malformedNodeIDs.contains(nodeID) { throw MeshPeerDirectoryError.invalidProbeResponse }
        return MeshPeerProbeResponse(
            version: 1,
            nonce: nonce,
            deviceIDHash: responseHashes[nodeID] ?? Data(sha256Bytes(nodeID)),
            displayName: "Mac \(nodeID)"
        )
    }

    func releaseAll() {
        released = true
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume() }
    }
    func maximumActiveCount() -> Int { maximumActive }
    func observations() -> [MeshProbeObservation] { records }
}

private actor OldBlockingMeshPeerProber: MeshPeerProbing {
    private let blockedNodeID: String
    private var waiter: CheckedContinuation<Void, Never>?

    init(blockedNodeID: String) { self.blockedNodeID = blockedNodeID }

    func probe(
        nodeID: String,
        endpoint: NWEndpoint,
        nonce: Data,
        timeout: Duration,
        maximumResponseBytes: Int
    ) async -> MeshPeerProbeResponse {
        if nodeID == blockedNodeID {
            await withCheckedContinuation { waiter = $0 }
        }
        return MeshPeerProbeResponse(
            version: 1,
            nonce: nonce,
            deviceIDHash: Data(sha256Bytes(nodeID)),
            displayName: nodeID
        )
    }

    func isBlocked() -> Bool { waiter != nil }
    func release() {
        waiter?.resume()
        waiter = nil
    }
}

private actor ControlledMeshRefreshSleeper: MeshRefreshSleeping {
    private var durations: [Duration] = []
    private var waiters: [CheckedContinuation<Void, Error>] = []

    func sleep(for duration: Duration) async throws {
        durations.append(duration)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiters.append($0) }
        } onCancel: {
            Task { await self.cancelAll() }
        }
    }
    func requestedDurations() -> [Duration] { durations }
    func advance() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }
    func cancelAll() {
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume(throwing: CancellationError()) }
    }
}

private func makePeers(count: Int) -> [TailscalePeer] {
    (0..<count).map { index in
        TailscalePeer(
            nodeID: String(format: "node-%03d", index),
            addresses: ["100.64.0.\(index + 1)"],
            online: true,
            connectionKind: .direct
        )
    }
}

private func sha256Bytes(_ value: String) -> [UInt8] {
    Array(SHA256.hash(data: Data(value.utf8)))
}

private func peerWaitUntil(
    timeout: Duration = .seconds(2),
    predicate: @escaping @Sendable () async -> Bool
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            while !(await predicate()) { try await Task.sleep(for: .milliseconds(5)) }
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw PeerDirectoryTestTimeout()
        }
        _ = try await group.next()
        group.cancelAll()
    }
}

private struct PeerDirectoryTestTimeout: Error {}
