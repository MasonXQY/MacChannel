import Foundation
import XCTest
@testable import MacChannelCore

final class SharedPresenceOwnerTests: XCTestCase {
    func testEverySocketAttemptOwnsADistinctPresenceClient() async throws {
        let identity = try DeviceIdentity.ephemeral()
        let trust = TrustStore(owner: identity.id)
        let repository = try TrustRepository(ownerIdentity: identity, trustStore: trust, persistedGeneration: 0)
        let first = try SupervisorSocket(identity: identity)
        let second = try SupervisorSocket(identity: identity)
        let factory = SupervisorSocketFactory([first, second])
        let clients = SupervisorClientProbe()
        let supervisor = AuthenticatedPresenceSupervisor(
            identity: identity, repository: repository, directory: DeviceDirectory(trust: trust),
            origin: URL(string: "wss://fixture.invalid/v1/ws")!,
            makeSocket: { try await factory.next() }, sleep: { _ in },
            makeClient: { clients.make(directory: $0) })
        await supervisor.start()
        try await eventually { await first.waitingForFrame }
        await first.failReceive()
        try await eventually { await second.waitingForFrame }
        await supervisor.stop()
        let values = clients.values
        XCTAssertEqual(values.count, 2)
        if values.count == 2 {
            XCTAssertFalse(values[0] === values[1], "No online set or heartbeat may be reused across attempts")
        }
    }

    func testConcurrentStopsBothWaitForSameBlockedCleanup() async throws {
        let identity = try DeviceIdentity.ephemeral()
        let socket = try SupervisorSocket(identity: identity, delayFirstClose: true)
        let factory = SupervisorSocketFactory([socket])
        let supervisor = try makeSupervisor(identity, factory: factory)
        let completions = SupervisorDelayRecorder()
        await supervisor.start()
        try await eventually { await socket.waitingForFrame }
        let first = Task { await supervisor.stop(); await completions.append(.seconds(1)) }
        try await eventually { await socket.closePending }
        let second = Task { await supervisor.stop(); await completions.append(.seconds(2)) }
        try await Task.sleep(for: .milliseconds(30))
        let returnedBeforeRelease = await completions.values
        let closesBeforeRelease = await socket.closeCalls
        XCTAssertTrue(returnedBeforeRelease.isEmpty)
        XCTAssertEqual(closesBeforeRelease, 1)
        await socket.releaseClose()
        await first.value
        await second.value
        let returnedAfterRelease = await completions.values
        XCTAssertEqual(returnedAfterRelease.count, 2)
    }

    func testStaleBridgeDisconnectCannotRemoveReplacementSender() async throws {
        let bridge = PresenceSignalBridge()
        let firstValue = await bridge.beginSocket()
        let first = try XCTUnwrap(firstValue)
        await bridge.activate(first) { _, _ in XCTFail("Retired sender used") }
        let secondValue = await bridge.beginSocket()
        let second = try XCTUnwrap(secondValue)
        let sent = SupervisorDelayRecorder()
        await bridge.activate(second) { _, _ in await sent.append(.seconds(1)) }
        await bridge.disconnect(first)
        try await bridge.sendSignal(Data([1]), to: DeviceID(rawValue: UUID()))
        let sends = await sent.values
        XCTAssertEqual(sends.count, 1)
        await bridge.finish()
    }

    func testStartStopReentrancyAuthenticatesExactlyOneSocket() async throws {
        let identity = try DeviceIdentity.ephemeral()
        let socket = try SupervisorSocket(identity: identity)
        let factory = SupervisorSocketFactory([socket])
        let supervisor = try makeSupervisor(identity, factory: factory)
        await supervisor.start()
        await supervisor.start()
        try await eventually { await supervisor.state == .online }
        let sentTypes = await socket.sentTypes
        XCTAssertEqual(sentTypes, ["auth"])
        async let firstStop: Void = supervisor.stop()
        async let secondStop: Void = supervisor.stop()
        _ = await (firstStop, secondStop)
        await supervisor.start()
        let count = await factory.count
        let state = await supervisor.state
        XCTAssertEqual(count, 1)
        XCTAssertEqual(state, .stopped)
    }

