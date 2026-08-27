import Foundation
import XCTest
@testable import MacChannelCore

final class TransferDatabaseLifecycleTests: XCTestCase {
    func testExplicitCloseRejectsFurtherUseAndAllowsImmediateReopen() async throws {
        let root = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: FileManager.default.temporaryDirectory,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.sqlite")
        let first = try TransferDatabase(url: url)

        try await first.close()
        let reopened = try TransferDatabase(url: url)

        do {
            _ = try await first.history(limit: 1)
            XCTFail("A closed database must reject further reads")
        } catch {
            XCTAssertEqual(error as? ReceiveStoreError, .databaseFailure)
        }
        let reopenedHistory = try await reopened.history(limit: 1)
        XCTAssertEqual(reopenedHistory, [])
        try await reopened.close()
    }
}
