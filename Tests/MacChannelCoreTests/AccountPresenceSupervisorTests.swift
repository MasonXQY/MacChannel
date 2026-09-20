import XCTest
@testable import MacChannelCore

final class AccountPresenceSupervisorTests: XCTestCase, @unchecked Sendable {
    func testRefreshWhileFactorySuspendsClosesStaleUnattachedSocketAndWaits() async throws {
        let f = try NativeProducerFixture()
        try await f.grant()
        let first = AccountSupervisorSocket(f.local)
        let second = AccountSupervisorSocket(f.local)
        let factory = AccountSupervisorFactory([first, second])
        let gate = NativeProducerGate()
        let trust = TrustStore(owner: f.local.id)
        let repository = try TrustRepository(ownerIdentity: f.local, trustStore: trust, persistedGeneration: 0)
        let supervisor = AuthenticatedPresenceSupervisor(identity: f.local, repository: repository,
            directory: DeviceDirectory(trust: trust), origin: URL(string: "wss://account.example.test/v1/ws")!,
            makeSocket: { await gate.block(); return try await factory.next() }, sleep: { _ in }, accountController: f.controller)
        await supervisor.start()
        await gate.entered()
        try await f.controller.refresh()
        await gate.release()
        try await eventually { await first.closed }
        try await Task.sleep(for: .milliseconds(20))
        let count = await factory.count
        let binds = await first.binds
        XCTAssertEqual(count, 1)
        XCTAssertEqual(binds, 0)
        _ = try await f.controller.syncGroup(groupID: groupID)
        try await eventually { await second.receivedBindAck }
        await supervisor.stop()
    }

    func testMissingHistoryOpensNoSocketThenWakeBindsWithoutBlockingReader() async throws {
        let f = try NativeProducerFixture()
        try await f.prepare()
        let socket = AccountSupervisorSocket(f.local)
        let factory = AccountSupervisorFactory([socket])
        let supervisor = try make(f, factory)
        await supervisor.start()
        try await Task.sleep(for: .milliseconds(20))
        let before = await factory.count
        XCTAssertEqual(before, 0)
        _ = try await f.controller.syncGroup(groupID: groupID)
        try await eventually { await socket.binds == 1 }
        try await eventually { await socket.receivedBindAck }
        _ = try await f.controller.syncGroup(groupID: groupID)
        try await Task.sleep(for: .milliseconds(20))
        let binds = await socket.binds
        XCTAssertEqual(binds, 1)
        await supervisor.stop()
    }

    func testSignedOutNoSocketAndStopJoinsReadinessWait() async throws {
        let f = try NativeProducerFixture(empty: true)
        await f.controller.restore()
        let factory = AccountSupervisorFactory([])
        let supervisor = try make(f, factory)
        await supervisor.start()
        await supervisor.retryConnection()
        await supervisor.stop()
        let count = await factory.count
        XCTAssertEqual(count, 0)
        let state = await supervisor.state
        XCTAssertEqual(state, .stopped)
    }

    func testLogoutWithBlockedSendAndCloseJoinsBeforeAnyReplacement() async throws {
        let f = try NativeProducerFixture()
        try await f.grant()
        let first = AccountSupervisorSocket(f.local, blockSend: true, blockClose: true)
        let second = AccountSupervisorSocket(f.local)
        let factory = AccountSupervisorFactory([first, second])
        let supervisor = try make(f, factory)
        await supervisor.start()
        await first.sendGate.entered()
        try await f.controller.logout()
        await first.closeGate.entered()
        let completed = PeerTestBox(false)
        let stop = Task { await supervisor.stop(); completed.update { $0 = true } }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(completed.value)
        let count = await factory.count
        XCTAssertEqual(count, 1)
        await first.closeGate.release()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(completed.value, "cancellation-insensitive send still belongs to old attempt")
        await first.sendGate.release()
        await stop.value
    }

    func testRefreshClosesOldAttemptAndWaitsForVerifiedHistoryBeforeReconnect() async throws {
        let f = try NativeProducerFixture()
        try await f.grant()
        let first = AccountSupervisorSocket(f.local)
        let second = AccountSupervisorSocket(f.local)
        let factory = AccountSupervisorFactory([first, second])
        let supervisor = try make(f, factory)
        await supervisor.start()
        try await eventually { await first.receivedBindAck }
        try await f.controller.refresh()
        try await eventually { await first.closed }
        try await Task.sleep(for: .milliseconds(20))
        let before = await factory.count
        XCTAssertEqual(before, 1)
        _ = try await f.controller.syncGroup(groupID: groupID)
        try await eventually { await second.receivedBindAck }
        let closed = await second.closed
        XCTAssertFalse(closed)
        await supervisor.stop()
    }

    func testRapidRetryCannotOvertakeBlockedCloseOrStopReplacement() async throws {
        let f = try NativeProducerFixture()
        try await f.grant()
        let first = AccountSupervisorSocket(f.local, blockClose: true)
        let second = AccountSupervisorSocket(f.local)
        let factory = AccountSupervisorFactory([first, second])
        let supervisor = try make(f, factory)
        await supervisor.start()
        try await eventually { await first.receivedBindAck }
        let one = Task { await supervisor.retryConnection() }
        await first.closeGate.entered()
        let two = Task { await supervisor.retryConnection() }
        try await Task.sleep(for: .milliseconds(20))
        let before = await factory.count
        XCTAssertEqual(before, 1)
        await first.closeGate.release()
        await one.value
        await two.value
        try await eventually { await second.receivedBindAck }
        let closed = await second.closed
        XCTAssertFalse(closed)
        await supervisor.stop()
    }

