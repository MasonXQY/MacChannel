import DropMeshMobileRuntime
import Foundation
import ImageIO
import MacChannelCore
import Observation
import QuickLook
import UIKit

/// App-owned metadata projection. A URL from the history list is never retained.
struct MobileHistoryEntry: Identifiable, Equatable, Sendable {
    let id: TransferID
    let peer: DeviceID
    let displayName: String
    let aggregateSize: UInt64
    let completedBytes: UInt64
    let updatedAt: Date
    let route: ConnectionRoute
    let phase: TransferPhase
    let direction: TransferRecordDirection
    var isAvailable: Bool
    var files: [MobileTransferHistoryFile] = []
    var isLegacy = true

    var isReceivedCompletion: Bool { direction == .inbound && phase == .completed }
    var canDelete: Bool { [.completed, .failed, .cancelled].contains(phase) }
    init(id: TransferID, peer: DeviceID, displayName: String, aggregateSize: UInt64,
         completedBytes: UInt64, updatedAt: Date, route: ConnectionRoute, phase: TransferPhase,
         direction: TransferRecordDirection, isAvailable: Bool) {
        self.id = id; self.peer = peer; self.displayName = displayName
        self.aggregateSize = aggregateSize; self.completedBytes = completedBytes
        self.updatedAt = updatedAt; self.route = route; self.phase = phase
        self.direction = direction; self.isAvailable = isAvailable
    }
    init(_ item: MobileTransferHistoryItem) {
        self.init(id: item.id, peer: item.peer, displayName: item.displayName,
            aggregateSize: item.aggregateSize, completedBytes: item.completedBytes,
            updatedAt: item.updatedAt, route: item.route, phase: item.phase,
            direction: item.direction, isAvailable: item.canOpenReceivedItem)
        self.files = item.files.map {
            MobileTransferHistoryFile(id: $0.id, name: $0.name, size: $0.size,
                isDirectory: $0.isDirectory, isAvailable: $0.isAvailable, availableURL: nil)
        }
        self.isLegacy = item.isLegacy
    }
}

enum MobileReceivedAction { case preview, share }
enum MobileReceivedMessage { case unavailable, unsupported }
struct MobileReceivedPresentation: Identifiable {
    let id = UUID()
    let action: MobileReceivedAction
    let url: URL
}

/// A small decoded preview. The unchecked conformance is confined to immutable
/// UIKit image output created off the main actor.
struct MobileHistoryThumbnail: @unchecked Sendable {
    let image: UIImage
}

@MainActor @Observable
final class MobileHistoryModel {
    private(set) var entries: [MobileHistoryEntry] = []
    private(set) var loading = false
    private(set) var deleting = false
    private(set) var deleteFailed = false
    func deleteRecords(ids: Set<TransferID>?) async -> Bool {
        guard !closed, !deleting else { return false }
        let eligible = Set(entries.filter { $0.canDelete && (ids == nil || ids!.contains($0.id)) }.map(\.id))
        if ids != nil && eligible.isEmpty { return false }
        deleting = true; deleteFailed = false
        refreshID = UUID(); loading = false
        actionID = UUID(); resolving = false
        dismissPresentation()
        do {
            try await session.deleteHistory(ids: ids == nil ? nil : eligible)
            guard !closed else { deleting = false; return true }
            entries.removeAll { eligible.contains($0.id) }
            if ids == nil { readIDs.removeAll() }
            else { for id in eligible { readIDs.remove(id.rawValue.uuidString) } }
            readDefaults.set(Array(readIDs), forKey: readKey)
            deleting = false
            await refresh()
            return true
        } catch {
            deleting = false
            if !closed { deleteFailed = true }
            return false
        }
    }
    private(set) var loadFailed = false
    private(set) var availabilityWarning = false
    private(set) var resolving = false
    private(set) var actionMessage: MobileReceivedMessage?
    var presentation: MobileReceivedPresentation?
    private let session: any MobileAppSession
    private let canPreview: (URL) -> Bool
    private let thumbnailLoader: @Sendable (URL) async -> MobileHistoryThumbnail?
    private var peerNames: [DeviceID: String] = [:]
    private var readIDs: Set<String>
    private let readDefaults: UserDefaults
    private let readKey = "history.read.transferIDs"
    private var refreshID = UUID()
    private var actionID = UUID()
    private var closed = false
    private var completed: [TransferSnapshot] = []
    private var receivedCompletionIDs: [TransferID] = []
    @ObservationIgnored private var completionRefresh: Task<Void, Never>?

    init(session: any MobileAppSession,
         canPreview: @escaping (URL) -> Bool = { QLPreviewController.canPreview($0 as NSURL) },
         thumbnailLoader: @escaping @Sendable (URL) async -> MobileHistoryThumbnail? = MobileHistoryModel.loadThumbnail,
         readDefaults: UserDefaults = .standard) {
        self.session = session; self.canPreview = canPreview; self.thumbnailLoader = thumbnailLoader
        self.readDefaults = readDefaults
        self.readIDs = Set(readDefaults.stringArray(forKey: "history.read.transferIDs") ?? [])
    }
    var unreadCount: Int { entries.filter { isUnread($0) }.count }
    func isUnread(_ entry: MobileHistoryEntry) -> Bool {
        entry.isReceivedCompletion && !readIDs.contains(entry.id.rawValue.uuidString)
    }
    func markRead(_ entry: MobileHistoryEntry) {
        guard isUnread(entry) else { return }
        readIDs.insert(entry.id.rawValue.uuidString)
        readDefaults.set(Array(readIDs), forKey: readKey)
    }
    var latestReceived: [MobileHistoryEntry] { Array(entries.filter(\.isReceivedCompletion).prefix(3)) }
    func receivedFolderURL() async -> URL? { await session.receivedFolderURL() }

