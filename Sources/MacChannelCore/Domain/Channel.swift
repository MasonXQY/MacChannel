import Foundation

public enum ConnectionRoute: String, Codable, Sendable {
    case lan
    case directInternet
    case relay
}

public protocol SecureChannel: Sendable {
    var route: ConnectionRoute { get }

    func send(_ frame: Data) async throws
    func frames() -> AsyncThrowingStream<Data, Error>
    func exportKey(label: String, context: Data, length: Int) async throws -> Data
    func close() async
}

public protocol PeerConnector: Sendable {
    func connect(to device: DeviceID) async throws -> any SecureChannel
}

/// A connector that can bind a transport connection to a durable transfer
/// identity. Orchestration uses this refinement when it is available so every
/// reconnect remains part of the same transfer task.
public protocol TransferAwarePeerConnector: PeerConnector {
    func connect(to device: DeviceID, transferID: TransferID) async throws -> any SecureChannel
}

public protocol TransferCoordinating: Sendable {
    func send(items: [URL], to device: DeviceID) async throws -> TransferID
    func pause(_ id: TransferID) async
    func resume(_ id: TransferID) async throws
    func cancel(_ id: TransferID) async
}
