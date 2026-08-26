import CryptoKit
import Foundation

public enum DeviceIdentityError: Error, Equatable {
    case invalidStoredPrivateKey
}

public struct DeviceIdentity {
    private static let privateKeyAccount = "p256-signing-private-key"

    public let id: DeviceID
    public let publicKey: P256.Signing.PublicKey
    private let privateKey: P256.Signing.PrivateKey

    private init(privateKey: P256.Signing.PrivateKey) {
        self.privateKey = privateKey
        publicKey = privateKey.publicKey
        id = Self.deviceID(for: privateKey.publicKey.rawRepresentation)
    }

    public static func loadOrCreate(keychain: any SecretStore) throws -> DeviceIdentity {
        if let storedPrivateKey = try keychain.data(
            for: privateKeyAccount,
            policy: KeychainStore.identityPolicy
        ) {
            do {
                return try DeviceIdentity(
                    privateKey: P256.Signing.PrivateKey(rawRepresentation: storedPrivateKey)
                )
            } catch {
                throw DeviceIdentityError.invalidStoredPrivateKey
            }
        }

        let identity = try ephemeral()
        try keychain.store(
            identity.privateKey.rawRepresentation,
            for: privateKeyAccount,
            policy: KeychainStore.identityPolicy
        )
        return identity
    }

    static func ephemeral() throws -> DeviceIdentity {
        DeviceIdentity(privateKey: P256.Signing.PrivateKey())
    }

    public func sign(_ message: Data) throws -> P256.Signing.ECDSASignature {
        try privateKey.signature(for: message)
    }

    static func deviceID(for publicKey: Data) -> DeviceID {
        let digest = Array(SHA256.hash(data: publicKey).prefix(16))
        let uuid = UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
        return DeviceID(rawValue: uuid)
    }
}
