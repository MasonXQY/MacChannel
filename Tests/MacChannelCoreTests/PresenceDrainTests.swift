import Foundation
import XCTest
@testable import MacChannelCore

final class PresenceDrainTests: XCTestCase {
    func testDisconnectJoinsReceivedPresenceAlreadyCrossingDirectoryHop() async throws {
        let peer = DeviceID(rawValue: UUID())
        let directory = DeviceDirectory(trust: .allowing(peer))
        let gate = RenewalGate(blockCall: 1)
        let client = PresenceClient(heartbeatInterval: 60, applyPresence: { event in
            if case .internet(_, online: true) = event { await gate.holdRenewal() }
            await directory.apply(event)
        })
        let receive = Task { await client.receiveAuthenticated(.availability(device: peer, isOnline: true)) }
        try await eventually { await gate.waiting }
        let returned = DrainCounter()
        let stop = Task { await client.disconnect(); await returned.increment() }
        try await Task.sleep(for: .milliseconds(30))
        let early = await returned.count
        XCTAssertEqual(early, 0)
        await gate.release()
        await receive.value
        await stop.value
        let drained = await directory.snapshot()
        XCTAssertTrue(drained.isEmpty, "Late received presence cannot resurrect a retired peer")
    }

    func testLivenessFailureInitiatesCleanupWithoutJoiningItself() async throws {
        let identity = try DeviceIdentity.ephemeral()
        let socket = try DrainSocket(identity: identity, rejectPing: true)
        let session = try AuthenticatedPresenceSession(
            identity: identity, origin: URL(string: "wss://fixture.invalid/v1/ws")!,
            socket: socket, client: PresenceClient(directory: DeviceDirectory(trust: .allowing())),
            livenessInterval: .milliseconds(1), livenessTimeout: .seconds(60),
            allowInsecureForTesting: false)
        try await session.connect()
        let returned = DrainCounter()
        let run = Task { try? await session.run(); await returned.increment() }
        try await eventually { await returned.count == 1 }
        await run.value
        await session.stop()
        let closed = await socket.closed
        XCTAssertTrue(closed)
    }

    func testDisconnectJoinsBlockedHeartbeatBeforeClearingOldPresence() async throws {
        let peer = DeviceID(rawValue: UUID())
        let directory = DeviceDirectory(trust: .allowing(peer))
        let gate = RenewalGate()
        let client = PresenceClient(heartbeatInterval: 0.001, applyPresence: { event in
            if case .internet(_, online: true) = event { await gate.holdRenewal() }
            await directory.apply(event)
        })
        await client.receiveAuthenticated(.availability(device: peer, isOnline: true))
        await client.startHeartbeats()
        try await eventually { await gate.waiting }
        // Even an offline event can finish while an earlier renewal is still
        // crossing the directory hop; cleanup must remember that touched peer.
        await client.receiveAuthenticated(.availability(device: peer, isOnline: false))
        let returned = DrainCounter()
        let first = Task { await client.disconnect(); await returned.increment() }
        let second = Task { await client.disconnect(); await returned.increment() }
        try await Task.sleep(for: .milliseconds(30))
        let early = await returned.count
        XCTAssertEqual(early, 0, "Disconnect must join in-flight directory delivery")
        await gate.release()
        await first.value
        await second.value
        // A replacement can now publish; the old owner must never erase or
        // renew anything after this joined boundary.
        let drained = await directory.snapshot()
        XCTAssertTrue(drained.isEmpty)
        await directory.apply(.internet(peer, online: true))
        try await Task.sleep(for: .milliseconds(10))
        let replacement = await directory.snapshot()
        XCTAssertEqual(replacement.map(\.id), [peer])
    }

    func testConcurrentSessionStopsJoinCancellationInsensitivePingAfterClose() async throws {
        let identity = try DeviceIdentity.ephemeral()
        let socket = try DrainSocket(identity: identity)
        let session = try AuthenticatedPresenceSession(
            identity: identity, origin: URL(string: "wss://fixture.invalid/v1/ws")!,
            socket: socket, client: PresenceClient(directory: DeviceDirectory(trust: .allowing())),
            livenessInterval: .milliseconds(1), livenessTimeout: .seconds(60),
            allowInsecureForTesting: false)
        try await session.connect()
        let run = Task { try? await session.run() }
        try await eventually { await socket.pingPending }
        let returned = DrainCounter()
        let first = Task { await session.stop(); await returned.increment() }
        try await eventually { await socket.closed }
        let second = Task { await session.stop(); await returned.increment() }
        try await Task.sleep(for: .milliseconds(30))
        let early = await returned.count
        XCTAssertEqual(early, 0, "Both stops must join the ping even when close returns first")
        await socket.releasePing()
        await first.value
        await second.value
        await run.value
        let completed = await returned.count
        let closeCalls = await socket.closeCalls
        XCTAssertEqual(completed, 2)
        XCTAssertEqual(closeCalls, 1, "Concurrent stops must share socket cleanup")
    }

    private func eventually(_ condition: @escaping @Sendable () async -> Bool) async throws {
        for _ in 0..<2_000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Drain fixture did not reach barrier")
        throw CancellationError()
    }
}

private actor DrainCounter {
    var count = 0
    func increment() { count += 1 }
}

private actor RenewalGate {
    private var calls = 0
    private let blockCall: Int
    init(blockCall: Int = 2) { self.blockCall = blockCall }
    private var waiter: CheckedContinuation<Void, Never>?
    var waiting: Bool { waiter != nil }
    func holdRenewal() async {
        calls += 1
        if calls == blockCall { await withCheckedContinuation { waiter = $0 } }
    }
    func release() { waiter?.resume(); waiter = nil }
}

private actor DrainSocket: PresenceWebSocket {
    private var incoming: [Data]
    private var receiver: CheckedContinuation<Data, Error>?
    private var pingWaiter: CheckedContinuation<Void, Never>?
    var pingPending: Bool { pingWaiter != nil }
    var closed = false
    var closeCalls = 0
    private let rejectPing: Bool
    init(identity: DeviceIdentity, rejectPing: Bool = false) throws {
        self.rejectPing = rejectPing
        incoming = [
            try JSONSerialization.data(withJSONObject: ["type": "challenge", "nonce": Data(repeating: 1, count: 32).base64EncodedString(), "expiresAt": 1234]),
            try JSONSerialization.data(withJSONObject: ["type": "auth-ok", "deviceID": identity.id.rawValue.uuidString.lowercased()])
        ]
    }
    func send(_ data: Data) {}
    func receive() async throws -> Data {
        if !incoming.isEmpty { return incoming.removeFirst() }
        if closed { throw CancellationError() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func ping() async throws {
        if rejectPing { throw AuthenticatedPresenceError.transport("fixture_ping_rejected") }
        await withCheckedContinuation { pingWaiter = $0 }
    }
    func close() {
        closeCalls += 1
        closed = true
        receiver?.resume(throwing: CancellationError())
        receiver = nil
    }
    func releasePing() { pingWaiter?.resume(); pingWaiter = nil }
}
