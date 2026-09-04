import Foundation
import MacChannelCore

final class RuntimeReceiveCompletionState: @unchecked Sendable {
    private let lock = NSLock()
    private var sequence: UInt64 = 0
    private var continuations: [UUID: AsyncStream<UInt64>.Continuation] = [:]
    private var isFinished = false

    var latestSequence: UInt64 {
        lock.withLock { sequence }
    }

    func sequences() -> AsyncStream<UInt64> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id)
            }
            let initial: UInt64? = lock.withLock {
                guard !isFinished else { return nil }
                continuations[id] = continuation
                return sequence
            }
            if let initial {
                continuation.yield(initial)
            } else {
                continuation.finish()
            }
        }
    }

    func recordCompletion() {
        let update: (UInt64, [AsyncStream<UInt64>.Continuation])? = lock.withLock {
            guard !isFinished else { return nil }
            sequence &+= 1
            return (sequence, Array(continuations.values))
        }
        guard let (sequence, continuations) = update else { return }
        continuations.forEach { $0.yield(sequence) }
    }

    func finish() {
        let current: [AsyncStream<UInt64>.Continuation] = lock.withLock {
            guard !isFinished else { return [] }
            isFinished = true
            let current = Array(continuations.values)
            continuations.removeAll(keepingCapacity: false)
            return current
        }
        current.forEach { $0.finish() }
    }

    private func removeContinuation(_ id: UUID) {
        _ = lock.withLock {
            continuations.removeValue(forKey: id)
        }
    }
}

struct RuntimeReceiveEventStream: AsyncSequence, Sendable {
    typealias Element = TransferReceiveResult

    struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate let subscription: Subscription

        mutating func next() async -> TransferReceiveResult? {
            await subscription.next()
        }
    }

    fileprivate final class Subscription: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private let nextValue: @Sendable () async -> TransferReceiveResult?
        private let cancelSubscription: @Sendable () async -> Void
        private let markRecordedValue: @Sendable (TransferReceiveResult) async -> Bool
        private let drainSubscription: @Sendable () async -> [TransferReceiveResult]

        init(
            next: @escaping @Sendable () async -> TransferReceiveResult?,
            cancel: @escaping @Sendable () async -> Void,
            markRecorded: @escaping @Sendable (TransferReceiveResult) async -> Bool = { _ in true },
            drainAndCancel: @escaping @Sendable () async -> [TransferReceiveResult] = { [] }
        ) {
            nextValue = next
            cancelSubscription = cancel
            markRecordedValue = markRecorded
            drainSubscription = drainAndCancel
        }

        func next() async -> TransferReceiveResult? {
            guard !lock.withLock({ cancelled }) else { return nil }
            return await nextValue()
        }

        func cancel() async {
            let shouldCancel = lock.withLock { () -> Bool in
                guard !cancelled else { return false }
                cancelled = true
                return true
            }
            if shouldCancel { await cancelSubscription() }
        }

        func markRecorded(_ result: TransferReceiveResult) async -> Bool {
            guard !lock.withLock({ cancelled }) else { return false }
            return await markRecordedValue(result)
        }

        func drainAndCancel() async -> [TransferReceiveResult] {
            let shouldDrain = lock.withLock { () -> Bool in
                guard !cancelled else { return false }
                cancelled = true
                return true
            }
            guard shouldDrain else { return [] }
            return await drainSubscription()
        }

        deinit {
            let shouldCancel = lock.withLock { () -> Bool in
                guard !cancelled else { return false }
                cancelled = true
                return true
            }
            guard shouldCancel else { return }
            let cancelSubscription = cancelSubscription
            Task { await cancelSubscription() }
        }
    }

    fileprivate let subscription: Subscription

    fileprivate init(subscription: Subscription) {
        self.subscription = subscription
    }

    init(
        next: @escaping @Sendable () async -> TransferReceiveResult?,
        cancel: @escaping @Sendable () async -> Void
    ) {
        subscription = Subscription(
            next: next,
            cancel: cancel,
            drainAndCancel: {
                await cancel()
                return []
            }
        )
    }

    init(
        next: @escaping @Sendable () async -> TransferReceiveResult?,
        cancel: @escaping @Sendable () async -> Void,
        markRecorded: @escaping @Sendable (TransferReceiveResult) async -> Bool,
        drainAndCancel: @escaping @Sendable () async -> [TransferReceiveResult]
    ) {
        subscription = Subscription(
            next: next,
            cancel: cancel,
            markRecorded: markRecorded,
            drainAndCancel: drainAndCancel
        )
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(subscription: subscription)
    }

    func cancel() async {
        await subscription.cancel()
    }

    func markRecorded(_ result: TransferReceiveResult) async -> Bool {
        await subscription.markRecorded(result)
    }

    func drainAndCancel() async -> [TransferReceiveResult] {
        await subscription.drainAndCancel()
    }

    fileprivate static var finished: RuntimeReceiveEventStream {
        RuntimeReceiveEventStream(
            subscription: Subscription(next: { nil }, cancel: {})
        )
    }
}

