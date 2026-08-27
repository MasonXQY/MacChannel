import CryptoKit
import Darwin
import Foundation
import SQLite3
import XCTest

@testable import MacChannelCore

final class ReceiveStoreTests: XCTestCase {
    func testFinalizeNeverOverwritesAndPublishesOnlyAfterVerification() async throws {
        let fixture = try StorageFixture()
        let old = Data("old".utf8)
        try old.write(to: fixture.downloads.appendingPathComponent("photo.jpg"))
        let bytes = Data("new".utf8)
        let manifest = try makeManifest(name: "photo.jpg", bytes: bytes)
        let store = try await fixture.prepare(manifest: manifest)

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.downloads.appendingPathComponent("photo 2.jpg").path
            ))
        try await store.write(bytes, index: 0, entry: 0)
        let output = try await store.finalize()

        XCTAssertEqual(output.lastPathComponent, "photo 2.jpg")
        XCTAssertEqual(try Data(contentsOf: output), bytes)
        XCTAssertEqual(
            try Data(contentsOf: fixture.downloads.appendingPathComponent("photo.jpg")), old)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging(manifest.id).path))
    }

    func testRestartReconcilesCrashAfterAtomicPublicationWithoutCreatingDuplicate() async throws {
        let fixture = try StorageFixture()
        let bytes = Data("durable publication".utf8)
        let manifest = try makeManifest(name: "durable.txt", bytes: bytes)
        var store: ReceiveStore? = try await fixture.prepare(manifest: manifest)
        try await store?.write(bytes, index: 0, entry: 0)

        do {
            _ = try await store?.finalize(onPublishedBeforeHistory: {
                throw PublicationTestFault.interrupted
            })
            XCTFail("Expected injected publication interruption")
        } catch {
            XCTAssertEqual(error as? ReceiveStoreError, .atomicPlacementUnavailable)
        }
        let published = fixture.downloads.appendingPathComponent("durable.txt")
        XCTAssertEqual(try Data(contentsOf: published), bytes)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.staging(manifest.id)
                    .appendingPathComponent(".macchannel-storage-metadata/.resume-state").path
            )
        )
        let interruptedHistory = try await fixture.database.history(limit: 1)
        XCTAssertEqual(interruptedHistory.first?.phase, .verifying)
        store = nil

        let recovered = try await fixture.prepare(manifest: manifest)
        let output = try await recovered.finalize()

        XCTAssertEqual(output, published)
        XCTAssertEqual(try Data(contentsOf: output), bytes)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.downloads.appendingPathComponent("durable 2.txt").path
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging(manifest.id).path))
        let recoveredHistory = try await fixture.database.history(limit: 1)
        XCTAssertEqual(recoveredHistory.first?.phase, .completed)
    }

    func testRestartFinishesEveryPostCompletionCleanupBoundary() async throws {
        for interruptedStep in PublicationCleanupStep.allCases {
            let fixture = try StorageFixture()
            let bytes = Data("cleanup \(interruptedStep)".utf8)
            let manifest = try makeManifest(name: "cleanup.txt", bytes: bytes)
            var store: ReceiveStore? = try await fixture.prepare(manifest: manifest)
            try await store?.write(bytes, index: 0, entry: 0)

            do {
                _ = try await store?.finalize(
                    onPublishedBeforeHistory: {},
                    onCleanupStep: { step in
                        if step == interruptedStep {
                            throw ReceiveStoreError.atomicPlacementUnavailable
                        }
                    }
                )
                XCTFail("Expected interruption after \(interruptedStep)")
            } catch {
                XCTAssertEqual(error as? ReceiveStoreError, .atomicPlacementUnavailable)
            }
            let completedHistory = try await fixture.database.history(limit: 1)
            XCTAssertEqual(completedHistory.first?.phase, .completed)
            store = nil

            do {
                let recovered = try await fixture.prepare(manifest: manifest)
                _ = try await recovered.finalize()
            } catch {
                XCTAssertEqual(error as? ReceiveStoreError, .alreadyFinished)
            }

            XCTAssertFalse(
                FileManager.default.fileExists(atPath: fixture.staging(manifest.id).path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.lease(manifest.id).path))
            XCTAssertEqual(
                try Data(contentsOf: fixture.downloads.appendingPathComponent("cleanup.txt")),
                bytes
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: fixture.downloads.appendingPathComponent("cleanup 2.txt").path
                )
            )
        }
    }

    func testSecondStoreCannotShareActiveTransferStaging() async throws {
        let fixture = try StorageFixture()
        let bytes = Data("exclusive".utf8)
        let manifest = try makeManifest(name: "exclusive.txt", bytes: bytes)
        let first = try await fixture.prepare(manifest: manifest)

        await assertReceiveError(.transferBusy) {
            _ = try await fixture.prepare(manifest: manifest)
        }

        try await first.write(bytes, index: 0, entry: 0)
        let output = try await first.finalize()
        XCTAssertEqual(try Data(contentsOf: output), bytes)
    }

    func testLeasePathReplacementFailsClosedDuringAcquisitionAndWhileHeld() throws {
        let fixture = try StorageFixture()
        try FileManager.default.createDirectory(
            at: fixture.incoming,
            withIntermediateDirectories: true
        )
        XCTAssertEqual(chmod(fixture.incoming.path, S_IRWXU), 0)
        let transfer = TransferID(rawValue: UUID())

        XCTAssertThrowsError(
            try ReceiveTransferLease.acquire(
                transferID: transfer,
                incomingDirectory: fixture.incoming,
                onLocked: { leaseURL in
                    XCTAssertEqual(unlink(leaseURL.path), 0)
                    XCTAssertTrue(
                        FileManager.default.createFile(
                            atPath: leaseURL.path,
                            contents: Data()
                        ))
                }
            )
        ) { error in
            XCTAssertEqual(error as? ReceiveStoreError, .stagingUnavailable)
        }

        try? FileManager.default.removeItem(at: fixture.lease(transfer))
        let lease = try ReceiveTransferLease.acquire(
            transferID: transfer,
            incomingDirectory: fixture.incoming
        )
        XCTAssertEqual(unlink(fixture.lease(transfer).path), 0)
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: fixture.lease(transfer).path,
                contents: Data()
            ))
        XCTAssertThrowsError(try lease.requireHeld()) { error in
            XCTAssertEqual(error as? ReceiveStoreError, .transferBusy)
        }
    }

    func testIncomingDirectoryReplacementInvalidatesPinnedLease() throws {
        let fixture = try StorageFixture()
        try FileManager.default.createDirectory(
            at: fixture.incoming,
            withIntermediateDirectories: true
        )
        XCTAssertEqual(chmod(fixture.incoming.path, S_IRWXU), 0)
        let transfer = TransferID(rawValue: UUID())
        let first = try ReceiveTransferLease.acquire(
            transferID: transfer,
            incomingDirectory: fixture.incoming
        )
        let displaced = fixture.root.appendingPathComponent("displaced-incoming")
        XCTAssertEqual(rename(fixture.incoming.path, displaced.path), 0)
        try FileManager.default.createDirectory(
            at: fixture.incoming,
            withIntermediateDirectories: false
        )
        XCTAssertEqual(chmod(fixture.incoming.path, S_IRWXU), 0)
        let second = try ReceiveTransferLease.acquire(
            transferID: transfer,
            incomingDirectory: fixture.incoming
        )

        XCTAssertThrowsError(try first.requireHeld()) { error in
            XCTAssertEqual(error as? ReceiveStoreError, .transferBusy)
        }
        XCTAssertThrowsError(
            try first.makeStagingTree(
                stagingName: transfer.rawValue.uuidString.lowercased(),
                metadataName: ".macchannel-storage-metadata"
            )
        ) { error in
            XCTAssertEqual(error as? ReceiveStoreError, .transferBusy)
        }
        XCTAssertNoThrow(try second.requireHeld())
    }

    func testIncomingDirectorySwapDuringLeaseAcquisitionFailsClosed() throws {
        let fixture = try StorageFixture()
        try FileManager.default.createDirectory(
            at: fixture.incoming,
            withIntermediateDirectories: true
        )
        XCTAssertEqual(chmod(fixture.incoming.path, S_IRWXU), 0)
        let displaced = fixture.root.appendingPathComponent("acquire-displaced-incoming")

        XCTAssertThrowsError(
            try ReceiveTransferLease.acquire(
                transferID: TransferID(rawValue: UUID()),
                incomingDirectory: fixture.incoming,
                onLocked: { _ in
                    XCTAssertEqual(rename(fixture.incoming.path, displaced.path), 0)
                    try FileManager.default.createDirectory(
                        at: fixture.incoming,
                        withIntermediateDirectories: false
                    )
                    XCTAssertEqual(chmod(fixture.incoming.path, S_IRWXU), 0)
                }
            )
        ) { error in
            XCTAssertEqual(error as? ReceiveStoreError, .stagingUnavailable)
        }
    }

    func testLeasePathReplacementPreventsFinalPublication() async throws {
        let fixture = try StorageFixture()
        let bytes = Data("lease-bound publication".utf8)
        let manifest = try makeManifest(name: "lease.txt", bytes: bytes)
        let store = try await fixture.prepare(manifest: manifest)
        try await store.write(bytes, index: 0, entry: 0)
        XCTAssertEqual(unlink(fixture.lease(manifest.id).path), 0)
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: fixture.lease(manifest.id).path,
                contents: Data()
            ))

        await assertReceiveError(.transferBusy) {
            _ = try await store.finalize()
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.downloads.appendingPathComponent("lease.txt").path
            ))
    }

    func testIncomingReplacementAfterPublicationIntentPreventsFinalPublication() async throws {
        let fixture = try StorageFixture()
        let bytes = Data("publication-bound incoming".utf8)
        let manifest = try makeManifest(name: "incoming-bound.txt", bytes: bytes)
        let store = try await fixture.prepare(manifest: manifest)
        try await store.write(bytes, index: 0, entry: 0)
        let displaced = fixture.root.appendingPathComponent("finalize-displaced-incoming")

        await assertReceiveError(.transferBusy) {
            _ = try await store.finalize(
                onPublishedBeforeHistory: {},
                onPublicationIntentRecorded: {
                    XCTAssertEqual(rename(fixture.incoming.path, displaced.path), 0)
                    try FileManager.default.createDirectory(
                        at: fixture.incoming,
                        withIntermediateDirectories: false
                    )
                    XCTAssertEqual(chmod(fixture.incoming.path, S_IRWXU), 0)
                },
                onCleanupStep: { _ in }
            )
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.downloads.appendingPathComponent("incoming-bound.txt").path
            )
        )
        let second = try ReceiveTransferLease.acquire(
            transferID: manifest.id,
            incomingDirectory: fixture.incoming
        )
        XCTAssertNoThrow(try second.requireHeld())
    }

    func testDestinationReplacementAfterPublicationIntentPreventsFinalPublication() async throws {
        let fixture = try StorageFixture()
        let bytes = Data("publication-bound destination".utf8)
        let manifest = try makeManifest(name: "destination-bound.txt", bytes: bytes)
        let store = try await fixture.prepare(manifest: manifest)
        try await store.write(bytes, index: 0, entry: 0)
        let displaced = fixture.root.appendingPathComponent("finalize-displaced-downloads")

        await assertReceiveError(.atomicPlacementUnavailable) {
            _ = try await store.finalize(
                onPublishedBeforeHistory: {},
                onPublicationIntentRecorded: {
                    XCTAssertEqual(rename(fixture.downloads.path, displaced.path), 0)
                    try FileManager.default.createDirectory(
                        at: fixture.downloads,
                        withIntermediateDirectories: false
                    )
                },
                onCleanupStep: { _ in }
            )
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.downloads.appendingPathComponent("destination-bound.txt").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: displaced.appendingPathComponent("destination-bound.txt").path
            )
        )
    }

    func testFinalizeRejectsIncompleteAndDigestMismatchedContent() async throws {
        let fixture = try StorageFixture()
        let bytes = Data(repeating: 0x41, count: TransferProtocolLimits.maximumChunkBytes + 9)
        let manifest = try makeManifest(name: "large.bin", bytes: bytes)
        let store = try await fixture.prepare(manifest: manifest)
        try await store.write(
            bytes.prefix(TransferProtocolLimits.maximumChunkBytes),
            index: 0,
            entry: 0
        )

        await assertReceiveError(.incompleteTransfer) {
            _ = try await store.finalize()
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.downloads.appendingPathComponent("large.bin").path
            ))

        let corruptManifest = try makeManifest(
            name: "corrupt.bin",
            bytes: Data("expected".utf8),
            digest: Data(SHA256.hash(data: Data("different".utf8)))
        )
        let corruptStore = try await fixture.prepare(manifest: corruptManifest)
        try await corruptStore.write(Data("expected".utf8), index: 0, entry: 0)
        await assertReceiveError(.digestMismatch) {
            _ = try await corruptStore.finalize()
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.downloads.appendingPathComponent("corrupt.bin").path
            ))
    }

    func testUnexpectedStagingRootSiblingPreventsPublicationAndRemainsExpiryEligible()
        async throws
    {
        let fixture = try StorageFixture()
        let bytes = Data("exact staging".utf8)
        let manifest = try makeManifest(name: "exact.txt", bytes: bytes)
        var store: ReceiveStore? = try await fixture.prepare(manifest: manifest)
        try await store?.write(bytes, index: 0, entry: 0)
        try Data("unexpected".utf8).write(
            to: fixture.staging(manifest.id).appendingPathComponent("unexpected-sibling")
        )

        await assertReceiveError(.atomicPlacementUnavailable) {
            _ = try await store?.finalize()
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.downloads.appendingPathComponent("exact.txt").path
            ))
        let failedHistory = try await fixture.database.history(limit: 1)
        XCTAssertEqual(failedHistory.first?.phase, .failed)
        try await store?.markFailed(at: Date(timeIntervalSince1970: 100))
        store = nil
        let removed = try await ReceiveStore.expireFailedStaging(
            database: fixture.database,
            incomingDirectory: fixture.incoming,
            now: Date(timeIntervalSince1970: 100 + 7 * 86_400)
        )
        XCTAssertEqual(removed, [manifest.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging(manifest.id).path))
    }

    func testUnexpectedPrivateMetadataSiblingPreventsPublication() async throws {
        let fixture = try StorageFixture()
        let bytes = Data("exact private metadata".utf8)
        let manifest = try makeManifest(name: "metadata.txt", bytes: bytes)
        let store = try await fixture.prepare(manifest: manifest)
        try await store.write(bytes, index: 0, entry: 0)
        try Data("unexpected".utf8).write(
            to: fixture.staging(manifest.id)
                .appendingPathComponent(".macchannel-storage-metadata")
                .appendingPathComponent("unexpected-private-state")
        )

        await assertReceiveError(.atomicPlacementUnavailable) {
            _ = try await store.finalize()
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.downloads.appendingPathComponent("metadata.txt").path
            ))
        let history = try await fixture.database.history(limit: 1)
        XCTAssertEqual(history.first?.phase, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.staging(manifest.id).path))
    }

    func testRestartCleansUnexpectedSiblingAddedAfterAtomicPublication() async throws {
        let fixture = try StorageFixture()
        let bytes = Data("published cleanup".utf8)
        let manifest = try makeManifest(name: "published.txt", bytes: bytes)
        var store: ReceiveStore? = try await fixture.prepare(manifest: manifest)
        try await store?.write(bytes, index: 0, entry: 0)

        do {
            _ = try await store?.finalize(onPublishedBeforeHistory: {
                try Data("late sibling".utf8).write(
                    to: fixture.staging(manifest.id).appendingPathComponent("late-sibling")
                )
                throw PublicationTestFault.interrupted
            })
            XCTFail("Expected injected publication interruption")
        } catch {
            XCTAssertEqual(error as? ReceiveStoreError, .atomicPlacementUnavailable)
        }
        store = nil

        let recovered = try await fixture.prepare(manifest: manifest)
        let output = try await recovered.finalize()

        XCTAssertEqual(try Data(contentsOf: output), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging(manifest.id).path))
        let history = try await fixture.database.history(limit: 1)
        XCTAssertEqual(history.first?.phase, .completed)
    }

    func testRestartUnlinksUnexpectedPostPublicationSymlinkWithoutTouchingTarget() async throws {
        let fixture = try StorageFixture()
        let bytes = Data("published symlink cleanup".utf8)
        let manifest = try makeManifest(name: "symlink-cleanup.txt", bytes: bytes)
        let outside = fixture.root.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        var store: ReceiveStore? = try await fixture.prepare(manifest: manifest)
        try await store?.write(bytes, index: 0, entry: 0)

        do {
            _ = try await store?.finalize(onPublishedBeforeHistory: {
                XCTAssertEqual(
                    symlink(
                        outside.path,
                        fixture.staging(manifest.id).appendingPathComponent("late-link").path
                    ),
                    0
                )
                throw PublicationTestFault.interrupted
            })
            XCTFail("Expected injected publication interruption")
        } catch {
            XCTAssertEqual(error as? ReceiveStoreError, .atomicPlacementUnavailable)
        }
        store = nil

        let recovered = try await fixture.prepare(manifest: manifest)
        let output = try await recovered.finalize()

        XCTAssertEqual(try Data(contentsOf: output), bytes)
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging(manifest.id).path))
    }

    func testPolicyRejectsBeforeCreatingStaging() async throws {
        let fixture = try StorageFixture()
        let bytes = Data(repeating: 1, count: 20)
        let untrustedManifest = try makeManifest(name: "untrusted.bin", bytes: bytes)
        await assertReceiveError(.untrustedSource) {
            _ = try await ReceiveStore.prepare(
                manifest: untrustedManifest,
                source: fixture.source,
                policy: ReceivePolicy(trustedSources: []),
                directories: DownloadDirectory(globalDirectory: fixture.downloads),
                database: fixture.database,
                incomingDirectory: fixture.incoming,
                capacity: FixedCapacity(bytes: 1_000_000)
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.staging(untrustedManifest.id).path))

        let disabledManifest = try makeManifest(name: "disabled.bin", bytes: bytes)
        let disabled = ReceivePolicy(
            trustedSources: [fixture.source],
            perDevice: [fixture.source: DeviceReceivePolicy(autoAccept: false)]
        )
        await assertReceiveError(.automaticReceiveDisabled) {
            _ = try await ReceiveStore.prepare(
                manifest: disabledManifest,
                source: fixture.source,
                policy: disabled,
                directories: DownloadDirectory(globalDirectory: fixture.downloads),
                database: fixture.database,
                incomingDirectory: fixture.incoming,
                capacity: FixedCapacity(bytes: 1_000_000)
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.staging(disabledManifest.id).path))

        let oversizedManifest = try makeManifest(name: "oversized.bin", bytes: bytes)
        let capped = ReceivePolicy(
            trustedSources: [fixture.source],
            perDevice: [fixture.source: DeviceReceivePolicy(maximumBytes: 19)]
        )
        await assertReceiveError(.exceedsMaximumSize(limit: 19, actual: 20)) {
            _ = try await ReceiveStore.prepare(
                manifest: oversizedManifest,
                source: fixture.source,
                policy: capped,
                directories: DownloadDirectory(globalDirectory: fixture.downloads),
                database: fixture.database,
                incomingDirectory: fixture.incoming,
                capacity: FixedCapacity(bytes: 1_000_000)
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.staging(oversizedManifest.id).path))
    }

    func testPreflightAndEveryWriteMonitorRemainingCapacityWithFivePercentReserve() async throws {
        let fixture = try StorageFixture()
        let bytes = Data(repeating: 7, count: 100)
        let manifest = try makeManifest(name: "space.bin", bytes: bytes)

        await assertReceiveError(.insufficientCapacity(required: 105, available: 104)) {
            _ = try await fixture.prepare(
                manifest: manifest,
                capacity: FixedCapacity(bytes: 104)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging(manifest.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.lease(manifest.id).path))

        let capacity = MutableCapacity(bytes: 105)
        let store = try await fixture.prepare(manifest: manifest, capacity: capacity)
        capacity.bytes = 0
        await assertReceiveError(.insufficientCapacity(required: 105, available: 0)) {
            try await store.write(bytes, index: 0, entry: 0)
        }
    }

    func testRestartPreflightsOnlyJournalRevalidatedRemainingBytes() async throws {
        let fixture = try StorageFixture()
        let bytes = Data(repeating: 4, count: TransferProtocolLimits.maximumChunkBytes + 100)
        let manifest = try makeManifest(name: "remaining.bin", bytes: bytes)
        var first: ReceiveStore? = try await fixture.prepare(manifest: manifest)
        try await first?.write(
            bytes.prefix(TransferProtocolLimits.maximumChunkBytes),
            index: 0,
            entry: 0
        )
        first = nil

        let resumed = try await fixture.prepare(
            manifest: manifest,
            capacity: FixedCapacity(bytes: 105)
        )
        let map = try await resumed.resumeMap()
        XCTAssertTrue(map.contains(ChunkCoordinate(entryIndex: 0, chunkIndex: 0)))
    }

    func testDownloadDirectoryDefaultsAndPerSourceOverride() {
        let home = URL(fileURLWithPath: "/tmp/macchannel-home", isDirectory: true)
        let source = DeviceID(rawValue: UUID())
        let special = URL(fileURLWithPath: "/tmp/special", isDirectory: true)
        let global = URL(fileURLWithPath: "/tmp/global", isDirectory: true)

        XCTAssertEqual(
            DownloadDirectory(homeDirectory: home).directory(for: source).path,
            "/tmp/macchannel-home/Downloads/Mac 通道"
        )
        XCTAssertEqual(
            DownloadDirectory(globalDirectory: global).directory(for: source),
            global
        )
        XCTAssertEqual(
            DownloadDirectory(globalDirectory: global, perSource: [source: special])
                .directory(for: source),
            special
        )
    }

    func testCaseAndUnicodeEquivalentNamesReceiveCollisionNumbers() async throws {
        let fixture = try StorageFixture()
        let existingName = "CAFE\u{301}.txt"
        try Data("old".utf8).write(
            to: fixture.downloads.appendingPathComponent(existingName)
        )
        let bytes = Data("fresh".utf8)
        let manifest = try makeManifest(name: "caf\u{00e9}.txt", bytes: bytes)
        let store = try await fixture.prepare(manifest: manifest)
        try await store.write(bytes, index: 0, entry: 0)

        let output = try await store.finalize()

        XCTAssertEqual(output.lastPathComponent, "caf\u{00e9} 2.txt")
        XCTAssertEqual(try Data(contentsOf: output), bytes)
    }

    func testCollisionScanRestartsForEveryCaseAndUnicodeEquivalentCandidate() async throws {
        let fixture = try StorageFixture()
        let decomposed = "cafe\u{301}"
        try Data("one".utf8).write(
            to: fixture.downloads.appendingPathComponent("CAF\u{00c9}.txt")
        )
        try Data("two".utf8).write(
            to: fixture.downloads.appendingPathComponent("\(decomposed) 2.txt")
        )
        try Data("three".utf8).write(
            to: fixture.downloads.appendingPathComponent("Caf\u{00e9} 3.TXT")
        )
        let bytes = Data("four".utf8)
        let manifest = try makeManifest(name: "caf\u{00e9}.txt", bytes: bytes)
        let store = try await fixture.prepare(manifest: manifest)
        try await store.write(bytes, index: 0, entry: 0)

        let output = try await store.finalize()

        XCTAssertEqual(output.lastPathComponent, "caf\u{00e9} 4.txt")
        XCTAssertEqual(try Data(contentsOf: output), bytes)
    }

    func testRepeatedCollisionScanUsesIndependentDirectoryDescription() throws {
        let fixture = try StorageFixture()
        try Data("existing".utf8).write(
            to: fixture.downloads.appendingPathComponent("CAFE\u{301}.txt")
        )
        let descriptor = Darwin.open(
            fixture.downloads.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }

        XCTAssertTrue(
            try directoryContainsEquivalentName(descriptor, candidate: "caf\u{00e9}.txt")
        )
        XCTAssertTrue(
            try directoryContainsEquivalentName(descriptor, candidate: "caf\u{00e9}.txt")
        )
    }

    func testMaximumLengthNameStillReceivesCollisionSuffix() async throws {
        let fixture = try StorageFixture()
        let name = String(repeating: "a", count: 255)
        try Data("old".utf8).write(to: fixture.downloads.appendingPathComponent(name))
        let bytes = Data("new".utf8)
        let manifest = try makeManifest(name: name, bytes: bytes)
        let store = try await fixture.prepare(manifest: manifest)
        try await store.write(bytes, index: 0, entry: 0)

        let output = try await store.finalize()

        XCTAssertLessThanOrEqual(output.lastPathComponent.utf8.count, 255)
        XCTAssertTrue(output.lastPathComponent.hasSuffix(" 2"))
        XCTAssertEqual(try Data(contentsOf: output), bytes)
    }

    func testMalformedDirectoryTreeAndNonNormalizedTraversalAreRejected() async throws {
        XCTAssertThrowsError(try RelativePath("../escape"))
        XCTAssertThrowsError(try RelativePath("folder/e\u{301}.txt"))

        let fixture = try StorageFixture()
        let bytes = Data("x".utf8)
        let entry = TransferManifestEntry(
            relativePath: try RelativePath("root/missing/file.txt"),
            kind: .file,
            size: 1,
            modificationDate: Date(timeIntervalSince1970: 10),
            chunkCount: 1,
            digest: Data(SHA256.hash(data: bytes))
        )
        let manifest = TransferManifest(id: TransferID(rawValue: UUID()), entries: [entry])
        await assertReceiveError(.invalidManifest) {
            _ = try await fixture.prepare(manifest: manifest)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging(manifest.id).path))

        let reserved = try makeManifest(
            name: ".macchannel-metadata-retired-\(UUID().uuidString.lowercased())",
            bytes: bytes
        )
        await assertReceiveError(.invalidManifest) {
            _ = try await fixture.prepare(manifest: reserved)
        }
    }

    func testManifestRejectsChunkCountThatDoesNotMatchFileSize() async throws {
        let fixture = try StorageFixture()
        let entry = TransferManifestEntry(
            relativePath: try RelativePath("bad.bin"),
            kind: .file,
            size: 1,
            modificationDate: Date(),
            chunkCount: 2,
            digest: Data(SHA256.hash(data: Data("x".utf8)))
        )
        let manifest = TransferManifest(id: TransferID(rawValue: UUID()), entries: [entry])

        await assertReceiveError(.invalidManifest) {
            _ = try await fixture.prepare(manifest: manifest)
        }
    }

    func testDestinationPermissionsAreCheckedBeforeStagingAllocation() async throws {
        let fixture = try StorageFixture()
        XCTAssertEqual(chmod(fixture.downloads.path, S_IRUSR | S_IXUSR), 0)
        defer { _ = chmod(fixture.downloads.path, S_IRWXU) }
        let manifest = try makeManifest(name: "denied.txt", bytes: Data("x".utf8))

        await assertReceiveError(.destinationNotWritable) {
            _ = try await fixture.prepare(manifest: manifest)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging(manifest.id).path))
    }

    func testManifestRejectsModificationDatesOutsideTimeTRangeWithoutTrapping() async throws {
        for interval in [1.0e300, -1.0e300] {
            let fixture = try StorageFixture()
            let bytes = Data("timestamp".utf8)
            let manifest = try makeManifest(
                name: "time.txt",
                bytes: bytes,
                modificationDate: Date(timeIntervalSince1970: interval)
            )

            await assertReceiveError(.invalidManifest) {
                _ = try await fixture.prepare(manifest: manifest)
            }

            XCTAssertFalse(
                FileManager.default.fileExists(atPath: fixture.staging(manifest.id).path))
        }
    }

    func testFractionalModificationDateIsValidatedAndAppliedDuringFinalization() async throws {
        let fixture = try StorageFixture()
        let bytes = Data("fractional timestamp".utf8)
        let date = Date(timeIntervalSince1970: 1_700_000_000.125)
        let manifest = try makeManifest(
            name: "fractional.txt",
            bytes: bytes,
            modificationDate: date
        )
        let store = try await fixture.prepare(manifest: manifest)
        try await store.write(bytes, index: 0, entry: 0)

        let output = try await store.finalize()

        var status = stat()
        XCTAssertEqual(stat(output.path, &status), 0)
        XCTAssertEqual(status.st_mtimespec.tv_sec, 1_700_000_000)
        XCTAssertEqual(status.st_mtimespec.tv_nsec, 125_000_000)
    }

    func testIncomingSymlinkIsRejectedWithoutChangingItsTargetPermissions() async throws {
        let fixture = try StorageFixture()
        let target = fixture.root.appendingPathComponent("target", isDirectory: true)
        let linkedIncoming = fixture.root.appendingPathComponent(
            "linked-incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(target.path, 0o755), 0)
        try FileManager.default.createSymbolicLink(at: linkedIncoming, withDestinationURL: target)
        let manifest = try makeManifest(name: "safe.txt", bytes: Data("x".utf8))

        await assertReceiveError(.stagingUnavailable) {
            _ = try await ReceiveStore.prepare(
                manifest: manifest,
                source: fixture.source,
                policy: ReceivePolicy(trustedSources: [fixture.source]),
                directories: DownloadDirectory(globalDirectory: fixture.downloads),
                database: fixture.database,
                incomingDirectory: linkedIncoming,
                capacity: FixedCapacity(bytes: 1_000_000)
            )
        }
        var status = stat()
        XCTAssertEqual(stat(target.path, &status), 0)
        XCTAssertEqual(status.st_mode & 0o777, 0o755)
    }

    func testDestinationReplacementAfterPrepareFailsClosed() async throws {
        let fixture = try StorageFixture()
        let bytes = Data("pinned".utf8)
        let manifest = try makeManifest(name: "pinned.txt", bytes: bytes)
        let store = try await fixture.prepare(manifest: manifest)
        let displaced = fixture.root.appendingPathComponent(
            "displaced-downloads", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.downloads, to: displaced)
        try FileManager.default.createDirectory(
            at: fixture.downloads, withIntermediateDirectories: true)
        try await store.write(bytes, index: 0, entry: 0)

        await assertReceiveError(.atomicPlacementUnavailable) {
            _ = try await store.finalize()
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.downloads.appendingPathComponent("pinned.txt").path
            ))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: displaced.appendingPathComponent("pinned.txt").path
            ))
    }

    func testStagingDirectoryReplacementAfterPrepareFailsClosed() async throws {
        let fixture = try StorageFixture()
        let bytes = Data("staged".utf8)
        let manifest = try makeManifest(name: "staged.txt", bytes: bytes)
        let store = try await fixture.prepare(manifest: manifest)
        let original = fixture.staging(manifest.id)
        let displaced = fixture.incoming.appendingPathComponent("displaced", isDirectory: true)
        try FileManager.default.moveItem(at: original, to: displaced)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(original.path, S_IRWXU), 0)
        await assertReceiveError(.stagingUnavailable) {
            try await store.write(bytes, index: 0, entry: 0)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.downloads.appendingPathComponent("staged.txt").path
            ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testRestartUsesOnlyDescriptorRevalidatedJournalAndRebuildsSQLiteRanges() async throws {
        let fixture = try StorageFixture()
        let bytes = Data(repeating: 9, count: TransferProtocolLimits.maximumChunkBytes + 5)
        let manifest = try makeManifest(name: "resume.bin", bytes: bytes)
        var first: ReceiveStore? = try await fixture.prepare(manifest: manifest)
        try await first?.write(
            bytes.prefix(TransferProtocolLimits.maximumChunkBytes),
            index: 0,
            entry: 0
        )
        let persisted = try await fixture.database.resumeMap(for: manifest.id)
        XCTAssertTrue(
            persisted.contains(
                ChunkCoordinate(entryIndex: 0, chunkIndex: 0)
            ))
        first = nil

        try await fixture.database.replaceVerifiedRanges(
            for: manifest.id,
            with: try ResumeMap(ranges: [
                ChunkRange(entryIndex: 0, lowerBound: 0, upperBound: 2)
            ])
        )
        let reopenedDatabase = try TransferDatabase(url: fixture.databaseURL)
        let resumed = try await fixture.prepare(manifest: manifest, database: reopenedDatabase)
        let recovered = try await resumed.resumeMap()

        XCTAssertTrue(recovered.contains(ChunkCoordinate(entryIndex: 0, chunkIndex: 0)))
        XCTAssertFalse(recovered.contains(ChunkCoordinate(entryIndex: 0, chunkIndex: 1)))
        let repairedDatabaseMap = try await reopenedDatabase.resumeMap(for: manifest.id)
        XCTAssertEqual(repairedDatabaseMap, recovered)
        try await resumed.write(Data(bytes.suffix(5)), index: 1, entry: 0)
        _ = try await resumed.finalize()
    }

    func testRestartCannotReassignPartialStagingToAnotherSource() async throws {
        let fixture = try StorageFixture()
        let secondSource = DeviceID(rawValue: UUID())
        let secondDownloads = fixture.root.appendingPathComponent(
            "second-downloads",
            isDirectory: true
        )
        let bytes = Data("bound source".utf8)
        let manifest = try makeManifest(name: "identity.txt", bytes: bytes)
        var first: ReceiveStore? = try await fixture.prepare(manifest: manifest)
        try await first?.write(bytes, index: 0, entry: 0)
        first = nil

        await assertReceiveError(.invalidManifest) {
            _ = try await ReceiveStore.prepare(
                manifest: manifest,
                source: secondSource,
                policy: ReceivePolicy(trustedSources: [fixture.source, secondSource]),
                directories: DownloadDirectory(
                    globalDirectory: fixture.downloads,
                    perSource: [secondSource: secondDownloads]
                ),
                database: fixture.database,
                incomingDirectory: fixture.incoming,
                capacity: FixedCapacity(bytes: 1_000_000)
            )
        }
        let history = try await fixture.database.history(limit: 1)
        XCTAssertEqual(history.first?.peer, fixture.source)
    }

    func testRestartCannotReassignStagingWhenHistoryDatabaseIsLost() async throws {
        let fixture = try StorageFixture()
        let bytes = Data("independent source binding".utf8)
        let manifest = try makeManifest(name: "bound.txt", bytes: bytes)
        var first: ReceiveStore? = try await fixture.prepare(manifest: manifest)
        try await first?.write(bytes, index: 0, entry: 0)
        first = nil
        let replacementDatabase = try TransferDatabase(
            url: fixture.root.appendingPathComponent("replacement.sqlite3")
        )
        let otherSource = DeviceID(rawValue: UUID())

        await assertReceiveError(.invalidManifest) {
            _ = try await ReceiveStore.prepare(
                manifest: manifest,
                source: otherSource,
                policy: ReceivePolicy(trustedSources: [otherSource]),
                directories: DownloadDirectory(globalDirectory: fixture.downloads),
                database: replacementDatabase,
                incomingDirectory: fixture.incoming,
                capacity: FixedCapacity(bytes: 1_000_000)
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.staging(manifest.id).path))
        let rejectedHistory = try await replacementDatabase.history(limit: 10)
        XCTAssertTrue(rejectedHistory.isEmpty)

        let resumed = try await fixture.prepare(
            manifest: manifest,
            database: replacementDatabase
        )
        let resumeMap = try await resumed.resumeMap()
        XCTAssertTrue(resumeMap.contains(ChunkCoordinate(entryIndex: 0, chunkIndex: 0)))
        let output = try await resumed.finalize()
        XCTAssertEqual(try Data(contentsOf: output), bytes)
    }

    func testRestartRecoversEveryInterruptedInitialPreparationBoundary() async throws {
        for interruptedStep in ReceivePreparationStep.allCases {
            let fixture = try StorageFixture()
            let bytes = Data("initial preparation \(interruptedStep)".utf8)
            let manifest = try makeManifest(name: "creation.txt", bytes: bytes)

            do {
                _ = try await fixture.prepare(
                    manifest: manifest,
                    onPreparationStep: { step in
                        if step == interruptedStep { throw PublicationTestFault.interrupted }
                    }
                )
                XCTFail("Expected preparation interruption after \(interruptedStep)")
            } catch {
                XCTAssertEqual(error as? PublicationTestFault, .interrupted)
            }

            let interruptedHistory = try await fixture.database.history(limit: 10)
            XCTAssertEqual(interruptedHistory.count, 1)
            XCTAssertEqual(interruptedHistory.first?.id, manifest.id)
            XCTAssertEqual(interruptedHistory.first?.peer, fixture.source)
            XCTAssertEqual(interruptedHistory.first?.phase, .preparing)
            let hasInterruptedIntent =
                try await fixture.database.creationIntentExists(for: manifest.id)
            XCTAssertTrue(hasInterruptedIntent)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.staging(manifest.id).path))

            let wrongSource = DeviceID(rawValue: UUID())
            await assertReceiveError(.invalidManifest) {
                _ = try await ReceiveStore.prepare(
                    manifest: manifest,
                    source: wrongSource,
                    policy: ReceivePolicy(trustedSources: [wrongSource]),
                    directories: DownloadDirectory(globalDirectory: fixture.downloads),
                    database: fixture.database,
                    incomingDirectory: fixture.incoming,
                    capacity: FixedCapacity(bytes: 1_000_000)
                )
            }
            let incompatible = try makeManifest(
                name: "creation.txt",
                bytes: Data("incompatible".utf8),
                id: manifest.id
            )
            await assertReceiveError(.invalidManifest) {
                _ = try await fixture.prepare(manifest: incompatible)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.staging(manifest.id).path))

            let recovered = try await fixture.prepare(manifest: manifest)
            let hasReadyIntent = try await fixture.database.creationIntentExists(for: manifest.id)
            XCTAssertFalse(hasReadyIntent)
            try await recovered.write(bytes, index: 0, entry: 0)
            let output = try await recovered.finalize()
            XCTAssertEqual(try Data(contentsOf: output), bytes)
        }
    }

    func testInterruptedPreparationRejectsUnknownContentAndRemainsExpiryEligible()
        async throws
    {
        let fixture = try StorageFixture()
        let bytes = Data("unknown creation content".utf8)
        let manifest = try makeManifest(name: "creation-unknown.txt", bytes: bytes)

        do {
            _ = try await fixture.prepare(
                manifest: manifest,
                onPreparationStep: { step in
                    if step == .sourceBindingWritten {
                        throw PublicationTestFault.interrupted
                    }
                }
            )
            XCTFail("Expected preparation interruption")
        } catch {
            XCTAssertEqual(error as? PublicationTestFault, .interrupted)
        }
        let unknown = fixture.staging(manifest.id).appendingPathComponent("unknown-private-state")
        try Data("do not delete until expiry".utf8).write(to: unknown)

        await assertReceiveError(.stagingUnavailable) {
            _ = try await fixture.prepare(manifest: manifest)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
        let failedHistory = try await fixture.database.history(limit: 1)
        XCTAssertEqual(failedHistory.first?.phase, .failed)
        try await fixture.database.markPhase(
            .failed,
            for: manifest.id,
            at: Date(timeIntervalSince1970: 100)
        )

        let removed = try await ReceiveStore.expireFailedStaging(
            database: fixture.database,
            incomingDirectory: fixture.incoming,
            now: Date(timeIntervalSince1970: 100 + 7 * 86_400)
        )
        XCTAssertEqual(removed, [manifest.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging(manifest.id).path))
    }

    func testReplacementDatabaseRemainsUntouchedWhenStagedJournalRejectsManifest() async throws {
        let fixture = try StorageFixture()
        let id = TransferID(rawValue: UUID())
        let originalBytes = Data("journal-bound manifest".utf8)
        let original = try makeManifest(name: "journal.txt", bytes: originalBytes, id: id)
        var first: ReceiveStore? = try await fixture.prepare(manifest: original)
        try await first?.write(originalBytes, index: 0, entry: 0)
        first = nil
        let replacementDatabase = try TransferDatabase(
            url: fixture.root.appendingPathComponent("journal-replacement.sqlite3")
        )
        let incompatible = try makeManifest(
            name: "journal.txt",
            bytes: Data("different bytes".utf8),
            id: id
        )

        await assertReceiveError(.stagingUnavailable) {
            _ = try await fixture.prepare(
                manifest: incompatible,
                database: replacementDatabase
            )
        }

        let rejectedHistory = try await replacementDatabase.history(limit: 10)
        XCTAssertTrue(rejectedHistory.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.staging(id).path))
    }

    func testRejectedResumeManifestLeavesTransferFailedForExpiry() async throws {
        let fixture = try StorageFixture()
        let id = TransferID(rawValue: UUID())
        let originalBytes = Data("first".utf8)
        let original = try makeManifest(name: "same.txt", bytes: originalBytes, id: id)
        var first: ReceiveStore? = try await fixture.prepare(manifest: original)
        try await first?.write(originalBytes, index: 0, entry: 0)
        try await first?.markFailed(at: Date(timeIntervalSince1970: 100))
        first = nil
        let replacement = try makeManifest(
            name: "same.txt",
            bytes: Data("other".utf8),
            id: id
        )

        await assertReceiveError(.stagingUnavailable) {
            _ = try await fixture.prepare(manifest: replacement)
        }
        let history = try await fixture.database.history(limit: 1)
        XCTAssertEqual(history.first?.phase, .failed)
    }

    func testRejectedAlternatePathsCannotLeakIntoLaterValidPublication() async throws {
        let fixture = try StorageFixture()
        let id = TransferID(rawValue: UUID())
        let bytes = Data("x".utf8)
        let valid = try makeDirectoryManifest(
            id: id,
            childName: "root/good.txt",
            bytes: bytes
        )
        var first: ReceiveStore? = try await fixture.prepare(manifest: valid)
        try await first?.markFailed(at: Date(timeIntervalSince1970: 100))
        first = nil
        let alternate = try makeDirectoryManifest(
            id: id,
            childName: "root/evil.txt",
            bytes: bytes
        )
        await assertReceiveError(.stagingUnavailable) {
            _ = try await fixture.prepare(manifest: alternate)
        }

        let resumed = try await fixture.prepare(manifest: valid)
        try await resumed.write(bytes, index: 0, entry: 1)
        let output = try await resumed.finalize()

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: output.appendingPathComponent("good.txt").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: output.appendingPathComponent("evil.txt").path
            )
        )
    }

    func testDatabaseHistorySchemaContainsNoPathsKeysDigestsOrContent() async throws {
        let fixture = try StorageFixture()
        let bytes = Data("private bytes".utf8)
        let manifest = try makeManifest(name: "history.txt", bytes: bytes)
        let store = try await fixture.prepare(manifest: manifest)
        try await store.write(bytes, index: 0, entry: 0)
        _ = try await store.finalize()

        let history = try await fixture.database.history(limit: 10)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].displayFilename, "history.txt")
        XCTAssertEqual(history[0].phase, .completed)

        let columns = try sqliteColumns(at: fixture.databaseURL)
        let forbiddenFragments = ["path", "content", "key", "digest", "hash"]
        XCTAssertFalse(
            columns.contains { column in
                forbiddenFragments.contains { column.lowercased().contains($0) }
            },
            "privacy-limited schema contained forbidden columns: \(columns)"
        )
    }

    func testMigrationRejectsLegacyPrivacyColumnWithoutAdvancingVersion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("malicious.sqlite3")
        try executeSQLite(
            at: url,
            sql: """
                CREATE TABLE transfers (
                    id TEXT PRIMARY KEY NOT NULL,
                    peer_id TEXT NOT NULL,
                    display_filename TEXT NOT NULL,
                    aggregate_size INTEGER NOT NULL CHECK (aggregate_size >= 0),
                    completed_bytes INTEGER NOT NULL CHECK (completed_bytes >= 0),
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    route TEXT NOT NULL,
                    phase TEXT NOT NULL,
                    content BLOB
                ) STRICT;
                """
        )

        XCTAssertThrowsError(try TransferDatabase(url: url)) { error in
            XCTAssertEqual(error as? ReceiveStoreError, .databaseFailure)
        }
        XCTAssertEqual(try sqliteUserVersion(at: url), 0)
    }

    func testMigrationUpgradesValidatedVersionOneSchemaAtomically() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("version-one.sqlite3")
        try executeSQLite(
            at: url,
            sql: """
                CREATE TABLE transfers (
                    id TEXT PRIMARY KEY NOT NULL,
                    peer_id TEXT NOT NULL,
                    display_filename TEXT NOT NULL,
                    aggregate_size INTEGER NOT NULL CHECK (aggregate_size >= 0),
                    completed_bytes INTEGER NOT NULL CHECK (completed_bytes >= 0),
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    route TEXT NOT NULL,
                    phase TEXT NOT NULL
                ) STRICT;
                CREATE TABLE entries (
                    transfer_id TEXT NOT NULL REFERENCES transfers(id) ON DELETE CASCADE,
                    entry_index INTEGER NOT NULL CHECK (entry_index >= 0),
                    size INTEGER NOT NULL CHECK (size >= 0),
                    chunk_count INTEGER NOT NULL CHECK (chunk_count >= 0),
                    PRIMARY KEY (transfer_id, entry_index)
                ) STRICT;
                CREATE TABLE verified_ranges (
                    transfer_id TEXT NOT NULL REFERENCES transfers(id) ON DELETE CASCADE,
                    entry_index INTEGER NOT NULL CHECK (entry_index >= 0),
                    lower_bound INTEGER NOT NULL CHECK (lower_bound >= 0),
                    upper_bound INTEGER NOT NULL CHECK (upper_bound > lower_bound),
                    PRIMARY KEY (transfer_id, entry_index, lower_bound)
                ) STRICT;
                CREATE INDEX transfers_phase_updated ON transfers(phase, updated_at);
                INSERT INTO transfers (
                    id, peer_id, display_filename, aggregate_size, completed_bytes,
                    created_at, updated_at, route, phase
                ) VALUES (
                    '11111111-1111-1111-1111-111111111111',
                    '22222222-2222-2222-2222-222222222222',
                    'legacy.bin', 10, 2, 1, 1, 'lan', 'transferring'
                );
                PRAGMA user_version = 1;
                """
        )

        let database = try TransferDatabase(url: url)
        let history = try await database.history()
        XCTAssertEqual(history.first?.direction, .unknown)
        withExtendedLifetime(database) {}
        XCTAssertEqual(try sqliteUserVersion(at: url), 3)
        XCTAssertTrue(try sqliteColumns(at: url).contains("preparation_fingerprint"))
        XCTAssertTrue(try sqliteColumns(at: url).contains("direction"))
    }

    func testMigrationRejectsWrongLegacyTypesAndConstraintsWithoutAdvancingVersion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("malformed.sqlite3")
        try executeSQLite(
            at: url,
            sql: """
                CREATE TABLE transfers (
                    id TEXT PRIMARY KEY NOT NULL,
                    peer_id TEXT NOT NULL,
                    display_filename TEXT NOT NULL,
                    aggregate_size TEXT NOT NULL,
                    completed_bytes INTEGER NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    route TEXT NOT NULL,
                    phase TEXT NOT NULL
                ) STRICT;
                """
        )

        XCTAssertThrowsError(try TransferDatabase(url: url)) { error in
            XCTAssertEqual(error as? ReceiveStoreError, .databaseFailure)
        }
        XCTAssertEqual(try sqliteUserVersion(at: url), 0)
    }

    func testMigrationRejectsWrongLegacyForeignKeyAndIndexWithoutAdvancingVersion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("constraints.sqlite3")
        try executeSQLite(
            at: url,
            sql: """
                CREATE TABLE transfers (
                    id TEXT PRIMARY KEY NOT NULL,
                    peer_id TEXT NOT NULL,
                    display_filename TEXT NOT NULL,
                    aggregate_size INTEGER NOT NULL CHECK (aggregate_size >= 0),
                    completed_bytes INTEGER NOT NULL CHECK (completed_bytes >= 0),
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    route TEXT NOT NULL,
                    phase TEXT NOT NULL
                ) STRICT;
                CREATE TABLE entries (
                    transfer_id TEXT NOT NULL,
                    entry_index INTEGER NOT NULL CHECK (entry_index >= 0),
                    size INTEGER NOT NULL CHECK (size >= 0),
                    chunk_count INTEGER NOT NULL CHECK (chunk_count >= 0),
                    PRIMARY KEY (transfer_id, entry_index)
                ) STRICT;
                CREATE INDEX transfers_phase_updated ON transfers(updated_at, phase);
                """
        )

        XCTAssertThrowsError(try TransferDatabase(url: url)) { error in
            XCTAssertEqual(error as? ReceiveStoreError, .databaseFailure)
        }
        XCTAssertEqual(try sqliteUserVersion(at: url), 0)
    }

    func testDatabasePersistsTransferSnapshotsForHistory() async throws {
        let fixture = try StorageFixture()
        let id = TransferID(rawValue: UUID())
        let snapshot = TransferSnapshot(
            id: id,
            peer: fixture.source,
            phase: .paused,
            completedBytes: 12,
            totalBytes: 30,
            route: .relay
        )

        try await fixture.database.record(
            snapshot,
            displayFilename: "report.pdf",
            at: Date(timeIntervalSince1970: 500)
        )
        let history = try await fixture.database.history(limit: 1)

        XCTAssertEqual(history.first?.id, id)
        XCTAssertEqual(history.first?.phase, .paused)
        XCTAssertEqual(history.first?.completedBytes, 12)
        XCTAssertEqual(history.first?.route, .relay)
    }

    func testCancellingDatabasePhaseCannotRegressThroughSnapshotOrPhaseUpdates() async throws {
        let fixture = try StorageFixture()
        let id = TransferID(rawValue: UUID())
        let original = TransferSnapshot(
            id: id,
            peer: fixture.source,
            phase: .transferring,
            completedBytes: 1,
            totalBytes: 10,
            route: .lan
        )
        try await fixture.database.record(original, displayFilename: "cancel-race.txt")
        try await fixture.database.markPhase(.cancelling, for: id, at: Date())
        let stale = TransferSnapshot(
            id: id,
            peer: fixture.source,
            phase: .paused,
            completedBytes: 2,
            totalBytes: 10,
            route: .relay
        )

        await assertReceiveError(.databaseFailure) {
            try await fixture.database.record(stale, displayFilename: "cancel-race.txt")
        }
        await assertReceiveError(.databaseFailure) {
            try await fixture.database.markPhase(.transferring, for: id, at: Date())
        }
        await assertReceiveError(.databaseFailure) {
            try await fixture.database.activatePrepared(id, route: .relay, at: Date())
        }

        let history = try await fixture.database.history(limit: 1)
        XCTAssertEqual(history.first?.phase, .cancelling)
        XCTAssertEqual(history.first?.completedBytes, 1)
        XCTAssertEqual(history.first?.route, .lan)
    }

    func testSnapshotUpdatesCannotRewriteTransferIdentity() async throws {
        let fixture = try StorageFixture()
        let id = TransferID(rawValue: UUID())
        let original = TransferSnapshot(
            id: id,
            peer: fixture.source,
            phase: .transferring,
            completedBytes: 1,
            totalBytes: 10,
            route: .lan
        )
        try await fixture.database.record(original, displayFilename: "fixed.txt")
        let replacement = TransferSnapshot(
            id: id,
            peer: DeviceID(rawValue: UUID()),
            phase: .paused,
            completedBytes: 2,
            totalBytes: 10,
            route: .relay
        )

        do {
            try await fixture.database.record(replacement, displayFilename: "changed.txt")
            XCTFail("Expected immutable identity rejection")
        } catch {
            XCTAssertEqual(error as? ReceiveStoreError, .invalidManifest)
        }
        let history = try await fixture.database.history(limit: 1)
        XCTAssertEqual(history.first?.peer, fixture.source)
        XCTAssertEqual(history.first?.displayFilename, "fixed.txt")
    }

    func testExistingDatabasePermissionsAreTightened() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.sqlite3")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        XCTAssertEqual(chmod(url.path, 0o644), 0)

        _ = try TransferDatabase(url: url)

        var status = stat()
        XCTAssertEqual(stat(url.path, &status), 0)
        XCTAssertEqual(status.st_mode & 0o777, 0o600)
    }

    func testCancelClearsStagingAndSevenDayExpiryRemovesOnlyOldFailedTransfers() async throws {
        let fixture = try StorageFixture()
        let bytes = Data("partial".utf8)
        let cancelledManifest = try makeManifest(name: "cancel.txt", bytes: bytes)
        let cancelled = try await fixture.prepare(manifest: cancelledManifest)
        try await cancelled.write(bytes, index: 0, entry: 0)
        try await cancelled.cancel()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.staging(cancelledManifest.id).path))

        let oldManifest = try makeManifest(name: "old.txt", bytes: bytes)
        var old: ReceiveStore? = try await fixture.prepare(manifest: oldManifest)
        try await old?.markFailed(at: Date(timeIntervalSince1970: 100))
        old = nil
        let recentManifest = try makeManifest(name: "recent.txt", bytes: bytes)
        let recent = try await fixture.prepare(manifest: recentManifest)
        try await recent.markFailed(at: Date(timeIntervalSince1970: 100 + 6 * 86_400))

        let expired = try await ReceiveStore.expireFailedStaging(
            database: fixture.database,
            incomingDirectory: fixture.incoming,
            now: Date(timeIntervalSince1970: 100 + 7 * 86_400)
        )

        XCTAssertEqual(expired, [oldManifest.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging(oldManifest.id).path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.staging(recentManifest.id).path))
    }

    func testRestartCompletesCancellationInterruptedAfterDurableIntent() async throws {
        let fixture = try StorageFixture()
        let bytes = Data("cancel after intent".utf8)
        let manifest = try makeManifest(name: "intent.txt", bytes: bytes)
        var store: ReceiveStore? = try await fixture.prepare(manifest: manifest)
        try await store?.write(bytes, index: 0, entry: 0)

        do {
            try await store?.cancel(onCleanupStep: { step in
                if step == .intentRecorded { throw PublicationTestFault.interrupted }
            })
            XCTFail("Expected cancellation interruption")
        } catch {
            XCTAssertEqual(error as? PublicationTestFault, .interrupted)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.staging(manifest.id).path))
        store = nil

        await assertReceiveError(.alreadyFinished) {
            _ = try await fixture.prepare(manifest: manifest)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging(manifest.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.lease(manifest.id).path))
        let recoveredHistory = try await fixture.database.history(limit: 1)
        XCTAssertEqual(recoveredHistory.first?.phase, .cancelled)
    }

    func testDurableCancellationIntentStopsWritesAndCanRetryInProcess() async throws {
        let fixture = try StorageFixture()
        let bytes = Data("intent blocks writes".utf8)
        let manifest = try makeManifest(name: "blocked.txt", bytes: bytes)
        let store = try await fixture.prepare(manifest: manifest)

        do {
            try await store.cancel(onCleanupStep: { step in
                if step == .intentRecorded { throw PublicationTestFault.interrupted }
            })
            XCTFail("Expected cancellation interruption")
        } catch {
            XCTAssertEqual(error as? PublicationTestFault, .interrupted)
        }
        await assertReceiveError(.alreadyFinished) {
            try await store.write(bytes, index: 0, entry: 0)
        }

        try await store.cancel()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging(manifest.id).path))
        let history = try await fixture.database.history(limit: 1)
        XCTAssertEqual(history.first?.phase, .cancelled)
    }

    func testRestartCompletesCancellationInterruptedAfterStagingDiscard() async throws {
        let fixture = try StorageFixture()
        let bytes = Data("cancel after discard".utf8)
        let manifest = try makeManifest(name: "discard.txt", bytes: bytes)
        var store: ReceiveStore? = try await fixture.prepare(manifest: manifest)
        try await store?.write(bytes, index: 0, entry: 0)

        do {
            try await store?.cancel(onCleanupStep: { step in
                if step == .stagingDiscarded { throw PublicationTestFault.interrupted }
            })
            XCTFail("Expected cancellation interruption")
        } catch {
            XCTAssertEqual(error as? PublicationTestFault, .interrupted)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging(manifest.id).path))
        let interruptedHistory = try await fixture.database.history(limit: 1)
        XCTAssertEqual(interruptedHistory.first?.phase, .cancelling)
        store = nil

        await assertReceiveError(.alreadyFinished) {
            _ = try await fixture.prepare(
                manifest: manifest,
                capacity: FixedCapacity(bytes: 0)
            )
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging(manifest.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.lease(manifest.id).path))
        let recoveredHistory = try await fixture.database.history(limit: 1)
        XCTAssertEqual(recoveredHistory.first?.phase, .cancelled)
    }

    func testSameStoreRetriesCancellationAfterPostDiscardCallbackFailure() async throws {
        let fixture = try StorageFixture()
        let bytes = Data("retry callback cancellation".utf8)
        let manifest = try makeManifest(name: "retry-callback.txt", bytes: bytes)
        let store = try await fixture.prepare(manifest: manifest)
        try await store.write(bytes, index: 0, entry: 0)

        do {
            try await store.cancel(onCleanupStep: { step in
                if step == .stagingDiscarded { throw PublicationTestFault.interrupted }
            })
            XCTFail("Expected cancellation interruption")
        } catch {
            XCTAssertEqual(error as? PublicationTestFault, .interrupted)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging(manifest.id).path))

        try await store.cancel()

        let history = try await fixture.database.history(limit: 1)
        XCTAssertEqual(history.first?.phase, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.lease(manifest.id).path))
    }

    func testCancelClaimPreventsConcurrentFinalizeFromPublishing() async throws {
        let fixture = try StorageFixture()
        let bytes = Data("cancel claims operation".utf8)
        let manifest = try makeManifest(name: "cancel-claim.txt", bytes: bytes)
        let store = try await fixture.prepare(manifest: manifest)
        try await store.write(bytes, index: 0, entry: 0)
        let gate = ReceiveOperationGate()

        let cancellation = Task {
            try await store.cancel(
                onOperationClaimed: { await gate.block() },
                onCleanupStep: { _ in }
            )
        }
        await gate.waitUntilBlocked()

        await assertReceiveError(.alreadyFinished) {
            _ = try await store.finalize()
        }
        await gate.release()
        try await cancellation.value

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.downloads.appendingPathComponent("cancel-claim.txt").path
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging(manifest.id).path))
        let history = try await fixture.database.history(limit: 1)
        XCTAssertEqual(history.first?.phase, .cancelled)
    }

    func testFinalizeClaimMakesConcurrentCancellationTooLate() async throws {
        let fixture = try StorageFixture()
        let bytes = Data("finalize claims operation".utf8)
        let manifest = try makeManifest(name: "finalize-claim.txt", bytes: bytes)
        let store = try await fixture.prepare(manifest: manifest)
        try await store.write(bytes, index: 0, entry: 0)
        let gate = ReceiveOperationGate()

        let finalization = Task {
            try await store.finalize(
                onOperationClaimed: { await gate.block() },
                onPublishedBeforeHistory: {},
                onCleanupStep: { _ in }
            )
        }
        await gate.waitUntilBlocked()

        await assertReceiveError(.alreadyFinalizing) {
            try await store.cancel()
        }
        await gate.release()
        let output = try await finalization.value

        XCTAssertEqual(try Data(contentsOf: output), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging(manifest.id).path))
        let history = try await fixture.database.history(limit: 1)
        XCTAssertEqual(history.first?.phase, .completed)
    }

    func testFinalizeDatabaseFailureReleasesOnlyItsClaimForCancellation() async throws {
        let fixture = try StorageFixture()
        let bytes = Data("finalize rollback epoch".utf8)
        let manifest = try makeManifest(name: "finalize-rollback.txt", bytes: bytes)
        let store = try await fixture.prepare(manifest: manifest)
        try await store.write(bytes, index: 0, entry: 0)
        try await fixture.database.markPhase(.cancelling, for: manifest.id, at: Date())

        await assertReceiveError(.databaseFailure) {
            _ = try await store.finalize()
        }
        try await store.cancel()

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.downloads.appendingPathComponent("finalize-rollback.txt").path
            )
        )
        let history = try await fixture.database.history(limit: 1)
        XCTAssertEqual(history.first?.phase, .cancelled)
    }

    func testSameStoreRetriesCancellationAfterDatabaseFailureFollowingDiscard() async throws {
        let fixture = try StorageFixture()
        let bytes = Data("retry database cancellation".utf8)
        let manifest = try makeManifest(name: "retry-database.txt", bytes: bytes)
        let store = try await fixture.prepare(manifest: manifest)
        try await store.write(bytes, index: 0, entry: 0)
        let lock = try SQLiteWriteLock(url: fixture.databaseURL)

        do {
            try await store.cancel(onCleanupStep: { step in
                if step == .stagingDiscarded { try lock.acquire() }
            })
            XCTFail("Expected database failure")
        } catch {
            XCTAssertEqual(error as? ReceiveStoreError, .databaseFailure)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging(manifest.id).path))
        lock.release()

        try await store.cancel()

        let history = try await fixture.database.history(limit: 1)
        XCTAssertEqual(history.first?.phase, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.lease(manifest.id).path))
    }

    func testRestartCompletesCancellationAfterDatabaseFailureFollowingDiscard() async throws {
        let fixture = try StorageFixture()
        let bytes = Data("restart database cancellation".utf8)
        let manifest = try makeManifest(name: "restart-database.txt", bytes: bytes)
        var store: ReceiveStore? = try await fixture.prepare(manifest: manifest)
        try await store?.write(bytes, index: 0, entry: 0)
        let lock = try SQLiteWriteLock(url: fixture.databaseURL)

        do {
            try await store?.cancel(onCleanupStep: { step in
                if step == .stagingDiscarded { try lock.acquire() }
            })
            XCTFail("Expected database failure")
        } catch {
            XCTAssertEqual(error as? ReceiveStoreError, .databaseFailure)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging(manifest.id).path))
        lock.release()
        store = nil

        await assertReceiveError(.alreadyFinished) {
            _ = try await fixture.prepare(manifest: manifest)
        }

        let history = try await fixture.database.history(limit: 1)
        XCTAssertEqual(history.first?.phase, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.lease(manifest.id).path))
    }

    func testTerminalPhaseCommittedAfterLeaseReadCannotBeOverwrittenOrAllocateStaging()
        async throws
    {
        let fixture = try StorageFixture()
        let bytes = Data("terminal phase race".utf8)
        let manifest = try makeManifest(name: "terminal-race.txt", bytes: bytes)
        var first: ReceiveStore? = try await fixture.prepare(manifest: manifest)
        try await first?.markFailed(at: Date(timeIntervalSince1970: 100))
        first = nil
        _ = try await ReceiveStore.expireFailedStaging(
            database: fixture.database,
            incomingDirectory: fixture.incoming,
            now: Date(timeIntervalSince1970: 100 + 7 * 86_400)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging(manifest.id).path))

        let capacity = BlockingReceiveCapacity(bytes: 1_000_000)
        let preparation = Task {
            try await fixture.prepare(
                manifest: manifest,
                capacity: capacity,
                onPreparationStep: { step in
                    if step == .treeCreated { throw PublicationTestFault.interrupted }
                }
            )
        }
        await capacity.waitUntilEntered()
        let competingDatabase = try TransferDatabase(url: fixture.databaseURL)
        try await competingDatabase.markPhase(.completed, for: manifest.id, at: Date())
        capacity.release()

        do {
            _ = try await preparation.value
            XCTFail("Expected terminal phase to reject preparation")
        } catch {
            XCTAssertEqual(error as? ReceiveStoreError, .alreadyFinished)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging(manifest.id).path))
        let history = try await fixture.database.history(limit: 1)
        XCTAssertEqual(history.first?.phase, .completed)
    }

    func testCompletedAndCancelledHistoryNeverAllocateFreshStaging() async throws {
        for phase in [TransferPhase.completed, .cancelled] {
            let fixture = try StorageFixture()
            let bytes = Data("terminal \(phase)".utf8)
            let manifest = try makeManifest(name: "terminal.txt", bytes: bytes)
            try await fixture.database.record(
                TransferSnapshot(
                    id: manifest.id,
                    peer: fixture.source,
                    phase: phase,
                    completedBytes: Int64(bytes.count),
                    totalBytes: Int64(bytes.count),
                    route: .lan
                ),
                displayFilename: "terminal.txt"
            )

            await assertReceiveError(.alreadyFinished) {
                _ = try await fixture.prepare(manifest: manifest)
            }

            XCTAssertFalse(
                FileManager.default.fileExists(atPath: fixture.staging(manifest.id).path)
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.lease(manifest.id).path))
        }
    }

    func testRestartCompletesCancellationFromPartiallyDiscardedStaging() async throws {
        let fixture = try StorageFixture()
        let bytes = Data("partial cancellation cleanup".utf8)
        let manifest = try makeManifest(name: "partial-cancel.txt", bytes: bytes)
        var store: ReceiveStore? = try await fixture.prepare(manifest: manifest)
        try await store?.write(bytes, index: 0, entry: 0)
        try await fixture.database.markPhase(.cancelling, for: manifest.id, at: Date())
        try FileManager.default.removeItem(
            at: fixture.staging(manifest.id)
                .appendingPathComponent(".macchannel-storage-metadata/.resume-state")
        )
        store = nil

        await assertReceiveError(.alreadyFinished) {
            _ = try await fixture.prepare(
                manifest: manifest,
                capacity: FixedCapacity(bytes: 0)
            )
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging(manifest.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.lease(manifest.id).path))
        let history = try await fixture.database.history(limit: 1)
        XCTAssertEqual(history.first?.phase, .cancelled)
    }

    func testTerminalCancellationRecoveryIgnoresRevokedPolicyAndUnavailableDestination()
        async throws
    {
        let fixture = try StorageFixture()
        let bytes = Data("policy independent cancellation".utf8)
        let manifest = try makeManifest(name: "revoked.txt", bytes: bytes)
        var store: ReceiveStore? = try await fixture.prepare(manifest: manifest)
        try await store?.write(bytes, index: 0, entry: 0)
        do {
            try await store?.cancel(onCleanupStep: { step in
                if step == .stagingDiscarded { throw PublicationTestFault.interrupted }
            })
            XCTFail("Expected cancellation interruption")
        } catch {
            XCTAssertEqual(error as? PublicationTestFault, .interrupted)
        }
        store = nil
        try FileManager.default.removeItem(at: fixture.downloads)
        XCTAssertTrue(
            FileManager.default.createFile(atPath: fixture.downloads.path, contents: Data()))

        await assertReceiveError(.alreadyFinished) {
            _ = try await ReceiveStore.prepare(
                manifest: manifest,
                source: fixture.source,
                policy: ReceivePolicy(trustedSources: []),
                directories: DownloadDirectory(globalDirectory: fixture.downloads),
                database: fixture.database,
                incomingDirectory: fixture.incoming,
                capacity: FixedCapacity(bytes: 0)
            )
        }

        let history = try await fixture.database.history(limit: 1)
        XCTAssertEqual(history.first?.phase, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.lease(manifest.id).path))
    }

    func testCompletedHistoryDiscardsPartiallyRemovedResidualStaging() async throws {
        let fixture = try StorageFixture()
        let bytes = Data("completed partial cleanup".utf8)
        let manifest = try makeManifest(name: "completed-partial.txt", bytes: bytes)
        var store: ReceiveStore? = try await fixture.prepare(manifest: manifest)
        try await store?.write(bytes, index: 0, entry: 0)
        do {
            _ = try await store?.finalize(
                onPublishedBeforeHistory: {},
                onCleanupStep: { step in
                    if step == .historyCommitted { throw PublicationTestFault.interrupted }
                }
            )
            XCTFail("Expected cleanup interruption")
        } catch {
            XCTAssertEqual(error as? ReceiveStoreError, .atomicPlacementUnavailable)
        }
        try FileManager.default.removeItem(
            at: fixture.staging(manifest.id)
                .appendingPathComponent(".macchannel-storage-metadata/.resume-state")
        )
        store = nil

        await assertReceiveError(.alreadyFinished) {
            _ = try await fixture.prepare(
                manifest: manifest,
                capacity: FixedCapacity(bytes: 0)
            )
        }

        XCTAssertEqual(
            try Data(contentsOf: fixture.downloads.appendingPathComponent("completed-partial.txt")),
            bytes
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging(manifest.id).path))
    }

    func testExpiryFinishesRecognizedCrashLeftQuarantine() async throws {
        let fixture = try StorageFixture()
        let manifest = try makeManifest(
            name: "quarantined.txt",
            bytes: Data("orphan".utf8)
        )
        var store: ReceiveStore? = try await fixture.prepare(manifest: manifest)
        try await store?.markFailed(at: Date(timeIntervalSince1970: 100))
        store = nil
        let quarantine = fixture.incoming.appendingPathComponent(
            ".macchannel-expired-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: fixture.staging(manifest.id), to: quarantine)

        _ = try await ReceiveStore.expireFailedStaging(
            database: fixture.database,
            incomingDirectory: fixture.incoming,
            now: Date(timeIntervalSince1970: 100 + 7 * 86_400)
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantine.path))
    }
}