    func testReconnectReusesBridgeAndJoinsOldSocketBeforeReplacement() async throws {
        let identity = try DeviceIdentity.ephemeral()
        let first = try SupervisorSocket(identity: identity)
        let second = try SupervisorSocket(identity: identity)
        let factory = SupervisorSocketFactory([first, second])
        let supervisor = try makeSupervisor(identity, factory: factory)
        let stream = await supervisor.bridge.signalFrames()
        await supervisor.start()
        try await eventually { await supervisor.state == .online }
        await first.failReceive()
        try await eventually {
            let count = await factory.count
            let state = await supervisor.state
            return count == 2 && state == .online
        }
        let firstClosed = await first.closed
        XCTAssertTrue(firstClosed)
        let peer = DeviceID(rawValue: UUID())
        await second.push(try frame(["type": "signal", "from": peer.rawValue.uuidString,
                                     "payload": Data([9]).base64EncodedString()]))
        var iterator = stream.makeAsyncIterator()
        let received = await iterator.next()
        XCTAssertEqual(received?.payload, Data([9]))
        await supervisor.stop()
    }

    func testStopWaitsForCancellationInsensitiveAuthenticationAndCannotRestart() async throws {
        let identity = try DeviceIdentity.ephemeral()
        let socket = try SupervisorSocket(identity: identity, delayAuthentication: true)
        let factory = SupervisorSocketFactory([socket])
        let supervisor = try makeSupervisor(identity, factory: factory)
        await supervisor.start()
        try await eventually { await socket.waitingForFrame }
        let stop = Task { await supervisor.stop() }
        try await eventually { await socket.closed }
        await supervisor.start()
        let stopping = await supervisor.state
        XCTAssertEqual(stopping, .stopping)
        await socket.push(try frame(["type": "auth-ok", "deviceID": identity.id.rawValue.uuidString.lowercased()]))
        await stop.value
        let state = await supervisor.state
        let count = await factory.count
        XCTAssertEqual(state, .stopped)
        XCTAssertEqual(count, 1)
    }

    func testBackoffIsCappedAndManualRetryInterruptsSleep() async throws {
        XCTAssertEqual((0..<8).map(AuthenticatedPresenceSupervisor.reconnectDelay),
                       [.seconds(1), .seconds(2), .seconds(4), .seconds(8),
                        .seconds(15), .seconds(15), .seconds(15), .seconds(15)])
        let identity = try DeviceIdentity.ephemeral()
        let first = try SupervisorSocket(identity: identity)
        let second = try SupervisorSocket(identity: identity)
        let factory = SupervisorSocketFactory([first, second])
        let supervisor = try makeSupervisor(identity, factory: factory, sleep: { _ in
            try await Task.sleep(for: .seconds(60))
        })
        await supervisor.start()
        try await eventually { await supervisor.state == .online }
        // Online is published just before run enters receive. The fixture's
        // failReceive injects into an existing waiter, so wait for that boundary.
        try await eventually { await first.waitingForFrame }
        await first.failReceive()
        try await eventually { await supervisor.state == .reconnecting }
        await supervisor.retryConnection()
        try await eventually {
            let count = await factory.count
            let state = await supervisor.state
            return count == 2 && state == .online
        }
        await supervisor.stop()
    }

    func testCancelledSocketCreationDoesNotScheduleReconnect() async throws {
        let identity = try DeviceIdentity.ephemeral()
        let factory = SupervisorSocketFactory([])
        let supervisor = try makeSupervisor(identity, factory: factory)
        await supervisor.start()
        do { try await eventually { await supervisor.state == .stopped } }
        catch { await supervisor.stop() }
        let count = await factory.count
        XCTAssertEqual(count, 1)
    }

