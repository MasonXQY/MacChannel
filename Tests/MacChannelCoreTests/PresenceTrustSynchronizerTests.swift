import CryptoKit
import Foundation
import XCTest
@testable import MacChannelCore

final class PresenceTrustSynchronizerTests: XCTestCase {
    func testRefreshWhileStateDeliveryIsSuspendedReconsidersUnsentProof() async throws {
        let fixture = try await SyncFixture()
        let gate = SyncPublicationGate()
        let sync = PresenceTrustSynchronizer(records: { await gate.publication(fixture.repository) },
            send: { _ in await gate.sent() }, sleep: { try await Task.sleep(for: $0) },
            onState: {
                await gate.record($0)
                if $0 == .synchronizing { await gate.hold() }
            }, onFailure: { })
        await sync.refresh()
        do {
            try await eventually { await gate.entered }
            await gate.exclude()
            await sync.refresh()
            await gate.release()
            try await eventually { await gate.state == .pendingPersistence }
        } catch {
            await gate.release()
            await sync.stop()
            throw error
        }
        let sent = await gate.sendCount
        XCTAssertEqual(sent, 0, "A refresh admitted before send must reconsider the old proof")
        await sync.stop()
    }
    func testUnsavedProofCannotSynchronizeAndSuccessfulReceiptRefreshesWithoutMutation() async throws {
        let fixture = try await SyncFixture()
        let receipt = SyncReceipt()
        let owner = fixture.makeOwner(publication: {
            await fixture.repository.publicationSnapshot(persisted: receipt.state())
        }, persistedUpdates: { await receipt.updates() })
        await owner.start()
        do { try await eventually { await owner.trustSyncState == .pendingPersistence } }
        catch { await owner.stop(); throw error }
        let initial = await owner.trustSyncState
        XCTAssertEqual(initial, .pendingPersistence, "Filtered current proof is waiting for local save")
        let before = await fixture.socket.updateCount
        XCTAssertEqual(before, 0)
        let snapshot = try await fixture.repository.latestSignedSnapshot()
        let records = await fixture.repository.authenticationRecords()
        await receipt.save(AuthenticatedTrustState(snapshot: snapshot, authenticationRecords: records))
        do { try await eventually { await fixture.socket.updateCount == 1 } }
        catch { await owner.stop(); throw error }
        await fixture.socket.ack("trust-ok")
        try await eventually { await owner.trustSyncState == .synchronized }
        // No manual refresh: the joined repository observer must notice revoke
        // even before the successful-receipt observer has anything to publish.
        let subject = try XCTUnwrap(records.first?.subject)
        let revocation = try await fixture.repository.revoke(subject)
        try await eventually { await owner.trustSyncState == .pendingPersistence }
        let pendingCount = await fixture.socket.updateCount
        let connected = await owner.state
        XCTAssertEqual(pendingCount, 1)
        XCTAssertEqual(connected, .online)
        await receipt.save(AuthenticatedTrustState(snapshot: try await fixture.repository.latestSignedSnapshot(),
            authenticationRecords: await fixture.repository.authenticationRecords()))
        try await eventually { await fixture.socket.updateCount == 2 }
        let sent = try await fixture.socket.updates()
        XCTAssertEqual(sent.last, [revocation])
        await fixture.socket.ack("trust-ok")
        try await eventually { await owner.trustSyncState == .synchronized }
        await owner.stop()
    }

    func testStopJoinsCancellationInsensitiveReceiptSubscription() async throws {
        let fixture = try await SyncFixture()
        let gate = SyncPublicationGate()
        let owner = fixture.makeOwner(publication: { TrustPublicationSnapshot(records: []) },
            persistedUpdates: {
                await gate.hold()
                return AsyncStream { $0.finish() }
            })
        await owner.start()
        try await eventually { await gate.entered }
        let stopping = Task { await owner.stop() }
        try await eventually { await fixture.socket.closed }
        let state = await owner.state
        XCTAssertEqual(state, .stopping)
        await gate.release()
        await stopping.value
        let stopped = await owner.state
        XCTAssertEqual(stopped, .stopped)
    }

