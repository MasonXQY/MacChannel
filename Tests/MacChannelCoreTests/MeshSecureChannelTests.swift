import Foundation
import XCTest

@testable import MacChannelCore

final class MeshSecureChannelTests: XCTestCase {
    func testAuthenticatedLoopbackSendsAndExportsMatchingSecret() async throws {
        let fixture = try await MeshSecureFixture.make()
        let channels = try await fixture.connect()
        let stream = channels.responder.frames()
        var iterator = stream.makeAsyncIterator()

        try await channels.initiator.send(Data("hello mesh".utf8))
        let received = try await iterator.next()
        let context = Data("transfer-context".utf8)
        let leftKey = try await channels.initiator.exportKey(label: "macchannel-test", context: context, length: 32)
        let rightKey = try await channels.responder.exportKey(label: "macchannel-test", context: context, length: 32)

        XCTAssertEqual(received, Data("hello mesh".utf8))
        XCTAssertEqual(leftKey, rightKey)
        XCTAssertEqual(channels.initiator.route, .lan)
        await channels.close()
    }

    func testDirectionalKeysProduceDifferentCiphertextForSamePlaintextAndSequence() async throws {
        let fixture = try await MeshSecureFixture.make()
        let channels = try await fixture.connect()
        let plaintext = Data("same plaintext".utf8)

        async let left: Void = channels.initiator.send(plaintext)
        async let right: Void = channels.responder.send(plaintext)
        _ = try await (left, right)
        let recordedLeftWire = await fixture.link.lastFrame(from: .left)
        let recordedRightWire = await fixture.link.lastFrame(from: .right)
        let leftWire = try XCTUnwrap(recordedLeftWire)
        let rightWire = try XCTUnwrap(recordedRightWire)

        XCTAssertNotEqual(leftWire, rightWire)
        XCTAssertFalse(leftWire.contains(plaintext))
        XCTAssertFalse(rightWire.contains(plaintext))
        await channels.close()
    }

    func testApplicationLimitIsInclusiveSixtyFourKiB() async throws {
        let channels = try await MeshSecureFixture.makeAndConnect()
        let stream = channels.responder.frames()
        var iterator = stream.makeAsyncIterator()
        let maximum = Data(repeating: 7, count: 64 * 1_024)

        try await channels.initiator.send(maximum)
        let received = try await iterator.next()
        XCTAssertEqual(received, maximum)
        await assertMeshError(.messageTooLarge) {
            try await channels.initiator.send(Data(repeating: 8, count: 64 * 1_024 + 1))
        }
        await channels.close()
    }

    func testExporterRejectsInvalidRequestsAndRevocation() async throws {
        let fixture = try await MeshSecureFixture.make()
        let channels = try await fixture.connect()
        await assertMeshError(.invalidKeyRequest) {
            try await channels.initiator.exportKey(label: "", context: Data(), length: 32)
        }
        await assertMeshError(.invalidKeyRequest) {
            try await channels.initiator.exportKey(label: "bad\0label", context: Data(), length: 32)
        }
        await assertMeshError(.invalidKeyRequest) {
            try await channels.initiator.exportKey(label: "valid", context: Data(), length: 0)
        }

        _ = try await fixture.leftTrust.revoke(fixture.rightIdentity.id)
        await assertMeshError(.untrustedPeer) {
            try await channels.initiator.exportKey(label: "valid", context: Data(), length: 32)
        }
        await channels.close()
    }

    func testUnknownPeerAndMismatchedTransferFailClosed() async throws {
        let fixture = try await MeshSecureFixture.make(authorize: false)
        await assertConnectFails(fixture: fixture, rightTransferID: fixture.transferID)

        let trusted = try await MeshSecureFixture.make()
        await assertConnectFails(
            fixture: trusted,
            rightTransferID: TransferID(rawValue: UUID())
        )
    }

