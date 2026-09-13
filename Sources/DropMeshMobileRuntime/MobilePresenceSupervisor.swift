import Foundation
import MacChannelCore

typealias MobilePresenceState = PresenceSessionState

/// Supplies the foreground platform configuration to the common sole owner.
struct MobilePresenceSupervisor: Sendable {
    private let owner: AuthenticatedPresenceSupervisor
    var bridge: MobileSignalBridge { owner.bridge }
    var state: MobilePresenceState { get async { await owner.state } }

    init(identity: DeviceIdentity, repository: TrustRepository, directory: DeviceDirectory,
         onState: @escaping @Sendable (MobilePresenceState) async -> Void = { _ in }) {
        self.init(identity: identity, repository: repository, directory: directory,
                  makeSocket: { try MobileRuntimeConfiguration.makePresenceSocket() },
                  sleep: { try await Task.sleep(for: $0) }, onState: onState)
    }

    init(identity: DeviceIdentity, repository: TrustRepository, directory: DeviceDirectory,
         makeSocket: @escaping @Sendable () async throws -> any PresenceWebSocket,
         sleep: @escaping @Sendable (Duration) async throws -> Void,
         onState: @escaping @Sendable (MobilePresenceState) async -> Void = { _ in }) {
        owner = AuthenticatedPresenceSupervisor(identity: identity, repository: repository,
            directory: directory, origin: MobileRuntimeConfiguration.webSocketURL,
            makeSocket: makeSocket, sleep: sleep, onState: onState)
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
