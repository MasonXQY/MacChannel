import Foundation

public enum TrustRepositoryError: Error, Equatable, Sendable {
    case invalidOwner
    case generationMismatch
    case noPersistedSnapshot
}

/// Shared, actor-isolated trust state. Every mutation also advances and signs
/// the durable snapshot, so issuer sequences and trusted peers cannot be lost
/// when a coordinator is replaced.
public actor TrustRepository {
    public nonisolated let ownerID: DeviceID

    private let ownerIdentity: DeviceIdentity
    private var store: TrustStore
    private var latestSnapshot: TrustStoreSnapshot?

    public init(
        ownerIdentity: DeviceIdentity,
        trustStore: TrustStore,
        persistedGeneration: UInt64
    ) throws {
        guard trustStore.isOwned(by: ownerIdentity) else {
            throw TrustRepositoryError.invalidOwner
        }
        guard trustStore.persistedGeneration == persistedGeneration else {
            throw TrustRepositoryError.generationMismatch
        }
        self.ownerID = ownerIdentity.id
        self.ownerIdentity = ownerIdentity
        self.store = trustStore
    }

    public func isTrusted(_ device: DeviceID) -> Bool {
        store.isTrusted(device)
    }

    public func issueAuthorization(
        subject: DeviceID,
        subjectPublicKey: Data,
        timestamp: Date
    ) throws -> SignedTrustRecord {
        var candidate = store
        let sequence = try candidate.nextIssuerSequence(for: ownerIdentity)
        let authorization = try SignedTrustRecord.authorizing(
            subject: subject,
            subjectPublicKey: subjectPublicKey,
            signedBy: ownerIdentity,
            sequence: sequence,
            timestamp: timestamp
        )
        try candidate.authorize(authorization)
        let snapshot = try candidate.snapshot(signedBy: ownerIdentity)
        store = candidate
        latestSnapshot = snapshot
        return authorization
    }

    public func bootstrapFromConfirmedPairing(_ record: SignedTrustRecord) throws {
        var candidate = store
        try candidate.bootstrapFromConfirmedPairing(record, localIdentity: ownerIdentity)
        let snapshot = try candidate.snapshot(signedBy: ownerIdentity)
        store = candidate
        latestSnapshot = snapshot
    }

    public func latestSignedSnapshot() throws -> TrustStoreSnapshot {
        guard let latestSnapshot else {
            throw TrustRepositoryError.noPersistedSnapshot
        }
        return latestSnapshot
    }
}