    func testRoleReflectionRouteSwapAndTranscriptMutationFailClosed() async throws {
        let roleFixture = try await MeshSecureFixture.make()
        await assertConnectFails(
            fixture: roleFixture,
            rightTransferID: roleFixture.transferID,
            rightRole: .initiator
        )

        let routeFixture = try await MeshSecureFixture.make()
        await assertConnectFails(
            fixture: routeFixture,
            rightTransferID: routeFixture.transferID,
            rightRoute: .relay
        )

        let mutationFixture = try await MeshSecureFixture.make()
        await mutationFixture.link.mutateNextFrame(from: .left)
        await assertConnectFails(fixture: mutationFixture, rightTransferID: mutationFixture.transferID)

        let proofFixture = try await MeshSecureFixture.make()
        await proofFixture.link.mutateSend(number: 2, from: .left)
        await assertConnectFails(fixture: proofFixture, rightTransferID: proofFixture.transferID)
    }

    func testCiphertextMutationAndReplayFailClosedWithoutDelivery() async throws {
        let fixture = try await MeshSecureFixture.make()
        let channels = try await fixture.connect()
        let stream = channels.responder.frames()
        var iterator = stream.makeAsyncIterator()

        await fixture.link.mutateNextSecureFrame(from: .left)
        try? await channels.initiator.send(Data("secret".utf8))
        do {
            _ = try await iterator.next()
            XCTFail("Mutated ciphertext must not be delivered")
        } catch {
            XCTAssertTrue([.decryptionFailed, .transportClosed].contains(error as? MeshSecureChannelError))
        }
        await channels.close()

        let replayFixture = try await MeshSecureFixture.make()
        let replayChannels = try await replayFixture.connect()
        let replayStream = replayChannels.responder.frames()
        var replayIterator = replayStream.makeAsyncIterator()
        await replayFixture.link.duplicateNextSecureFrame(from: .left)
        try await replayChannels.initiator.send(Data("once".utf8))
        let firstDelivery = try await replayIterator.next()
        XCTAssertEqual(firstDelivery, Data("once".utf8))
        do {
            _ = try await replayIterator.next()
            XCTFail("Replayed sequence must terminate the stream")
        } catch {
            XCTAssertEqual(error as? MeshSecureChannelError, .sequenceViolation)
        }
        await replayChannels.close()
    }

