import Foundation
import XCTest
@testable import MacChannelCore

final class AccountGroupCheckpointTests: XCTestCase, @unchecked Sendable {
    func testCheckpointValidationAndIntegerBounds() throws {
        for value in [UInt64(0), UInt64(Int64.max) + 1, UInt64.max] {
            XCTAssertThrowsError(try checkpointRecord(generation: value))
            XCTAssertThrowsError(try checkpointRecord(sequence: value))
        }
        for value in ["", "not-a-uuid", "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", groupAccount + " "] {
            XCTAssertThrowsError(try checkpointRecord(account: value))
            XCTAssertThrowsError(try checkpointRecord(group: value))
        }
        for length in [0, 31, 33] {
            XCTAssertThrowsError(try checkpointRecord(anchor: Data(repeating: 1, count: length)))
            XCTAssertThrowsError(try checkpointRecord(head: Data(repeating: 1, count: length)))
        }
        XCTAssertThrowsError(try checkpointRecord(head: Data(repeating: 2, count: 32)))
        XCTAssertNoThrow(try checkpointRecord(generation: UInt64(Int64.max), sequence: UInt64(Int64.max)))
    }

    func testDedicatedPolicyRoundTripAndIdempotence() async throws {
        let secret = CheckpointSecretStore()
        let storage = KeychainAccountGroupCheckpointStorage(store: secret)
        let record = try checkpointRecord()
        try await storage.save(record)
        try await storage.save(record)
        let loaded = try await storage.load(binding: record.binding, accountID: groupAccount, groupID: groupID)
        XCTAssertEqual(loaded, record)
        XCTAssertEqual(secret.writes, 1)
        XCTAssertTrue(secret.records.values.allSatisfy { $0.count <= 4096 })
        XCTAssertEqual(Set(secret.policies.map(\.service)), ["com.zensystech.dropmesh.account-group-checkpoint"])
        for policy in secret.policies {
            XCTAssertNil(policy.accessGroup)
            XCTAssertEqual(policy.accessibility, .afterFirstUnlockThisDeviceOnly)
            XCTAssertFalse(policy.synchronizable)
        }
    }

    func testMonotonicHeadAndImmutablePin() async throws {
        let secret = CheckpointSecretStore()
        let storage = KeychainAccountGroupCheckpointStorage(store: secret)
        let first = try checkpointRecord()
        let advanced = try checkpointRecord(sequence: 3, head: Data(repeating: 3, count: 32))
        try await storage.save(first)
        try await storage.save(advanced)
        for invalid in [first, try checkpointRecord(sequence: 3, head: Data(repeating: 9, count: 32)),
                        try checkpointRecord(generation: 2, sequence: 4),
                        try checkpointRecord(anchor: Data(repeating: 8, count: 32), sequence: 4)] {
            await checkpointFailure(.invalidCheckpoint) { try await storage.save(invalid) }
        }
        let loaded = try await storage.load(binding: first.binding, accountID: groupAccount, groupID: groupID)
        XCTAssertEqual(loaded, advanced)
        XCTAssertEqual(secret.writes, 2)
    }

    func testNormalizedBindingAndScopeIsolation() async throws {
        let secret = CheckpointSecretStore()
        let storage = KeychainAccountGroupCheckpointStorage(store: secret)
        let first = try checkpointRecord()
        try await storage.save(first)
        let normalized = try checkpointBinding(origin: "HTTPS://EXAMPLE.COM:443/")
        let same = try await storage.load(binding: normalized, accountID: groupAccount, groupID: groupID)
        XCTAssertEqual(same, first)
        let bindings = [try checkpointBinding(device: UUID()), try checkpointBinding(audience: "other.app"),
                        try checkpointBinding(origin: "https://other.example.com")]
        for binding in bindings {
            let absent = try await storage.load(binding: binding, accountID: groupAccount, groupID: groupID)
            XCTAssertNil(absent)
            try await storage.save(checkpointRecord(binding: binding))
        }
        for record in [try checkpointRecord(account: groupID), try checkpointRecord(group: groupAccount)] {
            let absent = try await storage.load(binding: record.binding, accountID: record.accountID, groupID: record.groupID)
            XCTAssertNil(absent)
            try await storage.save(record)
        }
        XCTAssertEqual(secret.records.count, 6)
        XCTAssertTrue(secret.records.keys.allSatisfy { !$0.contains(groupAccount) && !$0.contains("example.com") })
        // Even a correctly encoded record copied to a different scope is rejected.
        let firstKey = try XCTUnwrap(secret.records.keys.first)
        let otherKey = try XCTUnwrap(secret.records.keys.first { $0 != firstKey })
        let bytes = try XCTUnwrap(secret.records[otherKey])
        secret.set(bytes, for: firstKey)
        var failures = 0
        for record in [first] + (try bindings.map { try checkpointRecord(binding: $0) }) +
            [try checkpointRecord(account: groupID), try checkpointRecord(group: groupAccount)] {
            do { _ = try await storage.load(binding: record.binding, accountID: record.accountID, groupID: record.groupID) }
            catch { failures += 1; XCTAssertEqual(error as? AccountGroupCheckpointError, .secureStorage) }
        }
        XCTAssertEqual(failures, 1)
    }

