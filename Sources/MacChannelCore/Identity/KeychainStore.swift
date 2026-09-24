import Foundation
import Security

public protocol SecretStore {
    func data(for account: String, policy: KeychainPolicy) throws -> Data?
    func store(_ data: Data, for account: String, policy: KeychainPolicy) throws
}

/// Optional, explicitly policy-scoped cleanup capability. Existing SecretStore
/// conformers and read/write behavior remain unchanged.
public protocol ScopedSecretStoreRecords: SecretStore {
    func accounts(policy: KeychainPolicy, maximumCount: Int) throws -> [String]
    func dataForRemoval(for account: String, policy: KeychainPolicy) throws -> Data?
    func removeData(for account: String, policy: KeychainPolicy) throws
}

public enum KeychainAccessibility: String, Equatable, Sendable {
    case afterFirstUnlockThisDeviceOnly
}

public struct KeychainPolicy: Equatable, Sendable {
    public let service: String
    public let accessGroup: String?
    public let accessibility: KeychainAccessibility
    public let synchronizable: Bool

    public init(
        service: String,
        accessGroup: String? = nil,
        accessibility: KeychainAccessibility,
        synchronizable: Bool
    ) {
        self.service = service
        self.accessGroup = accessGroup
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

public struct KeychainStore: ScopedSecretStoreRecords, Sendable {
    public static let identityService = "com.mason.macchannel.identity"
    public static let identityPolicy = KeychainPolicy(
        service: identityService,
        accessGroup: nil,
        accessibility: .afterFirstUnlockThisDeviceOnly,
        synchronizable: false
    )

    private let allowedPolicy: KeychainPolicy

    public init(policy: KeychainPolicy = KeychainStore.identityPolicy) {
        allowedPolicy = policy
    }

    public func data(for account: String, policy: KeychainPolicy) throws -> Data? {
        try validate(policy)
        var query = recordQuery(account: account)
        query[kSecReturnData] = true
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            let validated = try validatedData(from: result, policy: policy)
            if validated.requiresAccessibilityMigration {
                var migrationQuery = recordQuery(account: account)
                migrationQuery[kSecAttrSynchronizable] = kCFBooleanFalse
                let migrationStatus = SecItemUpdate(
                    migrationQuery as CFDictionary,
                    [
                        kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                    ] as CFDictionary
                )
                guard migrationStatus == errSecSuccess else {
                    throw KeychainStoreError.operationFailed(migrationStatus)
                }
            }
            return validated.data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainStoreError.operationFailed(status)
        }
    }

    public func store(_ data: Data, for account: String, policy: KeychainPolicy) throws {
        try validate(policy)
        let query = recordQuery(account: account)
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

    public func removeAll() throws {
        let status = SecItemDelete(recordQuery(account: nil) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.operationFailed(status)
        }
    }

    public func accounts(policy: KeychainPolicy, maximumCount: Int) throws -> [String] {
        try validate(policy)
        guard (1...4096).contains(maximumCount) else { throw KeychainStoreError.invalidPolicy }
        let query = enumerationQuery(maximumCount: maximumCount)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainStoreError.operationFailed(status) }
        guard let records = result as? [[String: Any]], records.count <= maximumCount else {
            throw KeychainStoreError.unexpectedAttributes
        }
        var accounts = Set<String>()
        for attributes in records {
            guard let account = attributes[kSecAttrAccount as String] as? String, !account.isEmpty,
                  account.utf8.count <= 1024,
                  attributes[kSecAttrService as String] as? String == policy.service,
                  (attributes[kSecAttrSynchronizable as String] as? Bool ?? false) == policy.synchronizable,
                  accounts.insert(account).inserted else { throw KeychainStoreError.unexpectedAttributes }
        }
        return accounts.sorted()
    }

    public func removeData(for account: String, policy: KeychainPolicy) throws {
        try validate(policy)
        guard !account.isEmpty, account.utf8.count <= 1024 else { throw KeychainStoreError.invalidPolicy }
        let status = SecItemDelete(removalQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.operationFailed(status)
        }
    }

    /// Inspection for cleanup must not migrate attributes on unrelated records.
    public func dataForRemoval(for account: String, policy: KeychainPolicy) throws -> Data? {
        try validate(policy)
        var query = recordQuery(account: account)
        query[kSecReturnData] = true; query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainStoreError.operationFailed(status) }
        return try validatedData(from: result, policy: policy).data
    }

    func enumerationQuery(maximumCount: Int) -> [CFString: Any] {
        var query = recordQuery(account: nil)
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = maximumCount + 1
        return query
    }

    func removalQuery(account: String) -> [CFString: Any] {
        var query = recordQuery(account: account)
        query[kSecAttrSynchronizable] = allowedPolicy.synchronizable
        return query
    }

    func recordQuery(account: String?) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: allowedPolicy.service,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny,
        ]
        if let account { query[kSecAttrAccount] = account }
        if let group = allowedPolicy.accessGroup { query[kSecAttrAccessGroup] = group }
        return query
    }

    private func validate(_ policy: KeychainPolicy) throws {
        guard policy == allowedPolicy else {
            throw KeychainStoreError.invalidPolicy
        }
    }

    private func validatedData(
        from result: CFTypeRef?,
        policy: KeychainPolicy
    ) throws -> (data: Data, requiresAccessibilityMigration: Bool) {
        guard let attributes = result as? [String: Any],
              let data = attributes[kSecValueData as String] as? Data
        else {
            throw KeychainStoreError.unexpectedAttributes
        }
        let accessibility = attributes[kSecAttrAccessible as String] as? String
        let synchronizable = attributes[kSecAttrSynchronizable as String] as? Bool ?? false
        guard synchronizable == policy.synchronizable else {
            throw KeychainStoreError.unexpectedAttributes
        }
        return (
            data,
            accessibility != kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
    }
}