    func testReconnectWaitsForEarlierConcurrentCloseToReturn() async throws {
        let identity = try DeviceIdentity.ephemeral()
        let first = try SupervisorSocket(identity: identity, delayFirstClose: true)
        let second = try SupervisorSocket(identity: identity)
        let factory = SupervisorSocketFactory([first, second])
        let supervisor = try makeSupervisor(identity, factory: factory)
        await supervisor.start()
        try await eventually { await supervisor.state == .online }
        let retry = Task { await supervisor.retryConnection() }
        try await eventually { await first.closePending }
        let stateWhileClosing = await supervisor.state
        do {
            try await supervisor.bridge.sendSignal(Data([1]), to: DeviceID(rawValue: UUID()))
            XCTFail("Draining socket must reject outgoing signals")
        } catch is CancellationError { }
        try await Task.sleep(for: .milliseconds(30))
        let countWhileClosing = await factory.count
        await first.releaseClose()
        await retry.value
        try await eventually { await factory.count == 2 }
        await supervisor.stop()
        XCTAssertEqual(countWhileClosing, 1, "No new session while an old stop can still mutate the directory")
        XCTAssertEqual(stateWhileClosing, .reconnecting, "A draining attempt must never remain online")
    }

    func testSignalOverflowClosesAndDrainsForwarderBeforeReconnect() async throws {
        let identity = try DeviceIdentity.ephemeral()
        let first = try SupervisorSocket(identity: identity)
        let second = try SupervisorSocket(identity: identity)
        let factory = SupervisorSocketFactory([first, second])
        let supervisor = try makeSupervisor(identity, factory: factory)
        await supervisor.start()
        try await eventually { await supervisor.state == .online }
        let signal = try frame(["type": "signal", "from": UUID().uuidString,
                                "payload": Data([1]).base64EncodedString()])
        // No router consumes the bounded bridge in this fixture.
        for _ in 0..<129 { await first.push(signal) }
        try await eventually { await factory.count == 2 }
        await supervisor.stop()
    }

    func testManualRetryDuringLateAuthenticationCannotPublishOldOnline() async throws {
        let identity = try DeviceIdentity.ephemeral()
        let first = try SupervisorSocket(identity: identity, delayAuthentication: true)
        let second = try SupervisorSocket(identity: identity)
        let factory = SupervisorSocketFactory([first, second])
        let states = SupervisorStateRecorder()
        let supervisor = try makeSupervisor(identity, factory: factory, onState: { await states.append($0) })
        await supervisor.start()
        try await eventually { await first.waitingForFrame }
        await supervisor.retryConnection()
        await first.push(try frame(["type": "auth-ok", "deviceID": identity.id.rawValue.uuidString.lowercased()]))
        try await eventually {
            let count = await factory.count
            let state = await supervisor.state
            return count == 2 && state == .online
        }
        await supervisor.stop()
        let onlineCount = await states.values.filter { $0 == .online }.count
        XCTAssertEqual(onlineCount, 1, "Only the replacement socket may become online")
    }

