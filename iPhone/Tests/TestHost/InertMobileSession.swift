import DropMeshMobileRuntime
import Foundation
import MacChannelCore

/// Compiled only into the test host. No identity, keychain, file or network owner.
actor InertMobileSession: MobileAppSession {
    nonisolated let peer = DeviceSummary(id: DeviceID(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!),
        displayName: "Studio MacBook Pro — Design and Engineering 工作室设计与工程", availability: .internet)
    private var value: MobileAppSnapshot
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var saveFailure = false
    private var refreshFailure = false
    private var pairingAttempt: (any PairingAttempt)?
    private var beforeRevoke: @Sendable () async -> Void = {}
    private var beforeStart: @Sendable () async throws -> Void = {}
    private var beforeRetry: @Sendable () async -> Void = {}
    private var retryState: MobileRuntimeState = .online
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var revokeCount = 0
    private(set) var persistCount = 0
    private(set) var refreshCount = 0
    var observerCount: Int { observers.count }

    init() {
        value = MobileAppSnapshot(localID: DeviceID(rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!))
        value.trustedIDs = [peer.id]
        value.names = [peer.id: peer.displayName]
    }
    func snapshot() -> MobileAppSnapshot { value }
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
        value.state = .online; publish()
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
    func setTrustedIDs(_ ids: Set<DeviceID>) { value.trustedIDs = ids; publish() }
    func setPresence(_ state: MobileRuntimeState, peers: [DeviceSummary]) {
        value.state = state; value.reachable = peers; publish()
    }
    private func publish() { for observer in observers.values { observer.yield(()) } }
}
