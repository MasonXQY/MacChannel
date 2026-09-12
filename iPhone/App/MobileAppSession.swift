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
}

protocol MobileAppSession: Sendable {
    func snapshot() async -> MobileAppSnapshot
    /// Returns only after both upstream subscriptions have stopped.
    func observe(_ changed: @escaping @Sendable () async -> Void) async
    func startForeground() async throws
    func stopForeground() async
    func refreshTrust() async throws
    func retryConnection() async
    func makePairingAttempt() async throws -> any PairingAttempt
    func rememberConfirmedPeer(_ peer: DeviceSummary) async
    func revoke(_ id: DeviceID) async throws
    func persistTrust() async throws
}
