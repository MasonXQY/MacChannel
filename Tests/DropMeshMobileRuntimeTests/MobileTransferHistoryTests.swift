import Foundation
import XCTest
@testable import MacChannelCore
@testable import DropMeshMobileRuntime

final class MobileTransferHistoryTests: XCTestCase {
    func testDeleteHistoryPersistsAcrossRelaunchAndKeepsPayload() async throws {
        let f = try HistoryFixture(); defer { f.remove() }
        let first = try await f.receive("keep-payload")
        let second = try await f.receive("other")
        let history = MobileTransferHistory(database: f.database, outputs: f.index())
        await history.recordCompletedReceive(first); await history.recordCompletedReceive(second)
        try await history.delete(ids: [first.transferID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.receivedURLs[0].path))
        let reopened = MobileTransferHistory(database: f.database, outputs: f.index())
        let reopenedItems = try await reopened.items()
        let deletedURL = await reopened.availableURL(for: first.transferID)
        XCTAssertEqual(reopenedItems.map(\.id), [second.transferID])
        XCTAssertNil(deletedURL)
    }

    func testDeleteAllUsesFullDatabaseAndProtectsActiveTransfer() async throws {
        let f = try HistoryFixture(); defer { f.remove() }
        for index in 0..<105 { _ = try await f.receive("terminal-\(index)", phase: .failed) }
        let active = try await f.receive("active-delete-protected", phase: .transferring, bytes: 0)
        let history = MobileTransferHistory(database: f.database, outputs: f.index())
        try await history.delete(ids: nil)
        let remaining = try await history.items(limit: 1_000)
        XCTAssertEqual(remaining.map(\.id), [active.transferID])
        let databaseRows = try await f.database.persistedHistory(limit: 1_000)
        XCTAssertEqual(databaseRows.count, 106)
    }
    func testCorruptDeletionStoreFailsClosedWithoutResurrectingHistory() async throws {
        let f = try HistoryFixture(); defer { f.remove() }
        let result = try await f.receive("must-not-resurrect")
        let tombstones = f.indexURL.deletingLastPathComponent().appendingPathComponent("history-deletions-v1.json")
        try Data("corrupt".utf8).write(to: tombstones)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tombstones.path)
        let history = MobileTransferHistory(database: f.database, outputs: f.index())
        let visible = try await history.items()
        let resolved = await history.availableURL(for: result.transferID)
        XCTAssertTrue(visible.isEmpty)
        XCTAssertNil(resolved)
        do { try await history.delete(ids: [result.transferID]); XCTFail("Corrupt deletion state must reject writes") }
        catch { XCTAssertEqual(try Data(contentsOf: tombstones), Data("corrupt".utf8)) }
    }

    func testDeletionStoreRejectsCountBeyondReloadBoundTransactionally() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MobileHistoryDeletionStore(url: root.appendingPathComponent("deletions.json"))
        let ids = Set((0...20_000).map { _ in TransferID(rawValue: UUID()) })
        do { try await store.add(ids); XCTFail("Must enforce the reload count bound before commit") }
        catch { XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("deletions.json").path)) }
    }
    func testBatchFilesPersistResolveFreshAndRejectReplacementSymlink() async throws {
        let f = try HistoryFixture(); defer { f.remove() }
        let root = f.receiveRoot.appendingPathComponent("batch", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let first = root.appendingPathComponent("one.txt")
        let second = root.appendingPathComponent("two.txt")
        try Data([1]).write(to: first); try Data([2, 3]).write(to: second)
        let id = TransferID(rawValue: UUID())
        try await f.database.record(TransferSnapshot(id: id, peer: f.peer, phase: .completed,
            completedBytes: 3, totalBytes: 3, route: .lan), displayFilename: "batch", direction: .inbound)
        let result = TransferReceiveResult(transferID: id, receivedURLs: [root], source: f.peer,
            items: [
                TransferReceivedItemMetadata(relativePathComponents: ["one.txt"], name: "one.txt", size: 1, isDirectory: false),
                TransferReceivedItemMetadata(relativePathComponents: ["two.txt"], name: "two.txt", size: 2, isDirectory: false),
            ])
        await MobileTransferHistory(database: f.database, outputs: f.index()).recordCompletedReceive(result)

        let reopened = MobileTransferHistory(database: f.database, outputs: f.index())
        let loaded = try await reopened.items()
        let item = try XCTUnwrap(loaded.first)
        XCTAssertFalse(item.isLegacy)
        XCTAssertEqual(item.files.map(\.name), ["one.txt", "two.txt"])
        XCTAssertTrue(item.files.allSatisfy(\.isAvailable))
        let secondID = item.files[1].id
        try FileManager.default.removeItem(at: second)
        try FileManager.default.createSymbolicLink(at: second, withDestinationURL: f.root.appendingPathComponent("outside"))
        let replacedURL = await reopened.availableURL(for: id, itemID: secondID)
        let retainedURL = await reopened.availableURL(for: id, itemID: item.files[0].id)
        XCTAssertNil(replacedURL)
        XCTAssertNotNil(retainedURL)
    }

    func testSentMetadataSurvivesSourceDeletionWithoutRetainingPreview() async throws {
        let f = try HistoryFixture(); defer { f.remove() }
        let source = f.root.appendingPathComponent("temporary-photo.jpg")
        try Data([1, 2, 3]).write(to: source)
        let id = TransferID(rawValue: UUID())
        try await f.database.record(TransferSnapshot(id: id, peer: f.peer, phase: .completed,
            completedBytes: 3, totalBytes: 3, route: .lan), displayFilename: source.lastPathComponent, direction: .outbound)
        let history = MobileTransferHistory(database: f.database, outputs: f.index())
        await history.recordCompletedSend(id, items: [source])
        try FileManager.default.removeItem(at: source)
        let reopened = MobileTransferHistory(database: f.database, outputs: f.index())
        let loaded = try await reopened.items()
        let item = try XCTUnwrap(loaded.first)
        XCTAssertFalse(item.isLegacy)
        XCTAssertEqual(item.files.map(\.name), ["temporary-photo.jpg"])
        XCTAssertFalse(item.files[0].isAvailable)
        XCTAssertNil(item.files[0].availableURL)
    }

    func testDatabaseOnlyLegacyDirectoryDoesNotInventChildren() async throws {
        let f = try HistoryFixture(); defer { f.remove() }
        _ = try await f.receive("old-folder", directory: true)
        let loaded = try await MobileTransferHistory(database: f.database, outputs: f.index()).items()
        let item = try XCTUnwrap(loaded.first)
        XCTAssertTrue(item.isLegacy)
        XCTAssertTrue(item.files.isEmpty)
    }

    func testOversizedSentMetadataDoesNotPoisonLaterSmallRecord() async throws {
        let f = try HistoryFixture(); defer { f.remove() }
        let history = MobileTransferHistory(database: f.database, outputs: f.index())
        let oversizedID = TransferID(rawValue: UUID())
        let longPrefix = String(repeating: "x", count: 235)
        let excessive = (0..<10_000).map { f.root.appendingPathComponent("\(longPrefix)-\($0)") }
        await history.recordCompletedSend(oversizedID, items: excessive)

        let smallID = TransferID(rawValue: UUID())
        let small = f.root.appendingPathComponent("small.txt")
        try Data([1]).write(to: small)
        await history.recordCompletedSend(smallID, items: [small])
        let reloaded = MobileTransferHistory(database: f.database, outputs: f.index())
        let oversizedURL = await reloaded.availableURL(for: oversizedID,
            itemID: MobileHistoryFileID(rawValue: oversizedID.rawValue))
        XCTAssertNil(oversizedURL)
        let stored = await MobileHistoryItemsIndex(url: f.indexURL.deletingLastPathComponent()
            .appendingPathComponent("history-items-v1.json")).files(for: smallID)
        XCTAssertEqual(stored?.first?.name, "small.txt")
    }
    func testHistoryReadPropagatesParentIdentityFailureButNotMissingUserFile() async throws {
        let f = try HistoryFixture(); defer { f.remove() }
        let index = f.index()
        let history = MobileTransferHistory(database: f.database, outputs: index)
        let result = try await f.receive("published")
        await history.recordCompletedReceive(result)
        try FileManager.default.removeItem(at: result.receivedURLs[0])
        let missingItems = try await history.items()
        let missingFailure = await history.availabilityFailure
        XCTAssertNil(missingItems.first?.availableURL)
        XCTAssertNil(missingFailure)

        try Data([1]).write(to: result.receivedURLs[0])
        let oldState = f.root.appendingPathComponent("old-state")
        try FileManager.default.moveItem(at: f.indexURL.deletingLastPathComponent(), to: oldState)
        try FileManager.default.createDirectory(at: f.indexURL.deletingLastPathComponent(),
            withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let brokenItems = try await history.items()
        let brokenFailure = await history.availabilityFailure
        XCTAssertNil(brokenItems.first?.availableURL)
        XCTAssertEqual(brokenFailure, .receivedOutputIndexUnavailable)
    }

    func testJoinsCanonicalMetadataOrderingAndClampsVisibleLimitWithoutPruning() async throws {
        let f = try HistoryFixture(); defer { f.remove() }
        let index = f.index()
        let history = MobileTransferHistory(database: f.database, outputs: index)
        let received = try await f.receive("collision (2)")
        await history.recordCompletedReceive(received)
        _ = try await f.receive("outbound", direction: .outbound)
        _ = try await f.receive("active", phase: .transferring, bytes: 0)
        _ = try await f.receive("failed", phase: .failed)
        let rows = try await f.database.persistedHistory(limit: 1000)
        let items = try await history.items(limit: Int.max)
        XCTAssertEqual(items.map(\.id), rows.map(\.id))
        for (item, row) in zip(items, rows) {
            XCTAssertEqual(item.displayName, row.displayFilename)
            XCTAssertEqual(item.peer, row.peer)
            XCTAssertEqual(item.aggregateSize, row.aggregateSize)
            XCTAssertEqual(item.completedBytes, row.completedBytes)
            XCTAssertEqual(item.updatedAt, row.updatedAt)
            XCTAssertEqual(item.route, row.route)
            XCTAssertEqual(item.phase, row.phase)
            XCTAssertEqual(item.direction, row.direction)
            XCTAssertEqual(item.canOpenReceivedItem, item.id == received.transferID)
        }
        let empty = try await history.items(limit: 0)
        XCTAssertTrue(empty.isEmpty)
        let limited = try await history.items(limit: 1)
        XCTAssertEqual(limited.count, 1)
        let older = await history.availableURL(for: received.transferID)
        XCTAssertNotNil(older)
    }

    func testReopenedDatabaseAndIndexRetainMetadataThenDeletionDisablesAction() async throws {
        let f = try HistoryFixture(); defer { f.remove() }
        let result = try await f.receive("published")
        await MobileTransferHistory(database: f.database, outputs: f.index()).recordCompletedReceive(result)
        try await f.database.close()
        let reopenedDB = try TransferDatabase(url: f.indexURL.deletingLastPathComponent().appendingPathComponent("transfers.sqlite3"))
        let reopenedIndex = MobileReceivedOutputIndex(url: f.indexURL, receiveDirectory: f.receiveRoot, database: reopenedDB)
        let history = MobileTransferHistory(database: reopenedDB, outputs: reopenedIndex)
        let before = try await history.items()
        XCTAssertEqual(before.count, 1)
        XCTAssertTrue(before[0].canOpenReceivedItem)
        try FileManager.default.removeItem(at: result.receivedURLs[0])
        let actionURL = await history.availableURL(for: result.transferID)
        XCTAssertNil(actionURL)
        let after = try await history.items()
        XCTAssertEqual(after.first?.phase, .completed)
        XCTAssertFalse(after[0].canOpenReceivedItem)
        try await reopenedDB.close()
    }

    func testIndexWriteFailurePreservesSuccessfulMetadataAndCoarseDiagnostic() async throws {
        let f = try HistoryFixture(); defer { f.remove() }
        let index = f.index()
        let history = MobileTransferHistory(database: f.database, outputs: index)
        let result = try await f.receive("published")
        // Deterministic unwritable destination: a directory cannot be replaced by
        // the index regular file, even when the test process has elevated rights.
        try FileManager.default.createDirectory(at: f.indexURL, withIntermediateDirectories: false)
        await history.recordCompletedReceive(result)
        let items = try await history.items()
        XCTAssertEqual(items.first?.phase, .completed)
        XCTAssertNil(items.first?.availableURL)
        let diagnostic = await history.availabilityFailure
        XCTAssertEqual(diagnostic, .receivedOutputIndexUnavailable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.receivedURLs[0].path))
        let corruptHistory = MobileTransferHistory(database: f.database, outputs: f.index())
        let reopened = try await corruptHistory.items()
        XCTAssertEqual(reopened.first?.phase, .completed)
        XCTAssertNil(reopened.first?.availableURL)
    }
}