actor RuntimeReceiveEventSource {
    /// At most two inbound transfers complete concurrently. Four completion
    /// waves are retained per subscriber; the fifth wave backpressures those
    /// bounded receive runners instead of dropping a successful receive.
    static let defaultBufferCapacity = IncomingTransferCapacity.maximumActiveTransfers * 4

    private struct NextWaiter {
        let token: UUID
        let continuation: CheckedContinuation<TransferReceiveResult?, Never>
    }

    private struct SubscriptionState {
        var buffered: [TransferReceiveResult]
        var nextWaiter: NextWaiter?
        /// A yielded result stays owned by the source until the consumer marks
        /// its durable recording, so an atomic cutoff can recover the handoff race.
        var inFlight: TransferReceiveResult?
    }

    private struct PendingPublication {
        let token: UUID
        let result: TransferReceiveResult
        var recipientIDs: Set<UUID>?
        var continuation: CheckedContinuation<Void, Never>?
    }

    private let bufferCapacity: Int
    nonisolated let completionState = RuntimeReceiveCompletionState()
    private var subscriptions: [UUID: SubscriptionState] = [:]
    private var pendingFirstSubscription: [TransferReceiveResult] = []
    private var pendingPublications: [PendingPublication] = []
    private var hasSubscribed = false
    private var isFinished = false

    init(bufferCapacity: Int = RuntimeReceiveEventSource.defaultBufferCapacity) {
        self.bufferCapacity = max(1, bufferCapacity)
    }

    func stream() -> RuntimeReceiveEventStream {
        guard !isFinished else { return .finished }
        let id = UUID()
        let initial = hasSubscribed ? [] : pendingFirstSubscription
        hasSubscribed = true
        pendingFirstSubscription.removeAll(keepingCapacity: false)
        subscriptions[id] = SubscriptionState(buffered: initial, nextWaiter: nil, inFlight: nil)
        for index in pendingPublications.indices where pendingPublications[index].recipientIDs == nil {
            pendingPublications[index].recipientIDs = [id]
        }
        drainPendingPublications()

        return RuntimeReceiveEventStream(
            next: { [weak self] in await self?.next(subscription: id) },
            cancel: { [weak self] in await self?.cancelSubscription(id) },
            markRecorded: { [weak self] result in
                await self?.markRecorded(result, subscription: id) ?? false
            },
            drainAndCancel: { [weak self] in
                await self?.drainAndCancel(subscription: id) ?? []
            }
        )
    }

    func publish(_ result: TransferReceiveResult) async {
        guard !isFinished else { return }
        completionState.recordCompletion()
        let recipientIDs = hasSubscribed ? Set(subscriptions.keys) : nil
        if pendingPublications.isEmpty, canAcceptPublication(for: recipientIDs) {
            commitPublication(result, recipientIDs: recipientIDs)
            return
        }

        let token = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, !isFinished else {
                    continuation.resume()
                    return
                }
                pendingPublications.append(
                    PendingPublication(
                        token: token,
                        result: result,
                        recipientIDs: recipientIDs,
                        continuation: continuation
                    )
                )
                drainPendingPublications()
            }
        } onCancel: {
            Task { await self.cancelPublication(token) }
        }
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        completionState.finish()
        let publishers = pendingPublications
        pendingFirstSubscription.removeAll(keepingCapacity: false)
        pendingPublications.removeAll(keepingCapacity: false)
        for publication in publishers where publication.recipientIDs != nil {
            commitPublication(publication.result, recipientIDs: publication.recipientIDs)
        }
        for id in Array(subscriptions.keys) {
            guard var state = subscriptions[id],
                  state.buffered.isEmpty,
                  state.inFlight == nil
            else { continue }
            let waiter = state.nextWaiter
            state.nextWaiter = nil
            subscriptions.removeValue(forKey: id)
            waiter?.continuation.resume(returning: nil)
        }
        publishers.forEach { $0.continuation?.resume() }
    }

    private func canAcceptPublication(for recipientIDs: Set<UUID>?) -> Bool {
        guard let recipientIDs else {
            return pendingFirstSubscription.count < bufferCapacity
        }
        return recipientIDs.allSatisfy { id in
            guard let state = subscriptions[id] else { return true }
            return state.nextWaiter != nil || state.buffered.count < bufferCapacity
        }
    }

    private func commitPublication(
        _ result: TransferReceiveResult,
        recipientIDs: Set<UUID>?
    ) {
        guard let recipientIDs else {
            pendingFirstSubscription.append(result)
            return
        }

        for id in recipientIDs {
            guard var state = subscriptions[id] else { continue }
            if let waiter = state.nextWaiter {
                state.nextWaiter = nil
                state.inFlight = result
                subscriptions[id] = state
                waiter.continuation.resume(returning: result)
            } else {
                state.buffered.append(result)
                subscriptions[id] = state
            }
        }
    }

    private func drainPendingPublications() {
        while !isFinished,
              let publication = pendingPublications.first,
              canAcceptPublication(for: publication.recipientIDs)
        {
            _ = pendingPublications.removeFirst()
            commitPublication(publication.result, recipientIDs: publication.recipientIDs)
            publication.continuation?.resume()
        }
    }

    private func next(subscription id: UUID) async -> TransferReceiveResult? {
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, var state = subscriptions[id] else {
                    continuation.resume(returning: nil)
                    return
                }
                state.inFlight = nil
                if !state.buffered.isEmpty {
                    let result = state.buffered.removeFirst()
                    state.inFlight = result
                    subscriptions[id] = state
                    continuation.resume(returning: result)
                    drainPendingPublications()
                    return
                }
                guard !isFinished else {
                    subscriptions.removeValue(forKey: id)
                    continuation.resume(returning: nil)
                    return
                }
                guard state.nextWaiter == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                state.nextWaiter = NextWaiter(token: token, continuation: continuation)
                subscriptions[id] = state
            }
        } onCancel: {
            Task { await self.cancelNext(subscription: id, token: token) }
        }
    }

    private func cancelNext(subscription id: UUID, token: UUID) {
        guard var state = subscriptions[id], state.nextWaiter?.token == token else { return }
        let waiter = state.nextWaiter
        state.nextWaiter = nil
        subscriptions[id] = state
        waiter?.continuation.resume(returning: nil)
    }

    private func cancelSubscription(_ id: UUID) {
        guard let state = subscriptions.removeValue(forKey: id) else { return }
        state.nextWaiter?.continuation.resume(returning: nil)
        removeRecipient(id)
        drainPendingPublications()
    }

    private func cancelPublication(_ token: UUID) {
        guard let index = pendingPublications.firstIndex(where: { $0.token == token }) else { return }
        let continuation = pendingPublications[index].continuation
        pendingPublications[index].continuation = nil
        // Cancellation releases the publisher, but cannot retract a result the
        // source already accepted for live subscribers.
        continuation?.resume()
    }

    private func markRecorded(_ result: TransferReceiveResult, subscription id: UUID) -> Bool {
        guard var state = subscriptions[id], state.inFlight?.transferID == result.transferID else {
            return false
        }
        state.inFlight = nil
        subscriptions[id] = state
        return true
    }

    private func drainAndCancel(subscription id: UUID) -> [TransferReceiveResult] {
        // Actor isolation makes removal and the pending-recipient snapshot one cutoff.
        guard let state = subscriptions.removeValue(forKey: id) else { return [] }
        state.nextWaiter?.continuation.resume(returning: nil)
        var drained: [TransferReceiveResult] = []
        if let inFlight = state.inFlight {
            drained.append(inFlight)
        }
        drained.append(contentsOf: state.buffered)
        for publication in pendingPublications where publication.recipientIDs?.contains(id) == true {
            drained.append(publication.result)
        }
        removeRecipient(id)
        drainPendingPublications()
        return drained
    }

    private func removeRecipient(_ id: UUID) {
        for index in pendingPublications.indices {
            pendingPublications[index].recipientIDs?.remove(id)
        }
    }
}
