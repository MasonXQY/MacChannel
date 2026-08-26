import Foundation

public actor TransferSessionControl {
    public enum State: Sendable {
        case active
        case paused
        case cancelled
    }

    private var currentState: State = .active

    public init() {}

    public func pause() {
        guard currentState != .cancelled else { return }
        currentState = .paused
    }

    public func resume() {
        guard currentState != .cancelled else { return }
        currentState = .active
    }

    public func cancel() {
        currentState = .cancelled
    }

    func state() -> State { currentState }
}