    func testWakeDuringSocketFactoryIsNotLostAndManualAcknowledgementStillProgresses() async throws {
        let f = try NativeProducerFixture()
        try await f.grant()
        let socket = AccountSupervisorSocket(f.local)
        let factory = AccountSupervisorFactory([socket])
        let gate = NativeProducerGate()
        let trust = TrustStore(owner: f.local.id)
        let repository = try TrustRepository(ownerIdentity: f.local, trustStore: trust, persistedGeneration: 0)
        _ = try await repository.issueAuthorization(subject: f.peer.id, subjectPublicKey: f.peer.publicKey.rawRepresentation, timestamp: Date())
        let supervisor = AuthenticatedPresenceSupervisor(identity: f.local, repository: repository,
            directory: DeviceDirectory(trust: trust), origin: URL(string: "wss://account.example.test/v1/ws")!,
            makeSocket: { await gate.block(); return try await factory.next() }, sleep: { _ in }, accountController: f.controller)
        await supervisor.start()
        await gate.entered()
        _ = try await f.controller.syncGroup(groupID: groupID)
        await gate.release()
        try await eventually { await socket.receivedBindAck }
        try await eventually { await supervisor.trustSyncState == .synchronized }
        let updates = await socket.trustUpdates
        XCTAssertEqual(updates, 1)
        await supervisor.stop()
    }

    private func make(_ f: NativeProducerFixture, _ factory: AccountSupervisorFactory) throws -> AuthenticatedPresenceSupervisor {
        let trust = TrustStore(owner: f.local.id)
        let repository = try TrustRepository(ownerIdentity: f.local, trustStore: trust, persistedGeneration: 0)
        return AuthenticatedPresenceSupervisor(identity: f.local, repository: repository, directory: DeviceDirectory(trust: trust),
            origin: URL(string: "wss://account.example.test/v1/ws")!, makeSocket: { try await factory.next() }, sleep: { _ in }, accountController: f.controller)
    }

    private func eventually(_ condition: @escaping @Sendable () async -> Bool) async throws {
        for _ in 0..<2000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("timed out waiting for account supervisor")
        throw CancellationError()
    }
}

private actor AccountSupervisorFactory {
    var count = 0
    var sockets: [AccountSupervisorSocket]
    init(_ sockets: [AccountSupervisorSocket]) { self.sockets = sockets }
    func next() throws -> any PresenceWebSocket {
        count += 1
        guard !sockets.isEmpty else { throw CancellationError() }
        return sockets.removeFirst()
    }
}

private actor AccountSupervisorSocket: PresenceWebSocket {
    nonisolated let sendGate = NativeProducerGate()
    nonisolated let closeGate = NativeProducerGate()
    let blockSend: Bool, blockClose: Bool
    var binds = 0, trustUpdates = 0
    var closed = false, receivedBindAck = false
    private var incoming: [Data]
    private var receiver: CheckedContinuation<Data, Error>?
    init(_ identity: DeviceIdentity, blockSend: Bool = false, blockClose: Bool = false) {
        self.blockSend = blockSend; self.blockClose = blockClose
        incoming = [Self.frame(["type": "challenge", "nonce": Data(repeating: 1, count: 32).base64EncodedString(), "expiresAt": 9999999999999]),
                    Self.frame(["type": "auth-ok", "deviceID": identity.id.rawValue.uuidString.lowercased()])]
    }
    static func frame(_ value: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: value) }
    func send(_ data: Data) async throws {
        let type = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["type"] as? String
        if type == "account-route-bind-challenge" {
            if blockSend { await sendGate.block() }
            push(Self.frame(["type": "account-route-bind-challenge", "nonce": Data(repeating: 8, count: 32).base64EncodedString(), "expiresAt": Int64(Date().timeIntervalSince1970 * 1000) + 10000]))
        } else if type == "account-route-bind" {
            binds += 1
            push(Self.frame(["type": "account-route-bind-ok"]))
        } else if type == "trust-update" {
            trustUpdates += 1
            push(Self.frame(["type": "trust-ok"]))
        }
    }
    func push(_ frame: Data) {
        if let receiver { self.receiver = nil; receiver.resume(returning: frame) }
        else { incoming.append(frame) }
    }
    func receive() async throws -> Data {
        let data: Data
        if closed { throw CancellationError() }
        if !incoming.isEmpty { data = incoming.removeFirst() }
        else { data = try await withCheckedThrowingContinuation { receiver = $0 } }
        if (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["type"] as? String == "account-route-bind-ok" { receivedBindAck = true }
        return data
    }
    func ping() async throws {}
    func close() async {
        closed = true
        receiver?.resume(throwing: CancellationError()); receiver = nil
        if blockClose { await closeGate.block() }
    }
}
