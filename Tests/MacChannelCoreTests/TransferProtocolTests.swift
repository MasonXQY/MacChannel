import CryptoKit
import Foundation
import XCTest

@testable import MacChannelCore

final class TransferProtocolTests: XCTestCase {
    func testManifestBuildsForAFileWithoutLoadingItIntoTheProtocol() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("payload.bin")
        let bytes = Data((0..<200_000).map { UInt8($0 % 251) })
        try bytes.write(to: source)

        let manifest = try TransferManifest.build(from: source)

        XCTAssertEqual(manifest.entries.count, 1)
        XCTAssertEqual(manifest.entries[0].relativePath.string, "payload.bin")
        XCTAssertEqual(manifest.entries[0].size, UInt64(bytes.count))
        XCTAssertEqual(manifest.entries[0].digest, Data(SHA256.hash(data: bytes)))
        XCTAssertGreaterThan(manifest.entries[0].chunkCount, 1)
    }

    func testManifestRecursivelyBuildsNormalizedDirectoryEntries() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = parent.appendingPathComponent("shared", isDirectory: true)
        let nested = source.appendingPathComponent("caf\u{00E9}", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try Data("hello".utf8).write(to: nested.appendingPathComponent("note.txt"))

        let manifest = try TransferManifest.build(from: source)

        XCTAssertEqual(
            manifest.entries.map(\.relativePath.string),
            [
                "shared", "shared/caf\u{00E9}", "shared/caf\u{00E9}/note.txt",
            ])
        XCTAssertEqual(manifest.entries.map(\.kind), [.directory, .directory, .file])
    }

    func testVersionedBinaryOfferRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("private-name.txt")
        try Data("secret".utf8).write(to: source)
        let manifest = try TransferManifest.build(from: source)

        let encoded = try TransferFrame.offer(manifest).encode()
        let decoded = try TransferFrame.decode(encoded)

        guard case .offer(let decodedManifest) = decoded else {
            return XCTFail("Expected an offer")
        }
        XCTAssertEqual(decodedManifest.id, manifest.id)
        XCTAssertEqual(decodedManifest.entries[0].relativePath, manifest.entries[0].relativePath)
        XCTAssertNil(decodedManifest.entries[0].sourceURL)
    }

    func testTamperedEncryptedFrameIsRejectedAndHidesManifestPath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("private-name.txt")
        try Data("secret".utf8).write(to: source)
        let manifest = try TransferManifest.build(from: source)
        let cipher = try ChunkCipher(key: Data(repeating: 7, count: 32))
        var sealed = try cipher.seal(
            TransferFrame.offer(manifest).encode(),
            transfer: manifest.id,
            sequence: 0,
            direction: .senderToReceiver
        )

        XCTAssertLessThanOrEqual(
            sealed.wireData.count, TransferProtocolLimits.maximumWireFrameBytes)
        XCTAssertFalse(sealed.wireData.contains(Data("private-name.txt".utf8)))
        sealed.ciphertext[sealed.ciphertext.startIndex] ^= 1
        XCTAssertThrowsError(try cipher.open(sealed)) { error in
            XCTAssertEqual(error as? TransferProtocolError, .authenticationFailed)
        }
    }

    func testReconnectResumesWithoutResendingVerifiedChunks() async throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = fixtureDirectory.appendingPathComponent("received", isDirectory: true)
        try FileManager.default.createDirectory(
            at: fixtureDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let source = fixtureDirectory.appendingPathComponent("payload.bin")
        let bytes = Data(
            (0..<(TransferProtocolLimits.maximumChunkBytes * 4)).map {
                UInt8($0 % 251)
            })
        try bytes.write(to: source)
        let manifest = try TransferManifest.build(from: source)

        let interrupted = TestSecureChannelPair.make(failSenderAfter: 3)
        async let interruptedReceive: TransferReceiveResult = ReceiveSession(
            transferID: manifest.id,
            destinationDirectory: destination
        ).run(on: interrupted.receiver)
        do {
            _ = try await SendSession(manifest).run(on: interrupted.sender)
            XCTFail("Expected the first connection to be interrupted")
        } catch {
            // Expected; the receiver keeps only chunks it wrote and verified.
        }
        _ = try? await interruptedReceive

        let resumed = TestSecureChannelPair.make()
        async let receive: TransferReceiveResult = ReceiveSession(
            transferID: manifest.id,
            destinationDirectory: destination
        ).run(on: resumed.receiver)
        let sent = try await SendSession(manifest).run(on: resumed.sender)
        _ = try await receive

        XCTAssertEqual(sent.chunkCoordinates.map(\.chunkIndex), [2, 3])
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("payload.bin")),
            bytes
        )
    }

    func testCorruptedStagedChunkIsNotAdvertisedForResume() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent("received", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("payload.bin")
        let bytes = Data(
            (0..<(TransferProtocolLimits.maximumChunkBytes * 4)).map {
                UInt8($0 % 239)
            })
        try bytes.write(to: source)
        let manifest = try TransferManifest.build(from: source)
        let interrupted = TestSecureChannelPair.make(failSenderAfter: 3)
        async let interruptedReceive = ReceiveSession(
            transferID: manifest.id,
            destinationDirectory: destination
        ).run(on: interrupted.receiver)
        _ = try? await SendSession(manifest).run(on: interrupted.sender)
        _ = try? await interruptedReceive

        let stagingFile =
            destination
            .appendingPathComponent(
                ".macchannel-\(manifest.id.rawValue.uuidString.lowercased()).partial"
            )
            .appendingPathComponent("payload.bin")
        let handle = try FileHandle(forWritingTo: stagingFile)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data([bytes[0] ^ 0xff]))
        try handle.synchronize()
        try handle.close()

        let resumed = TestSecureChannelPair.make()
        async let receive = ReceiveSession(
            transferID: manifest.id,
            destinationDirectory: destination
        ).run(on: resumed.receiver)
        let result = try await SendSession(manifest).run(on: resumed.sender)
        _ = try await receive

        XCTAssertEqual(result.chunkIndexes, [0, 2, 3])
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("payload.bin")),
            bytes
        )
    }

    func testReceiverRejectsSymlinkEscapeInItsStagingTree() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent("received", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("payload.bin")
        let outside = directory.appendingPathComponent("outside.bin")
        try Data("source".utf8).write(to: source)
        try Data("must remain unchanged".utf8).write(to: outside)
        let manifest = try TransferManifest.build(from: source)
        let staging = destination.appendingPathComponent(
            ".macchannel-\(manifest.id.rawValue.uuidString.lowercased()).partial",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: staging.appendingPathComponent("payload.bin"),
            withDestinationURL: outside
        )
        let channels = TestSecureChannelPair.make()
        async let receive = ReceiveSession(
            transferID: manifest.id,
            destinationDirectory: destination
        ).run(on: channels.receiver)

        do {
            _ = try await SendSession(manifest).run(on: channels.sender)
            XCTFail("Expected sender to receive a destination error")
        } catch {
            XCTAssertEqual(error as? TransferProtocolError, .destinationEscape)
        }
        do {
            _ = try await receive
            XCTFail("Expected receiver to reject the symlink")
        } catch {
            XCTAssertEqual(error as? TransferProtocolError, .destinationEscape)
        }
        XCTAssertEqual(try Data(contentsOf: outside), Data("must remain unchanged".utf8))
    }

    func testProtocolMetadataCannotCollideWithAValidSourceName() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent("received", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent(".resume-state")
        try Data("ordinary user file".utf8).write(to: source)
        let manifest = try TransferManifest.build(from: source)
        let channels = TestSecureChannelPair.make()

        async let receive = ReceiveSession(
            transferID: manifest.id,
            destinationDirectory: destination
        ).run(on: channels.receiver)
        _ = try await SendSession(manifest).run(on: channels.sender)
        _ = try await receive

        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent(".resume-state")),
            Data("ordinary user file".utf8)
        )
    }

    func testNestedDirectoryTransferProducesOneVerifiedRoot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = directory.appendingPathComponent("folder", isDirectory: true)
        let nested = source.appendingPathComponent("nested", isDirectory: true)
        let emptyDirectory = source.appendingPathComponent("empty", isDirectory: true)
        let destination = directory.appendingPathComponent("received", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: emptyDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: source.appendingPathComponent("zero.bin"))
        try Data("nested payload".utf8).write(to: nested.appendingPathComponent("note.txt"))
        let manifest = try TransferManifest.build(from: source)
        let channels = TestSecureChannelPair.make()

        async let receive = ReceiveSession(
            transferID: manifest.id,
            destinationDirectory: destination
        ).run(on: channels.receiver)
        _ = try await SendSession(manifest).run(on: channels.sender)
        let result = try await receive

        XCTAssertEqual(result.receivedURLs, [destination.appendingPathComponent("folder")])
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("folder/nested/note.txt")),
            Data("nested payload".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("folder/zero.bin")),
            Data()
        )
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("folder/empty").path,
                isDirectory: &isDirectory
            ))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testRelativePathsAndEscapingSourceSymlinksAreRejected() throws {
        for path in ["/absolute", "../escape", "safe/../escape", "safe\0name", "a//b"] {
            XCTAssertThrowsError(try RelativePath(path)) { error in
                XCTAssertEqual(error as? TransferProtocolError, .invalidRelativePath)
            }
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = directory.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outside = directory.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("escape"),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(try TransferManifest.build(from: source)) { error in
            XCTAssertEqual(error as? TransferProtocolError, .symlinkEscape)
        }
    }

    func testMaximumChunkFitsTheChannelCapIncludingAuthenticationOverhead() throws {
        let transferID = TransferID(rawValue: UUID())
        let chunk = try TransferChunk(
            coordinate: ChunkCoordinate(entryIndex: 0, chunkIndex: 0),
            offset: 0,
            data: Data(repeating: 1, count: TransferProtocolLimits.maximumChunkBytes)
        )
        let cipher = try ChunkCipher(key: Data(repeating: 9, count: 32))
        let sealed = try cipher.seal(
            TransferFrame.chunk(chunk).encode(),
            transfer: transferID,
            sequence: 0,
            direction: .senderToReceiver
        )

        XCTAssertEqual(sealed.wireData.count, TransferProtocolLimits.maximumWireFrameBytes)
    }

    func testReplayAndOutOfOrderSequenceIsRejectedBeforeFrameDecode() throws {
        let transferID = TransferID(rawValue: UUID())
        let cipher = try ChunkCipher(key: Data(repeating: 3, count: 32))
        let sealed = try cipher.seal(
            TransferFrame.pause.encode(),
            transfer: transferID,
            sequence: 4,
            direction: .senderToReceiver
        )

        XCTAssertThrowsError(
            try cipher.openWire(
                sealed.wireData,
                expectedTransfer: transferID,
                expectedSequence: 3,
                expectedDirection: .senderToReceiver
            )
        ) { error in
            XCTAssertEqual(error as? TransferProtocolError, .replayOrOutOfOrder)
        }
    }

    func testReconnectCannotReuseNonceWhenExporterKeyAndSequenceRepeat() throws {
        let transferID = TransferID(rawValue: UUID())
        let cipher = try ChunkCipher(key: Data(repeating: 2, count: 32))
        let plaintext = try TransferFrame.pause.encode()

        let first = try cipher.seal(
            plaintext,
            transfer: transferID,
            sequence: 0,
            direction: .senderToReceiver
        )
        let reconnectCipher = try ChunkCipher(key: Data(repeating: 2, count: 32))
        let reconnect = try reconnectCipher.seal(
            plaintext,
            transfer: transferID,
            sequence: 0,
            direction: .senderToReceiver
        )

        XCTAssertNotEqual(first.wireData, reconnect.wireData)
        XCTAssertEqual(try cipher.open(first), plaintext)
        XCTAssertEqual(try cipher.open(reconnect), plaintext)
    }

    func testSenderStopsAtSixtyFourChunksUntilAcknowledged() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("window.bin")
        try Data(
            repeating: 5,
            count: TransferProtocolLimits.maximumChunkBytes * 65
        ).write(to: source)
        let manifest = try TransferManifest.build(from: source)
        let channels = TestSecureChannelPair.make()
        let crypto = try await TransferCryptographicContext.make(
            on: channels.receiver,
            transfer: manifest.id
        )
        var inboundSequence: UInt64 = 0
        var outboundSequence: UInt64 = 0
        var iterator = channels.receiver.frames().makeAsyncIterator()
        let sender = Task { try await SendSession(manifest).run(on: channels.sender) }

        guard
            case .offer = try await receive(
                from: &iterator,
                transferID: manifest.id,
                direction: .senderToReceiver,
                cipher: crypto.senderToReceiver,
                sequence: &inboundSequence
            )
        else { return XCTFail("Expected offer") }
        try await send(
            .accept(try ResumeMap()),
            transferID: manifest.id,
            direction: .receiverToSender,
            on: channels.receiver,
            cipher: crypto.receiverToSender,
            sequence: &outboundSequence
        )
        for expectedIndex in 0..<UInt32(64) {
            guard
                case .chunk(let chunk) = try await receive(
                    from: &iterator,
                    transferID: manifest.id,
                    direction: .senderToReceiver,
                    cipher: crypto.senderToReceiver,
                    sequence: &inboundSequence
                )
            else { return XCTFail("Expected chunk") }
            XCTAssertEqual(chunk.coordinate.chunkIndex, expectedIndex)
        }
        try await Task.sleep(for: .milliseconds(50))
        let sentBeforeAcknowledgement = await channels.sender.sentCount()
        XCTAssertEqual(sentBeforeAcknowledgement, 65, "offer plus exactly 64 chunks")

        try await send(
            .ackRanges(
                try ResumeMap(ranges: [
                    try ChunkRange(entryIndex: 0, lowerBound: 0, upperBound: 64)
                ])),
            transferID: manifest.id,
            direction: .receiverToSender,
            on: channels.receiver,
            cipher: crypto.receiverToSender,
            sequence: &outboundSequence
        )
        guard
            case .chunk(let lastChunk) = try await receive(
                from: &iterator,
                transferID: manifest.id,
                direction: .senderToReceiver,
                cipher: crypto.senderToReceiver,
                sequence: &inboundSequence
            )
        else { return XCTFail("Expected final chunk") }
        XCTAssertEqual(lastChunk.coordinate.chunkIndex, 64)
        guard
            case .complete = try await receive(
                from: &iterator,
                transferID: manifest.id,
                direction: .senderToReceiver,
                cipher: crypto.senderToReceiver,
                sequence: &inboundSequence
            )
        else { return XCTFail("Expected completion request") }
        try await send(
            .ackRanges(
                try ResumeMap(ranges: [
                    try ChunkRange(entryIndex: 0, lowerBound: 0, upperBound: 65)
                ])),
            transferID: manifest.id,
            direction: .receiverToSender,
            on: channels.receiver,
            cipher: crypto.receiverToSender,
            sequence: &outboundSequence
        )
        try await send(
            .complete,
            transferID: manifest.id,
            direction: .receiverToSender,
            on: channels.receiver,
            cipher: crypto.receiverToSender,
            sequence: &outboundSequence
        )
        let result = try await sender.value
        XCTAssertEqual(result.chunkCoordinates.count, 65)
    }

    func testReceiverAcknowledgesAContinuousRangeAtSixteenChunks() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent("received", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("ack.bin")
        let bytes = Data(
            repeating: 6,
            count: TransferProtocolLimits.maximumChunkBytes * 17
        )
        try bytes.write(to: source)
        let manifest = try TransferManifest.build(from: source)
        let channels = TestSecureChannelPair.make()
        let crypto = try await TransferCryptographicContext.make(
            on: channels.sender,
            transfer: manifest.id
        )
        var outboundSequence: UInt64 = 0
        var inboundSequence: UInt64 = 0
        var iterator = channels.sender.frames().makeAsyncIterator()
        let receiver = Task {
            try await ReceiveSession(
                transferID: manifest.id,
                destinationDirectory: destination
            ).run(on: channels.receiver)
        }

        try await send(
            .offer(manifest),
            transferID: manifest.id,
            direction: .senderToReceiver,
            on: channels.sender,
            cipher: crypto.senderToReceiver,
            sequence: &outboundSequence
        )
        guard
            case .accept = try await receive(
                from: &iterator,
                transferID: manifest.id,
                direction: .receiverToSender,
                cipher: crypto.receiverToSender,
                sequence: &inboundSequence
            )
        else { return XCTFail("Expected accept") }
        for index in 0..<UInt32(16) {
            let offset = Int(index) * TransferProtocolLimits.maximumChunkBytes
            try await send(
                .chunk(
                    try TransferChunk(
                        coordinate: ChunkCoordinate(entryIndex: 0, chunkIndex: index),
                        offset: UInt64(offset),
                        data: bytes.subdata(
                            in: offset..<(offset + TransferProtocolLimits.maximumChunkBytes))
                    )),
                transferID: manifest.id,
                direction: .senderToReceiver,
                on: channels.sender,
                cipher: crypto.senderToReceiver,
                sequence: &outboundSequence
            )
        }
        guard
            case .ackRanges(let map) = try await receive(
                from: &iterator,
                transferID: manifest.id,
                direction: .receiverToSender,
                cipher: crypto.receiverToSender,
                sequence: &inboundSequence
            )
        else { return XCTFail("Expected range ACK") }
        XCTAssertEqual(
            map.ranges,
            [
                try ChunkRange(entryIndex: 0, lowerBound: 0, upperBound: 16)
            ])
        try await send(
            .cancel,
            transferID: manifest.id,
            direction: .senderToReceiver,
            on: channels.sender,
            cipher: crypto.senderToReceiver,
            sequence: &outboundSequence
        )
        do {
            _ = try await receiver.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? TransferProtocolError, .cancelled)
        }
    }

    func testReceiverFlushesAcknowledgementAfterTwoHundredFiftyMilliseconds() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent("received", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("timer.bin")
        let bytes = Data(
            repeating: 8,
            count: TransferProtocolLimits.maximumChunkBytes * 2
        )
        try bytes.write(to: source)
        let manifest = try TransferManifest.build(from: source)
        let channels = TestSecureChannelPair.make()
        let crypto = try await TransferCryptographicContext.make(
            on: channels.sender,
            transfer: manifest.id
        )
        var outboundSequence: UInt64 = 0
        var inboundSequence: UInt64 = 0
        var iterator = channels.sender.frames().makeAsyncIterator()
        let receiver = Task {
            try await ReceiveSession(
                transferID: manifest.id,
                destinationDirectory: destination
            ).run(on: channels.receiver)
        }
        try await send(
            .offer(manifest),
            transferID: manifest.id,
            direction: .senderToReceiver,
            on: channels.sender,
            cipher: crypto.senderToReceiver,
            sequence: &outboundSequence
        )
        _ = try await receive(
            from: &iterator,
            transferID: manifest.id,
            direction: .receiverToSender,
            cipher: crypto.receiverToSender,
            sequence: &inboundSequence
        )
        try await send(
            .chunk(
                try TransferChunk(
                    coordinate: ChunkCoordinate(entryIndex: 0, chunkIndex: 0),
                    offset: 0,
                    data: bytes.prefix(TransferProtocolLimits.maximumChunkBytes)
                )),
            transferID: manifest.id,
            direction: .senderToReceiver,
            on: channels.sender,
            cipher: crypto.senderToReceiver,
            sequence: &outboundSequence
        )

        try await Task.sleep(for: .milliseconds(300))
        let receiverFrameCount = await channels.receiver.sentCount()
        XCTAssertEqual(receiverFrameCount, 2, "accept plus the timer-flushed ACK")

        try await send(
            .cancel,
            transferID: manifest.id,
            direction: .senderToReceiver,
            on: channels.sender,
            cipher: crypto.senderToReceiver,
            sequence: &outboundSequence
        )
        _ = try? await receiver.value
    }

    func testReceiverRejectsDuplicateChunkWithANewFrameSequence() async throws {
        try await assertReceiverRejects(
            chunkIndexes: [0, 0],
            expected: .duplicateChunk
        )
    }

    func testReceiverRejectsOutOfOrderChunk() async throws {
        try await assertReceiverRejects(
            chunkIndexes: [1],
            expected: .replayOrOutOfOrder
        )
    }

    private func assertReceiverRejects(
        chunkIndexes: [UInt32],
        expected: TransferProtocolError
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent("received", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("ordered.bin")
        let bytes = Data(
            repeating: 4,
            count: TransferProtocolLimits.maximumChunkBytes * 2
        )
        try bytes.write(to: source)
        let manifest = try TransferManifest.build(from: source)
        let channels = TestSecureChannelPair.make()
        let crypto = try await TransferCryptographicContext.make(
            on: channels.sender,
            transfer: manifest.id
        )
        var outboundSequence: UInt64 = 0
        var inboundSequence: UInt64 = 0
        var iterator = channels.sender.frames().makeAsyncIterator()
        let receiver = Task {
            try await ReceiveSession(
                transferID: manifest.id,
                destinationDirectory: destination
            ).run(on: channels.receiver)
        }
        try await send(
            .offer(manifest),
            transferID: manifest.id,
            direction: .senderToReceiver,
            on: channels.sender,
            cipher: crypto.senderToReceiver,
            sequence: &outboundSequence
        )
        _ = try await receive(
            from: &iterator,
            transferID: manifest.id,
            direction: .receiverToSender,
            cipher: crypto.receiverToSender,
            sequence: &inboundSequence
        )
        for chunkIndex in chunkIndexes {
            let offset = Int(chunkIndex) * TransferProtocolLimits.maximumChunkBytes
            try await send(
                .chunk(
                    try TransferChunk(
                        coordinate: ChunkCoordinate(entryIndex: 0, chunkIndex: chunkIndex),
                        offset: UInt64(offset),
                        data: bytes.subdata(
                            in: offset..<(offset + TransferProtocolLimits.maximumChunkBytes))
                    )),
                transferID: manifest.id,
                direction: .senderToReceiver,
                on: channels.sender,
                cipher: crypto.senderToReceiver,
                sequence: &outboundSequence
            )
        }
        do {
            _ = try await receiver.value
            XCTFail("Expected receiver rejection")
        } catch {
            XCTAssertEqual(error as? TransferProtocolError, expected)
        }
    }
}