    func testOutOfOrderAndOversizedEncryptedRecordsTerminateBeforeDelivery() async throws {
        let outOfOrderFixture = try await MeshSecureFixture.make()
        let outOfOrderChannels = try await outOfOrderFixture.connect()
        var outOfOrderIterator = outOfOrderChannels.responder.frames().makeAsyncIterator()
        let endpoints = await outOfOrderFixture.link.endpoints()
        var payload = Data([1, MeshSecureRole.initiator.rawValue])
        payload.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 1])
        payload.append(Data(repeating: 0, count: 16))
        try await endpoints.left.send(
            try MeshWireProtocol.encode(purpose: .transfer, payload: payload, limit: .encrypted)
        )
        do {
            _ = try await outOfOrderIterator.next()
            XCTFail("Out-of-order sequence must terminate")
        } catch {
            XCTAssertEqual(error as? MeshSecureChannelError, .sequenceViolation)
        }
        await outOfOrderChannels.close()

        let oversizedFixture = try await MeshSecureFixture.make()
        let oversizedChannels = try await oversizedFixture.connect()
        var oversizedIterator = oversizedChannels.responder.frames().makeAsyncIterator()
        let oversizedEndpoints = await oversizedFixture.link.endpoints()
        let declaredLength = 64 * 1_024 + 27
        let header = Data([
            0x4D, 0x43, 0x48, 1, MeshConnectionPurpose.transfer.rawValue,
            UInt8((declaredLength >> 16) & 0xff),
            UInt8((declaredLength >> 8) & 0xff),
            UInt8(declaredLength & 0xff),
        ])
        try await oversizedEndpoints.left.send(header)
        do {
            _ = try await oversizedIterator.next()
            XCTFail("Oversized encrypted record must terminate")
        } catch {
            XCTAssertEqual(error as? MeshSecureChannelError, .transportClosed)
        }
        await oversizedChannels.close()
    }

    func testEphemeralAgreementProducesUniqueSessionExporter() async throws {
        let fixture = try await MeshSecureFixture.make()
        let first = try await fixture.connect()
        let firstKey = try await first.initiator.exportKey(label: "unique", context: Data(), length: 32)
        await first.close()

        let secondLink = MeshMemoryLink()
        let second = try await fixture.connect(link: secondLink)
        let secondKey = try await second.initiator.exportKey(label: "unique", context: Data(), length: 32)

        XCTAssertNotEqual(firstKey, secondKey)
        await second.close()
    }

    func testCloseIsAwaitedIdempotentAndPreventsPostCloseDelivery() async throws {
        let fixture = try await MeshSecureFixture.make()
        let channels = try await fixture.connect()
        let stream = channels.responder.frames()
        var iterator = stream.makeAsyncIterator()

        await channels.responder.close()
        await channels.responder.close()
        await assertMeshError(.transportClosed) {
            try await channels.responder.send(Data([1]))
        }
        let afterClose = try await iterator.next()
        let closeCount = await fixture.link.closeCount(for: .right)
        XCTAssertNil(afterClose)
        XCTAssertEqual(closeCount, 1)
        let endpoints = await fixture.link.endpoints()
        try? await endpoints.left.send(
            try MeshWireProtocol.encode(
                purpose: .transfer,
                payload: Data(repeating: 0, count: 26),
                limit: .encrypted
            )
        )
        let afterInjectedPostCloseFrame = try await iterator.next()
        XCTAssertNil(afterInjectedPostCloseFrame)
        await channels.initiator.close()
    }

    func testInboundBufferOverflowFailsClosedWithoutAnUnboundedQueue() async throws {
        let channels = try await MeshSecureFixture.makeAndConnect()
        for index in 0..<129 {
            try? await channels.initiator.send(Data([UInt8(index % 251)]))
        }
        try await meshWaitUntil { await channels.responder._testOnlyTerminalError() == .overloaded }
        var iterator = channels.responder.frames().makeAsyncIterator()
        var delivered = 0
        do {
            while try await iterator.next() != nil { delivered += 1 }
            XCTFail("Overflow must finish with an error")
        } catch {
            XCTAssertEqual(error as? MeshSecureChannelError, .overloaded)
        }
        XCTAssertLessThanOrEqual(delivered, 128)
        await channels.close()
    }

    func testTruncatedEncryptedRecordAndCancelledHandshakeCloseTransport() async throws {
        let truncatedFixture = try await MeshSecureFixture.make()
        let truncatedChannels = try await truncatedFixture.connect()
        var iterator = truncatedChannels.responder.frames().makeAsyncIterator()
        let endpoints = await truncatedFixture.link.endpoints()
        let header = try MeshWireProtocol.header(
            purpose: .transfer,
            payloadLength: 26,
            limit: .encrypted
        )
        try await endpoints.left.send(header + Data(repeating: 0, count: 5))
        await endpoints.left.close()
        do {
            _ = try await iterator.next()
            XCTFail("Truncated record must terminate")
        } catch {
            XCTAssertEqual(error as? MeshSecureChannelError, .transportClosed)
        }
        await truncatedChannels.close()

        let fixture = try await MeshSecureFixture.make()
        let silent = SilentMeshByteConnection()
        let connecting = Task {
            try await MeshSecureChannel.connect(
                over: silent,
                identity: fixture.leftIdentity,
                remoteDevice: fixture.rightIdentity.id,
                transferID: fixture.transferID,
                role: .initiator,
                trustRepository: fixture.leftTrust,
                route: .lan
            )
        }
        try await meshWaitUntil { await silent.sendCount() == 1 }
        connecting.cancel()
        do {
            _ = try await connecting.value
            XCTFail("Expected handshake cancellation")
        } catch is CancellationError {}
        let closeCount = await silent.closeCount()
        XCTAssertEqual(closeCount, 1)
    }

    func testPendingSendAdmissionIsBoundedByFourMiB() async throws {
        let fixture = try await MeshSecureFixture.make()
        let channels = try await fixture.connect()
        await fixture.link.blockSends(from: .left)
        let payload = Data(repeating: 1, count: 64 * 1_024)
        let sends = (0..<64).map { _ in Task { try await channels.initiator.send(payload) } }
        try await meshWaitUntil { await channels.initiator._testOnlyPendingSendCount() == 64 }

        await assertMeshError(.overloaded) { try await channels.initiator.send(payload) }

        await channels.initiator.close()
        for send in sends { _ = try? await send.value }
        await channels.responder.close()
    }

    func testCancellationBeforeSequenceReservationDoesNotPoisonChannel() async throws {
        let fixture = try await MeshSecureFixture.make()
        let channels = try await fixture.connect()
        await fixture.link.blockSends(from: .left)
        let first = Task { try await channels.initiator.send(Data("first".utf8)) }
        try await meshWaitUntil { await channels.initiator._testOnlyPendingSendCount() == 1 }
        let cancelled = Task { try await channels.initiator.send(Data("cancelled".utf8)) }
        try await meshWaitUntil { await channels.initiator._testOnlyPendingSendCount() == 2 }

        cancelled.cancel()
        do {
            try await cancelled.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        let pendingAfterCancellation = await channels.initiator._testOnlyPendingSendCount()
        XCTAssertEqual(pendingAfterCancellation, 1)

        await fixture.link.releaseBlockedSends(from: .left)
        try await first.value
        try await channels.initiator.send(Data("still-open".utf8))
        await channels.close()
    }

    func testExistingTransferSessionsRunWithoutProtocolFork() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mesh-transfer-\(UUID().uuidString)", isDirectory: true)
        let destination = root.appendingPathComponent("received", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("payload.bin")
        let bytes = Data((0..<200_000).map { UInt8($0 % 251) })
        try bytes.write(to: source)
        let manifest = try TransferManifest.build(from: source)
        let fixture = try await MeshSecureFixture.make(transferID: manifest.id)
        let channels = try await fixture.connect()

        async let receive = ReceiveSession(
            transferID: manifest.id,
            destinationDirectory: destination,
            closeChannelOnExit: false
        ).run(on: channels.responder)
        _ = try await SendSession(manifest).run(on: channels.initiator)
        _ = try await receive

        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("payload.bin")), bytes)
        await channels.close()
    }

    func testAuthenticatedOneMiBLoopbackTwentyTimes() async throws {
        let frame = Data(repeating: 0xA5, count: 64 * 1_024)
        for _ in 0..<20 {
            let channels = try await MeshSecureFixture.makeAndConnect()
            var iterator = channels.responder.frames().makeAsyncIterator()
            for _ in 0..<16 { try await channels.initiator.send(frame) }
            for _ in 0..<16 {
                let received = try await iterator.next()
                XCTAssertEqual(received, frame)
            }
            await channels.close()
        }
    }

    private func assertConnectFails(
        fixture: MeshSecureFixture,
        rightTransferID: TransferID,
        rightRole: MeshSecureRole = .responder,
        rightRoute: ConnectionRoute = .lan
    ) async {
        let endpoints = await fixture.link.endpoints()
        async let left: MeshSecureChannel = MeshSecureChannel.connect(
            over: endpoints.left,
            identity: fixture.leftIdentity,
            remoteDevice: fixture.rightIdentity.id,
            transferID: fixture.transferID,
            role: .initiator,
            trustRepository: fixture.leftTrust,
            route: .lan
        )
        async let right: MeshSecureChannel = MeshSecureChannel.connect(
            over: endpoints.right,
            identity: fixture.rightIdentity,
            remoteDevice: fixture.leftIdentity.id,
            transferID: rightTransferID,
            role: rightRole,
            trustRepository: fixture.rightTrust,
            route: rightRoute
        )
        do {
            _ = try await (left, right)
            XCTFail("Expected authentication failure")
        } catch {
            XCTAssertTrue(
                [MeshSecureChannelError.untrustedPeer, .authenticationFailed, .transportClosed]
                    .contains(error as? MeshSecureChannelError)
            )
        }
        await endpoints.left.close()
        await endpoints.right.close()
    }
}