private enum PublicationTestFault: Error, Equatable {
    case interrupted
}

private struct StorageFixture {
    let root: URL
    let downloads: URL
    let incoming: URL
    let databaseURL: URL
    let database: TransferDatabase
    let source = DeviceID(rawValue: UUID())

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        downloads = root.appendingPathComponent("downloads", isDirectory: true)
        incoming = root.appendingPathComponent("Incoming", isDirectory: true)
        databaseURL = root.appendingPathComponent("history.sqlite3")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        database = try TransferDatabase(url: databaseURL)
    }

    func staging(_ id: TransferID) -> URL {
        incoming.appendingPathComponent(id.rawValue.uuidString.lowercased(), isDirectory: true)
    }

    func lease(_ id: TransferID) -> URL {
        incoming.appendingPathComponent(
            ".macchannel-lease-\(id.rawValue.uuidString.lowercased())"
        )
    }

    func prepare(
        manifest: TransferManifest,
        capacity: any ReceiveCapacityProviding = FixedCapacity(bytes: 1_000_000_000),
        database: TransferDatabase? = nil,
        onPreparationStep: @escaping @Sendable (ReceivePreparationStep) throws -> Void = { _ in }
    ) async throws -> ReceiveStore {
        try await ReceiveStore.prepare(
            manifest: manifest,
            source: source,
            policy: ReceivePolicy(trustedSources: [source]),
            directories: DownloadDirectory(globalDirectory: downloads),
            database: database ?? self.database,
            incomingDirectory: incoming,
            capacity: capacity,
            onPreparationStep: onPreparationStep
        )
    }
}

