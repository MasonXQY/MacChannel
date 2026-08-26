import CryptoKit
import Foundation

public enum TrustStoreError: Error, Equatable {
    case invalidSignature
    case untrustedIssuer(DeviceID)
    case nonIncreasingSequence(DeviceID)
    case sequenceExhausted(DeviceID)
    case unexpectedAction(TrustAction)
    case unknownSubject(DeviceID)
    case cannotRevokeOwner
    case invalidSnapshot
    case invalidSnapshotOwner
    case snapshotAnchorMismatch
    case invalidSnapshotSignature
    case snapshotRevokesOwner
    case snapshotGenerationTooLow
    case snapshotGenerationExhausted
    case invalidPairingBootstrap
}

public struct TrustStoreSnapshot: Codable, Sendable {
    public let owner: DeviceID
    public let ownerPublicKey: Data
    public let generation: UInt64
    public let trustedPublicKeys: [DeviceID: Data]
    public let issuerSequences: [DeviceID: UInt64]
    public let revokedDevices: Set<DeviceID>
    public let signature: Data

    fileprivate init(
        owner: DeviceID,
        ownerPublicKey: Data,
        generation: UInt64,
        trustedPublicKeys: [DeviceID: Data],
        issuerSequences: [DeviceID: UInt64],
        revokedDevices: Set<DeviceID>,
        signature: Data
    ) {
        self.owner = owner
        self.ownerPublicKey = ownerPublicKey
        self.generation = generation
        self.trustedPublicKeys = trustedPublicKeys
        self.issuerSequences = issuerSequences
        self.revokedDevices = revokedDevices
        self.signature = signature
    }

    fileprivate func validated(minimumGeneration: UInt64) throws {
        guard generation >= minimumGeneration else {
            throw TrustStoreError.snapshotGenerationTooLow
        }
        guard !revokedDevices.contains(owner) else {
            throw TrustStoreError.snapshotRevokesOwner
        }
        guard let ownerKey = try? P256.Signing.PublicKey(rawRepresentation: ownerPublicKey),
              DeviceIdentity.deviceID(for: ownerPublicKey) == owner
        else {
            throw TrustStoreError.invalidSnapshotOwner
        }
        guard let parsedSignature = try? P256.Signing.ECDSASignature(derRepresentation: signature),
              ownerKey.isValidSignature(parsedSignature, for: try canonicalPayload())
        else {
            throw TrustStoreError.invalidSnapshotSignature
        }
        if let pinnedOwnerKey = trustedPublicKeys[owner], pinnedOwnerKey != ownerPublicKey {
            throw TrustStoreError.invalidSnapshot
        }
        for (device, publicKey) in trustedPublicKeys {
            guard (try? P256.Signing.PublicKey(rawRepresentation: publicKey)) != nil,
                  DeviceIdentity.deviceID(for: publicKey) == device,
                  !revokedDevices.contains(device)
            else {
                throw TrustStoreError.invalidSnapshot
            }
        }
    }

    fileprivate func canonicalPayload() throws -> Data {
        struct PublicKeyEntry: Encodable {
            let device: String
            let publicKey: String
        }
        struct SequenceEntry: Encodable {
            let device: String
            let sequence: UInt64
        }
        struct Payload: Encodable {
            let generation: UInt64
            let issuerSequences: [SequenceEntry]
            let owner: String
            let ownerPublicKey: String
            let revokedDevices: [String]
            let trustedPublicKeys: [PublicKeyEntry]
        }

        let trustedKeys = trustedPublicKeys.map { device, publicKey in
            PublicKeyEntry(
                device: device.rawValue.uuidString.lowercased(),
                publicKey: publicKey.base64EncodedString()
            )
        }.sorted { $0.device < $1.device }
        let sequences = issuerSequences.map { device, sequence in
            SequenceEntry(device: device.rawValue.uuidString.lowercased(), sequence: sequence)
        }.sorted { $0.device < $1.device }
        let revoked = revokedDevices.map { $0.rawValue.uuidString.lowercased() }.sorted()
        let payload = Payload(
            generation: generation,
            issuerSequences: sequences,
            owner: owner.rawValue.uuidString.lowercased(),
            ownerPublicKey: ownerPublicKey.base64EncodedString(),
            revokedDevices: revoked,
            trustedPublicKeys: trustedKeys
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }
}

public struct TrustStore: Sendable {
    private let owner: DeviceID
    private var trustedPublicKeys: [DeviceID: Data] = [:]
    private var issuerSequences: [DeviceID: UInt64] = [:]
    private var revokedDevices: Set<DeviceID> = []
    private var snapshotGeneration: UInt64 = 0

    public init(owner: DeviceID) {
        self.owner = owner
    }

    public init(
        snapshot: TrustStoreSnapshot,
        expectedOwner: DeviceIdentity,
        minimumGeneration: UInt64
    ) throws {
        guard snapshot.owner == expectedOwner.id,
              snapshot.ownerPublicKey == expectedOwner.publicKey.rawRepresentation
        else {
            throw TrustStoreError.snapshotAnchorMismatch
        }
        try snapshot.validated(minimumGeneration: minimumGeneration)
        owner = snapshot.owner
        trustedPublicKeys = snapshot.trustedPublicKeys
        issuerSequences = snapshot.issuerSequences
        revokedDevices = snapshot.revokedDevices
        snapshotGeneration = snapshot.generation
    }

