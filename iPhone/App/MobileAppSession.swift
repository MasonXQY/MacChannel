import DropMeshMobileRuntime
import Foundation
import MacChannelCore

struct MobileAppSnapshot: Sendable {
    var state: MobileRuntimeState = .inactive
    var trustSyncState: PresenceTrustSyncState = .idle
    var localID: DeviceID
    var trustedIDs: Set<DeviceID> = []
    // Durable manual pairing is distinct from current account authorization.
    var effectivePeerIDs: Set<DeviceID>? = nil
    var accountConfigurationUnavailable = false
    var sendablePeerIDs: Set<DeviceID> { effectivePeerIDs ?? trustedIDs }
    var reachable: [DeviceSummary] = []
    var names: [DeviceID: String] = [:]
    var failure: MobileRuntimeFailure?
    var transfers: [TransferSnapshot] = []
    var receivedCompletionIDs: [TransferID] = []
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
    func renamePeer(id: DeviceID, name: String) async throws
    func revoke(_ id: DeviceID) async throws
    func persistTrust() async throws
    func send(items: [URL], to device: DeviceID) async throws -> TransferID
    func pause(_ id: TransferID) async throws
    func resume(_ id: TransferID) async throws
    func cancel(_ id: TransferID) async -> TransferCancellationResult
    func history(limit: Int) async throws -> [MobileHistoryEntry]
    func deleteHistory(ids: Set<TransferID>?) async throws
    func historyThumbnail(for id: TransferID, itemID: MobileHistoryFileID) async -> MobileHistoryThumbnail?
    func availableReceivedURL(for id: TransferID) async -> URL?
    func receivedFolderURL() async -> URL?
    func availableHistoryFileURL(for id: TransferID, itemID: MobileHistoryFileID) async -> URL?
    func recordSentHistorySources(_ files: [MobileSentHistorySource], for id: TransferID) async
    func releaseHistoryActionURL(_ url: URL) async
    func setLocalDiscoveryEnabled(_ enabled: Bool) async throws
    func accountController() async throws -> AccountSessionController?
    func accountLifecycle() async throws -> AccountForegroundLifecycle?
}

extension MobileAppSession {
    func receivedFolderURL() async -> URL? { nil }
    func deleteHistory(ids: Set<TransferID>?) async throws { throw CocoaError(.featureUnsupported) }
    func historyThumbnail(for id: TransferID, itemID: MobileHistoryFileID) async -> MobileHistoryThumbnail? { nil }
    func renamePeer(id: DeviceID, name: String) async throws { throw CocoaError(.featureUnsupported) }
    func availableHistoryFileURL(for id: TransferID, itemID: MobileHistoryFileID) async -> URL? { nil }
    func recordSentHistorySources(_ files: [MobileSentHistorySource], for id: TransferID) async {}
    func releaseHistoryActionURL(_ url: URL) async {}
    func accountController() async throws -> AccountSessionController? { nil }
    func accountLifecycle() async throws -> AccountForegroundLifecycle? { nil }
}

struct MobileSentHistorySource: Sendable {
    let name: String
    let bookmark: Data?
    let photoAssetIdentifier: String?
    init(name: String, bookmark: Data?, photoAssetIdentifier: String? = nil) {
        self.name = name; self.bookmark = bookmark; self.photoAssetIdentifier = photoAssetIdentifier
    }
}
