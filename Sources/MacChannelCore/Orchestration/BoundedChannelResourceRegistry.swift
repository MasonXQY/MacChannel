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
    static let maximumWaitingReservations = IncomingTransferCapacity.maximumAdmittedChannels

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
    private struct ReservationWaiter {
        let direction: Direction
        let onReleased: @Sendable () async -> Void
        let continuation: CheckedContinuation<Token, Never>
    }
    private var reservationWaiters: [ReservationWaiter] = []

    func reserve(
        _ direction: Direction,
        onReleased: @escaping @Sendable () async -> Void
    ) -> Token? {
        makeReservation(direction, onReleased: onReleased)
    }

    /// Waits for the same hard resource bound without allocating an additional
    /// channel slot. Incoming callers already own one of the process-wide
    /// retained-channel permits, so this waiter collection is also bounded.
    func reserveWhenAvailable(
        _ direction: Direction,
        onReleased: @escaping @Sendable () async -> Void
    ) async -> Token? {
        if let token = makeReservation(direction, onReleased: onReleased) { return token }
        guard reservationWaiters.count < Self.maximumWaitingReservations else { return nil }
        return await withCheckedContinuation { continuation in
            reservationWaiters.append(
                ReservationWaiter(
                    direction: direction,
                    onReleased: onReleased,
                    continuation: continuation
                )
            )
        }
    }

    private func makeReservation(
        _ direction: Direction,
        onReleased: @escaping @Sendable () async -> Void
    ) -> Token? {
        guard canReserve(direction) else { return nil }
        let token = Token(id: UUID())
        reservations[token.id] = Reservation(
            direction: direction,
            onReleased: onReleased
        )
        return token
    }

    private func canReserve(_ direction: Direction) -> Bool {
        reservations.count < Self.maximumTotal
            && reservations.values.lazy.filter({ $0.direction == direction }).count
                < Self.maximumPerDirection
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
        resumeFirstFittingReservationWaiter()
        Task { await reservation.onReleased() }
    }

    private func resumeFirstFittingReservationWaiter() {
        guard let index = reservationWaiters.firstIndex(where: { canReserve($0.direction) }) else {
            return
        }
        let waiter = reservationWaiters.remove(at: index)
        guard let token = makeReservation(waiter.direction, onReleased: waiter.onReleased) else {
            assertionFailure("A fitting bounded-resource waiter lost its actor-isolated capacity")
            reservationWaiters.insert(waiter, at: index)
            return
        }
        waiter.continuation.resume(returning: token)
    }
}

/// Process-wide retained-channel admission and bounded inbound-close execution.
/// Readers reserve one of 34 permits before pulling from their source. The same
/// permit follows the channel through receive, queue, and close, while at most
/// four independent resource tokens execute protocol or close operations.
actor IncomingChannelCloseRegistry {
    struct Permit: Hashable, Sendable {
        fileprivate let id: UUID
    }

    static let shared = IncomingChannelCloseRegistry()
    static let maximumAdmittedChannels = IncomingTransferCapacity.maximumAdmittedChannels
    static let maximumWaitingReaders = 4

    private let resources = BoundedChannelResourceRegistry.shared
    private struct Waiter {
        let continuation: CheckedContinuation<Permit, Never>
    }
    private struct CloseRequest {
        let channel: any SecureChannel
        let permit: Permit
        let timeout: Duration
    }

    private var admittedPermits: Set<Permit> = []
    private var admissionWaiters: [Waiter] = []
    private var closingPermits: Set<Permit> = []
    private var activeClosePermits: Set<Permit> = []
    private var closeQueue: [CloseRequest] = []
    private var closeWorker: Task<Void, Never>?

    /// Reserves cleanup ownership before a source is asked for its next
    /// channel. At most 34 channels and four additional channel-free readers
    /// may be retained process-wide.
    func acquire() async -> Permit? {
        guard !Task.isCancelled else { return nil }
        if admittedPermits.count < Self.maximumAdmittedChannels {
            return makePermit()
        }
        guard admissionWaiters.count < Self.maximumWaitingReaders else { return nil }
        let permit = await waitForCapacity()
        guard !Task.isCancelled else {
            releasePermit(permit)
            return nil
        }
        return permit
    }

    func close(
        _ channel: any SecureChannel,
        permit: Permit,
        timeout: Duration
    ) async {
        guard admittedPermits.contains(permit), closingPermits.insert(permit).inserted else {
            return
        }
        closeQueue.append(CloseRequest(channel: channel, permit: permit, timeout: timeout))
        scheduleCloseWorker()
    }

    func releaseUnused(_ permit: Permit) {
        guard !closingPermits.contains(permit) else { return }
        releasePermit(permit)
    }

    func waitingReaderCount() -> Int { admissionWaiters.count }
    func admittedChannelCount() -> Int { admittedPermits.count }
    func queuedCloseCount() -> Int { closeQueue.count }
    func activeCloseCount() -> Int { activeClosePermits.count }

    /// Completes ownership for a channel that used its resource token as an
    /// active receive (including a direct stop-time close).
    func activeResourceReleased(_ permit: Permit) {
        guard admittedPermits.contains(permit), !closingPermits.contains(permit) else { return }
        releasePermit(permit)
        scheduleCloseWorker()
    }

    private func makePermit() -> Permit {
        let permit = Permit(id: UUID())
        admittedPermits.insert(permit)
        return permit
    }

    private func waitForCapacity() async -> Permit {
        await withCheckedContinuation { continuation in
            admissionWaiters.append(Waiter(continuation: continuation))
        }
    }

    private func releasePermit(_ permit: Permit) {
        guard admittedPermits.remove(permit) != nil else { return }
        closingPermits.remove(permit)
        activeClosePermits.remove(permit)
        guard !admissionWaiters.isEmpty else { return }
        let waiter = admissionWaiters.removeFirst()
        waiter.continuation.resume(returning: makePermit())
    }

    private func scheduleCloseWorker() {
        guard closeWorker == nil, !closeQueue.isEmpty else { return }
        closeWorker = Task { await self.drainCloseQueue() }
    }

    private func drainCloseQueue() async {
        defer { closeWorker = nil }
        while let request = closeQueue.first {
            guard let resourceToken = await resources.reserveWhenAvailable(
                .inbound,
                onReleased: {
                    await IncomingChannelCloseRegistry.shared.closeResourceReleased(
                        request.permit
                    )
                }
            ) else { return }
            guard closeQueue.first?.permit == request.permit else {
                await resources.finishWithoutClose(resourceToken)
                continue
            }
            closeQueue.removeFirst()
            activeClosePermits.insert(request.permit)
            await resources.beginClose(
                request.channel,
                token: resourceToken,
                timeout: request.timeout
            )
            await resources.runnerReturned(resourceToken)
        }
    }

    private func closeResourceReleased(_ permit: Permit) {
        guard activeClosePermits.remove(permit) != nil else { return }
        releasePermit(permit)
        scheduleCloseWorker()
    }
}
