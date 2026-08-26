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
    private var updateSubscribers: [UUID: AsyncStream<TrustStore>.Continuation] = [:]

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

    /// Returns key material only for an identity trusted at the instant of the
    /// lookup. A later revocation removes it from this authentication surface.
    public func publicKey(for device: DeviceID) -> Data? {
        guard store.isTrusted(device) else { return nil }
        if device == ownerID { return ownerIdentity.publicKey.rawRepresentation }
        return store.trustedPublicKey(for: device)
    }

    public func currentTrustStore() -> TrustStore {
        store
    }

    /// Verified state changes only. Consumers receive the current store first,
    /// then each atomically committed authorization, revocation, or ingestion.
    public func updates() -> AsyncStream<TrustStore> {
        let id = UUID()
        var continuation: AsyncStream<TrustStore>.Continuation!
        let stream = AsyncStream<TrustStore>(bufferingPolicy: .bufferingNewest(1)) {
            continuation = $0
        }
        continuation.yield(store)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeUpdateSubscriber(id) }
        }
        updateSubscribers[id] = continuation
        return stream
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
        publishUpdate()
        return authorization
    }

    public func bootstrapFromConfirmedPairing(_ record: SignedTrustRecord) throws {
        var candidate = store
        try candidate.bootstrapFromConfirmedPairing(record, localIdentity: ownerIdentity)
        let snapshot = try candidate.snapshot(signedBy: ownerIdentity)
        store = candidate
        latestSnapshot = snapshot
        publishUpdate()
    }

    @discardableResult
    public func revoke(_ device: DeviceID) throws -> SignedTrustRecord {
        var candidate = store
        let record = try candidate.revoke(device, signedBy: ownerIdentity)
        let snapshot = try candidate.snapshot(signedBy: ownerIdentity)
        store = candidate
        latestSnapshot = snapshot
        publishUpdate()
        return record
    }

    /// Accept only an already signed trust record, then persist an owner-signed
    /// local snapshot before exposing the resulting state to discovery.
    public func ingest(_ record: SignedTrustRecord) throws {
        var candidate = store
        try candidate.ingest(record)
        let snapshot = try candidate.snapshot(signedBy: ownerIdentity)
        store = candidate
        latestSnapshot = snapshot
        publishUpdate()
    }

    public func latestSignedSnapshot() throws -> TrustStoreSnapshot {
        guard let latestSnapshot else {
            throw TrustRepositoryError.noPersistedSnapshot
        }
        return latestSnapshot
    }

    private func removeUpdateSubscriber(_ id: UUID) {
        updateSubscribers.removeValue(forKey: id)
    }

    private func publishUpdate() {
        for continuation in updateSubscribers.values {
            continuation.yield(store)
        }
    }
}
