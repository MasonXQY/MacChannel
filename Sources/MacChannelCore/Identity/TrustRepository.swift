import Foundation

public enum TrustRepositoryError: Error, Equatable, Sendable {
    case invalidOwner
    case generationMismatch
    case noPersistedSnapshot
}

public protocol IssuerSequenceReserving: Sendable {
    func reserveIssuerSequence(after floor: UInt64) throws -> UInt64
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
    private let issuerSequenceReserver: (any IssuerSequenceReserving)?
    private var store: TrustStore
    private var latestSnapshot: TrustStoreSnapshot?
    private var authenticationRecordsByPair: [RecordKey: SignedTrustRecord]
    private var updateSubscribers: [UUID: AsyncStream<TrustStore>.Continuation] = [:]

    public init(
        ownerIdentity: DeviceIdentity,
        trustStore: TrustStore,
        persistedGeneration: UInt64,
        authenticationRecords: [SignedTrustRecord] = [],
        issuerSequenceReserver: (any IssuerSequenceReserving)? = nil
    ) throws {
        guard trustStore.isOwned(by: ownerIdentity) else {
            throw TrustRepositoryError.invalidOwner
        }
        guard trustStore.persistedGeneration == persistedGeneration else {
            throw TrustRepositoryError.generationMismatch
        }
        self.ownerID = ownerIdentity.id
        self.ownerIdentity = ownerIdentity
        self.issuerSequenceReserver = issuerSequenceReserver
        self.store = trustStore
        var records: [RecordKey: SignedTrustRecord] = [:]
        for record in authenticationRecords {
            // The owner-signed snapshot is authoritative. Auxiliary proofs can
            // be safely discarded when an older app persisted them out of sync.
            guard (try? record.validated()) != nil else { continue }
            guard
                Self.isAuthenticationRecord(
                    record,
                    consistentWith: trustStore,
                    ownerIdentity: ownerIdentity
                )
            else {
                continue
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
        let sequence = try reserveIssuerSequence(for: candidate, timestamp: timestamp)
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
        let sequence = try reserveIssuerSequence(for: candidate, timestamp: timestamp)
        return try SignedTrustRecord.authorizing(
            subject: subject,
            subjectPublicKey: subjectPublicKey,
            signedBy: ownerIdentity,
            sequence: sequence,
            timestamp: timestamp
        )
    }

    private func reserveIssuerSequence(
        for candidate: TrustStore,
        timestamp: Date
    ) throws -> UInt64 {
        guard let issuerSequenceReserver else {
            return try candidate.nextIssuerSequence(for: ownerIdentity)
        }
        let milliseconds = timestamp.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              milliseconds > Double(Int64.min),
              milliseconds < Double(Int64.max)
        else {
            throw TrustRecordValidationError.invalidTimestamp
        }
        let timestampFloor = milliseconds > 0
            ? UInt64(milliseconds.rounded(.down))
            : 0
        return try issuerSequenceReserver.reserveIssuerSequence(
            after: max(candidate.issuerSequence(for: ownerID), timestampFloor)
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
    public func revoke(
        _ device: DeviceID,
        timestamp: Date = Date()
    ) throws -> SignedTrustRecord {
        var candidate = store
        let sequence = try reserveIssuerSequence(for: candidate, timestamp: timestamp)
        let record = try candidate.revoke(
            device,
            signedBy: ownerIdentity,
            sequence: sequence,
            timestamp: timestamp
        )
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
        _ = try ingestIfNew(record)
    }

    /// Idempotent ingestion is required for durable membership catch-up: a
    /// reconnecting service may resend the latest signed edge that this Mac
    /// already persisted before its acknowledgement was observed.
    @discardableResult
    public func ingestIfNew(_ record: SignedTrustRecord) throws -> Bool {
        let key = RecordKey(issuer: record.issuer, subject: record.subject)
        if authenticationRecordsByPair[key]?.signature == record.signature {
            return false
        }
        var candidate = store
        do {
            try candidate.ingest(record)
        } catch TrustStoreError.nonIncreasingSequence(let issuer)
            where issuer == record.issuer
        {
            // `TrustStore.apply` reaches this error only after validating the
            // signature, issuer trust and pinned key. A graph catch-up may
            // legitimately resend a third-party edge whose effect is already
            // covered by the persisted issuer high-water, even though that
            // auxiliary proof was intentionally not retained after restart.
            return false
        }
        let snapshot = try candidate.snapshot(signedBy: ownerIdentity)
        store = candidate
        latestSnapshot = snapshot
        recordAuthenticationProof(record)
        publishUpdate()
        return true
    }

    private func recordAuthenticationProof(_ record: SignedTrustRecord) {
        if record.action == .revoke, record.issuer == ownerID {
            authenticationRecordsByPair = authenticationRecordsByPair.filter { key, _ in
                key.issuer != record.subject && key.subject != record.subject
            }
        }
        if record.action == .authorize, record.subject == ownerID {
            let contradictoryRevocation = RecordKey(issuer: ownerID, subject: record.issuer)
            if authenticationRecordsByPair[contradictoryRevocation]?.action == .revoke {
                authenticationRecordsByPair.removeValue(forKey: contradictoryRevocation)
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

    func persistenceState() throws -> (
        snapshot: TrustStoreSnapshot,
        authenticationRecords: [SignedTrustRecord]
    ) {
        guard let latestSnapshot else {
            throw TrustRepositoryError.noPersistedSnapshot
        }
        return (latestSnapshot, authenticationRecords())
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