    func testInvalidIdentityConfirmationNeverPublishesOnlineOrSendsTrust() async throws {
        let fixture = try await SyncFixture()
        let foreign = try DeviceIdentity.ephemeral()
        let socket = try SyncSocket(identity: foreign)
        let states = SyncStates()
        let owner = fixture.makeOwner(factory: SyncFactory([socket]), onState: { await states.append($0) })
        await owner.start()
        try await eventually { await owner.state == .stopped }
        let updates = await socket.updateCount
        let values = await states.values
        XCTAssertFalse(values.contains(.online))
        XCTAssertEqual(updates, 0)
        await owner.stop()
    }

    func testProviderSnapshotUsesStableIssuerSequenceSignatureOrderAndDeduplicates() async throws {
        let fixture = try await SyncFixture()
        let peer = try DeviceIdentity.ephemeral()
        let other = try DeviceIdentity.ephemeral()
        let a = try SignedTrustRecord.authorizing(peer, signedBy: fixture.identity, sequence: 2)
        let b = try SignedTrustRecord.authorizing(peer, signedBy: fixture.identity, sequence: 1)
        let c = try SignedTrustRecord.authorizing(peer, signedBy: fixture.identity, sequence: 1)
        let d = try SignedTrustRecord.authorizing(peer, signedBy: other, sequence: 1)
        let records = [a, d, c, b]
        let expected = records.sorted {
            if $0.issuer != $1.issuer { return $0.issuer.rawValue.uuidString < $1.issuer.rawValue.uuidString }
            if $0.issuerSequence != $1.issuerSequence { return $0.issuerSequence < $1.issuerSequence }
            return $0.signature.lexicographicallyPrecedes($1.signature)
        }
        let owner = fixture.makeOwner(records: { records + [a] })
        await owner.start()
        for index in 1...4 {
            try await eventually { await fixture.socket.updateCount == index }
            await fixture.socket.ack("trust-ok")
        }
        try await eventually { await owner.trustSyncState == .synchronized }
        let updates = try await fixture.socket.updates()
        XCTAssertEqual(updates.map { $0.map(\.signature) }, expected.map { [$0.signature] })
        await owner.stop()
    }

    func testRejectedProofIsRetriedOnlyInNewSession() async throws {
        let fixture = try await SyncFixture()
        let second = try SyncSocket(identity: fixture.identity, nonce: 2)
        let owner = fixture.makeOwner(factory: SyncFactory([fixture.socket, second]))
        await owner.start()
        try await eventually { await fixture.socket.updateCount == 1 }
        await fixture.socket.ack("trust-error")
        try await eventually { await owner.trustSyncState == .needsAttention }
        await owner.retryConnection()
        try await eventually { await second.updateCount == 1 }
        let first = try await fixture.socket.updates()
        let replacement = try await second.updates()
        XCTAssertEqual(first[0].map(\.signature), replacement[0].map(\.signature))
        let state = await owner.trustSyncState
        XCTAssertEqual(state, .synchronizing)
        await second.ack("trust-ok")
        try await eventually { await owner.trustSyncState == .synchronized }
        await owner.stop()
    }

    func testTwentyDisconnectCyclesKeepStableBridgeAndFreshIdentityProofs() async throws {
        let fixture = try await SyncFixture()
        let sockets = try (1...21).map { try SyncSocket(identity: fixture.identity, nonce: UInt8($0)) }
        let factory = SyncFactory(sockets)
        let owner = fixture.makeOwner(factory: factory)
        let bridge = owner.bridge
        await owner.start()
        var previousNonce: Data?
        for (index, socket) in sockets.enumerated() {
            try await eventually { await socket.updateCount == 1 }
            let auth = try await socket.authentication()
            XCTAssertTrue(auth.trustRecords.isEmpty)
            XCTAssertNotEqual(previousNonce, auth.envelope.nonce)
            previousNonce = auth.envelope.nonce
            await socket.ack("trust-ok")
            try await eventually { await owner.trustSyncState == .synchronized }
            XCTAssertTrue(owner.bridge === bridge)
            if index < 20 { await socket.failReceive() }
        }
        let count = await factory.count
        let overlaps = await factory.overlaps
        XCTAssertEqual(count, 21)
        XCTAssertEqual(overlaps, 0)
        await owner.stop()
    }