    func testRetryRetiresAttemptBeforeSuspendedStateCallbackAndCannotCloseReplacement() async throws {
        let identity = try DeviceIdentity.ephemeral()
        let first = try SupervisorSocket(identity: identity, delayAuthentication: true)
        let second = try SupervisorSocket(identity: identity)
        let factory = SupervisorSocketFactory([first, second])
        let states = SupervisorStateRecorder()
        let gate = SupervisorReconnectGate()
        let supervisor = try makeSupervisor(identity, factory: factory, onState: {
            await states.append($0)
            if $0 == .reconnecting { await gate.holdFirst() }
        })
        await supervisor.start()
        try await eventually { await first.waitingForFrame }
        let retry = Task { await supervisor.retryConnection() }
        try await eventually { await gate.waiting }
        await first.push(try frame(["type": "auth-ok", "deviceID": identity.id.rawValue.uuidString.lowercased()]))
        try await eventually {
            let replacement = await factory.count == 2
            let runStarted = await first.receiveCalls >= 3
            return replacement || runStarted
        }
        let oldRunStarted = await first.receiveCalls >= 3
        // Let even the buggy old loop drain, so the second half detects a stale
        // retry closing the replacement after its callback finally resumes.
        if oldRunStarted { await first.failReceive() }
        try await eventually {
            let count = await factory.count
            let state = await supervisor.state
            return count == 2 && state == .online
        }
        await gate.release()
        await retry.value
        let replacementClosed = await second.closed
        let onlineCount = await states.values.filter { $0 == .online }.count
        await supervisor.stop()
        XCTAssertFalse(oldRunStarted, "Retired authentication must never enter run")
        XCTAssertEqual(onlineCount, 1, "Only the replacement may publish online")
        XCTAssertFalse(replacementClosed, "Resuming an old retry must not close its replacement")
    }

    func testTrustUpdateSendFailureReauthenticatesWithCurrentRepository() async throws {
        let identity = try DeviceIdentity.ephemeral()
        let peer = try DeviceIdentity.ephemeral()
        let trust = TrustStore(owner: identity.id)
        let repository = try TrustRepository(ownerIdentity: identity, trustStore: trust, persistedGeneration: 0)
        let first = try SupervisorSocket(identity: identity, rejectTrustUpdate: true)
        let second = try SupervisorSocket(identity: identity)
        let factory = SupervisorSocketFactory([first, second])
        let supervisor = AuthenticatedPresenceSupervisor(identity: identity, repository: repository,
                                                  directory: DeviceDirectory(trust: trust), origin: URL(string: "wss://fixture.invalid/v1/ws")!,
                                                  makeSocket: { try await factory.next() }, sleep: { _ in })
        await supervisor.start()
        try await eventually { await supervisor.state == .online }
        // Fixture-only authorization of an ephemeral identity, no production trust.
        _ = try await repository.issueAuthorization(subject: peer.id,
                                                    subjectPublicKey: peer.publicKey.rawRepresentation,
                                                    timestamp: Date())
        await supervisor.refreshTrust()
        try await eventually {
            let count = await factory.count
            let state = await supervisor.state
            return count == 2 && state == .online
        }
        let records = await second.authenticationRecordCount
        XCTAssertEqual(records, 1)
        await supervisor.stop()
    }


    func testSuccessfulSessionResetsRetryDelay() async throws {
        let identity = try DeviceIdentity.ephemeral()
        let first = try SupervisorSocket(identity: identity)
        let second = try SupervisorSocket(identity: identity)
        let factory = SupervisorSocketFactory([first, second])
        let delays = SupervisorDelayRecorder()
        let supervisor = try makeSupervisor(identity, factory: factory, sleep: { await delays.append($0) })
        await supervisor.start()
        try await eventually { await first.waitingForFrame }
        await first.failReceive()
        try await eventually { await second.waitingForFrame }
        await second.failReceive()
        try await eventually { await delays.values.count == 2 }
        await supervisor.stop()
        let values = await delays.values
        XCTAssertEqual(values, [.seconds(1), .seconds(1)])
    }

    private func makeSupervisor(
        _ identity: DeviceIdentity, factory: SupervisorSocketFactory,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in },
        onState: @escaping @Sendable (PresenceSessionState) async -> Void = { _ in }
    ) throws -> AuthenticatedPresenceSupervisor {
        let trust = TrustStore(owner: identity.id)
        let repository = try TrustRepository(ownerIdentity: identity, trustStore: trust, persistedGeneration: 0)
        return AuthenticatedPresenceSupervisor(identity: identity, repository: repository,
                                        directory: DeviceDirectory(trust: trust), origin: URL(string: "wss://fixture.invalid/v1/ws")!,
                                        makeSocket: { try await factory.next() }, sleep: sleep, onState: onState)
    }

    private func eventually(_ condition: @escaping @Sendable () async -> Bool) async throws {
        for _ in 0..<2_000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for lifecycle transition")
        throw CancellationError()
    }

    private func frame(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
}

