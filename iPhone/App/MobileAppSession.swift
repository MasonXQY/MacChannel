import DropMeshMobileRuntime
import Foundation
import MacChannelCore

struct MobileAppSnapshot: Sendable {
    var state: MobileRuntimeState = .inactive
    var localID: DeviceID
    var trustedIDs: Set<DeviceID> = []
    var reachable: [DeviceSummary] = []
    var names: [DeviceID: String] = [:]
    var failure: MobileRuntimeFailure?
    var transfers: [TransferSnapshot] = []
    var localNetworkAvailable = false
    var localDiscoveryEnabled = false
    var historyAvailabilityFailure: MobileHistoryAvailabilityFailure?
}

protocol MobileAppSession: Sendable {
    func snapshot() async -> MobileAppSnapshot
    /// Returns only after all upstream subscriptions have stopped.
    func observe(_ changed: @escaping @Sendable () async -> Void) async
    func startForeground() async throws
    func stopForeground() async
    func refreshTrust() async throws
    func retryConnection() async
    func makePairingAttempt() async throws -> any PairingAttempt
    func rememberConfirmedPeer(_ peer: DeviceSummary) async
    func revoke(_ id: DeviceID) async throws
    func persistTrust() async throws
    func send(items: [URL], to device: DeviceID) async throws -> TransferID
    func pause(_ id: TransferID) async throws
    func resume(_ id: TransferID) async throws
    func cancel(_ id: TransferID) async -> TransferCancellationResult
    func history(limit: Int) async throws -> [MobileHistoryEntry]
    func availableReceivedURL(for id: TransferID) async -> URL?
    func setLocalDiscoveryEnabled(_ enabled: Bool) async throws
}
