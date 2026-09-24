import CryptoKit
import Foundation

public protocol AccountGroupCheckpointStorage: Sendable {
    func load(binding: AccountSessionBinding, accountID: String, groupID: String) async throws -> AccountGroupCheckpoint?
    func save(_ checkpoint: AccountGroupCheckpoint) async throws
}

/// Dedicated namespace; no namespace reset API. Use one storage/coordinator per
/// runtime. In-process serialization does not promise cross-process CAS.
public actor KeychainAccountGroupCheckpointStorage: AccountGroupCheckpointStorage {
    static let policy = KeychainPolicy(service: "com.zensystech.dropmesh.account-group-checkpoint",
        accessGroup: nil, accessibility: .afterFirstUnlockThisDeviceOnly, synchronizable: false)
    private let store: any SecretStore & Sendable

    public init() { store = KeychainStore(policy: Self.policy) }
    init(store: any SecretStore & Sendable) { self.store = store }

    public func load(binding: AccountSessionBinding, accountID: String, groupID: String) async throws -> AccountGroupCheckpoint? {
        let key = try Self.key(binding: binding, accountID: accountID, groupID: groupID)
        return try read(key: key, binding: binding, accountID: accountID, groupID: groupID)
    }

    public func save(_ checkpoint: AccountGroupCheckpoint) async throws {
        let key = try Self.key(binding: checkpoint.binding, accountID: checkpoint.accountID, groupID: checkpoint.groupID)
        // No suspension between read/check/write: actor serializes the complete
        // monotonic update. Read/decode failures must never become absence.
        if let previous = try read(key: key, binding: checkpoint.binding,
                                   accountID: checkpoint.accountID, groupID: checkpoint.groupID) {
            guard previous.generation == checkpoint.generation, previous.anchorHash == checkpoint.anchorHash,
                  checkpoint.sequence >= previous.sequence,
                  checkpoint.sequence != previous.sequence || checkpoint.headHash == previous.headHash else {
                throw AccountGroupCheckpointError.invalidCheckpoint
            }
            if previous == checkpoint { return }
        }
        do {
            let data = try Self.encode(checkpoint)
            guard data.count <= 4096 else { throw AccountGroupCheckpointError.secureStorage }
            try store.store(data, for: key, policy: Self.policy)
        } catch { throw AccountGroupCheckpointError.secureStorage }
    }

    /// Only after confirmed server deletion and after all account writers have
    /// drained. This is actor-local serialization, not cross-process CAS.
    public func removeForAccount(binding: AccountSessionBinding, accountID: String) async throws {
        guard AccountGroupCheckpoint.canonicalUUID(accountID) else { throw AccountGroupCheckpointError.invalidCheckpoint }
        guard let records = store as? any ScopedSecretStoreRecords else { throw AccountGroupCheckpointError.secureStorage }
        do {
            let keys = try records.accounts(policy: Self.policy, maximumCount: 1024)
            guard keys.count <= 1024, Set(keys).count == keys.count else { throw AccountGroupCheckpointError.secureStorage }
            var selected: [(String, Data)] = []
            // Preflight the complete bounded namespace before deleting anything.
            // Hash-only keys cannot tell which account owns a malformed record.
            for key in keys.sorted() {
                guard let data = try records.dataForRemoval(for: key, policy: Self.policy), data.count <= 4096 else {
                    throw AccountGroupCheckpointError.secureStorage
                }
                let checkpoint = try JSONDecoder().decode(CheckpointDTO.self, from: data).checkpoint()
                guard try Self.encode(checkpoint) == data,
                      try Self.key(binding: checkpoint.binding, accountID: checkpoint.accountID, groupID: checkpoint.groupID) == key else {
                    throw AccountGroupCheckpointError.secureStorage
                }
                if checkpoint.binding == binding, checkpoint.accountID == accountID { selected.append((key, data)) }
            }
            for (key, data) in selected {
                // Detect an unexpected independent writer before its exact key
                // is removed. The runtime owner must still quiesce all writers.
                guard let current = try records.dataForRemoval(for: key, policy: Self.policy) else { continue }
                guard current == data else { throw AccountGroupCheckpointError.secureStorage }
                try records.removeData(for: key, policy: Self.policy)
            }
        } catch { throw AccountGroupCheckpointError.secureStorage }
    }

    private func read(key: String, binding: AccountSessionBinding, accountID: String, groupID: String) throws -> AccountGroupCheckpoint? {
        do {
            guard let data = try store.data(for: key, policy: Self.policy) else { return nil }
            guard data.count <= 4096 else { throw AccountGroupCheckpointError.secureStorage }
            let checkpoint = try JSONDecoder().decode(CheckpointDTO.self, from: data).checkpoint()
            // This is a private canonical storage format. Exact re-encoding also
            // rejects duplicate/unknown keys, alternate numeric types, base64,
            // UUID spellings, and trailing data lost by Foundation decoding.
            guard try Self.encode(checkpoint) == data, checkpoint.binding == binding,
                  checkpoint.accountID == accountID, checkpoint.groupID == groupID else {
                throw AccountGroupCheckpointError.secureStorage
            }
            return checkpoint
        } catch { throw AccountGroupCheckpointError.secureStorage }
    }

    private static func encode(_ checkpoint: AccountGroupCheckpoint) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(CheckpointDTO(checkpoint))
    }

    private static func key(binding: AccountSessionBinding, accountID: String, groupID: String) throws -> String {
        guard AccountGroupCheckpoint.canonicalUUID(accountID), AccountGroupCheckpoint.canonicalUUID(groupID) else {
            throw AccountGroupCheckpointError.invalidCheckpoint
        }
        // Fixed field order and byte-length prefixes avoid separator ambiguity.
        var bytes = Data("dropmesh.account.group.checkpoint.scope.v1".utf8)
        for value in [binding.deviceID.uuidString.lowercased(), binding.audience, binding.origin.absoluteString, accountID, groupID] {
            let field = Data(value.utf8)
            var length = UInt64(field.count).bigEndian
            withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
            bytes.append(field)
        }
        return "checkpoint-v1-" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

private struct CheckpointDTO: Codable {
    let version: UInt64
    let deviceID: String
    let audience: String
    let origin: String
    let accountID: String
    let groupID: String
    let generation: UInt64
    let anchorHash: Data
    let sequence: UInt64
    let headHash: Data

    init(_ value: AccountGroupCheckpoint) {
        version = 1
        deviceID = value.binding.deviceID.uuidString.lowercased()
        audience = value.binding.audience
        origin = value.binding.origin.absoluteString
        accountID = value.accountID
        groupID = value.groupID
        generation = value.generation
        anchorHash = value.anchorHash
        sequence = value.sequence
        headHash = value.headHash
    }

    func checkpoint() throws -> AccountGroupCheckpoint {
        guard version == 1, AccountGroupCheckpoint.canonicalUUID(deviceID),
              let device = UUID(uuidString: deviceID), let url = URL(string: origin) else {
            throw AccountGroupCheckpointError.secureStorage
        }
        let binding = try AccountSessionBinding(deviceID: device, audience: audience, origin: url)
        return try AccountGroupCheckpoint(binding: binding, accountID: accountID, groupID: groupID,
            generation: generation, anchorHash: anchorHash, sequence: sequence, headHash: headHash)
    }
}
