import Foundation
import MacChannelCore

typealias MobilePresenceState = PresenceSessionState

/// Supplies the foreground platform configuration to the common sole owner.
struct MobilePresenceSupervisor: Sendable {
    private let owner: AuthenticatedPresenceSupervisor
    var bridge: MobileSignalBridge { owner.bridge }
    var state: MobilePresenceState { get async { await owner.state } }
    var trustSyncState: PresenceTrustSyncState { get async { await owner.trustSyncState } }

    init(identity: DeviceIdentity, repository: TrustRepository, directory: DeviceDirectory,
         onState: @escaping @Sendable (MobilePresenceState) async -> Void = { _ in },
         onTrustSyncState: @escaping @Sendable (PresenceTrustSyncState) async -> Void = { _ in },
         records: (@Sendable () async throws -> [SignedTrustRecord])? = nil,
         publication: (@Sendable () async throws -> TrustPublicationSnapshot)? = nil,
         persistedUpdates: (@Sendable () async -> AsyncStream<AuthenticatedTrustState?>)? = nil) {
        self.init(identity: identity, repository: repository, directory: directory,
                  makeSocket: { try MobileRuntimeConfiguration.makePresenceSocket() },
                  sleep: { try await Task.sleep(for: $0) }, onState: onState,
                  onTrustSyncState: onTrustSyncState, records: records,
                  publication: publication, persistedUpdates: persistedUpdates)
    }

    init(identity: DeviceIdentity, repository: TrustRepository, directory: DeviceDirectory,
         makeSocket: @escaping @Sendable () async throws -> any PresenceWebSocket,
         sleep: @escaping @Sendable (Duration) async throws -> Void,
         onState: @escaping @Sendable (MobilePresenceState) async -> Void = { _ in },
         onTrustSyncState: @escaping @Sendable (PresenceTrustSyncState) async -> Void = { _ in },
         records: (@Sendable () async throws -> [SignedTrustRecord])? = nil,
         publication: (@Sendable () async throws -> TrustPublicationSnapshot)? = nil,
         persistedUpdates: (@Sendable () async -> AsyncStream<AuthenticatedTrustState?>)? = nil,
         deadlineSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        owner = AuthenticatedPresenceSupervisor(identity: identity, repository: repository,
            directory: directory, origin: MobileRuntimeConfiguration.webSocketURL,
            makeSocket: makeSocket, sleep: sleep, onState: onState,
            onTrustSyncState: onTrustSyncState, records: records,
            publication: publication, persistedUpdates: persistedUpdates, deadlineSleep: deadlineSleep)
    }

    func start() async { await owner.start() }
    func stop() async { await owner.stop() }
    func retryConnection() async { await owner.retryConnection() }
    func refreshTrust() async { await owner.refreshTrust() }
    static func reconnectDelay(_ failures: Int) -> Duration {
        AuthenticatedPresenceSupervisor.reconnectDelay(failures)
    }
    static func diagnosticCategory(_ error: any Error) -> String {
        AuthenticatedPresenceSupervisor.diagnosticCategory(error)
    }
}