    func testIdentityFirstAndOneRecordUntilAcknowledgedDespiteConcurrentRefresh() async throws {
        let fixture = try await SyncFixture()
        let secondPeer = try DeviceIdentity.ephemeral()
        _ = try await fixture.repository.issueAuthorization(subject: secondPeer.id,
            subjectPublicKey: secondPeer.publicKey.rawRepresentation, timestamp: Date())
        await fixture.owner.start()
        try await eventually { await fixture.owner.state == .online }
        await fixture.owner.refreshTrust()
        try await eventually { await fixture.socket.updateCount > 0 }
        let auth = try await fixture.socket.authentication()
        XCTAssertTrue(auth.trustRecords.isEmpty, "Connectivity must authenticate identity directly")
        XCTAssertTrue(fixture.identity.publicKey.isValidSignature(
            try P256.Signing.ECDSASignature(derRepresentation: auth.envelope.signature),
            for: try auth.envelope.canonicalPayload()))
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask { await fixture.owner.refreshTrust() } }
        }
        let count = await fixture.socket.updateCount
        XCTAssertEqual(count, 1, "One in-flight record until trust-ok, including concurrent refresh")
        let beforeACK = await fixture.owner.trustSyncState
        XCTAssertEqual(beforeACK, .synchronizing)
        await fixture.socket.ack("trust-ok")
        try await eventually { await fixture.socket.updateCount == 2 }
        await fixture.socket.ack("trust-ok")
        try await eventually { await fixture.owner.trustSyncState == .synchronized }
        await fixture.owner.refreshTrust()
        try await eventually { await fixture.owner.trustSyncState == .synchronized }
        let finalCount = await fixture.socket.updateCount
        XCTAssertEqual(finalCount, 2, "An unchanged snapshot is not resent")
        await fixture.owner.stop()
    }

    func testRejectedProofDoesNotDisconnectOrBlockValidRevokeOrDeleteLocalRecords() async throws {
        let fixture = try await SyncFixture()
        let peer = try DeviceIdentity.ephemeral()
        _ = try await fixture.repository.issueAuthorization(subject: peer.id,
            subjectPublicKey: peer.publicKey.rawRepresentation, timestamp: Date())
        let revoke = try await fixture.repository.revoke(peer.id)
        let before = await fixture.repository.authenticationRecords()
        await fixture.owner.start()
        try await eventually { await fixture.socket.updateCount == 1 }
        await fixture.socket.ack("trust-error")
        try await eventually { await fixture.socket.updateCount == 2 }
        let rejectedWhileSending = await fixture.owner.trustSyncState
        XCTAssertEqual(rejectedWhileSending, .needsAttention)
        let updates = try await fixture.socket.updates()
        XCTAssertEqual(updates.last?.map(\.signature), [revoke.signature])
        await fixture.socket.ack("trust-ok")
        try await eventually { await fixture.owner.trustSyncState == .needsAttention }
        for _ in 0..<20 { await fixture.owner.refreshTrust() }
        try await eventually { await fixture.owner.trustSyncState == .needsAttention }
        let count = await fixture.socket.updateCount
        let connection = await fixture.owner.state
        let after = await fixture.repository.authenticationRecords()
        let trusted = await fixture.repository.isTrusted(peer.id)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(connection, .online)
        XCTAssertFalse(trusted)
        XCTAssertEqual(before.map(\.signature), after.map(\.signature))
        await fixture.owner.stop()
    }

    func testNewSnapshotCanRemoveRejectedProofWithoutReauthorizingOrClearingRepository() async throws {
        let fixture = try await SyncFixture()
        let records = await fixture.repository.authenticationRecords()
        let source = SyncRecordSource(records)
        let owner = fixture.makeOwner(records: { await source.get() })
        await owner.start()
        try await eventually { await fixture.socket.updateCount == 1 }
        await fixture.socket.ack("trust-error")
        try await eventually { await owner.trustSyncState == .needsAttention }
        await source.set([])
        await owner.refreshTrust()
        try await eventually { await owner.trustSyncState == .synchronized }
        let retained = await fixture.repository.authenticationRecords()
        XCTAssertEqual(retained.map(\.signature), records.map(\.signature))
        await owner.stop()
    }

    func testAuthDeadlineAllowsTenSecondHandoverThenRetiresWithoutReplacingUndrainedReceive() async throws {
        let fixture = try await SyncFixture()
        let clock = SyncClock()
        let first = try SyncSocket(identity: fixture.identity, holdAuthentication: true)
        let second = try SyncSocket(identity: fixture.identity, nonce: 2)
        let factory = SyncFactory([first, second])
        let owner = fixture.makeOwner(factory: factory, clock: clock)
        await owner.start()
        try await eventually { await first.authWaiting }
        try await eventually { await clock.count == 1 }
        await clock.advance(.seconds(10))
        let openAtTen = await first.closed
        XCTAssertFalse(openAtTen, "Client deadline must exceed server's ten-second drain")
        await clock.advance(.seconds(5))
        try await eventually { await first.closed }
        let attempts = await factory.count
        let state = await owner.state
        XCTAssertEqual(attempts, 1, "Deadline requests close but cannot release the sole owner")
        XCTAssertEqual(state, .reconnecting)
        await first.releaseAuthentication(identity: fixture.identity)
        try await eventually { await second.updateCount == 1 }
        let firstAuth = try await first.authentication()
        let nextAuth = try await second.authentication()
        XCTAssertNotEqual(firstAuth.envelope.nonce, nextAuth.envelope.nonce)
        XCTAssertTrue(nextAuth.trustRecords.isEmpty)
        await owner.stop()
        let timers = await clock.count
        XCTAssertEqual(timers, 0)
    }

    func testAuthenticationAtTenSecondsSucceedsWithoutPrematureClose() async throws {
        let fixture = try await SyncFixture()
        let clock = SyncClock()
        let first = try SyncSocket(identity: fixture.identity, holdAuthentication: true)
        let owner = fixture.makeOwner(factory: SyncFactory([first]), clock: clock)
        await owner.start()
        try await eventually { await first.authWaiting }
        try await eventually { await clock.count == 1 }
        await clock.advance(.seconds(10))
        await first.releaseAuthentication(identity: fixture.identity)
        try await eventually { await first.updateCount == 1 }
        await first.ack("trust-ok")
        try await eventually { await owner.trustSyncState == .synchronized }
        let closed = await first.closed
        XCTAssertFalse(closed)
        await owner.stop()
    }

    func testAckDeadlineAndLateOldAckCannotConfirmReplacementSession() async throws {
        let fixture = try await SyncFixture()
        let clock = SyncClock()
        let second = try SyncSocket(identity: fixture.identity, nonce: 2)
        let factory = SyncFactory([fixture.socket, second])
        let owner = fixture.makeOwner(factory: factory, clock: clock)
        await owner.start()
        try await eventually { await fixture.socket.updateCount == 1 }
        try await eventually { await clock.count == 1 }
        await clock.advance(.seconds(15))
        try await eventually { await second.updateCount == 1 }
        await fixture.socket.ack("trust-ok")
        let unconfirmed = await owner.trustSyncState
        XCTAssertEqual(unconfirmed, .synchronizing)
        await second.ack("trust-ok")
        try await eventually { await owner.trustSyncState == .synchronized }
        await owner.stop()
        let timers = await clock.count
        XCTAssertEqual(timers, 0)
    }

    func testDeadlineCannotReplaceSessionWhileCancellationInsensitiveSendIsOutstanding() async throws {
        let fixture = try await SyncFixture()
        let clock = SyncClock()
        let first = try SyncSocket(identity: fixture.identity, holdSend: true)
        let second = try SyncSocket(identity: fixture.identity, nonce: 2)
        let factory = SyncFactory([first, second])
        let owner = fixture.makeOwner(factory: factory, clock: clock)
        await owner.start()
        try await eventually { await first.sendWaiting }
        try await eventually { await clock.count == 1 }
        await clock.advance(.seconds(15))
        try await eventually { await first.closed }
        let count = await factory.count
        XCTAssertEqual(count, 1)
        await first.releaseSend()
        try await eventually { await second.updateCount == 1 }
        await owner.stop()
        let timers = await clock.count
        XCTAssertEqual(timers, 0)
    }

    func testStopDuringAcknowledgementJoinsAndClearsTimer() async throws {
        let fixture = try await SyncFixture()
        let clock = SyncClock()
        let owner = fixture.makeOwner(clock: clock)
        await owner.start()
        try await eventually { await fixture.socket.updateCount == 1 }
        await owner.stop()
        let state = await owner.state
        let sync = await owner.trustSyncState
        let timers = await clock.count
        XCTAssertEqual(state, .stopped)
        XCTAssertEqual(sync, .idle)
        XCTAssertEqual(timers, 0)
    }

    func testAckBeforeBlockedSendReturnsStillBoundsExchangeAndDoesNotReplaceBeforeJoin() async throws {
        let fixture = try await SyncFixture()
        let clock = SyncClock()
        let first = try SyncSocket(identity: fixture.identity, holdSend: true)
        let second = try SyncSocket(identity: fixture.identity, nonce: 2)
        let factory = SyncFactory([first, second])
        let owner = fixture.makeOwner(factory: factory, clock: clock)
        await owner.start()
        try await eventually { await first.sendWaiting }
        try await eventually { await clock.count == 1 }
        await first.ack("trust-ok")
        try await eventually { await first.waitingForFrame }
        await clock.advance(.seconds(15))
        do { try await eventually { await first.closed } }
        catch { await first.releaseSend(); await owner.stop(); throw error }
        let count = await factory.count
        XCTAssertEqual(count, 1)
        await first.releaseSend()
        try await eventually { await second.updateCount == 1 }
        await owner.stop()
    }

    private func eventually(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<2000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Sync transition timed out")
        throw CancellationError()
    }
}

