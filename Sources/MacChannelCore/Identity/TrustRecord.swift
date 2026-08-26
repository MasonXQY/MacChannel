import CryptoKit
import Foundation

public enum TrustAction: String, Codable, Sendable {
    case authorize
    case revoke
}

public struct SignedTrustRecord: Codable, Sendable {
    public let issuer: DeviceID
    public let issuerPublicKey: Data
    public let subject: DeviceID
    public let subjectPublicKey: Data
    public let action: TrustAction
    public let issuerSequence: UInt64
    public let timestamp: Date
    public let signature: Data

    public static func authorizing(
        _ subject: DeviceIdentity,
        signedBy issuer: DeviceIdentity,
        sequence: UInt64 = 1,
        timestamp: Date = Date()
    ) throws -> SignedTrustRecord {
        try signed(
            issuer: issuer,
            subject: subject.id,
            subjectPublicKey: subject.publicKey.rawRepresentation,
            action: .authorize,
            sequence: sequence,
            timestamp: timestamp
        )
    }

    static func revoking(
        _ subject: DeviceID,
        subjectPublicKey: Data,
        signedBy issuer: DeviceIdentity,
        sequence: UInt64,
        timestamp: Date = Date()
    ) throws -> SignedTrustRecord {
        try signed(
            issuer: issuer,
            subject: subject,
            subjectPublicKey: subjectPublicKey,
            action: .revoke,
            sequence: sequence,
            timestamp: timestamp
        )
    }

    func hasValidSignature() -> Bool {
        guard DeviceIdentity.deviceID(for: issuerPublicKey) == issuer,
              DeviceIdentity.deviceID(for: subjectPublicKey) == subject,
              let publicKey = try? P256.Signing.PublicKey(rawRepresentation: issuerPublicKey),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: signature)
        else {
            return false
        }
        return publicKey.isValidSignature(signature, for: canonicalPayload())
    }

    private static func signed(
        issuer: DeviceIdentity,
        subject: DeviceID,
        subjectPublicKey: Data,
        action: TrustAction,
        sequence: UInt64,
        timestamp: Date
    ) throws -> SignedTrustRecord {
        let unsigned = SignedTrustRecord(
            issuer: issuer.id,
            issuerPublicKey: issuer.publicKey.rawRepresentation,
            subject: subject,
            subjectPublicKey: subjectPublicKey,
            action: action,
            issuerSequence: sequence,
            timestamp: timestamp,
            signature: Data()
        )
        let signature = try issuer.sign(unsigned.canonicalPayload()).derRepresentation
        return SignedTrustRecord(
            issuer: unsigned.issuer,
            issuerPublicKey: unsigned.issuerPublicKey,
            subject: unsigned.subject,
            subjectPublicKey: unsigned.subjectPublicKey,
            action: unsigned.action,
            issuerSequence: unsigned.issuerSequence,
            timestamp: unsigned.timestamp,
            signature: signature
        )
    }

    private func canonicalPayload() -> Data {
        struct Payload: Encodable {
            let action: String
            let issuer: String
            let issuerPublicKey: String
            let issuerSequence: UInt64
            let subject: String
            let subjectPublicKey: String
            let timestampMilliseconds: Int64
        }

        let payload = Payload(
            action: action.rawValue,
            issuer: issuer.rawValue.uuidString.lowercased(),
            issuerPublicKey: issuerPublicKey.base64EncodedString(),
            issuerSequence: issuerSequence,
            subject: subject.rawValue.uuidString.lowercased(),
            subjectPublicKey: subjectPublicKey.base64EncodedString(),
            timestampMilliseconds: Int64((timestamp.timeIntervalSince1970 * 1_000).rounded(.down))
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try! encoder.encode(payload)
    }
}
