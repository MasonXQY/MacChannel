import Foundation

public actor TransferSessionControl {
    public enum State: Sendable {
        case active
        case paused
        case cancelled
    }

    struct Snapshot: Sendable {
        let state: State
        let revision: UInt64
    }

    private var currentState: State = .active
    private var revision: UInt64 = 0
    private var waiters: [UUID: CheckedContinuation<Snapshot, Never>] = [:]

    public init() {}

    public func pause() {
        transition(to: .paused)
    }

    public func resume() {
        transition(to: .active)
    }

    public func cancel() {
        transition(to: .cancelled)
    }

    func snapshot() -> Snapshot {
        Snapshot(state: currentState, revision: revision)
    }

    func waitForChange(after observedRevision: UInt64) async -> Snapshot {
        if observedRevision != revision || Task.isCancelled {
            return snapshot()
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if observedRevision != revision || Task.isCancelled {
                    continuation.resume(returning: snapshot())
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await cancelWaiter(id) }
        }
    }

    func waitUntilCancelled() async throws {
        var observed = snapshot()
        while true {
            try Task.checkCancellation()
            if case .cancelled = observed.state { return }
            observed = await waitForChange(after: observed.revision)
        }
    }

    private func transition(to newState: State) {
        guard currentState != .cancelled, currentState != newState else { return }
        currentState = newState
        revision &+= 1
        let snapshot = snapshot()
        let continuations = waiters.values
        waiters.removeAll(keepingCapacity: false)
        for continuation in continuations {
            continuation.resume(returning: snapshot)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(returning: snapshot())
    }
}
