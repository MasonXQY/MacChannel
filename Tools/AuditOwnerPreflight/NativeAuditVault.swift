import CryptoKit
import Foundation
import LocalAuthentication
import Security

protocol AuditKeychainOperations {
    func copy(_ query: [String: Any]) -> (OSStatus, Data?)
    func add(_ attributes: [String: Any]) -> OSStatus
}
private struct SystemAuditKeychainOperations: AuditKeychainOperations {
    func copy(_ query: [String: Any]) -> (OSStatus, Data?) {
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        return (status, value as? Data)
    }
    func add(_ attributes: [String: Any]) -> OSStatus { SecItemAdd(attributes as CFDictionary, nil) }
}

final class NativeAuditVaultStore: AuditVaultStore {
    private let operations: AuditKeychainOperations
    init(operations: AuditKeychainOperations = SystemAuditKeychainOperations()) { self.operations = operations }
    private func attributes(_ slot: AuditVaultSlot, context: LAContext) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.zensystech.dropmesh.audit-owner.v1",
         kSecAttrAccount as String: slot.rawValue,
         kSecUseDataProtectionKeychain as String: true,
         kSecAttrSynchronizable as String: false,
         kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
         kSecUseAuthenticationContext as String: context]
    }
    func read(_ slot: AuditVaultSlot) throws -> Data? {
        let context = LAContext()
        context.interactionNotAllowed = true
        defer { context.invalidate() }
        var query = attributes(slot, context: context)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        let (status, bytes) = operations.copy(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes else { throw AuditVaultFailure.unavailable }
        guard bytes.count <= 4171 else { throw AuditVaultFailure.invalidRecord }
        return Data(Array(bytes))
    }
    func add(_ slot: AuditVaultSlot, bytes: Data) throws {
        switch slot {
        case .identity: _ = try AuditIdentityRecord(encoded: bytes)
        case .revoked:
            guard bytes == Data("DMAUDIT-REVOKED-1".utf8) else { throw AuditVaultFailure.invalidRecord }
        }
        let context = LAContext()
        context.interactionNotAllowed = true
        defer { context.invalidate() }
        var query = attributes(slot, context: context)
        query[kSecValueData as String] = Data(Array(bytes))
        switch operations.add(query) {
        case errSecSuccess: return
        case errSecDuplicateItem: throw AuditVaultFailure.alreadyExists
        default: throw AuditVaultFailure.unavailable
        }
    }
}

enum AuditNativeKeyGenerator {
    static func makeAccessControl() throws -> SecAccessControl {
        guard let control = SecAccessControlCreateWithFlags(nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .userPresence], nil) else {
            throw AuditVaultFailure.unavailable
        }
        return control
    }

    /// No CLI or test calls this. Actual creation requires explicit provisioning
    /// approval and a signed helper with a verified, dedicated access group.
    static func generate() throws -> AuditIdentityRecord {
        guard !Thread.isMainThread, SecureEnclave.isAvailable else { throw AuditVaultFailure.unavailable }
        let context = LAContext()
        defer { context.invalidate() }
        do {
            let key = try SecureEnclave.P256.Signing.PrivateKey(compactRepresentable: false,
                accessControl: makeAccessControl(), authenticationContext: context)
            return try AuditIdentityRecord(publicPoint: key.publicKey.x963Representation, wrapped: key.dataRepresentation)
        } catch { throw AuditVaultFailure.unavailable }
    }
}