private struct MeshSecureFixture {
    let leftIdentity: DeviceIdentity
    let rightIdentity: DeviceIdentity
    let leftTrust: TrustRepository
    let rightTrust: TrustRepository
    let transferID: TransferID
    let link: MeshMemoryLink

    static func make(
        authorize: Bool = true,
        transferID: TransferID = TransferID(rawValue: UUID())
    ) async throws -> MeshSecureFixture {
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
        if authorize {
            _ = try await leftTrust.issueAuthorization(
                subject: right.id,
                subjectPublicKey: right.publicKey.rawRepresentation,
                timestamp: Date()
            )
            _ = try await rightTrust.issueAuthorization(
                subject: left.id,
                subjectPublicKey: left.publicKey.rawRepresentation,
                timestamp: Date()
            )
        }
        return MeshSecureFixture(
            leftIdentity: left,
            rightIdentity: right,
            leftTrust: leftTrust,
            rightTrust: rightTrust,
            transferID: transferID,
            link: MeshMemoryLink()
        )
    }

    static func makeAndConnect() async throws -> MeshSecureChannels {
        try await make().connect()
    }

    func connect(link replacement: MeshMemoryLink? = nil) async throws -> MeshSecureChannels {
        let link = replacement ?? link
        let endpoints = await link.endpoints()
        async let left = MeshSecureChannel.connect(
            over: endpoints.left,
            identity: leftIdentity,
            remoteDevice: rightIdentity.id,
            transferID: transferID,
            role: .initiator,
            trustRepository: leftTrust,
            route: .lan
        )
        async let right = MeshSecureChannel.connect(
            over: endpoints.right,
            identity: rightIdentity,
            remoteDevice: leftIdentity.id,
            transferID: transferID,
            role: .responder,
            trustRepository: rightTrust,
            route: .lan
        )
        return try await MeshSecureChannels(initiator: left, responder: right)
    }
}

