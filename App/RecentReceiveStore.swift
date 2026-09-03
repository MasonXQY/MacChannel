import Foundation
import MacChannelCore

struct RecentReceiveSummary: Identifiable, Equatable, Sendable {
    let id: TransferID
    let sourceName: String
    let receivedURLs: [URL]
    let completedAt: Date

    var title: String {
        receivedURLs.count == 1
            ? receivedURLs[0].lastPathComponent
            : "已收到 \(receivedURLs.count) 个文件"
    }
}

struct RecentReceiveSnapshot: Equatable, Sendable {
    let visible: [RecentReceiveSummary]
    let overflowCount: Int
    var hasUnread: Bool { !visible.isEmpty || overflowCount > 0 }
}

@MainActor
final class RecentReceiveStore {
    static let maximumVisibleCount = 5
    private var unread: [RecentReceiveSummary] = []
    var onChange: ((RecentReceiveSnapshot) -> Void)?

    var snapshot: RecentReceiveSnapshot {
        RecentReceiveSnapshot(
            visible: Array(unread.prefix(Self.maximumVisibleCount)),
            overflowCount: max(unread.count - Self.maximumVisibleCount, 0)
        )
    }

    var hasUnread: Bool { !unread.isEmpty }

    func record(
        _ result: TransferReceiveResult,
        sourceName: String,
        completedAt: Date = Date()
    ) {
        guard !result.receivedURLs.isEmpty else { return }
        unread.removeAll { $0.id == result.transferID }
        unread.insert(
            RecentReceiveSummary(
                id: result.transferID,
                sourceName: sourceName.isEmpty ? "其他设备" : sourceName,
                receivedURLs: result.receivedURLs,
                completedAt: completedAt
            ),
            at: 0
        )
        onChange?(snapshot)
    }

    func acknowledge(_ id: TransferID) {
        let oldCount = unread.count
        unread.removeAll { $0.id == id }
        if unread.count != oldCount { onChange?(snapshot) }
    }

    func acknowledgeAll() {
        guard !unread.isEmpty else { return }
        unread.removeAll(keepingCapacity: false)
        onChange?(snapshot)
    }
}
