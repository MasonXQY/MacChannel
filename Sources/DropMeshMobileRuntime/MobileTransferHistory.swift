import Darwin
import Foundation
import MacChannelCore

public struct MobileHistoryFileID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

public struct MobileTransferHistoryFile: Identifiable, Equatable, Sendable {
    public let id: MobileHistoryFileID
    public let name: String
    public let size: UInt64
    public let isDirectory: Bool
    public let isAvailable: Bool
    public let availableURL: URL?

    public init(id: MobileHistoryFileID, name: String, size: UInt64, isDirectory: Bool,
                isAvailable: Bool, availableURL: URL?) {
        self.id = id; self.name = name; self.size = size; self.isDirectory = isDirectory
        self.isAvailable = isAvailable; self.availableURL = availableURL
    }
}

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
    public let files: [MobileTransferHistoryFile]
    public let isLegacy: Bool
    /// A rendering hint; resolve by ID again immediately before an action.
    public let availableURL: URL?
    public var canOpenReceivedItem: Bool {
        direction == .inbound && phase == .completed && availableURL != nil
    }
}

public actor MobileTransferHistory {
    private let database: TransferDatabase
    private let outputs: MobileReceivedOutputIndex
    private let itemIndex: MobileHistoryItemsIndex
    private let deletions: MobileHistoryDeletionStore
    public init(database: TransferDatabase, outputs: MobileReceivedOutputIndex) {
        self.database = database; self.outputs = outputs
        itemIndex = MobileHistoryItemsIndex(url: outputs.itemMetadataURL)
        deletions = MobileHistoryDeletionStore(url: outputs.itemMetadataURL.deletingLastPathComponent()
            .appendingPathComponent("history-deletions-v1.json"))
    }
    public var availabilityFailure: MobileHistoryAvailabilityFailure? {
        get async { await outputs.availabilityFailure }
    }
    public func items(limit: Int = 100) async throws -> [MobileTransferHistoryItem] {
        guard limit > 0 else { return [] }
        let rows = try await database.persistedAllHistory()
        var items: [MobileTransferHistoryItem] = []
        for row in rows {
            if await deletions.contains(row.id) { continue }
            if items.count == min(limit, 1_000) { break }
            let url = row.direction == .inbound && row.phase == .completed
                ? await outputs.availableURL(for: row.id) : nil
            let stored = await itemIndex.files(for: row.id)
            var files: [MobileTransferHistoryFile] = []
            if let stored {
                for file in stored {
                    let resolved = row.direction == .inbound ? await resolve(row.id, file: file) : nil
                    files.append(MobileTransferHistoryFile(id: MobileHistoryFileID(rawValue: file.id), name: file.name,
                        size: file.size, isDirectory: file.isDirectory, isAvailable: resolved != nil, availableURL: resolved))
                }
            }
            items.append(MobileTransferHistoryItem(id: row.id, peer: row.peer, displayName: row.displayFilename,
                aggregateSize: row.aggregateSize, completedBytes: row.completedBytes, updatedAt: row.updatedAt,
                route: row.route, phase: row.phase, direction: row.direction, files: files,
                isLegacy: stored == nil, availableURL: url))
        }
        return items
    }
    public func availableURL(for transferID: TransferID) async -> URL? {
        guard !(await deletions.contains(transferID)) else { return nil }
        return await outputs.availableURL(for: transferID)
    }
    public func availableURL(for transferID: TransferID, itemID: MobileHistoryFileID) async -> URL? {
        guard !(await deletions.contains(transferID)) else { return nil }
        guard let file = await itemIndex.files(for: transferID)?.first(where: { $0.id == itemID.rawValue }) else { return nil }
        return await resolve(transferID, file: file)
    }
    public func delete(ids requested: Set<TransferID>?) async throws {
        let rows = try await database.persistedAllHistory()
        let requested = requested ?? Set(rows.map(\.id))
        let eligible = Set(rows.compactMap { row -> TransferID? in
            guard requested.contains(row.id), [.completed, .failed, .cancelled].contains(row.phase) else { return nil }
            return row.id
        })
        try await deletions.add(eligible)
    }
    public func isDeleted(_ id: TransferID) async -> Bool { await deletions.contains(id) }
    func recordCompletedReceive(_ result: TransferReceiveResult) async {
        // Auxiliary metadata cannot change the authoritative completed transfer.
        do {
            try await outputs.recordCompletedReceive(result)
            try await itemIndex.recordReceive(result)
        } catch { }
    }

    func recordCompletedSend(_ id: TransferID, items: [URL]) async {
        // Auxiliary metadata must never convert a committed send into failure.
        do { try await itemIndex.recordSend(id: id, urls: items) } catch { }
    }

    private func resolve(_ transferID: TransferID, file: MobileHistoryItemsIndex.Stored) async -> URL? {
        guard !file.isDirectory, let root = await outputs.availableURL(for: transferID), let relative = file.relativePath else { return nil }
        if relative.isEmpty { return root }
        guard root.hasDirectoryPath || ((try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true) else { return nil }
        var descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var candidate = root
        for (offset, component) in relative.enumerated() {
            var status = stat()
            guard fstatat(descriptor, component, &status, AT_SYMLINK_NOFOLLOW) == 0,
                  status.st_mode & S_IFMT == (offset == relative.count - 1
                    ? (file.isDirectory ? S_IFDIR : S_IFREG) : S_IFDIR) else { return nil }
            if offset == relative.count - 1,
               let device = file.device, let inode = file.inode,
               (UInt64(UInt32(bitPattern: status.st_dev)) != device || UInt64(status.st_ino) != inode) { return nil }
            candidate.appendPathComponent(component, isDirectory: offset == relative.count - 1 && file.isDirectory)
            if offset < relative.count - 1 {
                let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                guard next >= 0 else { return nil }; close(descriptor); descriptor = next
            }
        }
        return candidate
    }
}