private actor SupervisorStateRecorder {
    var values: [PresenceSessionState] = []
    func append(_ state: PresenceSessionState) { values.append(state) }
}

private actor SupervisorReconnectGate {
    private var used = false
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func holdFirst() async {
        guard !used else { return }
        used = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private actor SupervisorSocketFactory {
    private var sockets: [SupervisorSocket]
    var count = 0
    init(_ sockets: [SupervisorSocket]) { self.sockets = sockets }
    func next() throws -> any PresenceWebSocket {
        count += 1
        guard !sockets.isEmpty else { throw CancellationError() }
        return sockets.removeFirst()
    }
}

private actor SupervisorSocket: PresenceWebSocket {
    private var incoming: [Data]
    private var receiver: CheckedContinuation<Data, Error>?
    private let delayAuthentication: Bool
    private let delayFirstClose: Bool
    private let rejectTrustUpdate: Bool
    private var closeWaiter: CheckedContinuation<Void, Never>?
    var closeCalls = 0
    var closePending: Bool { closeWaiter != nil }
    var sentTypes: [String] = []
    var authenticationRecordCount = 0
    var closed = false
    var receiveCalls = 0
    var waitingForFrame: Bool { receiver != nil }
    init(identity: DeviceIdentity, delayAuthentication: Bool = false, delayFirstClose: Bool = false,
         rejectTrustUpdate: Bool = false) throws {
        self.delayAuthentication = delayAuthentication
        self.delayFirstClose = delayFirstClose
        self.rejectTrustUpdate = rejectTrustUpdate
        incoming = [try JSONSerialization.data(withJSONObject: [
            "type": "challenge", "nonce": Data(repeating: 3, count: 32).base64EncodedString(), "expiresAt": 1234
        ])]
        if !delayAuthentication {
            incoming.append(try JSONSerialization.data(withJSONObject: [
                "type": "auth-ok", "deviceID": identity.id.rawValue.uuidString.lowercased()
            ]))
        }
    }
    func send(_ data: Data) throws {
        guard !closed || delayAuthentication else { throw CancellationError() }
        let frame = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        sentTypes.append(frame?["type"] as? String ?? (frame?["envelope"] != nil ? "auth" : "invalid"))
        if frame?["envelope"] != nil { authenticationRecordCount = (frame?["trustRecords"] as? [Any])?.count ?? 0 }
        if rejectTrustUpdate, frame?["type"] as? String == "trust-update" {
            throw AuthenticatedPresenceError.transport("fixture")
        }
    }
    func ping() { }
    func receive() async throws -> Data {
        receiveCalls += 1
        if !incoming.isEmpty { return incoming.removeFirst() }
        if closed { throw CancellationError() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func push(_ frame: Data) {
        if let receiver { self.receiver = nil; receiver.resume(returning: frame) }
        else { incoming.append(frame) }
    }
    func failReceive() { receiver?.resume(throwing: AuthenticatedPresenceError.transport("fixture")); receiver = nil }
    func close() async {
        closed = true
        if !delayAuthentication { failReceive() }
        closeCalls += 1
        if delayFirstClose, closeCalls == 1 {
            await withCheckedContinuation { closeWaiter = $0 }
        }
    }
    func releaseClose() { closeWaiter?.resume(); closeWaiter = nil }
}

private actor SupervisorDelayRecorder {
    var values: [Duration] = []
    func append(_ value: Duration) { values.append(value) }
}

private final class SupervisorClientProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [PresenceClient] = []
    var values: [PresenceClient] { lock.withLock { clients } }
    func make(directory: DeviceDirectory) -> PresenceClient {
        let client = PresenceClient(directory: directory)
        lock.withLock { clients.append(client) }
        return client
    }
}
