import DropMeshMobileRuntime
import Foundation
import MacChannelCore

/// Compiled only into the test host. No identity, keychain, file or network owner.
actor InertMobileSession: MobileAppSession {
    nonisolated let peer = DeviceSummary(id: DeviceID(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!),
        displayName: "Studio MacBook Pro — Design and Engineering 工作室设计与工程", availability: .internet)
    private var value: MobileAppSnapshot
    private var forcedStartState: MobileRuntimeState?
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var saveFailure = false
    private var refreshFailure = false
    private var pairingAttempt: (any PairingAttempt)?
    private var beforeRevoke: @Sendable () async -> Void = {}
    private var beforeStart: @Sendable () async throws -> Void = {}
    private var beforeRetry: @Sendable () async -> Void = {}
    private var retryState: MobileRuntimeState = .online
    private var beforeSend: @Sendable () async -> Void = {}
    private(set) var sendCount = 0
    private var cancelResult: TransferCancellationResult = .tooLate
    private var historyRows: [MobileHistoryEntry] = []
    private var receivedURL: URL?
    private var historyFailed = false
    private var discoverySaveFailed = false
    private var beforeHistory: @Sendable () async -> Void = {}
    private(set) var resolvedHistoryIDs: [TransferID] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var revokeCount = 0
    private(set) var persistCount = 0
    private(set) var refreshCount = 0
    private(set) var historyReadCount = 0
    var observerCount: Int { observers.count }

    init() {
        value = MobileAppSnapshot(localID: DeviceID(rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!))
        value.trustedIDs = [peer.id]
        value.names = [peer.id: peer.displayName]
    }
    func snapshot() -> MobileAppSnapshot { value }
    func setPresentation(state: MobileRuntimeState, sync: PresenceTrustSyncState,
                         names: [DeviceID: String], reachable: [DeviceSummary]) {
        value.state = state
        forcedStartState = state
        value.trustSyncState = sync
        value.names = names
        value.trustedIDs = Set(names.keys)
        value.reachable = reachable
        publish()
    }
    func observe(_ changed: @escaping @Sendable () async -> Void) async {
        let id = UUID()
        let stream = AsyncStream<Void> { observers[id] = $0 }
        await changed()
        for await _ in stream {
            guard !Task.isCancelled else { break }
            await changed()
        }
        observers[id] = nil
    }
    func startForeground() async throws {
        startCount += 1
        try await beforeStart()
        value.state = forcedStartState ?? .online; publish()
    }
    func stopForeground() { stopCount += 1; value.state = .inactive; value.reachable = []; publish() }
    func retryConnection() async {
        await beforeRetry()
        value.state = retryState; publish()
    }
    func refreshTrust() throws {
        refreshCount += 1
        if refreshFailure { throw MobileRuntimeError.notReady }
        publish()
    }
    func makePairingAttempt() throws -> any PairingAttempt {
        guard let pairingAttempt else { throw CancellationError() }
        return pairingAttempt
    }
    func rememberConfirmedPeer(_ peer: DeviceSummary) { value.names[peer.id] = peer.displayName }
    func revoke(_ id: DeviceID) async {
        await beforeRevoke()
        revokeCount += 1; value.trustedIDs.remove(id); publish()
    }
    func persistTrust() throws { persistCount += 1; if saveFailure { throw CocoaError(.fileWriteNoPermission) } }
    func setSaveFailure(_ fail: Bool) { saveFailure = fail }
    func setRefreshFailure(_ fail: Bool) { refreshFailure = fail }
    func setPairingAttempt(_ attempt: any PairingAttempt) { pairingAttempt = attempt }
    func setBeforeRevoke(_ operation: @escaping @Sendable () async -> Void) { beforeRevoke = operation }
    func setBeforeStart(_ operation: @escaping @Sendable () async throws -> Void) { beforeStart = operation }
    func setBeforeRetry(_ operation: @escaping @Sendable () async -> Void) { beforeRetry = operation }
    func setRetryState(_ state: MobileRuntimeState) { retryState = state }
    func setNames(_ names: [DeviceID: String]) { value.names = names; publish() }
    func setBeforeSend(_ operation: @escaping @Sendable () async -> Void) { beforeSend = operation }
    func send(items: [URL], to device: DeviceID) async throws -> TransferID {
        sendCount += 1
        await beforeSend()
        let id = TransferID(rawValue: UUID())
        value.transfers.append(TransferSnapshot(id: id, peer: device, phase: .completed,
            completedBytes: 11, totalBytes: 11, route: .lan))
        publish()
        return id
    }
    func pause(_ id: TransferID) {}
    func resume(_ id: TransferID) {}
    func cancel(_ id: TransferID) -> TransferCancellationResult { cancelResult }
    func setCancelResult(_ result: TransferCancellationResult) { cancelResult = result }
    func history(limit: Int) async throws -> [MobileHistoryEntry] {
        historyReadCount += 1
        let rows = historyRows
        await beforeHistory()
        if historyFailed { throw CocoaError(.fileReadUnknown) }
        return Array(rows.prefix(limit))
    }
    func availableReceivedURL(for id: TransferID) -> URL? { resolvedHistoryIDs.append(id); return receivedURL }
    func setHistory(_ rows: [MobileHistoryEntry]) { historyRows = rows }
    func setReceivedURL(_ url: URL?) { receivedURL = url }
    func setHistoryFailure(_ failed: Bool) { historyFailed = failed }
    func setBeforeHistory(_ operation: @escaping @Sendable () async -> Void) { beforeHistory = operation }
    func setHistoryDiagnostic(_ failed: Bool) {
        value.historyAvailabilityFailure = failed ? .receivedOutputIndexUnavailable : nil; publish()
    }
    func setDiscoverySaveFailure(_ failed: Bool) { discoverySaveFailed = failed }
    func setLocalDiscoveryEnabled(_ enabled: Bool) throws {
        if discoverySaveFailed { throw CocoaError(.fileWriteNoPermission) }
        value.localDiscoveryEnabled = enabled; publish()
    }
    func setTransfers(_ transfers: [TransferSnapshot]) { value.transfers = transfers; publish() }
    func setReceivedCompletionIDs(_ ids: [TransferID]) { value.receivedCompletionIDs = ids; publish() }
    func setTrustedIDs(_ ids: Set<DeviceID>) { value.trustedIDs = ids; publish() }
    func setPresence(_ state: MobileRuntimeState, peers: [DeviceSummary]) {
        value.state = state; value.reachable = peers; publish()
    }
    private func publish() { for observer in observers.values { observer.yield(()) } }
}
