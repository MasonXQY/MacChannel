import Foundation
import Security

public protocol SecretStore {
    func data(for account: String, policy: KeychainPolicy) throws -> Data?
    func store(_ data: Data, for account: String, policy: KeychainPolicy) throws
}

public enum KeychainAccessibility: String, Equatable, Sendable {
    case afterFirstUnlockThisDeviceOnly
}

public struct KeychainPolicy: Equatable, Sendable {
    public let service: String
    public let accessibility: KeychainAccessibility
    public let synchronizable: Bool

    public init(
        service: String,
        accessibility: KeychainAccessibility,
        synchronizable: Bool
    ) {
        self.service = service
        self.accessibility = accessibility
        self.synchronizable = synchronizable
    }
}

public enum KeychainStoreError: Error, Equatable {
    case unexpectedData
    case unexpectedAttributes
    case invalidPolicy
    case operationFailed(Int32)
}

public struct KeychainStore: SecretStore {
    public static let identityService = "com.mason.macchannel.identity"
    public static let identityPolicy = KeychainPolicy(
        service: identityService,
        accessibility: .afterFirstUnlockThisDeviceOnly,
        synchronizable: false
    )

    public init() {}

    public func data(for account: String, policy: KeychainPolicy) throws -> Data? {
        try validate(policy)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: policy.service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecReturnAttributes: true,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            return try validatedData(from: result, policy: policy)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainStoreError.operationFailed(status)
        }
    }

    public func store(_ data: Data, for account: String, policy: KeychainPolicy) throws {
        try validate(policy)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: policy.service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny,
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [
                kSecValueData: data,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecAttrSynchronizable: kCFBooleanFalse as Any,
            ] as CFDictionary
        )

        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainStoreError.operationFailed(updateStatus)
        }

        var item = query
        item[kSecValueData] = data
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrSynchronizable] = kCFBooleanFalse
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainStoreError.operationFailed(addStatus)
        }
    }

    private func validate(_ policy: KeychainPolicy) throws {
        guard policy == Self.identityPolicy else {
            throw KeychainStoreError.invalidPolicy
        }
    }

    private func validatedData(from result: CFTypeRef?, policy: KeychainPolicy) throws -> Data {
        guard let attributes = result as? [String: Any],
              let data = attributes[kSecValueData as String] as? Data,
              let accessibility = attributes[kSecAttrAccessible as String] as? String,
              accessibility == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        else {
            throw KeychainStoreError.unexpectedAttributes
        }
        let synchronizable = attributes[kSecAttrSynchronizable as String] as? Bool ?? false
        guard synchronizable == policy.synchronizable else {
            throw KeychainStoreError.unexpectedAttributes
        }
        return data
    }
}