private final class SQLiteWriteLock: @unchecked Sendable {
    private var connection: OpaquePointer?

    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            if let connection { sqlite3_close(connection) }
            throw NSError(domain: "ReceiveStoreTests", code: 8)
        }
        guard sqlite3_busy_timeout(connection, 0) == SQLITE_OK else {
            throw NSError(domain: "ReceiveStoreTests", code: 9)
        }
    }

    deinit {
        release()
        if let connection { sqlite3_close(connection) }
    }

    func acquire() throws {
        guard let connection,
            sqlite3_exec(connection, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK
        else { throw NSError(domain: "ReceiveStoreTests", code: 10) }
    }

    func release() {
        if let connection { _ = sqlite3_exec(connection, "ROLLBACK", nil, nil, nil) }
    }
}

private actor ReceiveOperationGate {
    private var blocked = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func block() async {
        blocked = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilBlocked() async {
        guard !blocked else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private final class BlockingReceiveCapacity: ReceiveCapacityProviding, @unchecked Sendable {
    private let condition = NSCondition()
    private let stateLock = NSLock()
    private let bytes: UInt64
    private var entered = false
    private var released = false

    init(bytes: UInt64) { self.bytes = bytes }

    func availableBytes(at directory: URL) throws -> UInt64 {
        _ = directory
        condition.lock()
        stateLock.withLock { entered = true }
        condition.broadcast()
        while !released { condition.wait() }
        condition.unlock()
        return bytes
    }

    func waitUntilEntered() async {
        while true {
            let hasEntered = stateLock.withLock { entered }
            if hasEntered { return }
            await Task.yield()
        }
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class FixedCapacity: ReceiveCapacityProviding, @unchecked Sendable {
    private let value: UInt64

    init(bytes: UInt64) { value = bytes }

    func availableBytes(at directory: URL) throws -> UInt64 {
        _ = directory
        return value
    }
}

private final class MutableCapacity: ReceiveCapacityProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64

    var bytes: UInt64 {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }

    init(bytes: UInt64) { value = bytes }

    func availableBytes(at directory: URL) throws -> UInt64 {
        _ = directory
        return bytes
    }
}

private func makeManifest(
    name: String,
    bytes: Data,
    digest: Data? = nil,
    id: TransferID = TransferID(rawValue: UUID()),
    modificationDate: Date = Date(timeIntervalSince1970: 1_700_000_000)
) throws -> TransferManifest {
    let count: UInt32
    if bytes.isEmpty {
        count = 0
    } else {
        let chunkSize = TransferProtocolLimits.maximumChunkBytes
        count = UInt32((bytes.count + chunkSize - 1) / chunkSize)
    }
    return TransferManifest(
        id: id,
        entries: [
            TransferManifestEntry(
                relativePath: try RelativePath(name),
                kind: .file,
                size: UInt64(bytes.count),
                modificationDate: modificationDate,
                chunkCount: count,
                digest: digest ?? Data(SHA256.hash(data: bytes))
            )
        ]
    )
}

private func makeDirectoryManifest(
    id: TransferID,
    childName: String,
    bytes: Data
) throws -> TransferManifest {
    TransferManifest(
        id: id,
        entries: [
            TransferManifestEntry(
                relativePath: try RelativePath("root"),
                kind: .directory,
                size: 0,
                modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
                chunkCount: 0,
                digest: Data(SHA256.hash(data: Data()))
            ),
            TransferManifestEntry(
                relativePath: try RelativePath(childName),
                kind: .file,
                size: UInt64(bytes.count),
                modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
                chunkCount: bytes.isEmpty ? 0 : 1,
                digest: Data(SHA256.hash(data: bytes))
            ),
        ]
    )
}

private func assertReceiveError(
    _ expected: ReceiveStoreError,
    operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? ReceiveStoreError, expected, file: file, line: line)
    }
}

private func sqliteColumns(at url: URL) throws -> [String] {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
        let database
    else { throw NSError(domain: "ReceiveStoreTests", code: 1) }
    defer { sqlite3_close(database) }
    var result: [String] = []
    for table in ["transfers", "entries", "verified_ranges"] {
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil)
                == SQLITE_OK,
            let statement
        else { throw NSError(domain: "ReceiveStoreTests", code: 2) }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) {
                result.append(String(cString: name))
            }
        }
    }
    return result
}

private func executeSQLite(at url: URL, sql: String) throws {
    var database: OpaquePointer?
    guard
        sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        ) == SQLITE_OK, let database
    else { throw NSError(domain: "ReceiveStoreTests", code: 3) }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw NSError(domain: "ReceiveStoreTests", code: 4)
    }
}

private func sqliteUserVersion(at url: URL) throws -> Int32 {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
        let database
    else { throw NSError(domain: "ReceiveStoreTests", code: 5) }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
        let statement
    else { throw NSError(domain: "ReceiveStoreTests", code: 6) }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw NSError(domain: "ReceiveStoreTests", code: 7)
    }
    return sqlite3_column_int(statement, 0)
}