private actor SyncReceipt {
    private var value: AuthenticatedTrustState?
    private let events = AsyncStream<AuthenticatedTrustState?>.makeStream(bufferingPolicy: .bufferingNewest(1))
    func state() -> AuthenticatedTrustState? { value }
    func updates() -> AsyncStream<AuthenticatedTrustState?> { events.stream }
    func save(_ state: AuthenticatedTrustState) {
        value = state
        events.continuation.yield(state)
    }
}

private actor SyncPublicationGate {
    private(set) var entered = false
    private(set) var sendCount = 0
    private(set) var state: PresenceTrustSyncState = .idle
    private var excluded = false
    private var waiter: CheckedContinuation<Void, Never>?
    func publication(_ repository: TrustRepository) async -> TrustPublicationSnapshot {
        if excluded { return TrustPublicationSnapshot(records: [], pendingPersistence: true) }
        return TrustPublicationSnapshot(records: await repository.authenticationRecords())
    }
    func hold() async { entered = true; await withCheckedContinuation { waiter = $0 } }
    func exclude() { excluded = true }
    func release() { waiter?.resume(); waiter = nil }
    func sent() { sendCount += 1 }
    func record(_ state: PresenceTrustSyncState) { self.state = state }
}

private struct SyncAuthentication: Decodable {
    let envelope: RendezvousSignedEnvelope
    let trustRecords: [SignedTrustRecord]
}

