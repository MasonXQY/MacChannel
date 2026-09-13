import Foundation

/// A single runtime generation's stable router input. Socket replacement
/// changes the sender, never the streams or the WebRTC offer consumer.
public actor PresenceSignalBridge: RendezvousSignalSession {
    public struct SocketToken: Equatable, Sendable { fileprivate let value: UInt64 }
    public typealias Sender = @Sendable (Data, DeviceID) async throws -> Void

    public init() {}

    private let frames = AsyncStream<RendezvousSignalFrame>.makeStream(bufferingPolicy: .bufferingOldest(128))
    private let errors = AsyncStream<RendezvousProtocolError>.makeStream(bufferingPolicy: .bufferingOldest(64))
    private var sequence: UInt64 = 0
    private var socket: SocketToken?
    private var sender: Sender?
    private var finished = false

    public func signalFrames() -> AsyncStream<RendezvousSignalFrame> { frames.stream }
    public func protocolErrors() -> AsyncStream<RendezvousProtocolError> { errors.stream }

    public func beginSocket() -> SocketToken? {
        guard !finished else { return nil }
        sequence += 1
        let token = SocketToken(value: sequence)
        socket = token
        sender = nil
        return token
    }

    public func activate(_ token: SocketToken, sender: @escaping Sender) {
        guard !finished, socket == token else { return }
        self.sender = sender
    }

    public func disconnect(_ token: SocketToken) {
        guard socket == token else { return }
        socket = nil
        sender = nil
    }

    /// False means stale or overflow; the owning supervisor stops that socket.
    public func receive(_ frame: RendezvousSignalFrame, socket token: SocketToken) -> Bool {
        guard !finished, socket == token, sender != nil else { return false }
        if case .enqueued = frames.continuation.yield(frame) { return true }
        return false
    }

    public func receive(_ error: RendezvousProtocolError, socket token: SocketToken) -> Bool {
        guard !finished, socket == token, sender != nil else { return false }
        if case .enqueued = errors.continuation.yield(error) { return true }
        return false
    }

    public func sendSignal(_ payload: Data, to device: DeviceID) async throws {
        guard !finished, let token = socket, let sender else { throw CancellationError() }
        try Task.checkCancellation()
        do {
            try await sender(payload, device)
        } catch {
            guard !finished, socket == token, self.sender != nil, !Task.isCancelled else {
                throw CancellationError()
            }
            throw error
        }
        guard !finished, socket == token, self.sender != nil, !Task.isCancelled else {
            throw CancellationError()
        }
    }

    public func finish() {
        guard !finished else { return }
        finished = true
        socket = nil
        sender = nil
        frames.continuation.finish()
        errors.continuation.finish()
    }
}