    public func isTrusted(_ device: DeviceID) -> Bool {
        !revokedDevices.contains(device) && (device == owner || trustedPublicKeys[device] != nil)
    }

    public func isOwned(by identity: DeviceIdentity) -> Bool {
        owner == identity.id
    }

    public var persistedGeneration: UInt64 {
        snapshotGeneration
    }

    public func nextIssuerSequence(for issuer: DeviceIdentity) throws -> UInt64 {
        guard isTrusted(issuer.id) else {
            throw TrustStoreError.untrustedIssuer(issuer.id)
        }
        if let pinnedKey = trustedPublicKeys[issuer.id],
           pinnedKey != issuer.publicKey.rawRepresentation {
            throw TrustStoreError.invalidSignature
        }
        let next = (issuerSequences[issuer.id] ?? 0).addingReportingOverflow(1)
        guard !next.overflow else {
            throw TrustStoreError.sequenceExhausted(issuer.id)
        }
        return next.partialValue
    }

    mutating func bootstrapFromConfirmedPairing(
        _ record: SignedTrustRecord,
        localIdentity: DeviceIdentity
    ) throws {
        guard owner == localIdentity.id,
              record.action == .authorize,
              record.subject == owner,
              record.subjectPublicKey == localIdentity.publicKey.rawRepresentation,
              record.issuer != owner
        else {
            throw TrustStoreError.invalidPairingBootstrap
        }
        try record.validated()
        guard record.issuerSequence > (issuerSequences[record.issuer] ?? 0) else {
            throw TrustStoreError.nonIncreasingSequence(record.issuer)
        }
        if let pinnedKey = trustedPublicKeys[record.issuer],
           pinnedKey != record.issuerPublicKey {
            throw TrustStoreError.invalidSignature
        }
        issuerSequences[record.issuer] = record.issuerSequence
        trustedPublicKeys[record.issuer] = record.issuerPublicKey
        revokedDevices.remove(record.issuer)
    }

    public mutating func authorize(_ record: SignedTrustRecord) throws {
        guard record.action == .authorize else {
            throw TrustStoreError.unexpectedAction(record.action)
        }
        try ingest(record)
    }

    public mutating func ingest(_ record: SignedTrustRecord) throws {
        try apply(record)
    }

    public mutating func snapshot(signedBy ownerIdentity: DeviceIdentity) throws -> TrustStoreSnapshot {
        guard ownerIdentity.id == owner else {
            throw TrustStoreError.invalidSnapshotOwner
        }
        let increment = snapshotGeneration.addingReportingOverflow(1)
        guard !increment.overflow else {
            throw TrustStoreError.snapshotGenerationExhausted
        }
        let unsigned = TrustStoreSnapshot(
            owner: owner,
            ownerPublicKey: ownerIdentity.publicKey.rawRepresentation,
            generation: increment.partialValue,
            trustedPublicKeys: trustedPublicKeys,
            issuerSequences: issuerSequences,
            revokedDevices: revokedDevices,
            signature: Data()
        )
        let signature = try ownerIdentity.sign(unsigned.canonicalPayload()).derRepresentation
        snapshotGeneration = increment.partialValue
        return TrustStoreSnapshot(
            owner: unsigned.owner,
            ownerPublicKey: unsigned.ownerPublicKey,
            generation: unsigned.generation,
            trustedPublicKeys: unsigned.trustedPublicKeys,
            issuerSequences: unsigned.issuerSequences,
            revokedDevices: unsigned.revokedDevices,
            signature: signature
        )
    }

    @discardableResult
    public mutating func revoke(_ device: DeviceID, signedBy issuer: DeviceIdentity) throws -> SignedTrustRecord {
        guard device != owner else {
            throw TrustStoreError.cannotRevokeOwner
        }
        guard let subjectPublicKey = trustedPublicKeys[device] else {
            throw TrustStoreError.unknownSubject(device)
        }
        let currentSequence = issuerSequences[issuer.id] ?? 0
        guard currentSequence < UInt64.max else {
            throw TrustStoreError.sequenceExhausted(issuer.id)
        }
        let record = try SignedTrustRecord.revoking(
            device,
            subjectPublicKey: subjectPublicKey,
            signedBy: issuer,
            sequence: currentSequence + 1
        )
        try ingest(record)
        return record
    }

    private mutating func apply(_ record: SignedTrustRecord) throws {
        guard !(record.action == .revoke && record.subject == owner) else {
            throw TrustStoreError.cannotRevokeOwner
        }
        try record.validated()
        guard isTrusted(record.issuer) else {
            throw TrustStoreError.untrustedIssuer(record.issuer)
        }
        if let trustedKey = trustedPublicKeys[record.issuer], trustedKey != record.issuerPublicKey {
            throw TrustStoreError.invalidSignature
        }
        guard record.issuerSequence > (issuerSequences[record.issuer] ?? 0) else {
            throw TrustStoreError.nonIncreasingSequence(record.issuer)
        }

        issuerSequences[record.issuer] = record.issuerSequence
        trustedPublicKeys[record.issuer] = record.issuerPublicKey
        switch record.action {
        case .authorize:
            trustedPublicKeys[record.subject] = record.subjectPublicKey
            revokedDevices.remove(record.subject)
        case .revoke:
            trustedPublicKeys.removeValue(forKey: record.subject)
            revokedDevices.insert(record.subject)
        }
    }
}