private struct SyncFixture {
    let identity: DeviceIdentity
    let repository: TrustRepository
    let socket: SyncSocket
    let owner: AuthenticatedPresenceSupervisor
    init() async throws {
        identity = try DeviceIdentity.ephemeral()
        let peer = try DeviceIdentity.ephemeral()
        repository = try TrustRepository(ownerIdentity: identity,
            trustStore: TrustStore(owner: identity.id), persistedGeneration: 0)
        _ = try await repository.issueAuthorization(subject: peer.id,
            subjectPublicKey: peer.publicKey.rawRepresentation, timestamp: Date())
        socket = try SyncSocket(identity: identity)
        let socket = socket
        owner = AuthenticatedPresenceSupervisor(identity: identity, repository: repository,
            directory: DeviceDirectory(trust: await repository.currentTrustStore()),
            origin: URL(string: "wss://fixture.invalid/v1/ws")!,
            makeSocket: { socket }, sleep: { try await Task.sleep(for: $0) })
    }
    func makeOwner(factory: SyncFactory? = nil, clock: SyncClock? = nil,
                   records: (@Sendable () async throws -> [SignedTrustRecord])? = nil,
                   publication: (@Sendable () async throws -> TrustPublicationSnapshot)? = nil,
                   persistedUpdates: (@Sendable () async -> AsyncStream<AuthenticatedTrustState?>)? = nil,
                   onState: @escaping @Sendable (PresenceSessionState) async -> Void = { _ in }) -> AuthenticatedPresenceSupervisor {
        let factory = factory ?? SyncFactory([socket])
        return AuthenticatedPresenceSupervisor(identity: identity, repository: repository,
            directory: DeviceDirectory(trust: TrustStore(owner: identity.id)),
            origin: URL(string: "wss://fixture.invalid/v1/ws")!,
            makeSocket: { try await factory.next() }, sleep: { _ in }, onState: onState, records: records,
            publication: publication, persistedUpdates: persistedUpdates,
            deadlineSleep: { if let clock { try await clock.sleep($0) } else { try await Task.sleep(for: $0) } })
    }
}

