import Foundation

public enum DurablePairingState: Equatable, Sendable {
    case active(PairingState)
    case saving(DeviceSummary)
    case saveFailed(DeviceSummary)
    case paired(DeviceSummary)
}

public enum DurablePairingError: Error {
    case confirmationTimedOut
    case saveRequired
    case noPendingSave
}

public protocol DurablePairingCoordinating: Sendable {
    var states: AsyncStream<PairingState> { get }
    func currentState() async -> PairingState
    func isTrusted(_ device: DeviceID) async -> Bool
    func createCode() async throws -> String
    func join(code: String) async throws -> PairingJoinResult
    func approvePendingPairing() async throws -> SignedTrustRecord
    func pendingHostConfirmation() async -> PairingHostConfirmation?
    func approvePendingPairing(_ expected: PairingHostConfirmation) async throws -> SignedTrustRecord
    func awaitHostApproval() async throws -> SignedTrustRecord
    func rejectPendingPairing() async throws
    func cancelPendingPairing() async throws
    func pendingPeerSummary() async -> DeviceSummary?
}

extension PairingCoordinator: DurablePairingCoordinating {}

extension DurablePairingCoordinating {
    public func pendingHostConfirmation() async -> PairingHostConfirmation? { nil }
    public func approvePendingPairing(_ expected: PairingHostConfirmation) async throws -> SignedTrustRecord {
        throw PairingError.noPendingConfirmation
    }
}

