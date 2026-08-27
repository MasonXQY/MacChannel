import Foundation

struct TransferIOResourceOwnership: Sendable {
    let registry: BoundedChannelResourceRegistry
    let token: BoundedChannelResourceRegistry.Token
}

enum TransferIOResourceContext {
    @TaskLocal static var ownership: TransferIOResourceOwnership?
}

/// A process-wide admission token for channel-owning operations. A token is
/// retained until both the protocol runner has returned and its channel close
/// has returned. Cancellation only requests close cancellation; it never frees
/// capacity for an operation that ignores cancellation.
actor BoundedChannelResourceRegistry {
    enum Direction: Sendable {
        case inbound
        case outbound
    }

    struct Token: Hashable, Sendable {
        fileprivate let id: UUID
    }

    static let shared = BoundedChannelResourceRegistry()
    static let maximumPerDirection = 4
    static let maximumTotal = 8

    private struct Reservation {
        let direction: Direction
        let onReleased: @Sendable () async -> Void
        var runnerFinished = false
        var closeFinished = false
        var closeStarted = false
        var closeTask: Task<Void, Never>?
        var watchdogTask: Task<Void, Never>?
        var retainedOperations = 0
    }

    private var reservations: [UUID: Reservation] = [:]

    func reserve(
        _ direction: Direction,
        onReleased: @escaping @Sendable () async -> Void
    ) -> Token? {
        guard reservations.count < Self.maximumTotal,
            reservations.values.lazy.filter({ $0.direction == direction }).count
                < Self.maximumPerDirection
        else { return nil }
        let token = Token(id: UUID())
        reservations[token.id] = Reservation(
            direction: direction,
            onReleased: onReleased
        )
        return token
    }

    func beginClose(
        _ channel: any SecureChannel,
        token: Token,
        timeout: Duration
    ) {
        guard var reservation = reservations[token.id], !reservation.closeStarted else { return }
        reservation.closeStarted = true
        let closeTask = Task {
            await channel.close()
            self.closeReturned(token)
        }
        reservation.closeTask = closeTask
        let watchdogTask = Task {
            try? await Task.sleep(for: timeout)
            self.cancelCloseIfPresent(token)
        }
        reservation.watchdogTask = watchdogTask
        reservations[token.id] = reservation
    }

    /// Use when a runner never acquired a channel or has relinquished one
    /// before starting another attempt.
    func finishWithoutClose(_ token: Token) {
        guard var reservation = reservations[token.id] else { return }
        reservation.runnerFinished = true
        // A stale no-channel observer may run after the protocol runner has
        // handed a channel to its local cleanup path. Once close has started,
        // only the actual close operation may satisfy closeFinished.
        if !reservation.closeStarted { reservation.closeFinished = true }
        reservations[token.id] = reservation
        releaseIfFinished(token)
    }

    func runnerReturned(_ token: Token) {
        guard var reservation = reservations[token.id] else { return }
        reservation.runnerFinished = true
        reservations[token.id] = reservation
        releaseIfFinished(token)
    }

    func retainOperation(_ token: Token) -> Bool {
        guard var reservation = reservations[token.id] else { return false }
        reservation.retainedOperations += 1
        reservations[token.id] = reservation
        return true
    }

    func operationReturned(_ token: Token) {
        guard var reservation = reservations[token.id], reservation.retainedOperations > 0 else {
            return
        }
        reservation.retainedOperations -= 1
        reservations[token.id] = reservation
        releaseIfFinished(token)
    }

    func counts() -> (total: Int, inbound: Int, outbound: Int) {
        (
            reservations.count,
            reservations.values.filter { $0.direction == .inbound }.count,
            reservations.values.filter { $0.direction == .outbound }.count
        )
    }

    private func cancelCloseIfPresent(_ token: Token) {
        reservations[token.id]?.closeTask?.cancel()
    }

    private func closeReturned(_ token: Token) {
        guard var reservation = reservations[token.id] else { return }
        reservation.closeFinished = true
        reservation.closeTask = nil
        reservation.watchdogTask?.cancel()
        reservation.watchdogTask = nil
        reservations[token.id] = reservation
        releaseIfFinished(token)
    }

    private func releaseIfFinished(_ token: Token) {
        guard let reservation = reservations[token.id],
            reservation.runnerFinished,
            reservation.closeFinished,
            reservation.retainedOperations == 0
        else { return }
        reservations.removeValue(forKey: token.id)
        Task { await reservation.onReleased() }
    }
}

/// Process-wide admission for inbound channels that must be closed before they
/// ever acquired a receive-runner token. Listener lifecycles share this
/// backpressure point, and only the global inbound resource cap can start close
/// work. Readers reserve a token before pulling from their source, so admission
/// waiters retain no yielded channel and no second close backlog exists.
actor IncomingChannelCloseRegistry {
    struct Permit: Sendable {
        let resourceToken: BoundedChannelResourceRegistry.Token
    }

    static let shared = IncomingChannelCloseRegistry()
    static let maximumWaitingReaders = 4

    private let resources = BoundedChannelResourceRegistry.shared
    private struct Waiter {
        let continuation: CheckedContinuation<Void, Never>
    }
    private var admissionWaiters: [Waiter] = []
    private var capacityGeneration: UInt64 = 0

    /// Reserves cleanup ownership before a source is asked for its next
    /// channel. At most four readers may wait, and those waiters retain no
    /// transport or file descriptor.
    func acquire() async -> Permit? {
        while true {
            guard !Task.isCancelled else {
                resumeNextWaiter()
                return nil
            }
            let observedGeneration = capacityGeneration
            if let token = await resources.reserve(.inbound, onReleased: {
                await IncomingChannelCloseRegistry.shared.resourceCapacityReleased()
            }) {
                return Permit(resourceToken: token)
            }
            if observedGeneration != capacityGeneration { continue }
            guard admissionWaiters.count < Self.maximumWaitingReaders else { return nil }
            await waitForCapacity()
        }
    }

    func close(
        _ channel: any SecureChannel,
        permit: Permit,
        timeout: Duration
    ) async {
        await resources.beginClose(channel, token: permit.resourceToken, timeout: timeout)
        await resources.runnerReturned(permit.resourceToken)
    }

    func releaseUnused(_ permit: Permit) async {
        await resources.finishWithoutClose(permit.resourceToken)
    }

    func waitingReaderCount() -> Int { admissionWaiters.count }

    private func waitForCapacity() async {
        await withCheckedContinuation { continuation in
            admissionWaiters.append(Waiter(continuation: continuation))
        }
    }

    private func resourceCapacityReleased() {
        capacityGeneration &+= 1
        resumeNextWaiter()
    }

    private func resumeNextWaiter() {
        guard !admissionWaiters.isEmpty else { return }
        let waiter = admissionWaiters.removeFirst()
        waiter.continuation.resume()
    }
}
