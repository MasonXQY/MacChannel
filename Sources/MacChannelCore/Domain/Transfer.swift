public enum TransferPhase: String, Codable, Sendable {
    case preparing
    case connecting
    case transferring
    case paused
    case verifying
    case completed
    case failed
    case cancelled
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
    case connectionFailed
    case transferFailed
    case cancelled
}
