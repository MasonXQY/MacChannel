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
    private struct RecordKey: Hashable {
        let issuer: DeviceID
        let subject: DeviceID
    }

    public nonisolated let ownerID: DeviceID

    private let ownerIdentity: DeviceIdentity
    private var store: TrustStore
    private var latestSnapshot: TrustStoreSnapshot?
    private var authenticationRecordsByPair: [RecordKey: SignedTrustRecord]
    private var updateSubscribers: [UUID: AsyncStream<TrustStore>.Continuation] = [:]

    public init(
        ownerIdentity: DeviceIdentity,
        trustStore: TrustStore,
        persistedGeneration: UInt64,
        authenticationRecords: [SignedTrustRecord] = []
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
        var records: [RecordKey: SignedTrustRecord] = [:]
        for record in authenticationRecords {
            try record.validated()
            guard
                Self.isAuthenticationRecord(
                    record,
                    consistentWith: trustStore,
                    ownerIdentity: ownerIdentity
                )
            else {
                throw TrustRepositoryError.invalidOwner
            }
            let key = RecordKey(issuer: record.issuer, subject: record.subject)
            if let current = records[key], current.issuerSequence >= record.issuerSequence {
                continue
            }
            records[key] = record
        }
        authenticationRecordsByPair = records
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

    public func authenticationRecords() -> [SignedTrustRecord] {
        authenticationRecordsByPair.values.sorted {
            if $0.issuerSequence != $1.issuerSequence {
                return $0.issuerSequence < $1.issuerSequence
            }
            return $0.issuer.rawValue.uuidString < $1.issuer.rawValue.uuidString
        }
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
        recordAuthenticationProof(authorization)
        publishUpdate()
        return authorization
    }

    /// Signs the local half of a bilateral pairing without exposing trust yet.
    /// The record becomes visible only through `commitBilateralPairing`.
    public func prepareAuthorization(
        subject: DeviceID,
        subjectPublicKey: Data,
        timestamp: Date
    ) throws -> SignedTrustRecord {
        let candidate = store
        let sequence = try candidate.nextIssuerSequence(for: ownerIdentity)
        return try SignedTrustRecord.authorizing(
            subject: subject,
            subjectPublicKey: subjectPublicKey,
            signedBy: ownerIdentity,
            sequence: sequence,
            timestamp: timestamp
        )
    }

    /// Atomically publishes the two directionally correct records. A rejected
    /// or interrupted confirmation leaves the prior trust snapshot untouched.
    public func commitBilateralPairing(
        localAuthorization: SignedTrustRecord,
        peerAuthorization: SignedTrustRecord
    ) throws {
        if authenticationRecordsByPair[
            RecordKey(issuer: localAuthorization.issuer, subject: localAuthorization.subject)
        ]?.signature == localAuthorization.signature,
            authenticationRecordsByPair[
                RecordKey(issuer: peerAuthorization.issuer, subject: peerAuthorization.subject)
            ]?.signature == peerAuthorization.signature
        {
            return
        }
        try localAuthorization.validated()
        try peerAuthorization.validated()
        guard localAuthorization.action == .authorize,
            localAuthorization.issuer == ownerID,
            localAuthorization.issuerPublicKey == ownerIdentity.publicKey.rawRepresentation,
            peerAuthorization.action == .authorize,
            peerAuthorization.subject == ownerID,
            peerAuthorization.subjectPublicKey == ownerIdentity.publicKey.rawRepresentation,
            localAuthorization.subject == peerAuthorization.issuer,
            localAuthorization.subjectPublicKey == peerAuthorization.issuerPublicKey
        else { throw TrustRepositoryError.invalidOwner }

        var candidate = store
        try candidate.bootstrapFromConfirmedPairing(peerAuthorization, localIdentity: ownerIdentity)
        try candidate.authorize(localAuthorization)
        let snapshot = try candidate.snapshot(signedBy: ownerIdentity)
        store = candidate
        latestSnapshot = snapshot
        recordAuthenticationProof(localAuthorization)
        recordAuthenticationProof(peerAuthorization)
        publishUpdate()
    }

    public func bootstrapFromConfirmedPairing(_ record: SignedTrustRecord) throws {
        var candidate = store
        try candidate.bootstrapFromConfirmedPairing(record, localIdentity: ownerIdentity)
        let snapshot = try candidate.snapshot(signedBy: ownerIdentity)
        store = candidate
        latestSnapshot = snapshot
        recordAuthenticationProof(record)
        publishUpdate()
    }

    @discardableResult
    public func revoke(_ device: DeviceID) throws -> SignedTrustRecord {
        var candidate = store
        let record = try candidate.revoke(device, signedBy: ownerIdentity)
        let snapshot = try candidate.snapshot(signedBy: ownerIdentity)
        store = candidate
        latestSnapshot = snapshot
        recordAuthenticationProof(record)
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
        recordAuthenticationProof(record)
        publishUpdate()
    }

    private func recordAuthenticationProof(_ record: SignedTrustRecord) {
        if record.action == .revoke, record.issuer == ownerID {
            authenticationRecordsByPair = authenticationRecordsByPair.filter { key, _ in
                key.issuer != record.subject && key.subject != record.subject
            }
        }
        authenticationRecordsByPair[
            RecordKey(issuer: record.issuer, subject: record.subject)
        ] = record
    }

    private static func isAuthenticationRecord(
        _ record: SignedTrustRecord,
        consistentWith store: TrustStore,
        ownerIdentity: DeviceIdentity
    ) -> Bool {
        let owner = ownerIdentity.id
        let ownerKey = ownerIdentity.publicKey.rawRepresentation
        if record.issuer == owner, record.subject != owner {
            guard record.issuerPublicKey == ownerKey else { return false }
            switch record.action {
            case .authorize:
                return store.trustedPublicKey(for: record.subject) == record.subjectPublicKey
            case .revoke:
                return !store.isTrusted(record.subject)
            }
        }
        if record.subject == owner, record.issuer != owner, record.action == .authorize {
            return record.subjectPublicKey == ownerKey
                && store.trustedPublicKey(for: record.issuer) == record.issuerPublicKey
        }
        return false
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
