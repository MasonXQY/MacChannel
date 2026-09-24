import Foundation
import Security
import XCTest
@testable import MacChannelCore

final class AccountDeletionCheckpointCleanupTests: XCTestCase, @unchecked Sendable {
    func testRealKeychainBoundedEnumerationAndExactIdempotentRemoval() throws {
        let policy = KeychainPolicy(service: "test.dropmesh.cleanup.\(UUID().uuidString)",
            accessibility: .afterFirstUnlockThisDeviceOnly, synchronizable: false)
        let keychain = KeychainStore(policy: policy)
        defer { try? keychain.removeData(for: "first", policy: policy); try? keychain.removeData(for: "second", policy: policy) }
        try keychain.store(Data([1]), for: "first", policy: policy)
        try keychain.store(Data([2]), for: "second", policy: policy)
        XCTAssertEqual(try keychain.accounts(policy: policy, maximumCount: 4), ["first", "second"])
        XCTAssertThrowsError(try keychain.accounts(policy: policy, maximumCount: 1))
        XCTAssertEqual(try keychain.dataForRemoval(for: "first", policy: policy), Data([1]))
        try keychain.removeData(for: "first", policy: policy)
        try keychain.removeData(for: "first", policy: policy)
        XCTAssertEqual(try keychain.accounts(policy: policy, maximumCount: 4), ["second"])
        XCTAssertEqual(try keychain.data(for: "second", policy: policy), Data([2]))
    }

    func testExactBindingAccountRemovesAllGroupsAndPreservesOtherScopes() async throws {
        let secret = CleanupSecretStore(), storage = KeychainAccountGroupCheckpointStorage(store: secret)
        let target = try checkpointRecord()
        let second = try checkpointRecord(group: "cccccccc-cccc-cccc-cccc-cccccccccccc")
        let others = [try checkpointRecord(account: groupID),
                      try checkpointRecord(binding: checkpointBinding(origin: "https://other.example.com")),
                      try checkpointRecord(binding: checkpointBinding(audience: "other.app")),
                      try checkpointRecord(binding: checkpointBinding(device: UUID()))]
        for record in [target, second] + others { try await storage.save(record) }
        secret.set(Data("manual identity".utf8), key: "identity", policy: KeychainStore.identityPolicy)
        try await storage.removeForAccount(binding: target.binding, accountID: target.accountID)
        try await storage.removeForAccount(binding: target.binding, accountID: target.accountID)
        for record in [target, second] {
            let value = try await storage.load(binding: record.binding, accountID: record.accountID, groupID: record.groupID)
            XCTAssertNil(value)
        }
        for record in others {
            let value = try await storage.load(binding: record.binding, accountID: record.accountID, groupID: record.groupID)
            XCTAssertEqual(value, record)
        }
        XCTAssertEqual(try secret.data(for: "identity", policy: KeychainStore.identityPolicy), Data("manual identity".utf8))
        XCTAssertEqual(secret.removals, 2)
    }

    func testCheckpointPreflightRejectsMalformedMiskeyedAndReadFailuresWithoutDeleting() async throws {
        for kind in ["malformed", "duplicate", "miskeyed", "read", "enumeration", "capacity"] {
            let secret = CleanupSecretStore(), storage = KeychainAccountGroupCheckpointStorage(store: secret)
            let target = try checkpointRecord()
            try await storage.save(target)
            let policy = KeychainAccountGroupCheckpointStorage.policy
            let key = try XCTUnwrap(secret.keys(policy: policy).first)
            let bytes = try XCTUnwrap(secret.data(for: key, policy: policy))
            switch kind {
            case "malformed": secret.set(Data("{}".utf8), key: "corrupt", policy: policy)
            case "duplicate": secret.set(Data("{\"version\":1,".utf8) + bytes.dropFirst(), key: "corrupt", policy: policy)
            case "miskeyed": secret.set(bytes, key: "checkpoint-v1-wrong", policy: policy)
            case "read": secret.failRead = true
            case "enumeration": secret.failEnumeration = true
            default: secret.exceedCapacity = true
            }
            await checkpointFailure(.secureStorage) { try await storage.removeForAccount(binding: target.binding, accountID: target.accountID) }
            XCTAssertEqual(secret.removals, 0, kind)
        }
    }

    func testPartialRemovalFailureIsRetryableAndNeverTouchesOtherAccount() async throws {
        let secret = CleanupSecretStore(), storage = KeychainAccountGroupCheckpointStorage(store: secret)
        let target = try checkpointRecord(), second = try checkpointRecord(group: "cccccccc-cccc-cccc-cccc-cccccccccccc")
        let other = try checkpointRecord(account: groupID)
        for record in [target, second, other] { try await storage.save(record) }
        secret.failRemovalNumber = 2
        await checkpointFailure(.secureStorage) { try await storage.removeForAccount(binding: target.binding, accountID: target.accountID) }
        XCTAssertEqual(secret.removals, 1)
        secret.failRemovalNumber = nil
        try await storage.removeForAccount(binding: target.binding, accountID: target.accountID)
        let preserved = try await storage.load(binding: other.binding, accountID: other.accountID, groupID: other.groupID)
        XCTAssertEqual(preserved, other)
        XCTAssertEqual(secret.keys(policy: KeychainAccountGroupCheckpointStorage.policy).count, 1)
    }

