import Foundation
import MacChannelCore

actor RuntimeReceiveEventSource {
    private var continuations: [UUID: AsyncStream<TransferReceiveResult>.Continuation] = [:]
    private var pendingFirstSubscription: [TransferReceiveResult] = []
    private var hasSubscribed = false
    private var isFinished = false

    func stream() -> AsyncStream<TransferReceiveResult> {
        guard !isFinished else { return AsyncStream { $0.finish() } }
        let id = UUID()
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            continuations[id] = continuation
            if !hasSubscribed {
                hasSubscribed = true
                pendingFirstSubscription.forEach { _ = continuation.yield($0) }
                pendingFirstSubscription.removeAll(keepingCapacity: false)
            }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.remove(id) }
            }
        }
    }

    func publish(_ result: TransferReceiveResult) {
        guard !isFinished else { return }
        if continuations.isEmpty, !hasSubscribed {
            pendingFirstSubscription.append(result)
            return
        }
        continuations.values.forEach { continuation in
            _ = continuation.yield(result)
        }
    }

    func finish() {
        isFinished = true
        continuations.values.forEach { $0.finish() }
        continuations.removeAll()
        pendingFirstSubscription.removeAll(keepingCapacity: false)
    }

    private func remove(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
