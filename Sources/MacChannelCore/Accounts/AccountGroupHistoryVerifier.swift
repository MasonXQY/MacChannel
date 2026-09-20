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
        try await confirm(anchor: anchor, expectedAccountID: expectedAccountID, expectedGroupID: expectedGroupID,
            expectedGeneration: expectedGeneration, expectedAnchorHash: expectedAnchorHash, binding: binding, authorization: nil)
    }

    func confirm(anchor: AccountGroupEvent, expectedAccountID: String, expectedGroupID: String,
                 expectedGeneration: UInt64, expectedAnchorHash: Data, binding: AccountSessionBinding,
                 authorization: AccountGroupVerificationAuthorization?) async throws -> AccountGroupSnapshot {
        try beginOperation()
        defer { operationInProgress = false }
        try requireCurrent(authorization)
        let state: AccountGroupState
        do {
            state = try AccountGroupState(anchor: anchor, expectedAccountID: expectedAccountID,
                expectedGroupID: expectedGroupID, expectedGeneration: expectedGeneration, expectedAnchorHash: expectedAnchorHash)
        } catch { throw AccountGroupCheckpointError.invalidHistory }
        let checkpoint = try AccountGroupCheckpoint(binding: binding, accountID: expectedAccountID, groupID: expectedGroupID,
            generation: expectedGeneration, anchorHash: expectedAnchorHash, sequence: 1, headHash: expectedAnchorHash)
        if let previous = try await load(binding: binding, accountID: expectedAccountID, groupID: expectedGroupID, authorization: authorization) {
            guard previous == checkpoint else { throw AccountGroupCheckpointError.invalidHistory }
        } else {
            try await save(checkpoint, authorization: authorization)
        }
        try requireCurrent(authorization)
        return state.snapshot
    }

    /// Accepts a complete bootstrap-to-head journal, never an unverified suffix.
    public func accept(history: [AccountGroupEvent], binding: AccountSessionBinding,
                       accountID: String, groupID: String) async throws -> AccountGroupSnapshot {
        try await accept(history: history, binding: binding, accountID: accountID, groupID: groupID, authorization: nil)
    }

    func accept(history: [AccountGroupEvent], binding: AccountSessionBinding,
                accountID: String, groupID: String, authorization: AccountGroupVerificationAuthorization?) async throws -> AccountGroupSnapshot {
        try beginOperation()
        defer { operationInProgress = false }
        try requireCurrent(authorization)
        guard !history.isEmpty, history.count <= 8192 else { throw AccountGroupCheckpointError.invalidHistory }
        guard let checkpoint = try await load(binding: binding, accountID: accountID, groupID: groupID, authorization: authorization) else {
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
        try requireCurrent(authorization)
        if next != checkpoint { try await save(next, authorization: authorization) }
        try requireCurrent(authorization)
        return snapshot
    }

    private func beginOperation() throws {
        // Actor isolation alone allows reentrancy at storage awaits. Bounded
        // admission rejects overlap instead of buffering unbounded operations.
        guard !operationInProgress else { throw AccountGroupCheckpointError.operationInProgress }
        operationInProgress = true
    }

    private func requireCurrent(_ authorization: AccountGroupVerificationAuthorization?) throws {
        guard !Task.isCancelled else { throw AccountGroupCheckpointError.invalidHistory }
        try authorization?.requireCurrent()
    }

    private func load(binding: AccountSessionBinding, accountID: String, groupID: String,
                      authorization: AccountGroupVerificationAuthorization?) async throws -> AccountGroupCheckpoint? {
        try requireCurrent(authorization)
        let checkpoint: AccountGroupCheckpoint?
        do { checkpoint = try await storage.load(binding: binding, accountID: accountID, groupID: groupID) }
        catch { try requireCurrent(authorization); throw AccountGroupCheckpointError.secureStorage }
        try requireCurrent(authorization)
        return checkpoint
    }

    private func save(_ checkpoint: AccountGroupCheckpoint, authorization: AccountGroupVerificationAuthorization?) async throws {
        // This synchronous authorization immediately precedes dependency issuance;
        // there is no async session-actor check whose reply can become stale.
        // Admission remains held until even a noncooperative save settles.
        try requireCurrent(authorization)
        do { try await storage.save(checkpoint) }
        catch { try requireCurrent(authorization); throw AccountGroupCheckpointError.secureStorage }
        try requireCurrent(authorization)
    }
}

/// Internal, credential-free lifecycle fence shared by the session and verifier.
/// Invalidation and successful authorization are ordered by the same lock. A
/// successful check immediately before issuing a dependency is its start
/// linearization point: that already-authorized operation may finish after a
/// concurrent invalidation, but every later dependency/result requires a new
/// check. No lock is held over I/O and no actor hop separates check from issuance.
final class AccountGroupVerificationAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var invalidated = false
    private let accessExpiresAt: Date
    private let confirmationExpiresAt: Date?
    private let now: @Sendable () -> Date

    init(accessExpiresAt: Date, confirmationExpiresAt: Date? = nil, now: @escaping @Sendable () -> Date) {
        self.accessExpiresAt = accessExpiresAt
        self.confirmationExpiresAt = confirmationExpiresAt
        self.now = now
    }

    func invalidate() { lock.withLock { invalidated = true } }

    func requireCurrent() throws {
        try lock.withLock {
            guard !invalidated else { throw AccountSessionControllerError.needsSignIn }
            let date = now()
            guard AccountServiceClient.validEpochMilliseconds(date) != nil else { throw AccountSessionControllerError.unavailable }
            if let confirmationExpiresAt, confirmationExpiresAt <= date { throw AccountFirstDeviceEnrollmentError.invalidAttempt }
            guard accessExpiresAt > date else { throw AccountSessionControllerError.needsSignIn }
        }
    }
}
