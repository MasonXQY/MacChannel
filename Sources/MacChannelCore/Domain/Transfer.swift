public enum TransferPhase: String, Codable, Sendable {
    case preparing
    case connecting
    case transferring
    case paused
    case verifying
    case cancelling
    case completed
    case failed
    case cancelled
}

/// Privacy-limited ownership of a durable history row. This is distinct from
/// encrypted frame direction and contains no source or destination path.
public enum TransferRecordDirection: String, Codable, Sendable {
    case inbound
    case outbound
    case unknown
}

public enum TransferCancellationResult: Equatable, Sendable {
    case requested
    case tooLate
}

public struct TransferSnapshot: Codable, Equatable, Sendable {
    public let id: TransferID
    public let peer: DeviceID
    public let phase: TransferPhase
    public let completedBytes: Int64
    public let totalBytes: Int64
    public let route: ConnectionRoute

    public init(
        id: TransferID,
        peer: DeviceID,
        phase: TransferPhase,
        completedBytes: Int64,
        totalBytes: Int64,
        route: ConnectionRoute
    ) {
        self.id = id
        self.peer = peer
        self.phase = phase
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.route = route
    }
}

public enum MacChannelError: Error, Equatable, Sendable {
    case invalidConfiguration(String)
    case untrustedDevice(DeviceID)
    case pairingInvalidCode
    case pairingCodeExpired
    case pairingCodeAlreadyUsed
    case pairingRateLimited
    case pairingFingerprintMismatch
    case pairingAuthorizationPending
    case pairingRejected
    case pairingHandshakeFailed
    case pairingTrustFailed
    case pairingSessionExpired
    case pairingResourceExhausted
    case pairingOperationInProgress
    case pairingStaleOperation
    case connectionFailed
    case transferFailed
    case transferInvalidState
    case cancelled
}
