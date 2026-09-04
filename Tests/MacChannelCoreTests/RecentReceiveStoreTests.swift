import Foundation
import XCTest
@testable import MacChannelAppKit
@testable import MacChannelCore

@MainActor
final class RecentReceiveStoreTests: XCTestCase {
    func testStoreShowsNewestFiveAndAcknowledgesIndividually() {
        let store = RecentReceiveStore()
        let base = Date(timeIntervalSince1970: 1_000)
        let results = (0..<6).map { index in
            TransferReceiveResult(
                transferID: TransferID(rawValue: UUID()),
                receivedURLs: [URL(fileURLWithPath: "/tmp/file-\(index).txt")]
            )
        }
        for (index, result) in results.enumerated() {
            store.record(result, sourceName: "Mac \(index)", completedAt: base.addingTimeInterval(Double(index)))
        }

        XCTAssertEqual(store.snapshot.visible.map(\.id), results.reversed().prefix(5).map(\.transferID))
        XCTAssertEqual(store.snapshot.overflowCount, 1)
        store.acknowledge(results[5].transferID)
        XCTAssertFalse(store.snapshot.visible.contains { $0.id == results[5].transferID })
        XCTAssertTrue(store.hasUnread)
        store.acknowledgeAll()
        XCTAssertFalse(store.hasUnread)
    }

    func testStoreRejectsEmptyResultsAndDoesNotNotify() {
        let store = RecentReceiveStore()
        var changes = 0
        store.onChange = { _ in changes += 1 }

        store.record(
            TransferReceiveResult(transferID: TransferID(rawValue: UUID()), receivedURLs: []),
            sourceName: "Mac"
        )

        XCTAssertEqual(store.snapshot, RecentReceiveSnapshot(visible: [], overflowCount: 0))
        XCTAssertFalse(store.hasUnread)
        XCTAssertEqual(changes, 0)
    }

    func testStoreRetainsSourceNameAtReceiveTimeAndUsesFallbackForEmptyName() {
        let store = RecentReceiveStore()
        let source = DeviceID(rawValue: UUID())
        let result = TransferReceiveResult(
            transferID: TransferID(rawValue: UUID()),
            receivedURLs: [URL(fileURLWithPath: "/tmp/report.pdf")],
            source: source
        )

        store.record(result, sourceName: "MacBook Pro")
        XCTAssertEqual(store.snapshot.visible.first?.sourceName, "MacBook Pro")
        XCTAssertEqual(store.snapshot.visible.first?.source, source)
        XCTAssertEqual(store.snapshot.visible.first?.title, "report.pdf")

        store.record(result, sourceName: "")
        XCTAssertEqual(store.snapshot.visible.first?.sourceName, "其他设备")
    }

    func testAcknowledgeUnknownAndAcknowledgeAllWhenEmptyDoNotNotify() {
        let store = RecentReceiveStore()
        var changes = 0
        store.onChange = { _ in changes += 1 }
        let unknown = TransferID(rawValue: UUID())

        store.acknowledge(unknown)
        store.acknowledgeAll()

        XCTAssertEqual(changes, 0)
    }

    func testOnChangePublishesAfterEffectiveMutations() {
        let store = RecentReceiveStore()
        var snapshots: [RecentReceiveSnapshot] = []
        store.onChange = { snapshots.append($0) }
        let result = TransferReceiveResult(
            transferID: TransferID(rawValue: UUID()),
            receivedURLs: [URL(fileURLWithPath: "/tmp/file.txt")]
        )

        store.record(result, sourceName: "Mac")
        store.record(result, sourceName: "Mac renamed")
        store.acknowledge(result.transferID)
        store.acknowledgeAll()

        XCTAssertEqual(snapshots.count, 3)
        XCTAssertEqual(snapshots[0].visible.count, 1)
        XCTAssertEqual(snapshots[1].visible.first?.sourceName, "Mac renamed")
        XCTAssertFalse(snapshots[2].hasUnread)
    }

    func testStoreOrdersByReceiveCompletionInsteadOfPublicationOrder() {
        let store = RecentReceiveStore()
        let older = TransferReceiveResult(
            transferID: TransferID(
                rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
            ),
            receivedURLs: [URL(fileURLWithPath: "/tmp/older.pdf")],
            completedAt: Date(timeIntervalSince1970: 1_000)
        )
        let newer = TransferReceiveResult(
            transferID: TransferID(
                rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            ),
            receivedURLs: [URL(fileURLWithPath: "/tmp/newer.pdf")],
            completedAt: Date(timeIntervalSince1970: 2_000)
        )

        store.record(newer, sourceName: "New Mac")
        store.record(older, sourceName: "Old Mac")

        XCTAssertEqual(store.snapshot.visible.map(\.id), [newer.transferID, older.transferID])
        XCTAssertEqual(
            store.snapshot.visible.map(\.completedAt),
            [newer.completedAt, older.completedAt]
        )
    }

    func testStoreUsesTransferIDAsDeterministicCompletionTimeTieBreaker() {
        let store = RecentReceiveStore()
        let completedAt = Date(timeIntervalSince1970: 1_000)
        let lower = TransferReceiveResult(
            transferID: TransferID(
                rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            ),
            receivedURLs: [URL(fileURLWithPath: "/tmp/lower.pdf")],
            completedAt: completedAt
        )
        let higher = TransferReceiveResult(
            transferID: TransferID(
                rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
            ),
            receivedURLs: [URL(fileURLWithPath: "/tmp/higher.pdf")],
            completedAt: completedAt
        )

        store.record(higher, sourceName: "Mac")
        store.record(lower, sourceName: "Mac")

        XCTAssertEqual(store.snapshot.visible.map(\.id), [lower.transferID, higher.transferID])
    }
}
