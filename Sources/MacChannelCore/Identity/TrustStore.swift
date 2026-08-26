import CryptoKit
import Foundation

public enum TrustStoreError: Error, Equatable {
    case invalidSignature
    case untrustedIssuer(DeviceID)
    case nonIncreasingSequence(DeviceID)
    case unexpectedAction(TrustAction)
    case unknownSubject(DeviceID)
    case invalidSnapshot
}

public struct TrustStoreSnapshot: Codable, Sendable {
    public let owner: DeviceID
    public let trustedPublicKeys: [DeviceID: Data]
    public let issuerSequences: [DeviceID: UInt64]
    public let revokedDevices: Set<DeviceID>

    public init(
        owner: DeviceID,
        trustedPublicKeys: [DeviceID: Data],
        issuerSequences: [DeviceID: UInt64],
        revokedDevices: Set<DeviceID>
    ) {
        self.owner = owner
        self.trustedPublicKeys = trustedPublicKeys
        self.issuerSequences = issuerSequences
        self.revokedDevices = revokedDevices
    }
}

public struct TrustStore {
    private let owner: DeviceID
    private var trustedPublicKeys: [DeviceID: Data] = [:]
    private var issuerSequences: [DeviceID: UInt64] = [:]
    private var revokedDevices: Set<DeviceID> = []

    public init(owner: DeviceID) {
        self.owner = owner
    }

    public init(snapshot: TrustStoreSnapshot) throws {
        for (device, publicKey) in snapshot.trustedPublicKeys {
            guard (try? P256.Signing.PublicKey(rawRepresentation: publicKey)) != nil,
                  DeviceIdentity.deviceID(for: publicKey) == device,
                  !snapshot.revokedDevices.contains(device)
            else {
                throw TrustStoreError.invalidSnapshot
            }
        }
        owner = snapshot.owner
        trustedPublicKeys = snapshot.trustedPublicKeys
        issuerSequences = snapshot.issuerSequences
        revokedDevices = snapshot.revokedDevices
    }

    public func isTrusted(_ device: DeviceID) -> Bool {
        !revokedDevices.contains(device) && (device == owner || trustedPublicKeys[device] != nil)
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

    public func snapshot() -> TrustStoreSnapshot {
        TrustStoreSnapshot(
            owner: owner,
            trustedPublicKeys: trustedPublicKeys,
            issuerSequences: issuerSequences,
            revokedDevices: revokedDevices
        )
    }

    @discardableResult
    public mutating func revoke(_ device: DeviceID, signedBy issuer: DeviceIdentity) throws -> SignedTrustRecord {
        guard let subjectPublicKey = trustedPublicKeys[device] else {
            throw TrustStoreError.unknownSubject(device)
        }
        let sequence = (issuerSequences[issuer.id] ?? 0) + 1
        let record = try SignedTrustRecord.revoking(
            device,
            subjectPublicKey: subjectPublicKey,
            signedBy: issuer,
            sequence: sequence
        )
        try ingest(record)
        return record
    }

    private mutating func apply(_ record: SignedTrustRecord) throws {
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