private struct MeshSecureChannels {
    let initiator: MeshSecureChannel
    let responder: MeshSecureChannel

    func close() async {
        async let left: Void = initiator.close()
        async let right: Void = responder.close()
        _ = await (left, right)
    }
}

private enum MeshMemorySide: Sendable { case left, right }

private actor MeshMemoryLink {
    private struct ReceiveWaiter {
        let maximum: Int
        let continuation: CheckedContinuation<Data, Error>
    }

    private var buffers: [MeshMemorySide: Data] = [.left: Data(), .right: Data()]
    private var waiters: [MeshMemorySide: [ReceiveWaiter]] = [.left: [], .right: []]
    private var closed: Set<MeshMemorySide> = []
    private var closes: [MeshMemorySide: Int] = [:]
    private var mutateNext: Set<MeshMemorySide> = []
    private var duplicateNext: Set<MeshMemorySide> = []
    private var mutationSendNumbers: [MeshMemorySide: Set<Int>] = [:]
    private var blockedSends: Set<MeshMemorySide> = []
    private var blockedSendWaiters: [MeshMemorySide: [CheckedContinuation<Void, Error>]] = [:]
    private var sendCounts: [MeshMemorySide: Int] = [:]
    private var sentFrames: [MeshMemorySide: [Data]] = [:]

    func endpoints() -> (left: MeshMemoryEndpoint, right: MeshMemoryEndpoint) {
        (MeshMemoryEndpoint(side: .left, link: self), MeshMemoryEndpoint(side: .right, link: self))
    }

    func send(_ data: Data, from side: MeshMemorySide) async throws {
        guard !closed.contains(side) else { throw MeshWireError.connectionClosed }
        if blockedSends.contains(side) {
            try await withCheckedThrowingContinuation { blockedSendWaiters[side, default: []].append($0) }
        }
        guard !closed.contains(side) else { throw MeshWireError.connectionClosed }
        sendCounts[side, default: 0] += 1
        var delivered = data
        let sendNumber = sendCounts[side, default: 0]
        let mutateIndexed = mutationSendNumbers[side]?.remove(sendNumber) != nil
        if mutateNext.remove(side) != nil || mutateIndexed, !delivered.isEmpty {
            delivered[delivered.count - 1] ^= 0xff
        }
        sentFrames[side, default: []].append(delivered)
        let copies = duplicateNext.remove(side) == nil ? 1 : 2
        let target: MeshMemorySide = side == .left ? .right : .left
        for _ in 0..<copies { deliver(delivered, to: target) }
    }

    func receive(side: MeshMemorySide, maximum: Int) async throws -> Data {
        if let immediate = take(side: side, maximum: maximum) { return immediate }
        return try await withCheckedThrowingContinuation {
            waiters[side, default: []].append(ReceiveWaiter(maximum: maximum, continuation: $0))
        }
    }

    func close(side: MeshMemorySide) {
        guard closed.insert(side).inserted else { return }
        closes[side, default: 0] += 1
        let bothSides: [MeshMemorySide] = [.left, .right]
        for target in bothSides {
            let current = waiters[target, default: []]
            waiters[target] = []
            for waiter in current { waiter.continuation.resume(throwing: MeshWireError.connectionClosed) }
        }
        for target in bothSides {
            let current = blockedSendWaiters[target, default: []]
            blockedSendWaiters[target] = []
            for waiter in current { waiter.resume(throwing: MeshWireError.connectionClosed) }
        }
    }

    func mutateNextFrame(from side: MeshMemorySide) { mutateNext.insert(side) }
    func mutateNextSecureFrame(from side: MeshMemorySide) { mutateNext.insert(side) }
    func mutateSend(number: Int, from side: MeshMemorySide) {
        mutationSendNumbers[side, default: []].insert(number)
    }
    func duplicateNextSecureFrame(from side: MeshMemorySide) { duplicateNext.insert(side) }
    func blockSends(from side: MeshMemorySide) { blockedSends.insert(side) }
    func releaseBlockedSends(from side: MeshMemorySide) {
        blockedSends.remove(side)
        let current = blockedSendWaiters[side, default: []]
        blockedSendWaiters[side] = []
        for waiter in current { waiter.resume() }
    }
    func closeCount(for side: MeshMemorySide) -> Int { closes[side, default: 0] }
    func lastFrame(from side: MeshMemorySide) -> Data? { sentFrames[side]?.last }

    private func deliver(_ data: Data, to side: MeshMemorySide) {
        buffers[side, default: Data()].append(data)
        guard !waiters[side, default: []].isEmpty else { return }
        let waiter = waiters[side]!.removeFirst()
        guard let chunk = take(side: side, maximum: waiter.maximum) else { return }
        waiter.continuation.resume(returning: chunk)
    }

    private func take(side: MeshMemorySide, maximum: Int) -> Data? {
        guard !buffers[side, default: Data()].isEmpty else {
            let peer: MeshMemorySide = side == .left ? .right : .left
            return closed.contains(side) || closed.contains(peer) ? Data() : nil
        }
        let count = min(maximum, buffers[side, default: Data()].count)
        let chunk = Data(buffers[side, default: Data()].prefix(count))
        buffers[side]?.removeFirst(count)
        return chunk
    }
}

