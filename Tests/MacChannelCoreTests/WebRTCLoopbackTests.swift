import CryptoKit
import Foundation
import XCTest
@testable import MacChannelCore

final class WebRTCLoopbackTests: XCTestCase {
    func testOrderedReliableLoopbackTransfersOneMiBIn64KiBFrames() async throws {
        let leftIdentity = try DeviceIdentity.ephemeral()
        let rightIdentity = try DeviceIdentity.ephemeral()
        let bus = InMemoryWebRTCSignalBus()
        let connectionID = UUID()
        let factory = WebRTCFactory(connectionTimeout: .seconds(15))
        let ice = ICEConfiguration(stunURLs: [], turnServers: [])

        async let left = factory.connect(
            localIdentity: leftIdentity,
            remoteDevice: rightIdentity.id,
            remotePublicKey: rightIdentity.publicKey.rawRepresentation,
            connectionID: connectionID,
            role: .offerer,
            route: .lan,
            ice: ice,
            signaling: bus.endpoint(for: leftIdentity.id)
        )
        async let right = factory.connect(
            localIdentity: rightIdentity,
            remoteDevice: leftIdentity.id,
            remotePublicKey: leftIdentity.publicKey.rawRepresentation,
            connectionID: connectionID,
            role: .answerer,
            route: .lan,
            ice: ice,
            signaling: bus.endpoint(for: rightIdentity.id)
        )
        let (leftChannel, rightChannel) = try await (left, right)

        let expected = Data((0..<(1024 * 1024)).map { UInt8($0 % 251) })
        let receiver = Task { () throws -> Data in
            var received = Data()
            for try await frame in rightChannel.frames() {
                received.append(frame)
                if received.count == expected.count { return received }
            }
            return received
        }
        for offset in stride(from: 0, to: expected.count, by: WebRTCSecureChannel.maximumMessageBytes) {
            let end = min(offset + WebRTCSecureChannel.maximumMessageBytes, expected.count)
            try await leftChannel.send(expected.subdata(in: offset..<end))
        }

        let received = try await receiver.value
        XCTAssertEqual(received, expected)
        XCTAssertEqual(leftChannel.route, .lan)
        XCTAssertEqual(rightChannel.route, .lan)
        XCTAssertTrue(leftChannel.isOrderedReliable)
        XCTAssertTrue(rightChannel.isOrderedReliable)

        let context = Data("transfer-42".utf8)
        let leftKey = try await leftChannel.exportKey(label: "file-content", context: context, length: 32)
        let rightKey = try await rightChannel.exportKey(label: "file-content", context: context, length: 32)
        let manifestKey = try await leftChannel.exportKey(label: "manifest", context: context, length: 32)
        XCTAssertEqual(leftKey, rightKey)
        XCTAssertNotEqual(leftKey, manifestKey)
        do {
            _ = try await leftChannel.exportKey(label: "file\0content", context: context, length: 32)
            XCTFail("Expected an ambiguous exporter label to be rejected")
        } catch {
            XCTAssertEqual(error as? WebRTCSecureChannelError, .invalidKeyRequest)
        }

        await leftChannel.close()
        await leftChannel.close()
        await rightChannel.close()
    }

    func testRejectsApplicationMessageLargerThan64KiB() async throws {
        let channels = try await makeLoopbackPair()

        do {
            try await channels.left.send(Data(repeating: 1, count: WebRTCSecureChannel.maximumMessageBytes + 1))
            XCTFail("Expected an oversized message to be rejected")
        } catch {
            XCTAssertEqual(error as? WebRTCSecureChannelError, .messageTooLarge)
        }

        await channels.left.close()
        await channels.right.close()
    }

    func testRejectsReceivedMessageLargerThan64KiB() async throws {
        let channels = try await makeLoopbackPair()
        var iterator = channels.right.frames().makeAsyncIterator()

        XCTAssertTrue(channels.left._testOnlySendRawFrame(Data(
            repeating: 1,
            count: WebRTCSecureChannel.maximumMessageBytes + 1
        )))

        do {
            _ = try await iterator.next()
            XCTFail("Expected an oversized inbound message to close the channel")
        } catch {
            XCTAssertEqual(error as? WebRTCSecureChannelError, .messageTooLarge)
        }
        await channels.left.close()
        await channels.right.close()
    }

