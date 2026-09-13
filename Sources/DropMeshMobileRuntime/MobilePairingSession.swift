import MacChannelCore

public typealias MobilePairingState = DurablePairingState
public typealias MobilePairingError = DurablePairingError
public typealias MobilePairingSession = DurablePairingSession

extension DurablePairingSession {
    public init(coordinator: PairingCoordinator, persistTrust: @escaping @Sendable () async throws -> Void) {
        self.init(coordinator: coordinator, persistTrust: { _ in try await persistTrust() })
    }
}