private final class TestSecureChannel: SecureChannel, @unchecked Sendable {
    let route = ConnectionRoute.lan
    private let key: Data
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let sendGate: TestSendGate
    private weak var peer: TestSecureChannel?

    init(key: Data, failAfter: Int?) {
        self.key = key
        sendGate = TestSendGate(failAfter: failAfter)
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        stream = AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.continuation = continuation
    }

    func connect(to peer: TestSecureChannel) { self.peer = peer }

    func send(_ frame: Data) async throws {
        guard frame.count <= TransferProtocolLimits.maximumWireFrameBytes,
            let peer
        else { throw WebRTCSecureChannelError.messageTooLarge }
        guard await sendGate.permit() else {
            continuation.finish(throwing: WebRTCSecureChannelError.transportClosed)
            peer.continuation.finish(throwing: WebRTCSecureChannelError.transportClosed)
            throw WebRTCSecureChannelError.transportClosed
        }
        peer.continuation.yield(frame)
    }

    func frames() -> AsyncThrowingStream<Data, Error> { stream }

    func exportKey(label: String, context: Data, length: Int) async throws -> Data {
        XCTAssertEqual(label, "macchannel-transfer-v1")
        XCTAssertEqual(context.count, 16)
        XCTAssertEqual(length, 32)
        return key
    }

    func close() async {
        continuation.finish()
        peer?.continuation.finish()
    }

    func sentCount() async -> Int { await sendGate.count }
}

private actor TestSendGate {
    private let failAfter: Int?
    private var sent = 0

    init(failAfter: Int?) { self.failAfter = failAfter }

    func permit() -> Bool {
        guard failAfter == nil || sent < failAfter! else { return false }
        sent += 1
        return true
    }

    var count: Int { sent }
}

private enum TestSecureChannelPair {
    static func make(failSenderAfter: Int? = nil) -> (
        sender: TestSecureChannel,
        receiver: TestSecureChannel
    ) {
        let key = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        let sender = TestSecureChannel(key: key, failAfter: failSenderAfter)
        let receiver = TestSecureChannel(key: key, failAfter: nil)
        sender.connect(to: receiver)
        receiver.connect(to: sender)
        return (sender, receiver)
    }
}