    func testMalformedSchemaTypesVersionSizeAndNoncanonicalRecordsCannotBeOverwritten() async throws {
        let secret = CheckpointSecretStore()
        let storage = KeychainAccountGroupCheckpointStorage(store: secret)
        let record = try checkpointRecord()
        try await storage.save(record)
        let (key, original) = try XCTUnwrap(secret.records.first)
        let text = String(decoding: original, as: UTF8.self)
        var malformed = [Data(), Data("{}".utf8), Data(repeating: 32, count: 4097), original + Data("{}".utf8),
                         Data(text.replacingOccurrences(of: "{", with: "{\"version\":1,").utf8),
                         Data(text.replacingOccurrences(of: "\"sequence\":1", with: "\"sequence\":1.0").utf8),
                         Data(text.replacingOccurrences(of: "\"sequence\":1", with: "\"sequence\":1e0").utf8)]
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        for field in object.keys {
            var missing = object; missing.removeValue(forKey: field)
            malformed.append(try JSONSerialization.data(withJSONObject: missing, options: [.sortedKeys, .withoutEscapingSlashes]))
            var null = object; null[field] = NSNull()
            malformed.append(try JSONSerialization.data(withJSONObject: null, options: [.sortedKeys, .withoutEscapingSlashes]))
        }
        for (field, value) in [("version", 2 as Any), ("version", true), ("extra", 1),
            ("sequence", "1"), ("sequence", 0), ("sequence", -1), ("sequence", true),
            ("generation", 0), ("generation", "1"), ("generation", UInt64(Int64.max) + 1),
            ("accountID", "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"), ("groupID", "bad"),
            ("deviceID", "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"), ("audience", "bad audience"),
            ("origin", "http://example.com"), ("origin", "https://EXAMPLE.COM/"),
            ("anchorHash", "AA=="), ("headHash", Data(repeating: 2, count: 32).base64EncodedString()),
            ("anchorHash", Data(repeating: 1, count: 32).base64EncodedString() + "\n")] {
            var invalid = object; invalid[field] = value
            malformed.append(try JSONSerialization.data(withJSONObject: invalid, options: [.sortedKeys, .withoutEscapingSlashes]))
        }
        for bytes in malformed {
            secret.set(bytes, for: key)
            await checkpointFailure(.secureStorage) { try await storage.load(binding: record.binding, accountID: groupAccount, groupID: groupID) }
            await checkpointFailure(.secureStorage) { try await storage.save(record) }
            XCTAssertEqual(secret.records[key], bytes)
        }
        XCTAssertEqual(secret.writes, 1)
    }

    func testProtectedReadAndFailedWritePreserveExistingData() async throws {
        let secret = CheckpointSecretStore()
        let storage = KeychainAccountGroupCheckpointStorage(store: secret)
        let record = try checkpointRecord()
        try await storage.save(record)
        let before = secret.records
        secret.failReads(true)
        await checkpointFailure(.secureStorage) { try await storage.save(checkpointRecord(sequence: 2)) }
        await checkpointFailure(.secureStorage) { try await storage.load(binding: record.binding, accountID: groupAccount, groupID: groupID) }
        XCTAssertEqual(secret.records, before)
        secret.failReads(false)
        secret.failWrites(true)
        await checkpointFailure(.secureStorage) { try await storage.save(checkpointRecord(sequence: 2)) }
        XCTAssertEqual(secret.records, before)
        secret.failWrites(false)
        try await storage.save(checkpointRecord(sequence: 2))
        XCTAssertEqual(secret.writes, 2)
    }
}

func checkpointBinding(device: UUID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
                       audience: String = "test.app", origin: String = "https://example.com") throws -> AccountSessionBinding {
    try AccountSessionBinding(deviceID: device, audience: audience, origin: URL(string: origin)!)
}
func checkpointRecord(binding: AccountSessionBinding? = nil, account: String = groupAccount, group: String = groupID,
                      generation: UInt64 = 1, anchor: Data = Data(repeating: 1, count: 32),
                      sequence: UInt64 = 1, head: Data = Data(repeating: 1, count: 32)) throws -> AccountGroupCheckpoint {
    try AccountGroupCheckpoint(binding: binding ?? checkpointBinding(), accountID: account, groupID: group,
        generation: generation, anchorHash: anchor, sequence: sequence, headHash: head)
}

final class CheckpointSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var seenPolicies: [KeychainPolicy] = []
    private var writeCount = 0
    private var readFailure = false
    private var writeFailure = false
    var records: [String: Data] { lock.withLock { values } }
    var policies: [KeychainPolicy] { lock.withLock { seenPolicies } }
    var writes: Int { lock.withLock { writeCount } }
    func set(_ bytes: Data, for key: String) { lock.withLock { values[key] = bytes } }
    func failReads(_ fail: Bool) { lock.withLock { readFailure = fail } }
    func failWrites(_ fail: Bool) { lock.withLock { writeFailure = fail } }
    func data(for account: String, policy: KeychainPolicy) throws -> Data? {
        try lock.withLock {
            seenPolicies.append(policy)
            if readFailure { throw KeychainStoreError.unexpectedData }
            return values[account]
        }
    }
    func store(_ data: Data, for account: String, policy: KeychainPolicy) throws {
        try lock.withLock {
            seenPolicies.append(policy)
            if writeFailure { throw KeychainStoreError.unexpectedData }
            values[account] = data
            writeCount += 1
        }
    }
}