/// Local durable completion requires bilateral confirmation and successful saving.
/// Failed/interrupted saving retains the same signed authorization for retry.
public actor DurablePairingSession {
    public nonisolated let states: AsyncStream<DurablePairingState>
    private let continuation: AsyncStream<DurablePairingState>.Continuation
    private let coordinator: any DurablePairingCoordinating
    private let persistTrust: @Sendable (DeviceSummary) async throws -> Void
    private let confirmationTimeout: Duration
    private var busy = false
    private var operationDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var unsettled = false
    private var savedPeer: DeviceSummary?
    private var savingPeer: DeviceSummary?
    private var observation: Task<Void, Never>?
    private var observationGeneration = 0
    private var retired = false
    private var published: DurablePairingState?

    public init(coordinator: any DurablePairingCoordinating, confirmationTimeout: Duration = .seconds(30),
                persistTrust: @escaping @Sendable (DeviceSummary) async throws -> Void) {
        self.coordinator = coordinator
        self.persistTrust = persistTrust
        self.confirmationTimeout = confirmationTimeout
        let stream = AsyncStream<DurablePairingState>.makeStream()
        states = stream.stream
        continuation = stream.continuation
    }

    deinit { observation?.cancel(); continuation.finish() }

    public func startObservation() async {
        guard observation == nil, !retired else { return }
        observationGeneration += 1
        let generation = observationGeneration
        let updates = coordinator.states
        observation = Task { [weak self] in
            await self?.refreshObservation(generation)
            for await _ in updates {
                guard !Task.isCancelled else { return }
                await self?.refreshObservation(generation)
            }
        }
    }

    /// Terminal runtime retirement. Closing a pairing sheet calls `cancel`, not
    /// this method. Joins every admitted operation, including suspended saves,
    /// before a replacement runtime may load storage and create a fresh gate.
    public func stopObservation() async {
        retired = true
        observationGeneration += 1
        let task = observation
        task?.cancel()
        await task?.value
        observation = nil
        if busy {
            await withCheckedContinuation { operationDrainWaiters.append($0) }
        }
        continuation.finish()
    }

    private func refreshObservation(_ generation: Int) async {
        let state = await currentState()
        guard generation == observationGeneration, !Task.isCancelled else { return }
        publish(state)
    }

    public func currentState() async -> DurablePairingState {
        let state = await coordinator.currentState()
        guard case let .confirmed(peer) = state else { return .active(state) }
        guard await coordinator.isTrusted(peer.id) else { return .active(.idle) }
        if savedPeer?.id == peer.id { return .paired(peer) }
        if savingPeer?.id == peer.id { return .saving(peer) }
        return .saveFailed(peer)
    }

    public func pendingPeerSummary() async -> DeviceSummary? { await coordinator.pendingPeerSummary() }
    public func pendingHostConfirmation() async -> PairingHostConfirmation? {
        guard !retired, !busy else { return nil }
        return await coordinator.pendingHostConfirmation()
    }

    public func createCode() async throws -> String {
        try await begin(newPair: true)
        defer { endOperation() }
        savedPeer = nil
        let code = try await coordinator.createCode()
        publish(await currentState())
        return code
    }

    public func join(code: String) async throws -> PairingJoinResult {
        try await begin(newPair: true)
        defer { endOperation() }
        savedPeer = nil
        let result = try await coordinator.join(code: code)
        publish(await currentState())
        return result
    }

    public func approve() async throws -> DeviceSummary { try await complete(host: true) }
    public func approve(_ expected: PairingHostConfirmation) async throws -> DeviceSummary {
        try await complete(host: true, expected: expected)
    }
    public func awaitApproval() async throws -> DeviceSummary { try await complete(host: false) }

    private func complete(host: Bool, expected: PairingHostConfirmation? = nil) async throws -> DeviceSummary {
        try await begin(newPair: true)
        defer { endOperation() }
        guard let peer = await coordinator.pendingPeerSummary() else { throw PairingError.noPendingConfirmation }
        guard !retired else { throw PairingError.staleOperation }
        if let expected {
            guard await coordinator.pendingHostConfirmation() == expected else { throw PairingError.staleOperation }
        }
        unsettled = true
        do {
            if let expected { _ = try await coordinator.approvePendingPairing(expected) }
            else if host { _ = try await coordinator.approvePendingPairing() }
            else { _ = try await coordinator.awaitHostApproval() }
            let deadline = ContinuousClock.now.advanced(by: confirmationTimeout)
            while true {
                try Task.checkCancellation()
                guard !retired else { throw PairingError.staleOperation }
                let state = await coordinator.currentState()
                if case let .confirmed(confirmed) = state, confirmed.id == peer.id {
                    return try await save(confirmed)
                }
                publish(.active(state))
                if case .failed = state { throw PairingError.invalidHandshake }
                guard ContinuousClock.now < deadline else { throw DurablePairingError.confirmationTimedOut }
                try await Task.sleep(for: .milliseconds(20))
            }
        } catch {
            publish(await currentState())
            throw error
        }
    }

    public func reject() async throws {
        try await begin(newPair: false)
        defer { endOperation() }
        try await coordinator.rejectPendingPairing()
        try await reconcileCancellation()
    }

    /// Cancel and await any active caller before invoking this operation.
    public func cancel() async throws {
        try await begin(newPair: false)
        defer { endOperation() }
        try await coordinator.cancelPendingPairing()
        try await reconcileCancellation()
    }

    private func reconcileCancellation() async throws {
        let state = await currentState()
        publish(state)
        if case .active(.idle) = state { savedPeer = nil; unsettled = false }
        if case .active(.failed) = state, await coordinator.pendingPeerSummary() == nil {
            unsettled = false
        }
        if case .saveFailed = state { throw DurablePairingError.saveRequired }
    }

    public func retrySaving() async throws -> DeviceSummary {
        guard !retired else { throw PairingError.staleOperation }
        guard !busy else { throw PairingError.operationInProgress }
        busy = true
        defer { endOperation() }
        guard case let .confirmed(peer) = await coordinator.currentState(), savedPeer?.id != peer.id else {
            throw DurablePairingError.noPendingSave
        }
        return try await save(peer)
    }

    private func begin(newPair: Bool) async throws {
        guard !retired else { throw PairingError.staleOperation }
        guard !busy else { throw PairingError.operationInProgress }
        busy = true
        let state = await currentState()
        guard !retired else {
            endOperation()
            throw PairingError.staleOperation
        }
        if case .saveFailed = state {
            endOperation()
            publish(state)
            throw DurablePairingError.saveRequired
        }
        if newPair && unsettled {
            endOperation()
            throw PairingError.operationInProgress
        }
    }

    private func endOperation() {
        busy = false
        let waiters = operationDrainWaiters
        operationDrainWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func save(_ peer: DeviceSummary) async throws -> DeviceSummary {
        try await validateConfirmation(peer)
        guard !retired else { throw PairingError.staleOperation }
        savingPeer = peer
        publish(.saving(peer))
        do {
            try await persistTrust(peer)
            try await validateConfirmation(peer)
            savedPeer = peer
            savingPeer = nil
            unsettled = false
            publish(.paired(peer))
            return peer
        } catch {
            savingPeer = nil
            publish(await currentState())
            throw error
        }
    }

    private func validateConfirmation(_ peer: DeviceSummary) async throws {
        guard case let .confirmed(current) = await coordinator.currentState(), current.id == peer.id,
              await coordinator.isTrusted(peer.id) else {
            savedPeer = nil
            unsettled = false
            throw PairingError.staleOperation
        }
    }

    private func publish(_ state: DurablePairingState) {
        guard !retired, published != state else { return }
        published = state
        continuation.yield(state)
    }
}
