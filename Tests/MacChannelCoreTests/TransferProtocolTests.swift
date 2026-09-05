import CryptoKit
import Foundation
import XCTest

@testable import MacChannelCore

final class TransferProtocolTests: XCTestCase {
    func testReceiveResultDefaultsUnknownSourceForLegacySessions() {
        let beforeCreation = Date()
        let result = TransferReceiveResult(
            transferID: TransferID(rawValue: UUID()),
            receivedURLs: [URL(fileURLWithPath: "/tmp/report.pdf")]
        )

        XCTAssertNil(result.source)
        XCTAssertGreaterThanOrEqual(result.completedAt, beforeCreation)
        XCTAssertLessThanOrEqual(result.completedAt, Date())
    }

    func testDurableReceiveResultIncludesAuthenticatedSource() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = root.appendingPathComponent("downloads", isDirectory: true)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("report.pdf")
        try Data("received report".utf8).write(to: sourceURL)
        let manifest = try TransferManifest.build(from: sourceURL)
        let source = DeviceID(rawValue: UUID())
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        let channels = TestSecureChannelPair.make()
        let receiver = ReceiveSession(
            transferID: manifest.id,
            source: source,
            policy: ReceivePolicy(trustedSources: [source]),
            directories: DownloadDirectory(globalDirectory: destination),
            database: database,
            incomingDirectory: incoming
        )

        let beforeReceive = Date()
        async let result = receiver.run(on: channels.receiver)
        _ = try await SendSession(manifest).run(on: channels.sender)

