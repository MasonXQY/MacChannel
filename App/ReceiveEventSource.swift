import Foundation
import MacChannelCore

actor RuntimeReceiveEventSource {
    private var continuations: [UUID: AsyncStream<TransferReceiveResult>.Continuation] = [:]
    private var isFinished = false

    func stream() -> AsyncStream<TransferReceiveResult> {
        guard !isFinished else { return AsyncStream { $0.finish() } }
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.remove(id) }
            }
        }
    }

    func publish(_ result: TransferReceiveResult) {
        guard !isFinished else { return }
        continuations.values.forEach { $0.yield(result) }
    }

    func finish() {
        isFinished = true
        continuations.values.forEach { $0.finish() }
        continuations.removeAll()
    }

    private func remove(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
