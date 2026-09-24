import Foundation

public enum AccountForegroundState: Equatable, Sendable {
    case idle, signedOut, absent, enrolling, approvalRequired, unavailable, secureStorageError
    case verified(AccountGroupSnapshot)
}

/// Foreground ownership is independent of any settings presentation.
public actor AccountForegroundLifecycle {
    private let controller: AccountSessionController
    private let automaticEnrollment: AccountAutomaticEnrollment?
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date
    private var generation = UUID()
    private var worker: Task<Void, Never>?
    private var cycle: Task<AccountForegroundState, Never>?
    private var delay: Task<Void, Error>?
    private var observer: Task<Void, Never>?
    private var drain: Task<Void, Never>?
    private var drainID = UUID()
    private var lastSession: AccountSessionSnapshot?
    private var pendingSessionRefresh = false
    private var state = AccountForegroundState.idle
    private var waiters: [CheckedContinuation<AccountForegroundState, Never>] = []

    public init(controller: AccountSessionController,
                automaticEnrollment: AccountAutomaticEnrollment? = nil,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                now: @escaping @Sendable () -> Date = Date.init) {
        self.controller = controller; self.automaticEnrollment = automaticEnrollment
        self.sleep = sleep; self.now = now
    }

    public func start() async {
        if let drain { let id = drainID; await drain.value; finishStop(id) }
        guard worker == nil else { return }
        let id = UUID(); generation = id
        worker = Task { await run(id) }
    }

    public func stop() async {
        if let drain { let id = drainID; await drain.value; finishStop(id); return }
        generation = UUID()
        worker?.cancel(); cycle?.cancel(); delay?.cancel(); observer?.cancel()
        let old = worker, observation = observer
        let task = Task {
            await controller.suspendAccountRuntime()
            await old?.value
            await observation?.value
        }
        drain = task
        let id = UUID(); drainID = id
        await task.value
        finishStop(id)
    }

    private func finishStop(_ id: UUID) {
        // A resumed old stop must never erase a newly started generation.
        guard drain != nil, drainID == id else { return }
        worker = nil; cycle = nil; delay = nil; observer = nil; drain = nil
        state = .idle
        completeWaiters()
    }

    /// Joins owned refresh work; cancelling the presentation caller does not
    /// cancel the foreground task, revoke authority, or invalidate consent.
    @discardableResult public func requestRefresh() async -> AccountForegroundState {
        guard worker != nil, drain == nil else { return state }
        if let cycle { return await cycle.value }
        delay?.cancel()
        return await withCheckedContinuation {
            if waiters.count >= 32 { waiters.removeFirst().resume(returning: state) }
            waiters.append($0)
        }
    }

    private func run(_ id: UUID) async {
        let changes = await controller.runtimeChanges()
        observer = Task { [weak self, controller] in
            for await _ in changes {
                guard !Task.isCancelled else { return }
                let session = await controller.snapshot()
                await self?.sessionChanged(session, id: id)
            }
        }
        await controller.restore()
        lastSession = await controller.snapshot()
        while current(id) {
            pendingSessionRefresh = false
            let task = Task { await refreshOnce(id) }
            cycle = task
            let result = await task.value
            guard current(id) else { break }
            state = result; cycle = nil
            completeWaiters()
            if pendingSessionRefresh { continue }
            let pause: Duration = result == .unavailable ? .seconds(5) : .seconds(60)
            let timer = Task { try await sleep(pause) }
            delay = timer
            _ = await timer.result
            delay = nil
        }
        cycle?.cancel()
        observer?.cancel()
        await observer?.value
        completeWaiters()
    }

    private func sessionChanged(_ session: AccountSessionSnapshot, id: UUID) {
        guard current(id), lastSession != session else { return }
        lastSession = session
        // Session snapshots are scheduling hints only. Sync's own notifications
        // cannot create a feedback loop, and in-flight cycles already recheck.
        if cycle == nil { delay?.cancel() }
        else { pendingSessionRefresh = true }
    }

    private func current(_ id: UUID) -> Bool { generation == id && !Task.isCancelled }
    private func completeWaiters() {
        let pending = waiters; waiters = []
        for waiter in pending { waiter.resume(returning: state) }
    }

    private func refreshOnce(_ id: UUID) async -> AccountForegroundState {
        do {
            guard current(id), AccountServiceClient.validEpochMilliseconds(now()) != nil else { throw CancellationError() }
            // Retry failed restoration on the bounded next cycle, never on a
            // successfully restored session or every history refresh.
            if state == .unavailable || state == .secureStorageError {
                let phase = await controller.snapshot().phase
                if phase == .unavailable || phase == .secureStorageError {
                    await controller.restore()
                    guard current(id) else { throw CancellationError() }
                }
            }
            if let automaticEnrollment {
                let enrollment = try await automaticEnrollment.runOnce()
                guard current(id) else { throw CancellationError() }
                switch enrollment {
                case .signedOut: return .signedOut
                case .waitingForMember, .waitingForJoiningDevice: return .enrolling
                case .verified(let snapshot): return .verified(snapshot)
                }
            }
            try await controller.prepareAccountForegroundSync()
            guard current(id) else { throw CancellationError() }
            let discovery = try await controller.discoverAccountGroup()
            guard current(id) else { throw CancellationError() }
            switch discovery {
            case .absent:
                await controller.withdrawAccountForegroundEvidence()
                return .absent
            case .present(let metadata):
                let verified = try await controller.syncGroup(groupID: metadata.groupID)
                guard current(id) else { throw CancellationError() }
                return .verified(verified)
            }
        } catch {
            guard current(id) else { return .idle }
            if error as? AccountSessionControllerError == .busy { return .unavailable }
            await controller.withdrawAccountForegroundEvidence()
            if error as? AccountGroupCheckpointError == .missingCheckpoint { return .approvalRequired }
            if error as? AccountSessionControllerError == .needsSignIn {
                switch await controller.snapshot().phase {
                case .unavailable: return .unavailable
                case .secureStorageError: return .secureStorageError
                default: return .signedOut
                }
            }
            if error as? AccountGroupCheckpointError == .secureStorage || error as? AccountGroupCheckpointError == .invalidCheckpoint ||
                error as? AccountSessionControllerError == .secureStorage { return .secureStorageError }
            return .unavailable
        }
    }
}