private actor SyncStates {
    private(set) var values: [PresenceSessionState] = []
    func append(_ value: PresenceSessionState) { values.append(value) }
}

private actor SyncSocket: PresenceWebSocket {
    private var incoming: [Data]
    private var receiver: CheckedContinuation<Data, any Error>?
    private var sent: [Data] = []
    private(set) var closed = false
    private var holdAuthentication: Bool
    private let holdSend: Bool
    private var sender: CheckedContinuation<Void, Never>?
    var authWaiting: Bool { holdAuthentication && receiver != nil }
    var sendWaiting: Bool { sender != nil }
    var waitingForFrame: Bool { receiver != nil }
    var updateCount: Int { max(0, sent.count - 1) }
    init(identity: DeviceIdentity, nonce: UInt8 = 1, holdAuthentication: Bool = false, holdSend: Bool = false) throws {
        self.holdAuthentication = holdAuthentication
        self.holdSend = holdSend
        incoming = [try JSONSerialization.data(withJSONObject: [
            "type": "challenge", "nonce": Data(repeating: nonce, count: 32).base64EncodedString(),
            "expiresAt": 1234]), try JSONSerialization.data(withJSONObject: [
                "type": "auth-ok", "deviceID": identity.id.rawValue.uuidString.lowercased()])]
        if holdAuthentication { incoming.removeLast() }
    }
    func authentication() throws -> SyncAuthentication {
        try JSONDecoder().decode(SyncAuthentication.self, from: XCTUnwrap(sent.first))
    }
    func updates() throws -> [[SignedTrustRecord]] {
        struct Update: Decodable { let trustRecords: [SignedTrustRecord] }
        return try sent.dropFirst().map { try JSONDecoder().decode(Update.self, from: $0).trustRecords }
    }
    func send(_ data: Data) async {
        sent.append(data)
        if holdSend, sent.count > 1 { await withCheckedContinuation { sender = $0 } }
    }
    func releaseSend() { sender?.resume(); sender = nil }
    func releaseAuthentication(identity: DeviceIdentity) {
        holdAuthentication = false
        push(Data("{\"type\":\"auth-ok\",\"deviceID\":\"\(identity.id.rawValue.uuidString.lowercased())\"}".utf8))
    }
    func ping() { }
    func receive() async throws -> Data {
        if closed { throw CancellationError() }
        if !incoming.isEmpty { return incoming.removeFirst() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func ack(_ type: String) {
        push(Data("{\"type\":\"\(type)\"}".utf8))
    }
    func push(_ data: Data) {
        if let receiver { self.receiver = nil; receiver.resume(returning: data) }
        else { incoming.append(data) }
    }
    func close() {
        closed = true
        if holdAuthentication { return }
        receiver?.resume(throwing: CancellationError())
        receiver = nil
    }
    func failReceive() {
        receiver?.resume(throwing: AuthenticatedPresenceError.transport("fixture"))
        receiver = nil
    }
}

private actor SyncRecordSource {
    private var records: [SignedTrustRecord]
    init(_ records: [SignedTrustRecord]) { self.records = records }
    func get() -> [SignedTrustRecord] { records }
    func set(_ value: [SignedTrustRecord]) { records = value }
}

private actor SyncFactory {
    private var sockets: [SyncSocket]
    private(set) var count = 0
    private var previous: SyncSocket?
    private(set) var overlaps = 0
    init(_ sockets: [SyncSocket]) { self.sockets = sockets }
    func next() async throws -> any PresenceWebSocket {
        count += 1
        if let previous, !(await previous.closed) { overlaps += 1 }
        guard !sockets.isEmpty else { throw CancellationError() }
        let next = sockets.removeFirst()
        previous = next
        return next
    }
}

private actor SyncClock {
    private var now: Duration = .zero
    private var sleepers: [UUID: (Duration, CheckedContinuation<Void, any Error>)] = [:]
    var count: Int { sleepers.count }
    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { sleepers[id] = (now + duration, continuation) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        sleepers.removeValue(forKey: id)?.1.resume(throwing: CancellationError())
    }
    func advance(_ duration: Duration) {
        now += duration
        for (id, sleeper) in sleepers where sleeper.0 <= now {
            sleepers.removeValue(forKey: id)?.1.resume()
        }
    }
}