    func testTwoLegSignalingMITMCannotDeriveTheEndToEndExporter() async throws {
        let channels = try await makeLoopbackPair()
        let label = "file-content"
        let context = Data("mitm-regression".utf8)
        let actual = try await channels.left.exportKey(label: label, context: context, length: 32)
        let material = try await channels.left._testOnlyHandshakePublicMaterial()
        let leftPublicKey = try P256.KeyAgreement.PublicKey(
            rawRepresentation: material.localAgreementPublicKey
        )
        let rightPublicKey = try P256.KeyAgreement.PublicKey(
            rawRepresentation: material.remoteAgreementPublicKey
        )
        let proxyLeftLeg = P256.KeyAgreement.PrivateKey()
        let proxyRightLeg = P256.KeyAgreement.PrivateKey()
        let leftLegSecret = try proxyLeftLeg.sharedSecretFromKeyAgreement(with: leftPublicKey)
        let rightLegSecret = try proxyRightLeg.sharedSecretFromKeyAgreement(with: rightPublicKey)
        var salt = Data("macchannel-webrtc-export-v1".utf8)
        salt.append(material.transcriptHash)
        var info = Data(label.utf8)
        info.append(0)
        info.append(context)
        let proxyLeftKey = leftLegSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: info,
            outputByteCount: 32
        ).withUnsafeBytes { Data($0) }
        let proxyRightKey = rightLegSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: info,
            outputByteCount: 32
        ).withUnsafeBytes { Data($0) }

        XCTAssertNotEqual(proxyLeftKey, actual)
        XCTAssertNotEqual(proxyRightKey, actual)
        XCTAssertNotEqual(proxyLeftKey, proxyRightKey)
        await channels.left.close()
        await channels.right.close()
    }

    func testRemoteCloseTerminatesTheActorBackedFrameStream() async throws {
        let channels = try await makeLoopbackPair()
        let streamEnded = expectation(description: "remote frame stream ended")
        var iterator = channels.right.frames().makeAsyncIterator()
        Task {
            do {
                _ = try await iterator.next()
                XCTFail("Expected the remote frame stream to fail")
            } catch {
                XCTAssertEqual(error as? WebRTCSecureChannelError, .transportClosed)
            }
            streamEnded.fulfill()
        }

        await channels.left.close()

        await fulfillment(of: [streamEnded], timeout: 2)
        await channels.right.close()
    }

    func testActorBackedFrameStreamDoesNotDropAReceiverBurst() async throws {
        let channels = try await makeLoopbackPair()
        let expected = (0..<80).map { Data([UInt8($0)]) }
        for frame in expected { try await channels.left.send(frame) }
        try await Task.sleep(for: .milliseconds(100))
        let allReceived = expectation(description: "all buffered frames received")
        let recorder = ReceivedFrameRecorder()
        Task {
            do {
                for try await frame in channels.right.frames() {
                    await recorder.append(frame)
                    if await recorder.count == expected.count {
                        allReceived.fulfill()
                        return
                    }
                }
            } catch {}
        }

        await fulfillment(of: [allReceived], timeout: 2)
        let received = await recorder.frames
        XCTAssertEqual(received, expected)
        await channels.left.close()
        await channels.right.close()
    }

    func testCancellingConnectionDoesNotWaitForTheRouteTimeout() async throws {
        let local = try DeviceIdentity.ephemeral()
        let remote = try DeviceIdentity.ephemeral()
        let factory = WebRTCFactory(connectionTimeout: .seconds(30))
        let task = Task {
            try await factory.connect(
                localIdentity: local,
                remoteDevice: remote.id,
                remotePublicKey: remote.publicKey.rawRepresentation,
                connectionID: UUID(),
                role: .offerer,
                route: .lan,
                ice: ICEConfiguration(stunURLs: [], turnServers: []),
                signaling: NeverSignalTransport()
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let cancelled = expectation(description: "cancelled connection returned")
        Task {
            do {
                _ = try await task.value
                XCTFail("Expected cancellation")
            } catch is CancellationError {
                // Expected.
            } catch {
                XCTFail("Expected CancellationError, got \(error)")
            }
            cancelled.fulfill()
        }

        await fulfillment(of: [cancelled], timeout: 1)
    }

    func testAuthenticatedApplicationFrameMayStartWithHandshakeMagic() async throws {
        let channels = try await makeLoopbackPair()
        let frame = Data("MACCHANNEL-HANDSHAKE-1\nthis-is-application-data".utf8)
        var iterator = channels.right.frames().makeAsyncIterator()

        try await channels.left.send(frame)

        let received = try await iterator.next()
        XCTAssertEqual(received, frame)
        await channels.left.close()
        await channels.right.close()
    }

    private func makeLoopbackPair() async throws -> (left: WebRTCSecureChannel, right: WebRTCSecureChannel) {
        let leftIdentity = try DeviceIdentity.ephemeral()
        let rightIdentity = try DeviceIdentity.ephemeral()
        let bus = InMemoryWebRTCSignalBus()
        let connectionID = UUID()
        let factory = WebRTCFactory(connectionTimeout: .seconds(15))
        let ice = ICEConfiguration(stunURLs: [], turnServers: [])
        async let left = factory.connect(
            localIdentity: leftIdentity,
            remoteDevice: rightIdentity.id,
            remotePublicKey: rightIdentity.publicKey.rawRepresentation,
            connectionID: connectionID,
            role: .offerer,
            route: .lan,
            ice: ice,
            signaling: bus.endpoint(for: leftIdentity.id)
        )
        async let right = factory.connect(
            localIdentity: rightIdentity,
            remoteDevice: leftIdentity.id,
            remotePublicKey: leftIdentity.publicKey.rawRepresentation,
            connectionID: connectionID,
            role: .answerer,
            route: .lan,
            ice: ice,
            signaling: bus.endpoint(for: rightIdentity.id)
        )
        return try await (left, right)
    }
}

private actor ReceivedFrameRecorder {
    private(set) var frames: [Data] = []
    var count: Int { frames.count }
    func append(_ frame: Data) { frames.append(frame) }
}

private actor NeverSignalTransport: WebRTCSignalTransport {
    private let stream: AsyncThrowingStream<WebRTCSignalMessage, Error>
    private let continuation: AsyncThrowingStream<WebRTCSignalMessage, Error>.Continuation

    init() {
        var continuation: AsyncThrowingStream<WebRTCSignalMessage, Error>.Continuation!
        stream = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
    }

    func messages(from remoteDevice: DeviceID, connectionID: UUID) async -> AsyncThrowingStream<WebRTCSignalMessage, Error> {
        _ = remoteDevice
        _ = connectionID
        return stream
    }

    func send(_ message: WebRTCSignalMessage, to remoteDevice: DeviceID, connectionID: UUID) async throws {
        _ = message
        _ = remoteDevice
        _ = connectionID
    }
}

private actor InMemoryWebRTCSignalBus {
    struct Key: Hashable {
        let recipient: DeviceID
        let sender: DeviceID
        let connectionID: UUID
    }

    private var subscribers: [Key: AsyncThrowingStream<WebRTCSignalMessage, Error>.Continuation] = [:]
    private var pending: [Key: [WebRTCSignalMessage]] = [:]

    nonisolated func endpoint(for localDevice: DeviceID) -> InMemoryWebRTCSignalEndpoint {
        InMemoryWebRTCSignalEndpoint(localDevice: localDevice, bus: self)
    }

    func stream(local: DeviceID, remote: DeviceID, connectionID: UUID) -> AsyncThrowingStream<WebRTCSignalMessage, Error> {
        let key = Key(recipient: local, sender: remote, connectionID: connectionID)
        return AsyncThrowingStream { continuation in
            subscribers[key] = continuation
            for message in pending.removeValue(forKey: key) ?? [] { continuation.yield(message) }
        }
    }

    func send(_ message: WebRTCSignalMessage, from: DeviceID, to: DeviceID, connectionID: UUID) {
        let key = Key(recipient: to, sender: from, connectionID: connectionID)
        if let continuation = subscribers[key] {
            continuation.yield(message)
        } else {
            pending[key, default: []].append(message)
        }
    }
}

private struct InMemoryWebRTCSignalEndpoint: WebRTCSignalTransport {
    let localDevice: DeviceID
    let bus: InMemoryWebRTCSignalBus

    func messages(from remoteDevice: DeviceID, connectionID: UUID) async -> AsyncThrowingStream<WebRTCSignalMessage, Error> {
        await bus.stream(local: localDevice, remote: remoteDevice, connectionID: connectionID)
    }

    func send(_ message: WebRTCSignalMessage, to remoteDevice: DeviceID, connectionID: UUID) async throws {
        await bus.send(message, from: localDevice, to: remoteDevice, connectionID: connectionID)
    }
}