    func testBootstrapAndApprovalIntentCleanupIncludesActiveIntents() async throws {
        let secret = CleanupSecretStore(), identity = try DeviceIdentity.ephemeral()
        let bootstrap = KeychainAccountGroupBootstrapIntentStorage(store: secret)
        let binding = try checkpointBinding(device: identity.id.rawValue)
        let target = try AccountGroupBootstrapIntent(binding: binding, event: bootstrapEvent(identity))
        let other = try AccountGroupBootstrapIntent(binding: binding, event: bootstrapEvent(identity, account: groupID))
        try await bootstrap.save(target); try await bootstrap.save(other)
        try await bootstrap.removeForAccount(binding: binding, accountID: groupAccount)
        try await bootstrap.removeForAccount(binding: binding, accountID: groupAccount)
        let absent = try await bootstrap.load(binding: binding, accountID: groupAccount)
        let retained = try await bootstrap.load(binding: binding, accountID: groupID)
        XCTAssertNil(absent); XCTAssertEqual(retained, other)

        let approvals = KeychainAccountGroupApprovalIntentStorage(store: secret)
        let subject = try approvalIntent(), actor = try approvalIntent(role: .actor)
        try await approvals.insert(subject); try await approvals.insert(actor)
        try await approvals.removeForAccount(binding: subject.scope.binding, accountID: subject.scope.accountID)
        try await approvals.removeForAccount(binding: subject.scope.binding, accountID: subject.scope.accountID)
        let removed = try await approvals.load(scope: subject.scope), preserved = try await approvals.load(scope: actor.scope)
        XCTAssertNil(removed); XCTAssertEqual(preserved, actor)
    }

    func testIntentCleanupRejectsCorruptRecordsWithoutRemoval() async throws {
        let secret = CleanupSecretStore(), identity = try DeviceIdentity.ephemeral()
        let bootstrap = KeychainAccountGroupBootstrapIntentStorage(store: secret)
        let binding = try checkpointBinding(device: identity.id.rawValue)
        try await bootstrap.save(AccountGroupBootstrapIntent(binding: binding, event: bootstrapEvent(identity)))
        let bootstrapKey = try XCTUnwrap(secret.keys(policy: KeychainAccountGroupBootstrapIntentStorage.policy).first)
        secret.set(Data("{}".utf8), key: bootstrapKey, policy: KeychainAccountGroupBootstrapIntentStorage.policy)
        await enrollmentFailure(.secureStorage) { try await bootstrap.removeForAccount(binding: binding, accountID: groupAccount) }
        let approvals = KeychainAccountGroupApprovalIntentStorage(store: secret), intent = try approvalIntent()
        try await approvals.insert(intent)
        let approvalKey = try XCTUnwrap(secret.keys(policy: KeychainAccountGroupApprovalIntentStorage.policy).first)
        secret.set(Data("{}".utf8), key: approvalKey, policy: KeychainAccountGroupApprovalIntentStorage.policy)
        await approvalFailure { try await approvals.removeForAccount(binding: intent.scope.binding, accountID: intent.scope.accountID) }
        XCTAssertEqual(secret.removals, 0)
    }

    func testKeychainQueryScopeAndOptionalCapabilityFailClosed() async throws {
        let policy = KeychainAccountGroupCheckpointStorage.policy, keychain = KeychainStore(policy: KeychainAccountGroupCheckpointStorage.policy)
        let query = keychain.enumerationQuery(maximumCount: 1024)
        XCTAssertEqual(query[kSecAttrService] as? String, policy.service)
        XCTAssertEqual(query[kSecMatchLimit] as? Int, 1025)
        XCTAssertNil(query[kSecReturnData]); XCTAssertNil(query[kSecAttrAccount])
        let remove = keychain.removalQuery(account: "exact-key")
        XCTAssertEqual(remove[kSecAttrService] as? String, policy.service)
        XCTAssertEqual(remove[kSecAttrAccount] as? String, "exact-key")
        XCTAssertEqual(remove[kSecAttrSynchronizable] as? Bool, false)
        XCTAssertThrowsError(try keychain.removeData(for: "", policy: policy))
        XCTAssertThrowsError(try keychain.accounts(policy: KeychainStore.identityPolicy, maximumCount: 1))
        let target = try checkpointRecord(), unsupported = KeychainAccountGroupCheckpointStorage(store: CheckpointSecretStore())
        await checkpointFailure(.secureStorage) { try await unsupported.removeForAccount(binding: target.binding, accountID: target.accountID) }
    }
}

private final class CleanupSecretStore: ScopedSecretStoreRecords, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: [String: Data]] = [:]
    private var removed = 0
    var failRead = false, failEnumeration = false, exceedCapacity = false
    var failRemovalNumber: Int?
    var removals: Int { lock.withLock { removed } }
    func keys(policy: KeychainPolicy) -> [String] { lock.withLock { Array(records[policy.service, default: [:]].keys).sorted() } }
    func set(_ data: Data, key: String, policy: KeychainPolicy) { lock.withLock { records[policy.service, default: [:]][key] = data } }
    func data(for account: String, policy: KeychainPolicy) throws -> Data? {
        try lock.withLock { if failRead { throw KeychainStoreError.unexpectedData }; return records[policy.service]?[account] }
    }
    func store(_ data: Data, for account: String, policy: KeychainPolicy) throws { set(data, key: account, policy: policy) }
    func dataForRemoval(for account: String, policy: KeychainPolicy) throws -> Data? { try data(for: account, policy: policy) }
    func accounts(policy: KeychainPolicy, maximumCount: Int) throws -> [String] {
        if failEnumeration { throw KeychainStoreError.unexpectedData }
        if exceedCapacity { return (0...maximumCount).map { "overflow-\($0)" } }
        return keys(policy: policy)
    }
    func removeData(for account: String, policy: KeychainPolicy) throws {
        try lock.withLock {
            if failRemovalNumber == removed + 1 { throw KeychainStoreError.operationFailed(-1) }
            if records[policy.service]?.removeValue(forKey: account) != nil { removed += 1 }
        }
    }
}
