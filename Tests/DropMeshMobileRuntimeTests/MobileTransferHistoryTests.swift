import Foundation
import XCTest
@testable import MacChannelCore
@testable import DropMeshMobileRuntime

final class MobileTransferHistoryTests: XCTestCase {
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
