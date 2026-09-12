import Foundation
import MacChannelCore

public struct MobileTransferHistoryItem: Identifiable, Equatable, Sendable {
    public let id: TransferID
    public let peer: DeviceID
    public let displayName: String
    public let aggregateSize: UInt64
    public let completedBytes: UInt64
    public let updatedAt: Date
    public let route: ConnectionRoute
    public let phase: TransferPhase
    public let direction: TransferRecordDirection
    /// A rendering hint; resolve by ID again immediately before an action.
    public let availableURL: URL?
    public var canOpenReceivedItem: Bool {
        direction == .inbound && phase == .completed && availableURL != nil
    }
}

public actor MobileTransferHistory {
    private let database: TransferDatabase
    private let outputs: MobileReceivedOutputIndex
    public init(database: TransferDatabase, outputs: MobileReceivedOutputIndex) {
        self.database = database; self.outputs = outputs
    }
    public var availabilityFailure: MobileHistoryAvailabilityFailure? {
        get async { await outputs.availabilityFailure }
    }
    public func items(limit: Int = 100) async throws -> [MobileTransferHistoryItem] {
        guard limit > 0 else { return [] }
        let rows = try await database.persistedHistory(limit: min(limit, 1_000))
        var items: [MobileTransferHistoryItem] = []
        for row in rows {
            let url = row.direction == .inbound && row.phase == .completed
                ? await outputs.availableURL(for: row.id) : nil
            items.append(MobileTransferHistoryItem(id: row.id, peer: row.peer, displayName: row.displayFilename,
                aggregateSize: row.aggregateSize, completedBytes: row.completedBytes, updatedAt: row.updatedAt,
                route: row.route, phase: row.phase, direction: row.direction, availableURL: url))
        }
        return items
    }
    public func availableURL(for transferID: TransferID) async -> URL? {
        await outputs.availableURL(for: transferID)
    }
    func recordCompletedReceive(_ result: TransferReceiveResult) async {
        // Auxiliary metadata cannot change the authoritative completed transfer.
        do { try await outputs.recordCompletedReceive(result) } catch { }
    }
}
