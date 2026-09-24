import CryptoKit
import Foundation

/// Local recovery state only. A link is shareable only after an authenticated
/// server response confirms the same capability hash and monotonic version.
public struct AccountInvitationShareState: Equatable, Sendable {
    public let version: UInt64
    public let current: AccountInvitationLink?
    public let pending: AccountInvitationLink?
    public let operationID: UUID?
}

public actor KeychainAccountInvitationLinkStorage {
    static let policy = KeychainPolicy(service: "com.zensystech.dropmesh.account-invitation-link",
        accessGroup: nil, accessibility: .afterFirstUnlockThisDeviceOnly, synchronizable: false)
    private let store: any SecretStore & Sendable
    public init() { store = KeychainStore(policy: Self.policy) }
    public init(store: any SecretStore & Sendable) { self.store = store }

    public func load(binding: AccountSessionBinding, accountID: String) async throws -> AccountInvitationShareState {
        let record = try read(binding, accountID)
        return AccountInvitationShareState(version: record.version,
            current: try record.current.map(AccountInvitationLink.init(token:)),
            pending: try record.pending.map(AccountInvitationLink.init(token:)), operationID: record.operation)
    }
    public func prepare(binding: AccountSessionBinding, accountID: String, link: AccountInvitationLink, operationID: UUID) async throws {
        guard invitationUUID(operationID.uuidString.lowercased()) else { throw AccountInvitationError.invalidContext }
        var record = try read(binding, accountID)
        if record.pending != nil {
            guard record.pending == link.token, record.operation == operationID else { throw AccountInvitationError.conflict }
            return
        }
        guard record.current != link.token else { throw AccountInvitationError.conflict }
        record.pending = link.token; record.operation = operationID
        try write(record, binding, accountID)
    }
    public func confirm(binding: AccountSessionBinding, accountID: String, operationID: UUID, server: AccountInvitationLinkState) async throws {
        var record = try read(binding, accountID)
        guard record.operation == operationID, let token = record.pending,
              try AccountInvitationLink(token: token).tokenHash == server.hash,
              server.version > record.version else { throw AccountInvitationError.conflict }
        record.version = server.version; record.hash = server.hash
        record.current = token; record.pending = nil; record.operation = nil
        try write(record, binding, accountID)
    }
    public func observe(binding: AccountSessionBinding, accountID: String, server: AccountInvitationLinkState) async throws {
        var record = try read(binding, accountID)
        guard server.version >= record.version else { throw AccountInvitationError.rollback }
        if server.version == record.version {
            guard record.hash == server.hash else { throw AccountInvitationError.conflict }
            return
        }
        guard record.hash != server.hash else { throw AccountInvitationError.conflict }
        if let token = record.pending, try AccountInvitationLink(token: token).tokenHash == server.hash {
            record.current = token
            record.pending = nil; record.operation = nil
        } else { record.current = nil }
        record.version = server.version; record.hash = server.hash
        // An unrelated observation cannot tell whether our in-flight rotation
        // will commit later. Preserve its secret for retry/restart recovery.
        try write(record, binding, accountID)
    }
    public func removeForAccount(binding: AccountSessionBinding, accountID: String) async throws {
        let key = try Self.key(binding, accountID)
        guard let records = store as? any ScopedSecretStoreRecords else { throw AccountInvitationError.secureStorage }
        do {
            if let data = try records.dataForRemoval(for: key, policy: Self.policy) {
                _ = try decode(data, binding, accountID)
                try records.removeData(for: key, policy: Self.policy)
            }
        } catch { throw AccountInvitationError.secureStorage }
    }

    private static func key(_ binding: AccountSessionBinding, _ accountID: String) throws -> String {
        guard invitationUUID(accountID) else { throw AccountInvitationError.invalidContext }
        var bytes = Data("dropmesh.account.invitation.link.scope.v1".utf8)
        for value in [binding.origin.absoluteString, binding.audience, binding.deviceID.uuidString.lowercased(), accountID] {
            let field = Data(value.utf8); var count = UInt64(field.count).bigEndian
            withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }; bytes.append(field)
        }
        return "invitation-link-v1-" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    private func read(_ binding: AccountSessionBinding, _ accountID: String) throws -> LinkRecord {
        let key = try Self.key(binding, accountID)
        do {
            guard let data = try store.data(for: key, policy: Self.policy) else { return LinkRecord(scope: key) }
            return try decode(data, binding, accountID)
        } catch { throw AccountInvitationError.secureStorage }
    }
    private func decode(_ data: Data, _ binding: AccountSessionBinding, _ accountID: String) throws -> LinkRecord {
        guard data.count <= 4096 else { throw AccountInvitationError.secureStorage }
        let record = try JSONDecoder().decode(LinkRecord.self, from: data)
        guard record.scope == (try Self.key(binding, accountID)), try record.encoded() == data else { throw AccountInvitationError.secureStorage }
        return record
    }
    private func write(_ record: LinkRecord, _ binding: AccountSessionBinding, _ accountID: String) throws {
        do { try store.store(record.encoded(), for: Self.key(binding, accountID), policy: Self.policy) }
        catch { throw AccountInvitationError.secureStorage }
    }
}

private struct LinkRecord: Codable {
    var schema = 1
    let scope: String
    var version: UInt64 = 0
    var hash: Data?
    var current: String?
    var pending: String?
    var operation: UUID?
    func encoded() throws -> Data {
        guard schema == 1, version <= UInt64(Int64.max),
              (version == 0 ? hash == nil && current == nil : hash?.count == 32),
              (pending == nil) == (operation == nil) else { throw AccountInvitationError.secureStorage }
        if let current { guard try AccountInvitationLink(token: current).tokenHash == hash else { throw AccountInvitationError.secureStorage } }
        if let pending {
            _ = try AccountInvitationLink(token: pending)
            guard pending != current, let operation, invitationUUID(operation.uuidString.lowercased()) else { throw AccountInvitationError.secureStorage }
        }
        let data = try invitationEncode(self)
        guard data.count <= 4096 else { throw AccountInvitationError.secureStorage }
        return data
    }
}
