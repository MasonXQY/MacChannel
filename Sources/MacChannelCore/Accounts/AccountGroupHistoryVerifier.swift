import Foundation

/// Own one coordinator per runtime. Callers must still fence session lifecycle
/// and obtain explicit device consent; a valid snapshot grants no transfer trust.
public actor AccountGroupHistoryVerifier {
    private let storage: any AccountGroupCheckpointStorage
    private var operationInProgress = false

    public init(storage: any AccountGroupCheckpointStorage) { self.storage = storage }

    /// Pins are independently supplied by the caller, never inferred from history.
    /// Reconfirmation cannot reset a later head or synthesize its membership.
    public func confirm(anchor: AccountGroupEvent, expectedAccountID: String, expectedGroupID: String,
                        expectedGeneration: UInt64, expectedAnchorHash: Data,
                        binding: AccountSessionBinding) async throws -> AccountGroupSnapshot {
        try beginOperation()
        defer { operationInProgress = false }
        try requireNotCancelled()
        let state: AccountGroupState
        do {
            state = try AccountGroupState(anchor: anchor, expectedAccountID: expectedAccountID,
                expectedGroupID: expectedGroupID, expectedGeneration: expectedGeneration, expectedAnchorHash: expectedAnchorHash)
        } catch { throw AccountGroupCheckpointError.invalidHistory }
        let checkpoint = try AccountGroupCheckpoint(binding: binding, accountID: expectedAccountID, groupID: expectedGroupID,
            generation: expectedGeneration, anchorHash: expectedAnchorHash, sequence: 1, headHash: expectedAnchorHash)
        if let previous = try await load(binding: binding, accountID: expectedAccountID, groupID: expectedGroupID) {
            guard previous == checkpoint else { throw AccountGroupCheckpointError.invalidHistory }
        } else {
            try requireNotCancelled()
            try await save(checkpoint)
        }
        try requireNotCancelled()
        return state.snapshot
    }

    /// Accepts a complete bootstrap-to-head journal, never an unverified suffix.
    public func accept(history: [AccountGroupEvent], binding: AccountSessionBinding,
                       accountID: String, groupID: String) async throws -> AccountGroupSnapshot {
        try beginOperation()
        defer { operationInProgress = false }
        try requireNotCancelled()
        guard !history.isEmpty, history.count <= 8192 else { throw AccountGroupCheckpointError.invalidHistory }
        guard let checkpoint = try await load(binding: binding, accountID: accountID, groupID: groupID) else {
            throw AccountGroupCheckpointError.missingCheckpoint
        }
        guard checkpoint.binding == binding, checkpoint.accountID == accountID, checkpoint.groupID == groupID,
              UInt64(history.count) >= checkpoint.sequence else { throw AccountGroupCheckpointError.invalidHistory }
        var state: AccountGroupState
        do {
            state = try AccountGroupState(anchor: history[0], expectedAccountID: accountID, expectedGroupID: groupID,
                expectedGeneration: checkpoint.generation, expectedAnchorHash: checkpoint.anchorHash)
            for (index, event) in history.enumerated() {
                if index > 0 { try state.apply(event) }
                // The old head must appear at its exact sequence, even when the
                // candidate ends later. Final sequence alone cannot detect forks.
                if state.snapshot.sequence == checkpoint.sequence {
                    guard state.snapshot.headHash == checkpoint.headHash else { throw AccountGroupCheckpointError.invalidHistory }
                }
            }
        } catch { throw AccountGroupCheckpointError.invalidHistory }
        let snapshot = state.snapshot
        let next = try AccountGroupCheckpoint(binding: binding, accountID: accountID, groupID: groupID,
            generation: snapshot.generation, anchorHash: checkpoint.anchorHash,
            sequence: snapshot.sequence, headHash: snapshot.headHash)
        try requireNotCancelled()
        if next != checkpoint { try await save(next) }
        try requireNotCancelled()
        return snapshot
    }

    private func beginOperation() throws {
        // Actor isolation alone allows reentrancy at storage awaits. Bounded
        // admission rejects overlap instead of buffering unbounded operations.
        guard !operationInProgress else { throw AccountGroupCheckpointError.operationInProgress }
        operationInProgress = true
    }

    private func requireNotCancelled() throws {
        guard !Task.isCancelled else { throw AccountGroupCheckpointError.invalidHistory }
    }

    private func load(binding: AccountSessionBinding, accountID: String, groupID: String) async throws -> AccountGroupCheckpoint? {
        do { return try await storage.load(binding: binding, accountID: accountID, groupID: groupID) }
        catch { throw AccountGroupCheckpointError.secureStorage }
    }

    private func save(_ checkpoint: AccountGroupCheckpoint) async throws {
        // Cancellation never releases admission while this await is in flight.
        // A cancelled successful write can advance high-water but publishes no snapshot.
        do { try await storage.save(checkpoint) }
        catch { throw AccountGroupCheckpointError.secureStorage }
    }
}
