import Foundation

public enum TrustStoreError: Error, Equatable {
    case invalidSignature
    case untrustedIssuer(DeviceID)
    case nonIncreasingSequence(DeviceID)
    case unexpectedAction(TrustAction)
    case unknownSubject(DeviceID)
}

public struct TrustStore {
    private let owner: DeviceID
    private var trustedPublicKeys: [DeviceID: Data] = [:]
    private var issuerSequences: [DeviceID: UInt64] = [:]

    public init(owner: DeviceID) {
        self.owner = owner
    }

    public func isTrusted(_ device: DeviceID) -> Bool {
        device == owner || trustedPublicKeys[device] != nil
    }

    public mutating func authorize(_ record: SignedTrustRecord) throws {
        guard record.action == .authorize else {
            throw TrustStoreError.unexpectedAction(record.action)
        }
        try apply(record)
    }

    public mutating func revoke(_ device: DeviceID, signedBy issuer: DeviceIdentity) throws {
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
        try apply(record)
    }

    private mutating func apply(_ record: SignedTrustRecord) throws {
        guard record.hasValidSignature() else {
            throw TrustStoreError.invalidSignature
        }
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
        case .revoke:
            trustedPublicKeys.removeValue(forKey: record.subject)
        }
    }
}
