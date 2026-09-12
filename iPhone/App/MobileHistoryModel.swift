import DropMeshMobileRuntime
import Foundation
import MacChannelCore
import Observation
import QuickLook

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

    var isReceivedCompletion: Bool { direction == .inbound && phase == .completed }
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
    }
}

enum MobileReceivedAction { case preview, share }
enum MobileReceivedMessage { case unavailable, unsupported }
struct MobileReceivedPresentation: Identifiable {
    let id = UUID()
    let action: MobileReceivedAction
    let url: URL
}

@MainActor @Observable
final class MobileHistoryModel {
    private(set) var entries: [MobileHistoryEntry] = []
    private(set) var loading = false
    private(set) var loadFailed = false
    private(set) var availabilityWarning = false
    private(set) var resolving = false
    private(set) var actionMessage: MobileReceivedMessage?
    var presentation: MobileReceivedPresentation?
    private let session: any MobileAppSession
    private let canPreview: (URL) -> Bool
    private var refreshID = UUID()
    private var actionID = UUID()
    private var closed = false
    private var completed: [TransferSnapshot] = []
    private var receivedCompletionIDs: [TransferID] = []
    @ObservationIgnored private var completionRefresh: Task<Void, Never>?

    init(session: any MobileAppSession,
         canPreview: @escaping (URL) -> Bool = { QLPreviewController.canPreview($0 as NSURL) }) {
        self.session = session; self.canPreview = canPreview
    }
    var latestReceived: [MobileHistoryEntry] { Array(entries.filter(\.isReceivedCompletion).prefix(3)) }

    func update(_ snapshot: MobileAppSnapshot) {
        guard !closed else { return }
        availabilityWarning = snapshot.historyAvailabilityFailure != nil
        let next = snapshot.transfers.filter { $0.phase == .completed }
        let receivedChanged = snapshot.receivedCompletionIDs != receivedCompletionIDs
        guard next != completed || receivedChanged else { return }
        completed = next
        receivedCompletionIDs = snapshot.receivedCompletionIDs
        completionRefresh?.cancel()
        completionRefresh = Task { [weak self] in await self?.refresh() }
    }
    func refresh() async {
        guard !closed else { return }
        let id = UUID(); refreshID = id; loading = true
        do {
            let result = try await session.history(limit: 100)
            let snapshot = await session.snapshot()
            guard !closed, refreshID == id else { return }
            entries = result; loadFailed = false
            availabilityWarning = snapshot.historyAvailabilityFailure != nil
        } catch {
            guard !closed, refreshID == id else { return }
            loadFailed = true
        }
        loading = false
    }
    func perform(_ action: MobileReceivedAction, for id: TransferID) async {
        guard !closed, !resolving, presentation == nil,
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
    func close() {
        closed = true; refreshID = UUID(); actionID = UUID()
        completionRefresh?.cancel(); completionRefresh = nil
        presentation = nil; resolving = false; loading = false
    }
}
