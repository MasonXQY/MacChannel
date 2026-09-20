import CryptoKit
import Foundation

public protocol AccountGroupBootstrapIntentStorage: Sendable {
    func load(binding: AccountSessionBinding, accountID: String) async throws -> AccountGroupBootstrapIntent?
    func save(_ intent: AccountGroupBootstrapIntent) async throws
}

/// Own one storage/controller per runtime. Actor serialization protects the
/// in-process read/check/write, not cross-process compare-and-swap. No namespace reset API.
public actor KeychainAccountGroupBootstrapIntentStorage: AccountGroupBootstrapIntentStorage {
    static let policy = KeychainPolicy(service: "com.zensystech.dropmesh.account-group-bootstrap",
        accessGroup: nil, accessibility: .afterFirstUnlockThisDeviceOnly, synchronizable: false)
    private let store: any SecretStore & Sendable

    public init() { store = KeychainStore(policy: Self.policy) }
    init(store: any SecretStore & Sendable) { self.store = store }

    public func load(binding: AccountSessionBinding, accountID: String) async throws -> AccountGroupBootstrapIntent? {
        try read(key: Self.key(binding: binding, accountID: accountID), binding: binding, accountID: accountID)
    }

    public func save(_ intent: AccountGroupBootstrapIntent) async throws {
        let key = try Self.key(binding: intent.binding, accountID: intent.event.accountID)
        // No suspension between read/check/write. A protected or malformed read
        // must not become absence; an uncertain HTTP outcome retains this event.
        if let previous = try read(key: key, binding: intent.binding, accountID: intent.event.accountID) {
            guard previous == intent else { throw AccountFirstDeviceEnrollmentError.secureStorage }
            return
        }
        do {
            let data = try Self.encode(intent)
            guard data.count <= 8192 else { throw AccountFirstDeviceEnrollmentError.secureStorage }
            try store.store(data, for: key, policy: Self.policy)
        } catch { throw AccountFirstDeviceEnrollmentError.secureStorage }
    }

    /// Confirmed deletion only; caller must first drain the enrollment writer.
    public func removeForAccount(binding: AccountSessionBinding, accountID: String) async throws {
        guard let records = store as? any ScopedSecretStoreRecords else { throw AccountFirstDeviceEnrollmentError.secureStorage }
        do {
            let key = try Self.key(binding: binding, accountID: accountID)
            _ = try read(key: key, binding: binding, accountID: accountID, inspection: true)
            try records.removeData(for: key, policy: Self.policy)
        } catch { throw AccountFirstDeviceEnrollmentError.secureStorage }
    }

    private func read(key: String, binding: AccountSessionBinding, accountID: String, inspection: Bool = false) throws -> AccountGroupBootstrapIntent? {
        do {
            let stored: Data?
            if inspection {
                guard let records = store as? any ScopedSecretStoreRecords else { throw AccountFirstDeviceEnrollmentError.secureStorage }
                stored = try records.dataForRemoval(for: key, policy: Self.policy)
            } else { stored = try store.data(for: key, policy: Self.policy) }
            guard let data = stored else { return nil }
            guard data.count <= 8192 else { throw AccountFirstDeviceEnrollmentError.secureStorage }
            let intent = try JSONDecoder().decode(BootstrapIntentDTO.self, from: data).intent()
            // Exact canonical reencoding rejects lost duplicate/unknown fields,
            // noncanonical numbers/base64/binding spellings and trailing data.
            guard intent.binding == binding, intent.event.accountID == accountID,
                  try Self.encode(intent) == data else { throw AccountFirstDeviceEnrollmentError.secureStorage }
            return intent
        } catch { throw AccountFirstDeviceEnrollmentError.secureStorage }
    }

    private static func encode(_ intent: AccountGroupBootstrapIntent) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(BootstrapIntentDTO(intent))
    }

    private static func key(binding: AccountSessionBinding, accountID: String) throws -> String {
        guard AccountGroupCheckpoint.canonicalUUID(accountID) else { throw AccountFirstDeviceEnrollmentError.secureStorage }
        var bytes = Data("dropmesh.account.group.bootstrap.scope.v1".utf8)
        for value in [binding.deviceID.uuidString.lowercased(), binding.audience, binding.origin.absoluteString, accountID] {
            let field = Data(value.utf8)
            var length = UInt64(field.count).bigEndian
            withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
            bytes.append(field)
        }
        return "bootstrap-v1-" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

private struct BootstrapIntentDTO: Codable {
    let version: UInt64
    let deviceID: String
    let audience: String
    let origin: String
    let event: AccountGroupWireEvent

    init(_ intent: AccountGroupBootstrapIntent) throws {
        version = 1
        deviceID = intent.binding.deviceID.uuidString.lowercased()
        audience = intent.binding.audience
        origin = intent.binding.origin.absoluteString
        event = try intent.event.wireEvent()
    }

    func intent() throws -> AccountGroupBootstrapIntent {
        guard version == 1, AccountGroupCheckpoint.canonicalUUID(deviceID),
              let deviceID = UUID(uuidString: deviceID), let origin = URL(string: origin) else {
            throw AccountFirstDeviceEnrollmentError.secureStorage
        }
        return try AccountGroupBootstrapIntent(
            binding: AccountSessionBinding(deviceID: deviceID, audience: audience, origin: origin),
            event: AccountGroupEvent(wire: event))
    }
}