private final class MeshMemoryEndpoint: MeshByteConnection, @unchecked Sendable {
    private let side: MeshMemorySide
    private let link: MeshMemoryLink

    init(side: MeshMemorySide, link: MeshMemoryLink) {
        self.side = side
        self.link = link
    }

    func send(_ bytes: Data) async throws { try await link.send(bytes, from: side) }
    func receive(minimum: Int, maximum: Int) async throws -> Data {
        try await link.receive(side: side, maximum: maximum)
    }
    func close() async { await link.close(side: side) }
}

private actor SilentMeshByteConnection: MeshByteConnection {
    private var sends = 0
    private var closes = 0
    private var waiters: [CheckedContinuation<Data, Error>] = []

    func send(_ bytes: Data) { sends += 1 }
    func receive(minimum: Int, maximum: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { waiters.append($0) }
    }
    func close() {
        guard closes == 0 else { return }
        closes = 1
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume(throwing: CancellationError()) }
    }
    func sendCount() -> Int { sends }
    func closeCount() -> Int { closes }
}

private func assertMeshError<T>(
    _ expected: MeshSecureChannelError,
    operation: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await operation()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? MeshSecureChannelError, expected, file: file, line: line)
    }
}

private func meshWaitUntil(
    timeout: Duration = .seconds(2),
    predicate: @escaping @Sendable () async -> Bool
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            while !(await predicate()) { try await Task.sleep(for: .milliseconds(5)) }
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw MeshSecureTestTimeout()
        }
        _ = try await group.next()
        group.cancelAll()
    }
}

private struct MeshSecureTestTimeout: Error {}
