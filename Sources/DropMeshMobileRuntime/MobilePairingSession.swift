import Foundation
import MacChannelCore

public enum MobilePairingState: Equatable, Sendable {
    case active(PairingState)
    case saving(DeviceSummary)
    case saveFailed(DeviceSummary)
    case paired(DeviceSummary)
}

public enum MobilePairingError: Error {
    case confirmationTimedOut
    case saveRequired
    case noPendingSave
}

/// A single UI session. Success is local durability plus the core's bilateral
/// confirmation, never just successful delivery of an authorization message.
public actor MobilePairingSession {
    private let coordinator: PairingCoordinator
    private let persistTrust: @Sendable () async throws -> Void
    private var busy = false
    private var savedPeer: DeviceSummary?
    private var failedSavePeer: DeviceSummary?

    public init(coordinator: PairingCoordinator, persistTrust: @escaping @Sendable () async throws -> Void) {
        self.coordinator = coordinator
        self.persistTrust = persistTrust
    }

    public func currentState() async -> MobilePairingState {
        let state = await coordinator.currentState()
        guard case let .confirmed(peer) = state else { return .active(state) }
        if savedPeer?.id == peer.id { return .paired(peer) }
        if failedSavePeer?.id == peer.id { return .saveFailed(peer) }
        return busy ? .saving(peer) : .saveFailed(peer)
    }

    public func createCode() async throws -> String {
        try begin()
        defer { busy = false }
        savedPeer = nil
        return try await coordinator.createCode()
    }

    public func join(code: String) async throws -> PairingJoinResult {
        try begin()
        defer { busy = false }
        savedPeer = nil
        return try await coordinator.join(code: code)
    }

    public func approve() async throws -> DeviceSummary {
        try begin()
        defer { busy = false }
        guard let peer = await coordinator.pendingPeerSummary() else { throw PairingError.noPendingConfirmation }
        _ = try await coordinator.approvePendingPairing()
        return try await finish(peer: peer)
    }

    public func awaitApproval() async throws -> DeviceSummary {
        try begin()
        defer { busy = false }
        guard let peer = await coordinator.pendingPeerSummary() else { throw PairingError.noPendingConfirmation }
        _ = try await coordinator.awaitHostApproval()
        return try await finish(peer: peer)
    }

    public func reject() async throws {
        try begin()
        defer { busy = false }
        try await coordinator.rejectPendingPairing()
        savedPeer = nil
    }

    /// An active caller task must be cancelled and awaited before invoking this.
    /// A rejected cancellation never pretends the peer rolled back trust.
    public func cancel() async throws {
        try begin()
        defer { busy = false }
        try await coordinator.cancelPendingPairing()
        if case .idle = await coordinator.currentState() { savedPeer = nil }
    }

    public func retrySaving() async throws -> DeviceSummary {
        guard !busy else { throw PairingError.operationInProgress }
        busy = true
        defer { busy = false }
        // Core confirmation can arrive after caller cancellation or timeout.
        // Recover its persistence without issuing a second authorization.
        let state = await coordinator.currentState()
        guard case let .confirmed(peer) = state, savedPeer?.id != peer.id else {
            throw MobilePairingError.noPendingSave
        }
        return try await finish(peer: peer)
    }

    private func begin() throws {
        guard !busy else { throw PairingError.operationInProgress }
        guard failedSavePeer == nil else { throw MobilePairingError.saveRequired }
        busy = true
    }

    private func finish(peer: DeviceSummary) async throws -> DeviceSummary {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while true {
            try Task.checkCancellation()
            let state = await coordinator.currentState()
            if case let .confirmed(confirmed) = state, confirmed.id == peer.id {
                do {
                    try await persistTrust()
                    savedPeer = confirmed
                    failedSavePeer = nil
                    return confirmed
                } catch {
                    failedSavePeer = confirmed
                    throw error
                }
            }
            if case .failed = state { throw PairingError.invalidHandshake }
            guard clock.now < deadline else { throw MobilePairingError.confirmationTimedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