        let received = try await result
        XCTAssertEqual(received.source, source)
        XCTAssertGreaterThanOrEqual(received.completedAt, beforeReceive)
        XCTAssertLessThanOrEqual(received.completedAt, Date())
    }

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
        let recorder = TestChunkRecorder()
        let negotiationRecorder = TestResumeNegotiationRecorder()
        async let receive: TransferReceiveResult = ReceiveSession(
            transferID: manifest.id,
            destinationDirectory: destination
        ).run(on: resumed.receiver)
        _ = try await SendSession(
            manifest,
            recorder: recorder,
            resumeObserver: negotiationRecorder
        ).run(on: resumed.sender)
        _ = try await receive

        let sentCoordinates = await recorder.coordinates
        let recordedNegotiation = await negotiationRecorder.values.last
        let negotiation = try XCTUnwrap(recordedNegotiation)
        XCTAssertEqual(sentCoordinates.map(\.chunkIndex), [2, 3])
        XCTAssertEqual(
            negotiation.resumeMap.ranges,
            [try ChunkRange(entryIndex: 0, lowerBound: 0, upperBound: 2)]
        )
        XCTAssertEqual(
            negotiation.acceptedBytes,
            UInt64(TransferProtocolLimits.maximumChunkBytes * 2)
        )
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("payload.bin")),
            bytes
        )
    }

    func testSenderUsesPinnedManifestBytesAfterSourcePathReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent("received", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("replace.bin")
        let original = Data(repeating: 0x11, count: TransferProtocolLimits.maximumChunkBytes + 7)
        try original.write(to: source)
        let manifest = try TransferManifest.build(from: source)

        try FileManager.default.removeItem(at: source)
        try Data(repeating: 0x22, count: original.count).write(to: source)
        let channels = TestSecureChannelPair.make()
        async let receive = ReceiveSession(
            transferID: manifest.id,
            destinationDirectory: destination
        ).run(on: channels.receiver)

        _ = try await SendSession(manifest).run(on: channels.sender)
        _ = try await receive

        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("replace.bin")),
            original
        )
    }

    func testSenderUsesPinnedManifestBytesAfterInPlaceSourceMutation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent("received", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("mutate.bin")
        let original = Data(repeating: 0x33, count: TransferProtocolLimits.maximumChunkBytes + 7)
        try original.write(to: source)
        let manifest = try TransferManifest.build(from: source)

        let handle = try FileHandle(forWritingTo: source)
        try handle.write(contentsOf: Data(repeating: 0x44, count: original.count))
        try handle.synchronize()
        try handle.close()
        let channels = TestSecureChannelPair.make()
        async let receive = ReceiveSession(
            transferID: manifest.id,
            destinationDirectory: destination
        ).run(on: channels.receiver)

        _ = try await SendSession(manifest).run(on: channels.sender)
        _ = try await receive

        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("mutate.bin")),
            original
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
        let recorder = TestChunkRecorder()
        async let receive = ReceiveSession(
            transferID: manifest.id,
            destinationDirectory: destination
        ).run(on: resumed.receiver)
        _ = try await SendSession(manifest, recorder: recorder).run(on: resumed.sender)
        _ = try await receive

        let sentCoordinates = await recorder.coordinates
        XCTAssertEqual(sentCoordinates.map(\.chunkIndex), [0, 2, 3])
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("payload.bin")),
            bytes
        )
    }

    func testResumeJournalRecoversValidPrefixAfterTornTail() async throws {
        let fixture = try await makeInterruptedResumeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let handle = try FileHandle(forWritingTo: fixture.journal)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data([0xde, 0xad, 0xbe, 0xef, 0x01]))
        try handle.synchronize()
        try handle.close()

        let channels = TestSecureChannelPair.make()
        async let receive = ReceiveSession(
            transferID: fixture.manifest.id,
            destinationDirectory: fixture.destination
        ).run(on: channels.receiver)
        _ = try await SendSession(fixture.manifest).run(on: channels.sender)
        _ = try await receive

        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appendingPathComponent("resume.bin")),
            fixture.bytes
        )
    }

    func testResumeJournalRejectsCorruptCompleteRecord() async throws {
        let fixture = try await makeInterruptedResumeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var journal = try Data(contentsOf: fixture.journal)
        XCTAssertGreaterThan(journal.count, 37)
        journal[journal.index(before: journal.endIndex)] ^= 0x01
        try journal.write(to: fixture.journal)

        let channels = TestSecureChannelPair.make()
        let receiver = Task {
            try await ReceiveSession(
                transferID: fixture.manifest.id,
                destinationDirectory: fixture.destination
            ).run(on: channels.receiver)
        }
        _ = try? await SendSession(fixture.manifest).run(on: channels.sender)
        do {
            _ = try await receiver.value
            XCTFail("Expected the corrupt journal record to be rejected")
        } catch {
            XCTAssertEqual(error as? TransferProtocolError, .invalidResumeMap)
        }
    }

    func testResumeInitializationRemovesRecognizedStaleCheckpoint() async throws {
        let fixture = try await makeInterruptedResumeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let checkpoint = fixture.metadata.appendingPathComponent(
            ".resume-checkpoint-\(UUID().uuidString.lowercased())"
        )
        try Data("torn checkpoint".utf8).write(to: checkpoint)

        let channels = TestSecureChannelPair.make()
        async let receive = ReceiveSession(
            transferID: fixture.manifest.id,
            destinationDirectory: fixture.destination
        ).run(on: channels.receiver)
        _ = try await SendSession(fixture.manifest).run(on: channels.sender)
        _ = try await receive

        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appendingPathComponent("resume.bin")),
            fixture.bytes
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging.path))
    }

    func testResumeCheckpointIdentitySwapDoesNotDeleteReplacement() async throws {
        let fixture = try await makeInterruptedResumeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let checkpointName = ".resume-checkpoint-\(UUID().uuidString.lowercased())"
        let checkpoint = fixture.metadata.appendingPathComponent(checkpointName)
        let replacementBytes = Data("must not be deleted".utf8)
        try Data("recognized stale checkpoint".utf8).write(to: checkpoint)
        let channels = TestSecureChannelPair.make()
        let receiver = Task {
            try await ReceiveSession(
                transferID: fixture.manifest.id,
                destinationDirectory: fixture.destination,
                onStagingPrepared: { _ in },
                onCheckpointValidated: { validatedName in
                    let validated = fixture.metadata.appendingPathComponent(validatedName)
                    let displaced = fixture.metadata.appendingPathComponent(
                        validatedName + ".displaced"
                    )
                    try! FileManager.default.moveItem(at: validated, to: displaced)
                    try! replacementBytes.write(to: validated)
                }
            ).run(on: channels.receiver)
        }

        _ = try? await SendSession(fixture.manifest).run(on: channels.sender)
        do {
            _ = try await receiver.value
            XCTFail("Expected checkpoint identity swap to fail closed")
        } catch {
            XCTAssertEqual(error as? TransferProtocolError, .destinationEscape)
        }
        let metadataEntries = try FileManager.default.contentsOfDirectory(
            at: fixture.metadata,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(
            try metadataEntries.contains { try Data(contentsOf: $0) == replacementBytes }
        )
        XCTAssertTrue(metadataEntries.contains { $0.lastPathComponent.hasSuffix(".displaced") })
    }

    func testResumeInitializationNeverDeletesUnrecognizedCheckpointName() async throws {
        let fixture = try await makeInterruptedResumeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let unrecognized = fixture.metadata.appendingPathComponent(
            ".resume-checkpoint-not-a-protocol-uuid"
        )
        try Data("user controlled".utf8).write(to: unrecognized)

        let channels = TestSecureChannelPair.make()
        let receiver = Task {
            try await ReceiveSession(
                transferID: fixture.manifest.id,
                destinationDirectory: fixture.destination
            ).run(on: channels.receiver)
        }
        _ = try? await SendSession(fixture.manifest).run(on: channels.sender)
        do {
            _ = try await receiver.value
            XCTFail("Expected unknown metadata to prevent staging cleanup")
        } catch {
            XCTAssertEqual(error as? TransferProtocolError, .destinationEscape)
        }
        XCTAssertEqual(try Data(contentsOf: unrecognized), Data("user controlled".utf8))
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

    func testReceiverFailsClosedWhenStagedFileIsSwappedAfterOpening() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent("received", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("swapped.bin")
        let outside = directory.appendingPathComponent("outside.bin")
        try Data("source bytes".utf8).write(to: source)
        try Data("outside remains".utf8).write(to: outside)
        let manifest = try TransferManifest.build(from: source)
        let channels = TestSecureChannelPair.make()
        let receiver = Task {
            try await ReceiveSession(
                transferID: manifest.id,
                destinationDirectory: destination,
                onStagingPrepared: { staging in
                    let stagedFile = staging.appendingPathComponent("swapped.bin")
                    try! FileManager.default.removeItem(at: stagedFile)
                    try! FileManager.default.linkItem(at: outside, to: stagedFile)
                }
            ).run(on: channels.receiver)
        }

        _ = try? await SendSession(manifest).run(on: channels.sender)
        do {
            _ = try await receiver.value
            XCTFail("Expected the descriptor identity check to reject the swap")
        } catch {
            XCTAssertEqual(error as? TransferProtocolError, .destinationEscape)
        }
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside remains".utf8))
    }

    func testReceiverDoesNotPublishAfterMetadataDirectoryIdentitySwap() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent("received", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("metadata-swap.bin")
        try Data("verified bytes".utf8).write(to: source)
        let manifest = try TransferManifest.build(from: source)
        let metadataName =
            ".macchannel-protocol-"
            + manifest.id.rawValue.uuidString.lowercased()
        let displacedName = metadataName + ".displaced"
        let channels = TestSecureChannelPair.make()
        let receiver = Task {
            try await ReceiveSession(
                transferID: manifest.id,
                destinationDirectory: destination,
                onStagingPrepared: { staging in
                    let metadata = staging.appendingPathComponent(
                        metadataName,
                        isDirectory: true
                    )
                    let displaced = staging.appendingPathComponent(
                        displacedName,
                        isDirectory: true
                    )
                    try! FileManager.default.moveItem(at: metadata, to: displaced)
                    try! FileManager.default.createDirectory(
                        at: metadata,
                        withIntermediateDirectories: false
                    )
                }
            ).run(on: channels.receiver)
        }

        _ = try? await SendSession(manifest).run(on: channels.sender)
        do {
            _ = try await receiver.value
            XCTFail("Expected metadata identity swap to fail closed")
        } catch {
            XCTAssertEqual(error as? TransferProtocolError, .destinationEscape)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("metadata-swap.bin").path
            )
        )
    }

    func testMetadataCleanupQuarantineDoesNotDeleteRacedReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent("received", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("metadata-quarantine.bin")
        try Data("verified bytes".utf8).write(to: source)
        let manifest = try TransferManifest.build(from: source)
        let channels = TestSecureChannelPair.make()
        let staging = destination.appendingPathComponent(
            ".macchannel-\(manifest.id.rawValue.uuidString.lowercased()).partial",
            isDirectory: true
        )
        let receiver = Task {
            try await ReceiveSession(
                transferID: manifest.id,
                destinationDirectory: destination,
                onStagingPrepared: { _ in },
                onMetadataValidated: { validatedName in
                    let validated = staging.appendingPathComponent(
                        validatedName,
                        isDirectory: true
                    )
                    let displaced = staging.appendingPathComponent(
                        validatedName + ".displaced",
                        isDirectory: true
                    )
                    try! FileManager.default.moveItem(at: validated, to: displaced)
                    try! FileManager.default.createDirectory(
                        at: validated,
                        withIntermediateDirectories: false
                    )
                }
            ).run(on: channels.receiver)
        }

        _ = try? await SendSession(manifest).run(on: channels.sender)
        do {
            _ = try await receiver.value
            XCTFail("Expected metadata quarantine identity swap to fail closed")
        } catch {
            XCTAssertEqual(error as? TransferProtocolError, .destinationEscape)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("metadata-quarantine.bin").path
            )
        )
        let entries = try FileManager.default.contentsOfDirectory(
            at: staging,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(entries.contains { $0.lastPathComponent.hasSuffix(".displaced") })
        XCTAssertTrue(
            entries.contains {
                $0.lastPathComponent.hasPrefix(".macchannel-metadata-retired-")
                    && !$0.lastPathComponent.hasSuffix(".displaced")
            }
        )
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

    func testProtocolMetadataCannotAliasCaseEquivalentManifestRoot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent("received", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let volume = try directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        try XCTSkipIf(volume.volumeSupportsCaseSensitiveNames == true)
        let source = directory.appendingPathComponent("ordinary.bin")
        let payload = Data("case-equivalent root".utf8)
        try payload.write(to: source)
        let built = try TransferManifest.build(from: source)
        let rootName =
            ".MACCHANNEL-PROTOCOL-"
            + built.id.rawValue.uuidString.uppercased()
        let original = built.entries[0]
        let manifest = TransferManifest(
            id: built.id,
            entries: [
                TransferManifestEntry(
                    relativePath: try RelativePath(rootName),
                    kind: original.kind,
                    size: original.size,
                    modificationDate: original.modificationDate,
                    chunkCount: original.chunkCount,
                    digest: original.digest,
                    pinnedSource: original.pinnedSource
                )
            ]
        )
        let channels = TestSecureChannelPair.make()

        async let receive = ReceiveSession(
            transferID: manifest.id,
            destinationDirectory: destination
        ).run(on: channels.receiver)
        _ = try await SendSession(manifest).run(on: channels.sender)
        _ = try await receive

        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent(rootName)),
            payload
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

    func testDestinationVolumeEquivalentPathsAreRejectedBeforeStaging() throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let volume = try destination.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        try XCTSkipIf(volume.volumeSupportsCaseSensitiveNames == true)
        let emptyDigest = Data(SHA256.hash(data: Data()))
        let manifest = TransferManifest(
            id: TransferID(rawValue: UUID()),
            entries: [
                TransferManifestEntry(
                    relativePath: try RelativePath("root"),
                    kind: .directory,
                    size: 0,
                    modificationDate: .now,
                    chunkCount: 0,
                    digest: emptyDigest
                ),
                TransferManifestEntry(
                    relativePath: try RelativePath("root/A"),
                    kind: .file,
                    size: 0,
                    modificationDate: .now,
                    chunkCount: 0,
                    digest: emptyDigest
                ),
                TransferManifestEntry(
                    relativePath: try RelativePath("root/a"),
                    kind: .file,
                    size: 0,
                    modificationDate: .now,
                    chunkCount: 0,
                    digest: emptyDigest
                ),
            ]
        )

        XCTAssertThrowsError(
            try manifest.validateDestinationPaths(onVolumeContaining: destination)
        ) { error in
            XCTAssertEqual(error as? TransferProtocolError, .destinationPathCollision)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.appendingPathComponent("root").path))
    }

    func testDecomposedUnicodePathIsRejectedBeforeDestinationUse() throws {
        XCTAssertThrowsError(try RelativePath("root/cafe\u{0301}.txt")) { error in
            XCTAssertEqual(error as? TransferProtocolError, .invalidRelativePath)
        }
    }

    func testManifestTraversalRejectsMoreThanMaximumEntries() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        for index in 0..<TransferProtocolLimits.maximumManifestEntries {
            XCTAssertTrue(
                FileManager.default.createFile(
                    atPath: source.appendingPathComponent("f-\(index)").path,
                    contents: nil
                ))
        }

        XCTAssertThrowsError(try TransferManifest.build(from: source)) { error in
            XCTAssertEqual(error as? TransferProtocolError, .manifestTooLarge)
        }
    }

    func testManifestPreflightRejectsAggregateBytesBeforeContentProcessing() throws {
        let chunkSize = UInt64(TransferProtocolLimits.maximumChunkBytes)
        let oversized = TransferManifest(
            id: TransferID(rawValue: UUID()),
            entries: [
                TransferManifestEntry(
                    relativePath: try RelativePath("oversized.bin"),
                    kind: .file,
                    size: TransferProtocolLimits.maximumTransferBytes + 1,
                    modificationDate: .now,
                    chunkCount: UInt32(TransferProtocolLimits.maximumTransferChunks),
                    digest: Data(repeating: 0, count: 32)
                )
            ]
        )
        XCTAssertGreaterThan(oversized.entries[0].size, chunkSize)

        XCTAssertThrowsError(try oversized.validateProtocolLimits()) { error in
            XCTAssertEqual(error as? TransferProtocolError, .manifestTooLarge)
        }
    }

    func testManifestPreflightRejectsOfferThatCannotFitAuthenticatedFrame() throws {
        let digest = Data(SHA256.hash(data: Data()))
        let entries = try (0..<100).map { index in
            TransferManifestEntry(
                relativePath: try RelativePath(
                    "root/\(index)-" + String(repeating: "p", count: 700)
                ),
                kind: .file,
                size: 0,
                modificationDate: .now,
                chunkCount: 0,
                digest: digest
            )
        }
        let manifest = TransferManifest(
            id: TransferID(rawValue: UUID()),
            entries: entries
        )

        XCTAssertThrowsError(try manifest.validateProtocolLimits()) { error in
            XCTAssertEqual(error as? TransferProtocolError, .manifestTooLarge)
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

    func testResumeMapRejectsMoreRangesThanABoundedFrameCanAdvertise() throws {
        let ranges = try (0...TransferProtocolLimits.maximumResumeRanges).map { index in
            try ChunkRange(
                entryIndex: UInt32(index),
                lowerBound: 0,
                upperBound: 1
            )
        }

        XCTAssertThrowsError(try ResumeMap(ranges: ranges)) { error in
            XCTAssertEqual(error as? TransferProtocolError, .invalidResumeMap)
        }
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

    func testReceiverChallengeRejectsRecordedFrameWhenExporterRepeats() async throws {
        let transferID = TransferID(rawValue: UUID())
        let channels = TestSecureChannelPair.make(key: Data(repeating: 0x42, count: 32))
        let oldContext = try await TransferCryptographicContext.make(
            on: channels.sender,
            transfer: transferID,
            receiverChallenge: Data(repeating: 1, count: 32)
        )
        let newContext = try await TransferCryptographicContext.make(
            on: channels.sender,
            transfer: transferID,
            receiverChallenge: Data(repeating: 2, count: 32)
        )
        let recorded = try oldContext.senderToReceiver.seal(
            TransferFrame.pause.encode(),
            transfer: transferID,
            sequence: 0,
            direction: .senderToReceiver
        )

        XCTAssertThrowsError(
            try newContext.senderToReceiver.openWire(
                recorded.wireData,
                expectedTransfer: transferID,
                expectedSequence: 0,
                expectedDirection: .senderToReceiver
            )
        ) { error in
            XCTAssertEqual(error as? TransferProtocolError, .authenticationFailed)
        }
    }

    func testRecordedOfferFromOldRunFailsInNewSameExporterSession() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let firstDestination = directory.appendingPathComponent("first", isDirectory: true)
        let secondDestination = directory.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("replay.bin")
        try Data("not replayable".utf8).write(to: source)
        let manifest = try TransferManifest.build(from: source)
        let repeatedExporter = Data(repeating: 0x42, count: 32)

        let oldChannels = TestSecureChannelPair.make(key: repeatedExporter)
        var oldIterator = oldChannels.sender.frames().makeAsyncIterator()
        let oldReceiver = Task {
            try await ReceiveSession(
                transferID: manifest.id,
                destinationDirectory: firstDestination
            ).run(on: oldChannels.receiver)
        }
        let oldCrypto = try await receiveCryptographicContext(
            from: oldChannels.sender,
            iterator: &oldIterator,
            transferID: manifest.id
        )
        let recordedOffer = try oldCrypto.senderToReceiver.seal(
            TransferFrame.offer(manifest).encode(),
            transfer: manifest.id,
            sequence: 0,
            direction: .senderToReceiver
        ).wireData
        try await oldChannels.sender.send(recordedOffer)
        var oldInboundSequence: UInt64 = 0
        _ = try await receive(
            from: &oldIterator,
            transferID: manifest.id,
            direction: .receiverToSender,
            cipher: oldCrypto.receiverToSender,
            sequence: &oldInboundSequence
        )
        var oldOutboundSequence: UInt64 = 1
        try await send(
            .cancel,
            transferID: manifest.id,
            direction: .senderToReceiver,
            on: oldChannels.sender,
            cipher: oldCrypto.senderToReceiver,
            sequence: &oldOutboundSequence
        )
        _ = try? await oldReceiver.value

        let newChannels = TestSecureChannelPair.make(key: repeatedExporter)
        var newIterator = newChannels.sender.frames().makeAsyncIterator()
        let newReceiver = Task {
            try await ReceiveSession(
                transferID: manifest.id,
                destinationDirectory: secondDestination
            ).run(on: newChannels.receiver)
        }
        _ = try await newIterator.next()  // Consume the new, different challenge.
        try await newChannels.sender.send(recordedOffer)

        do {
            _ = try await newReceiver.value
            XCTFail("Expected the recorded offer to fail under the fresh challenge")
        } catch {
            XCTAssertEqual(error as? TransferProtocolError, .authenticationFailed)
        }
    }

    func testSenderStopsAtTwoHundredFiftySixChunksUntilAcknowledged() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("window.bin")
        try Data(
            repeating: 5,
            count: TransferProtocolLimits.maximumChunkBytes * 257
        ).write(to: source)
        let manifest = try TransferManifest.build(from: source)
        let channels = TestSecureChannelPair.make()
        let challenge = TransferReceiverChallenge.fresh(for: manifest.id)
        try await channels.receiver.send(challenge.encode())
        let crypto = try await TransferCryptographicContext.make(
            on: channels.receiver,
            transfer: manifest.id,
            receiverChallenge: challenge.bytes
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
        try await Task.sleep(for: .milliseconds(50))
        let sentBeforeAcknowledgement = await channels.sender.sentCount()
        guard sentBeforeAcknowledgement == 257 else {
            await channels.receiver.close()
            _ = try? await sender.value
            return XCTFail("Expected offer plus exactly 256 chunks, got \(sentBeforeAcknowledgement)")
        }
        for expectedIndex in 0..<UInt32(256) {
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

        try await send(
            .ackRanges(
                try ResumeMap(ranges: [
                    try ChunkRange(entryIndex: 0, lowerBound: 0, upperBound: 16)
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
        XCTAssertEqual(lastChunk.coordinate.chunkIndex, 256)
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
                    try ChunkRange(entryIndex: 0, lowerBound: 0, upperBound: 257)
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
        XCTAssertEqual(result.sentChunkCount, 257)
    }

    func testSenderControlPauseResumeStopsAndRestartsChunkProduction() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent("received", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("controlled.bin")
        try Data(
            repeating: 0x61,
            count: TransferProtocolLimits.maximumChunkBytes * 2
        ).write(to: source)
        let manifest = try TransferManifest.build(from: source)
        let channels = TestSecureChannelPair.make()
        let control = TransferSessionControl()
        let recorder = TestChunkRecorder()
        await control.pause()
        let receiver = Task {
            try await ReceiveSession(
                transferID: manifest.id,
                destinationDirectory: destination
            ).run(on: channels.receiver)
        }
        let sender = Task {
            try await SendSession(
                manifest,
                recorder: recorder,
                control: control
            ).run(on: channels.sender)
        }

        try await Task.sleep(for: .milliseconds(50))
        let pausedCoordinates = await recorder.coordinates
        XCTAssertTrue(pausedCoordinates.isEmpty)
        await control.resume()
        _ = try await sender.value
        _ = try await receiver.value
        let completedCoordinates = await recorder.coordinates
        XCTAssertEqual(completedCoordinates.count, 2)
    }

    func testSenderControlCancellationTerminatesBothSidesAsCancelled() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent("received", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("cancel.bin")
        try Data(repeating: 0x71, count: TransferProtocolLimits.maximumChunkBytes * 2)
            .write(to: source)
        let manifest = try TransferManifest.build(from: source)
        let channels = TestSecureChannelPair.make()
        let control = TransferSessionControl()
        await control.cancel()
        let receiver = Task {
            try await ReceiveSession(
                transferID: manifest.id,
                destinationDirectory: destination
            ).run(on: channels.receiver)
        }

        do {
            _ = try await SendSession(manifest, control: control).run(on: channels.sender)
            XCTFail("Expected sender cancellation")
        } catch {
            XCTAssertEqual(error as? TransferProtocolError, .cancelled)
        }
        do {
            _ = try await receiver.value
            XCTFail("Expected receiver cancellation")
        } catch {
            XCTAssertEqual(error as? TransferProtocolError, .cancelled)
        }
    }

    func testControlCancelWakesSenderWaitingForRemoteResume() async throws {
        let fixture = try makeManualSenderWaitFixture(name: "remote-pause.bin")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let control = TransferSessionControl()
        let completion = TestSessionCompletion()
        let sender = Task {
            do {
                _ = try await SendSession(fixture.manifest, control: control)
                    .run(on: fixture.channels.sender)
                await completion.finish(nil)
            } catch {
                await completion.finish(error as? TransferProtocolError)
            }
        }
        var iterator = fixture.channels.receiver.frames().makeAsyncIterator()
        let crypto = try await establishManualReceiver(
            fixture: fixture
        )
        var inboundSequence: UInt64 = 0
        var outboundSequence: UInt64 = 0
        _ = try await receive(
            from: &iterator,
            transferID: fixture.manifest.id,
            direction: .senderToReceiver,
            cipher: crypto.senderToReceiver,
            sequence: &inboundSequence
        )
        try await send(
            .accept(try ResumeMap()),
            transferID: fixture.manifest.id,
            direction: .receiverToSender,
            on: fixture.channels.receiver,
            cipher: crypto.receiverToSender,
            sequence: &outboundSequence
        )
        _ = try await receive(
            from: &iterator,
            transferID: fixture.manifest.id,
            direction: .senderToReceiver,
            cipher: crypto.senderToReceiver,
            sequence: &inboundSequence
        )
        try await send(
            .pause,
            transferID: fixture.manifest.id,
            direction: .receiverToSender,
            on: fixture.channels.receiver,
            cipher: crypto.receiverToSender,
            sequence: &outboundSequence
        )
        try await Task.sleep(for: .milliseconds(20))

        await control.cancel()
        try await Task.sleep(for: .milliseconds(150))
        let completedWithoutPeerResume = await completion.isFinished
        if !completedWithoutPeerResume { await fixture.channels.receiver.close() }
        await sender.value

        XCTAssertTrue(completedWithoutPeerResume)
        let remotePauseError = await completion.protocolError
        XCTAssertEqual(remotePauseError, .cancelled)
    }

    func testFrameControlSelectionNeverDiscardsAlreadyDequeuedFrame() async throws {
        let control = TransferSessionControl()
        let staleSnapshot = await control.snapshot()
        await control.pause()
        let frames: [TransferFrame] = [
            .chunk(
                try TransferChunk(
                    coordinate: ChunkCoordinate(entryIndex: 0, chunkIndex: 0),
                    offset: 0,
                    data: Data([1])
                )
            ),
            .ackRanges(
                try ResumeMap(ranges: [
                    try ChunkRange(entryIndex: 0, lowerBound: 0, upperBound: 1)
                ])
            ),
            .complete,
        ]

        for expected in frames {
            let reader = TransferFrameReader(bufferedFrames: [expected])
            let event = try await waitForTransferSessionEvent(
                reader: reader,
                control: control,
                after: staleSnapshot
            )
            guard case .frame(let actual) = event else {
                return XCTFail("A ready authenticated frame must win without being discarded")
            }
            XCTAssertEqual(try actual.encode(), try expected.encode())
        }
    }

    func testControlCancelWakesSenderWaitingForInitialChallenge() async throws {
        let fixture = try makeManualSenderWaitFixture(name: "challenge-wait.bin")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let control = TransferSessionControl()
        let completion = TestSessionCompletion()
        let sender = Task {
            do {
                _ = try await SendSession(fixture.manifest, control: control)
                    .run(on: fixture.channels.sender)
                await completion.finish(nil)
            } catch {
                await completion.finish(error as? TransferProtocolError)
            }
        }

        await control.cancel()
        try await Task.sleep(for: .milliseconds(150))
        let completedWithoutChallenge = await completion.isFinished
        if !completedWithoutChallenge { await fixture.channels.receiver.close() }
        await sender.value

        XCTAssertTrue(completedWithoutChallenge)
        let challengeError = await completion.protocolError
        XCTAssertEqual(challengeError, .cancelled)
    }

    func testControlCancelWakesSenderBlockedOnOrdinarySend() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("blocked-offer.bin")
        try Data().write(to: source)
        let manifest = try TransferManifest.build(from: source)
        let channels = TestSecureChannelPair.make(blockSenderAfter: 0)
        let challenge = TransferReceiverChallenge.fresh(for: manifest.id)
        try await channels.receiver.send(challenge.encode())
        let control = TransferSessionControl()
        let completion = TestSessionCompletion()
        let sender = Task {
            do {
                _ = try await SendSession(manifest, control: control).run(on: channels.sender)
                await completion.finish(nil)
            } catch {
                await completion.finish(error as? TransferProtocolError)
            }
        }
        try await Task.sleep(for: .milliseconds(20))

        await control.cancel()
        try await Task.sleep(for: .milliseconds(250))
        let completedDespiteBlockedOffer = await completion.isFinished
        if !completedDespiteBlockedOffer { await channels.receiver.close() }
        await sender.value

        XCTAssertTrue(completedDespiteBlockedOffer)
        let blockedOfferError = await completion.protocolError
        XCTAssertEqual(blockedOfferError, .cancelled)
    }

    func testCancelAfterFrameDeliveryNeverReusesEncryptedSequence() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent("received", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("delivered-before-return.bin")
        try Data().write(to: source)
        let manifest = try TransferManifest.build(from: source)
        let channels = TestSecureChannelPair.make(blockSenderReturnAfterDeliveryAfter: 0)
        let control = TransferSessionControl()
        let sender = Task {
            try await SendSession(manifest, control: control).run(on: channels.sender)
        }
        let receiver = Task {
            try await ReceiveSession(
                transferID: manifest.id,
                destinationDirectory: destination
            ).run(on: channels.receiver)
        }

        await channels.sender.waitUntilSentCount(1)
        await control.cancel()

        do {
            _ = try await sender.value
            XCTFail("Expected sender cancellation")
        } catch {
            XCTAssertEqual(error as? TransferProtocolError, .cancelled)
        }
        do {
            _ = try await receiver.value
            XCTFail("Expected authenticated receiver cancellation")
        } catch {
            XCTAssertEqual(
                error as? TransferProtocolError,
                .cancelled,
                "The terminal frame must use the next sequence even when prior delivery is ambiguous"
            )
        }
    }

    func testControlCancelWakesSenderWhileLocallyPaused() async throws {
        let fixture = try makeManualSenderWaitFixture(name: "local-pause.bin")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let control = TransferSessionControl()
        await control.pause()
        let completion = TestSessionCompletion()
        let sender = Task {
            do {
                _ = try await SendSession(fixture.manifest, control: control)
                    .run(on: fixture.channels.sender)
                await completion.finish(nil)
            } catch {
                await completion.finish(error as? TransferProtocolError)
            }
        }
        var iterator = fixture.channels.receiver.frames().makeAsyncIterator()
        let crypto = try await establishManualReceiver(fixture: fixture)
        var inboundSequence: UInt64 = 0
        guard
            case .offer = try await receive(
                from: &iterator,
                transferID: fixture.manifest.id,
                direction: .senderToReceiver,
                cipher: crypto.senderToReceiver,
                sequence: &inboundSequence
            )
        else { return XCTFail("Expected offer") }
        guard
            case .pause = try await receive(
                from: &iterator,
                transferID: fixture.manifest.id,
                direction: .senderToReceiver,
                cipher: crypto.senderToReceiver,
                sequence: &inboundSequence
            )
        else { return XCTFail("Expected local pause") }

        await control.cancel()
        try await Task.sleep(for: .milliseconds(150))
        let completedWhilePaused = await completion.isFinished
        if !completedWhilePaused { await fixture.channels.receiver.close() }
        await sender.value

        XCTAssertTrue(completedWhilePaused)
        let pausedError = await completion.protocolError
        XCTAssertEqual(pausedError, .cancelled)
    }

    func testControlCancelWakesSenderWaitingForAcknowledgement() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("ack-wait.bin")
        try Data(
            repeating: 0x6b,
            count: TransferProtocolLimits.maximumChunkBytes * 257
        ).write(to: source)
        let fixture = ManualSenderWaitFixture(
            directory: directory,
            manifest: try TransferManifest.build(from: source),
            channels: TestSecureChannelPair.make()
        )
        let control = TransferSessionControl()
        let completion = TestSessionCompletion()
        let sender = Task {
            do {
                _ = try await SendSession(fixture.manifest, control: control)
                    .run(on: fixture.channels.sender)
                await completion.finish(nil)
            } catch {
                await completion.finish(error as? TransferProtocolError)
            }
        }
        var iterator = fixture.channels.receiver.frames().makeAsyncIterator()
        let crypto = try await establishManualReceiver(fixture: fixture)
        var inboundSequence: UInt64 = 0
        var outboundSequence: UInt64 = 0
        _ = try await receive(
            from: &iterator,
            transferID: fixture.manifest.id,
            direction: .senderToReceiver,
            cipher: crypto.senderToReceiver,
            sequence: &inboundSequence
        )
        try await send(
            .accept(try ResumeMap()),
            transferID: fixture.manifest.id,
            direction: .receiverToSender,
            on: fixture.channels.receiver,
            cipher: crypto.receiverToSender,
            sequence: &outboundSequence
        )
        for _ in 0..<TransferProtocolLimits.maximumUnacknowledgedChunks {
            guard
                case .chunk = try await receive(
                    from: &iterator,
                    transferID: fixture.manifest.id,
                    direction: .senderToReceiver,
                    cipher: crypto.senderToReceiver,
                    sequence: &inboundSequence
                )
            else { return XCTFail("Expected chunk") }
        }

        await control.cancel()
        try await Task.sleep(for: .milliseconds(150))
        let completedWithoutAcknowledgement = await completion.isFinished
        if !completedWithoutAcknowledgement { await fixture.channels.receiver.close() }
        await sender.value

        XCTAssertTrue(completedWithoutAcknowledgement)
        let acknowledgementError = await completion.protocolError
        XCTAssertEqual(acknowledgementError, .cancelled)
    }

    func testControlCancelWakesSenderWaitingForFinalCompletion() async throws {
        let fixture = try makeManualSenderWaitFixture(name: "final-wait.bin")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let control = TransferSessionControl()
        let completion = TestSessionCompletion()
        let sender = Task {
            do {
                _ = try await SendSession(fixture.manifest, control: control)
                    .run(on: fixture.channels.sender)
                await completion.finish(nil)
            } catch {
                await completion.finish(error as? TransferProtocolError)
            }
        }
        var iterator = fixture.channels.receiver.frames().makeAsyncIterator()
        let crypto = try await establishManualReceiver(
            fixture: fixture
        )
        var inboundSequence: UInt64 = 0
        var outboundSequence: UInt64 = 0
        _ = try await receive(
            from: &iterator,
            transferID: fixture.manifest.id,
            direction: .senderToReceiver,
            cipher: crypto.senderToReceiver,
            sequence: &inboundSequence
        )
        try await send(
            .accept(try ResumeMap()),
            transferID: fixture.manifest.id,
            direction: .receiverToSender,
            on: fixture.channels.receiver,
            cipher: crypto.receiverToSender,
            sequence: &outboundSequence
        )
        _ = try await receive(
            from: &iterator,
            transferID: fixture.manifest.id,
            direction: .senderToReceiver,
            cipher: crypto.senderToReceiver,
            sequence: &inboundSequence
        )

        await control.cancel()
        try await Task.sleep(for: .milliseconds(150))
        let completedWithoutReceiverCompletion = await completion.isFinished
        if !completedWithoutReceiverCompletion { await fixture.channels.receiver.close() }
        await sender.value

        XCTAssertTrue(completedWithoutReceiverCompletion)
        let finalWaitError = await completion.protocolError
        XCTAssertEqual(finalWaitError, .cancelled)
    }

    func testBlockedTerminalSendTimesOutAndClosesChannel() async throws {
        let transferID = TransferID(rawValue: UUID())
        let manifest = TransferManifest(
            id: transferID,
            entries: [
                TransferManifestEntry(
                    relativePath: try RelativePath("unavailable.bin"),
                    kind: .file,
                    size: 0,
                    modificationDate: .now,
                    chunkCount: 0,
                    digest: Data(SHA256.hash(data: Data()))
                )
            ]
        )
        let channels = TestSecureChannelPair.make(blockSenderAfter: 0)
        let challenge = TransferReceiverChallenge.fresh(for: transferID)
        try await channels.receiver.send(challenge.encode())
        let completion = TestSessionCompletion()
        let sender = Task {
            do {
                _ = try await SendSession(manifest).run(on: channels.sender)
                await completion.finish(nil)
            } catch {
                await completion.finish(error as? TransferProtocolError)
            }
        }

        try await Task.sleep(for: .milliseconds(250))
        let completedDespiteBackpressure = await completion.isFinished
        if !completedDespiteBackpressure { await channels.receiver.close() }
        await sender.value

        XCTAssertTrue(completedDespiteBackpressure)
        let backpressureError = await completion.protocolError
        XCTAssertEqual(backpressureError, .sourceChanged)
        var receiverIterator = channels.receiver.frames().makeAsyncIterator()
        let frameAfterClose = try await receiverIterator.next()
        XCTAssertNil(frameAfterClose)
    }

    func testSuccessfulTerminalFrameFlushesBeforeReturning() async throws {
        let transferID = TransferID(rawValue: UUID())
        let channels = TestSecureChannelPair.make()
        let cipher = try ChunkCipher(key: Data(repeating: 0x5a, count: 32))

        let outcome = await sendTerminalFrameBestEffort(
            .error(.destinationUnavailable),
            transferID: transferID,
            direction: .receiverToSender,
            on: channels.receiver,
            cipher: cipher,
            sequence: 0
        )

        XCTAssertEqual(outcome, .sent)
        let flushCount = await channels.receiver.flushCount()
        XCTAssertEqual(flushCount, 1)
    }

    func testControlCancelWakesReceiverWaitingForPeerFrame() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent("received", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transferID = TransferID(rawValue: UUID())
        let manifest = TransferManifest(
            id: transferID,
            entries: [
                TransferManifestEntry(
                    relativePath: try RelativePath("receiver-wait.bin"),
                    kind: .file,
                    size: 0,
                    modificationDate: .now,
                    chunkCount: 0,
                    digest: Data(SHA256.hash(data: Data()))
                )
            ]
        )
        let channels = TestSecureChannelPair.make()
        let control = TransferSessionControl()
        let completion = TestSessionCompletion()
        let receiver = Task {
            do {
                _ = try await ReceiveSession(
                    transferID: transferID,
                    destinationDirectory: destination,
                    control: control
                ).run(on: channels.receiver)
                await completion.finish(nil)
            } catch {
                await completion.finish(error as? TransferProtocolError)
            }
        }
        var iterator = channels.sender.frames().makeAsyncIterator()
        let crypto = try await receiveCryptographicContext(
            from: channels.sender,
            iterator: &iterator,
            transferID: transferID
        )
        var outboundSequence: UInt64 = 0
        var inboundSequence: UInt64 = 0
        try await send(
            .offer(manifest),
            transferID: transferID,
            direction: .senderToReceiver,
            on: channels.sender,
            cipher: crypto.senderToReceiver,
            sequence: &outboundSequence
        )
        _ = try await receive(
            from: &iterator,
            transferID: transferID,
            direction: .receiverToSender,
            cipher: crypto.receiverToSender,
            sequence: &inboundSequence
        )

        await control.cancel()
        try await Task.sleep(for: .milliseconds(150))
        let completedWithoutPeerFrame = await completion.isFinished
        if !completedWithoutPeerFrame { await channels.sender.close() }
        await receiver.value

        XCTAssertTrue(completedWithoutPeerFrame)
        let receiverError = await completion.protocolError
        XCTAssertEqual(receiverError, .cancelled)
    }

    func testControlCancelWakesReceiverWaitingForInitialOffer() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent("received", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transferID = TransferID(rawValue: UUID())
        let channels = TestSecureChannelPair.make()
        let control = TransferSessionControl()
        let completion = TestSessionCompletion()
        let receiver = Task {
            do {
                _ = try await ReceiveSession(
                    transferID: transferID,
                    destinationDirectory: destination,
                    control: control
                ).run(on: channels.receiver)
                await completion.finish(nil)
            } catch {
                await completion.finish(error as? TransferProtocolError)
            }
        }
        var iterator = channels.sender.frames().makeAsyncIterator()
        _ = try await iterator.next()

        await control.cancel()
        try await Task.sleep(for: .milliseconds(150))
        let completedWithoutOffer = await completion.isFinished
        if !completedWithoutOffer { await channels.sender.close() }
        await receiver.value

        XCTAssertTrue(completedWithoutOffer)
        let offerError = await completion.protocolError
        XCTAssertEqual(offerError, .cancelled)
    }

    func testControlCancelWakesReceiverBlockedOnChallengeSend() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent("received", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let channels = TestSecureChannelPair.make(blockReceiverAfter: 0)
        let control = TransferSessionControl()
        let completion = TestSessionCompletion()
        let receiver = Task {
            do {
                _ = try await ReceiveSession(
                    transferID: TransferID(rawValue: UUID()),
                    destinationDirectory: destination,
                    control: control
                ).run(on: channels.receiver)
                await completion.finish(nil)
            } catch {
                await completion.finish(error as? TransferProtocolError)
            }
        }
        try await Task.sleep(for: .milliseconds(20))

        await control.cancel()
        try await Task.sleep(for: .milliseconds(150))
        let completedDespiteBlockedChallenge = await completion.isFinished
        if !completedDespiteBlockedChallenge { await channels.sender.close() }
        await receiver.value

        XCTAssertTrue(completedDespiteBlockedChallenge)
        let challengeError = await completion.protocolError
        XCTAssertEqual(challengeError, .cancelled)
    }

    func testSenderSourceFailureSendsTypedErrorAndClosesReceiver() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent("received", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transferID = TransferID(rawValue: UUID())
        let manifest = TransferManifest(
            id: transferID,
            entries: [
                TransferManifestEntry(
                    relativePath: try RelativePath("unavailable.bin"),
                    kind: .file,
                    size: 0,
                    modificationDate: .now,
                    chunkCount: 0,
                    digest: Data(SHA256.hash(data: Data()))
                )
            ]
        )
        let channels = TestSecureChannelPair.make()
        let receiver = Task {
            try await ReceiveSession(
                transferID: transferID,
                destinationDirectory: destination
            ).run(on: channels.receiver)
        }

        do {
            _ = try await SendSession(manifest).run(on: channels.sender)
            XCTFail("Expected the missing pinned source to terminate the sender")
        } catch {
            XCTAssertEqual(error as? TransferProtocolError, .sourceChanged)
        }
        do {
            _ = try await receiver.value
            XCTFail("Expected the receiver to map the typed source error")
        } catch {
            XCTAssertEqual(error as? TransferProtocolError, .sourceChanged)
        }
    }

    func testPublishedReceiverResultSurvivesFailedCompletionNotification() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent("received", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("committed.bin")
        let bytes = Data()
        try bytes.write(to: source)
        let manifest = try TransferManifest.build(from: source)
        let channels = TestSecureChannelPair.make(failReceiverAfter: 2)
        let receiver = Task {
            try await ReceiveSession(
                transferID: manifest.id,
                destinationDirectory: destination
            ).run(on: channels.receiver)
        }

        _ = try? await SendSession(manifest).run(on: channels.sender)
        let result = try await receiver.value

        XCTAssertEqual(result.transferID, manifest.id)
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("committed.bin")),
            bytes
        )
    }

    func testBlockedCompletionAfterPublicationClosesAndTerminatesSender() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent("received", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("blocked-completion.bin")
        try Data().write(to: source)
        let manifest = try TransferManifest.build(from: source)
        let channels = TestSecureChannelPair.make(blockReceiverAfter: 2)
        let senderCompletion = TestSessionCompletion()
        let sender = Task {
            do {
                _ = try await SendSession(manifest).run(on: channels.sender)
                await senderCompletion.finish(nil)
            } catch {
                await senderCompletion.finish(error as? TransferProtocolError)
            }
        }
        let receiver = Task {
            try await ReceiveSession(
                transferID: manifest.id,
                destinationDirectory: destination
            ).run(on: channels.receiver)
        }

        let result = try await receiver.value
        try await Task.sleep(for: .milliseconds(250))
        let senderTerminated = await senderCompletion.isFinished
        if !senderTerminated { await channels.receiver.close() }
        await sender.value

        XCTAssertEqual(result.transferID, manifest.id)
        XCTAssertTrue(senderTerminated)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("blocked-completion.bin").path
            )
        )
    }

    func testReceiverControlPauseBackpressuresSenderUntilResume() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent("received", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("receiver-controlled.bin")
        try Data(
            repeating: 0x7a,
            count: TransferProtocolLimits.maximumChunkBytes * 257
        ).write(to: source)
        let manifest = try TransferManifest.build(from: source)
        let channels = TestSecureChannelPair.make()
        let control = TransferSessionControl()
        let recorder = TestChunkRecorder()
        await control.pause()
        let receiver = Task {
            try await ReceiveSession(
                transferID: manifest.id,
                destinationDirectory: destination,
                control: control
            ).run(on: channels.receiver)
        }
        let sender = Task {
            try await SendSession(manifest, recorder: recorder).run(on: channels.sender)
        }

        try await Task.sleep(for: .milliseconds(100))
        let pausedCoordinates = await recorder.coordinates
        XCTAssertEqual(pausedCoordinates.count, 256)
        await control.resume()
        _ = try await sender.value
        _ = try await receiver.value
        let completedCoordinates = await recorder.coordinates
        XCTAssertEqual(completedCoordinates.count, 257)
    }

    func testReceiverAcknowledgesAContinuousRangeAtOneHundredTwentyEightChunks() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent("received", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("ack.bin")
        let bytes = Data(
            repeating: 6,
            count: TransferProtocolLimits.maximumChunkBytes * 129
        )
        try bytes.write(to: source)
        let manifest = try TransferManifest.build(from: source)
        let channels = TestSecureChannelPair.make()
        var outboundSequence: UInt64 = 0
        var inboundSequence: UInt64 = 0
        var iterator = channels.sender.frames().makeAsyncIterator()
        let receiver = Task {
            try await ReceiveSession(
                transferID: manifest.id,
                destinationDirectory: destination
            ).run(on: channels.receiver)
        }
        let crypto = try await receiveCryptographicContext(
            from: channels.sender,
            iterator: &iterator,
            transferID: manifest.id
        )

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
        for index in 0..<UInt32(128) {
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
                try ChunkRange(entryIndex: 0, lowerBound: 0, upperBound: 128)
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
        var outboundSequence: UInt64 = 0
        var inboundSequence: UInt64 = 0
        var iterator = channels.sender.frames().makeAsyncIterator()
        let receiver = Task {
            try await ReceiveSession(
                transferID: manifest.id,
                destinationDirectory: destination
            ).run(on: channels.receiver)
        }
        let crypto = try await receiveCryptographicContext(
            from: channels.sender,
            iterator: &iterator,
            transferID: manifest.id
        )
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
        XCTAssertEqual(
            receiverFrameCount,
            3,
            "challenge, accept, and the timer-flushed ACK"
        )

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
        var outboundSequence: UInt64 = 0
        var inboundSequence: UInt64 = 0
        var iterator = channels.sender.frames().makeAsyncIterator()
        let receiver = Task {
            try await ReceiveSession(
                transferID: manifest.id,
                destinationDirectory: destination
            ).run(on: channels.receiver)
        }
        let crypto = try await receiveCryptographicContext(
            from: channels.sender,
            iterator: &iterator,
            transferID: manifest.id
        )
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
    private let blockAfter: Int?
    private let blockReturnAfterDeliveryAfter: Int?
    private let blocker = TestSendBlocker()
    private let returnBlocker = TestSendBlocker()
    private let flushCounter = TestFlushCounter()
    private weak var peer: TestSecureChannel?

    init(
        key: Data,
        failAfter: Int?,
        blockAfter: Int? = nil,
        blockReturnAfterDeliveryAfter: Int? = nil
    ) {
        self.key = key
        sendGate = TestSendGate(failAfter: failAfter)
        self.blockAfter = blockAfter
        self.blockReturnAfterDeliveryAfter = blockReturnAfterDeliveryAfter
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
        if let blockAfter, await sendGate.count > blockAfter {
            await blocker.waitUntilClosed()
            throw WebRTCSecureChannelError.transportClosed
        }
        peer.continuation.yield(frame)
        if let blockReturnAfterDeliveryAfter,
            await sendGate.count > blockReturnAfterDeliveryAfter
        {
            await returnBlocker.waitUntilClosed()
            throw WebRTCSecureChannelError.transportClosed
        }
    }

    func frames() -> AsyncThrowingStream<Data, Error> { stream }

    func exportKey(label: String, context: Data, length: Int) async throws -> Data {
        XCTAssertEqual(label, "macchannel-transfer-v1")
        XCTAssertEqual(context.count, 16)
        XCTAssertEqual(length, 32)
        return key
    }

    func flush() async {
        await flushCounter.increment()
    }

    func close() async {
        await blocker.close()
        await returnBlocker.close()
        await peer?.blocker.close()
        await peer?.returnBlocker.close()
        continuation.finish()
        peer?.continuation.finish()
    }

    func sentCount() async -> Int { await sendGate.count }
    func flushCount() async -> Int { await flushCounter.value }

    func waitUntilSentCount(_ count: Int) async {
        await sendGate.waitUntilCount(count)
    }
}

private actor TestFlushCounter {
    private(set) var value = 0

    func increment() { value += 1 }
}

private struct ManualSenderWaitFixture {
    let directory: URL
    let manifest: TransferManifest
    let channels: (sender: TestSecureChannel, receiver: TestSecureChannel)
}

private func makeManualSenderWaitFixture(name: String) throws -> ManualSenderWaitFixture {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = directory.appendingPathComponent(name)
    try Data().write(to: source)
    return ManualSenderWaitFixture(
        directory: directory,
        manifest: try TransferManifest.build(from: source),
        channels: TestSecureChannelPair.make()
    )
}

private func establishManualReceiver(
    fixture: ManualSenderWaitFixture
) async throws -> TransferCryptographicContext {
    let challenge = TransferReceiverChallenge.fresh(for: fixture.manifest.id)
    try await fixture.channels.receiver.send(challenge.encode())
    return try await TransferCryptographicContext.make(
        on: fixture.channels.receiver,
        transfer: fixture.manifest.id,
        receiverChallenge: challenge.bytes
    )
}

private struct InterruptedResumeFixture {
    let directory: URL
    let destination: URL
    let staging: URL
    let metadata: URL
    let journal: URL
    let manifest: TransferManifest
    let bytes: Data
}

private func makeInterruptedResumeFixture() async throws -> InterruptedResumeFixture {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let destination = directory.appendingPathComponent("received", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = directory.appendingPathComponent("resume.bin")
    let bytes = Data(
        repeating: 0x5a,
        count: TransferProtocolLimits.maximumChunkBytes * 4
    )
    try bytes.write(to: source)
    let manifest = try TransferManifest.build(from: source)
    let channels = TestSecureChannelPair.make(failSenderAfter: 3)
    async let receive = ReceiveSession(
        transferID: manifest.id,
        destinationDirectory: destination
    ).run(on: channels.receiver)
    _ = try? await SendSession(manifest).run(on: channels.sender)
    _ = try? await receive
    let staging =
        destination
        .appendingPathComponent(
            ".macchannel-\(manifest.id.rawValue.uuidString.lowercased()).partial",
            isDirectory: true
        )
    let metadata = staging.appendingPathComponent(
        ".macchannel-protocol-\(manifest.id.rawValue.uuidString.lowercased())",
        isDirectory: true
    )
    let journal = metadata.appendingPathComponent(".resume-state")
    return InterruptedResumeFixture(
        directory: directory,
        destination: destination,
        staging: staging,
        metadata: metadata,
        journal: journal,
        manifest: manifest,
        bytes: bytes
    )
}

private func receiveCryptographicContext(
    from channel: TestSecureChannel,
    iterator: inout AsyncThrowingStream<Data, Error>.Iterator,
    transferID: TransferID
) async throws -> TransferCryptographicContext {
    guard let wire = try await iterator.next() else {
        throw TransferProtocolError.channelEnded
    }
    let challenge = try TransferReceiverChallenge.decode(
        wire,
        expectedTransferID: transferID
    )
    return try await TransferCryptographicContext.make(
        on: channel,
        transfer: transferID,
        receiverChallenge: challenge.bytes
    )
}

private actor TestSendGate {
    private let failAfter: Int?
    private var sent = 0
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(failAfter: Int?) { self.failAfter = failAfter }

    func permit() -> Bool {
        guard failAfter == nil || sent < failAfter! else { return false }
        sent += 1
        let ready = waiters.filter { sent >= $0.count }
        waiters.removeAll { sent >= $0.count }
        for waiter in ready { waiter.continuation.resume() }
        return true
    }

    var count: Int { sent }

    func waitUntilCount(_ count: Int) async {
        guard sent < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }
}

private actor TestSendBlocker {
    private var closed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilClosed() async {
        guard !closed else { return }
        await withCheckedContinuation { continuation in
            if closed {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        let continuations = waiters
        waiters.removeAll(keepingCapacity: false)
        for continuation in continuations { continuation.resume() }
    }
}

private actor TestSessionCompletion {
    private(set) var isFinished = false
    private(set) var protocolError: TransferProtocolError?

    func finish(_ error: TransferProtocolError?) {
        protocolError = error
        isFinished = true
    }
}

private actor TestChunkRecorder: TransferChunkRecording {
    private(set) var coordinates: [ChunkCoordinate] = []

    func recordSentChunk(_ coordinate: ChunkCoordinate) {
        coordinates.append(coordinate)
    }
}

private actor TestResumeNegotiationRecorder: TransferResumeNegotiationObserving {
    private(set) var values: [TransferResumeNegotiation] = []

    func recordResumeNegotiation(_ value: TransferResumeNegotiation) {
        values.append(value)
    }
}

private enum TestSecureChannelPair {
    static func make(
        failSenderAfter: Int? = nil,
        failReceiverAfter: Int? = nil,
        key suppliedKey: Data? = nil,
        blockSenderAfter: Int? = nil,
        blockReceiverAfter: Int? = nil,
        blockSenderReturnAfterDeliveryAfter: Int? = nil
    ) -> (
        sender: TestSecureChannel,
        receiver: TestSecureChannel
    ) {
        let key =
            suppliedKey
            ?? Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        let sender = TestSecureChannel(
            key: key,
            failAfter: failSenderAfter,
            blockAfter: blockSenderAfter,
            blockReturnAfterDeliveryAfter: blockSenderReturnAfterDeliveryAfter
        )
        let receiver = TestSecureChannel(
            key: key,
            failAfter: failReceiverAfter,
            blockAfter: blockReceiverAfter
        )
        sender.connect(to: receiver)
        receiver.connect(to: sender)
        return (sender, receiver)
    }
}