    func peerName(for id: DeviceID) -> String {
        PeerConnectionPresentation.displayName(peerNames[id] ?? "", unnamed: String(localized: "history.peer.unknown"))
    }

    func update(_ snapshot: MobileAppSnapshot) {
        guard !closed else { return }
        peerNames = snapshot.names
        availabilityWarning = snapshot.historyAvailabilityFailure != nil
        let next = snapshot.transfers.filter { $0.phase == .completed }
        let receivedChanged = snapshot.receivedCompletionIDs != receivedCompletionIDs
        guard next != completed || receivedChanged else { return }
        completed = next
        receivedCompletionIDs = snapshot.receivedCompletionIDs
        completionRefresh?.cancel()
        completionRefresh = Task { [weak self] in await self?.refresh() }
    }
    func thumbnail(for id: TransferID) async -> MobileHistoryThumbnail? {
        guard !closed, !deleting, let entry = entries.first(where: { $0.id == id }) else { return nil }
        for file in entry.files.filter({ !$0.isDirectory }).prefix(3) {
            let result = await session.historyThumbnail(for: id, itemID: file.id)
            guard !closed, !deleting, !Task.isCancelled, entries.contains(entry) else { return nil }
            if let result { return result }
        }
        guard entry.files.isEmpty, entry.isReceivedCompletion, entry.isAvailable,
              let url = await session.availableReceivedURL(for: id) else { return nil }
        guard !closed, !Task.isCancelled,
              entries.contains(where: { $0.id == id && $0.isReceivedCompletion && $0.isAvailable }) else { return nil }
        let thumbnail = await thumbnailLoader(url)
        guard !closed, !Task.isCancelled,
              entries.contains(where: { $0.id == id && $0.isReceivedCompletion && $0.isAvailable }) else { return nil }
        return thumbnail
    }
    func refresh() async {
        guard !closed, !deleting else { return }
        let id = UUID(); refreshID = id; loading = true
        do {
            let result = try await session.history(limit: 100)
            let snapshot = await session.snapshot()
            guard !closed, refreshID == id else { return }
            entries = result; peerNames = snapshot.names; loadFailed = false
            availabilityWarning = snapshot.historyAvailabilityFailure != nil
        } catch {
            guard !closed, refreshID == id else { return }
            loadFailed = true
        }
        loading = false
    }
    func perform(_ action: MobileReceivedAction, for id: TransferID) async {
        guard !closed, !deleting, !resolving, presentation == nil,
              entries.contains(where: { $0.id == id && $0.isReceivedCompletion }) else { return }
        resolving = true; actionMessage = nil
        let request = UUID(); actionID = request
        let url = await session.availableReceivedURL(for: id)
        let snapshot = await session.snapshot()
        guard !closed, actionID == request else { return }
        availabilityWarning = snapshot.historyAvailabilityFailure != nil
        resolving = false
        guard let url else {
            if let index = entries.firstIndex(where: { $0.id == id }) { entries[index].isAvailable = false }
            actionMessage = .unavailable
            return
        }
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        if isDirectory || (action == .preview && !canPreview(url)) {
            actionMessage = .unsupported
            return
        }
        presentation = MobileReceivedPresentation(action: action, url: url)
    }
    func perform(_ action: MobileReceivedAction, for id: TransferID, itemID: MobileHistoryFileID) async {
        guard !closed, !deleting, !resolving, presentation == nil,
              entries.contains(where: { $0.id == id && $0.files.contains(where: { $0.id == itemID }) }) else { return }
        resolving = true; actionMessage = nil
        let request = UUID(); actionID = request
        let url = await session.availableHistoryFileURL(for: id, itemID: itemID)
        guard !closed, actionID == request else {
            if let url { await session.releaseHistoryActionURL(url) }
            return
        }
        resolving = false
        guard let url else { actionMessage = .unavailable; return }
        let directory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        guard !directory, action != .preview || canPreview(url) else {
            await session.releaseHistoryActionURL(url)
            actionMessage = .unsupported; return
        }
        presentation = MobileReceivedPresentation(action: action, url: url)
    }
    func close() {
        closed = true; refreshID = UUID(); actionID = UUID()
        completionRefresh?.cancel(); completionRefresh = nil
        dismissPresentation(); resolving = false; loading = false
    }
    func dismissPresentation() {
        guard let url = presentation?.url else { presentation = nil; return }
        presentation = nil
        Task { await session.releaseHistoryActionURL(url) }
    }

    nonisolated private static func loadThumbnail(_ url: URL) async -> MobileHistoryThumbnail? {
        await MobileHistoryThumbnailLoader.load(url)
    }
}
