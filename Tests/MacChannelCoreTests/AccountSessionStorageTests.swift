import Foundation
import XCTest
@testable import MacChannelCore

final class AccountSessionStorageTests: XCTestCase {
    func testRemovingCandidateLeavesLegacySessionUntouched() async throws {
        let secrets = NamespacedSessionSecrets()
        let record = try record()
        let candidatePolicy = KeychainAccountSessionStorage.scopedPolicy(record.binding)
        let legacy = KeychainAccountSessionStorage(store: secrets, remove: {
            secrets.remove(policy: KeychainAccountSessionStorage.policy)
        })
        let candidate = KeychainAccountSessionStorage(store: secrets, binding: record.binding, remove: {
            secrets.remove(policy: candidatePolicy)
        })
        try await legacy.save(record)
        let initiallyAbsent = try await candidate.load()
        XCTAssertNil(initiallyAbsent)
        try await candidate.save(record)
        try await candidate.remove()
        let legacyAfter = try await legacy.load()
        let candidateAfter = try await candidate.load()
        XCTAssertEqual(legacyAfter?.tokens.accessToken, record.tokens.accessToken)
        XCTAssertNil(candidateAfter)
    }
    func testBoundNamespaceSeparatesOriginAudienceAndDevice() throws {
        let device = UUID()
        let a = try AccountSessionBinding(deviceID: device, audience: "app", origin: URL(string: "https://example.com")!)
        let equivalent = try AccountSessionBinding(deviceID: device, audience: "app", origin: URL(string: "HTTPS://EXAMPLE.COM:443/")!)
        XCTAssertEqual(KeychainAccountSessionStorage.scopedPolicy(a), KeychainAccountSessionStorage.scopedPolicy(equivalent))
        for b in [
            try AccountSessionBinding(deviceID: device, audience: "app", origin: URL(string: "https://candidate.example.com")!),
            try AccountSessionBinding(deviceID: device, audience: "other", origin: a.origin),
            try AccountSessionBinding(deviceID: UUID(), audience: "app", origin: a.origin)
        ] {
            XCTAssertNotEqual(KeychainAccountSessionStorage.scopedPolicy(a), KeychainAccountSessionStorage.scopedPolicy(b))
        }
        XCTAssertNotEqual(KeychainAccountSessionStorage.scopedPolicy(a), KeychainAccountSessionStorage.policy)
    }

    func testBoundStoreRejectsWrongBindingWithoutOverwrite() async throws {
        let secret = SessionSecretStore()
        let first = try record()
        let store = KeychainAccountSessionStorage(store: secret, binding: first.binding, remove: { secret.remove() })
        try await store.save(first)
        let bytes = secret.bytes
        do { try await store.save(record()); XCTFail("wrong binding saved") } catch {}
        XCTAssertEqual(secret.bytes, bytes)
        XCTAssertEqual(secret.writes.count, 1)
        let wrong = KeychainAccountSessionStorage(store: secret, binding: try record().binding, remove: { secret.remove() })
        do { _ = try await wrong.load(); XCTFail("wrong binding read") } catch {}
        XCTAssertEqual(secret.removals, 0)
        XCTAssertTrue(secret.policies.allSatisfy { $0.service != KeychainAccountSessionStorage.policy.service })
    }

    func testDedicatedPolicyAndAtomicSingleRecordRoundTrip() async throws {
        let secret = SessionSecretStore()
        let store = KeychainAccountSessionStorage(store: secret, remove: { secret.remove() })
        let first = try record()
        try await store.save(first)
        let loaded = try await store.load()
        XCTAssertEqual(loaded?.binding, first.binding)
        XCTAssertEqual(loaded?.tokens.accessToken, first.tokens.accessToken)
        XCTAssertEqual(loaded?.tokens.refreshExpiresAt, first.tokens.refreshExpiresAt)
        let pending = try AccountStoredSession(binding: first.binding, tokens: first.tokens, phase: .refreshPending)
        try await store.save(pending)
        let again = try await store.load()
        XCTAssertEqual(again?.phase, .refreshPending)
        XCTAssertEqual(secret.writes.count, 2)
        XCTAssertTrue(secret.writes.allSatisfy { $0.count <= 16_384 })
        XCTAssertEqual(Set(secret.accounts), ["session-v1"])
        for policy in secret.policies {
            XCTAssertEqual(policy.service, "com.zensystech.dropmesh.account-session")
            XCTAssertNil(policy.accessGroup)
            XCTAssertEqual(policy.accessibility, .afterFirstUnlockThisDeviceOnly)
            XCTAssertFalse(policy.synchronizable)
        }
        XCTAssertFalse(String(describing: first).contains(first.tokens.accessToken))
        XCTAssertFalse(String(reflecting: first).contains(first.tokens.refreshToken))
        try await store.remove()
        XCTAssertEqual(secret.removals, 1)
        let absent = try await store.load()
        XCTAssertNil(absent)
    }

    func testMalformedAndUnreadableRecordsCannotBeOverwritten() async throws {
        let secret = SessionSecretStore()
        let store = KeychainAccountSessionStorage(store: secret, remove: { secret.remove() })
        let valid = try record()
        try await store.save(valid)
        let base = try XCTUnwrap(secret.bytes)
        var variants = [Data(repeating: 1, count: 16_385), Data("{}".utf8)]
        for (key, value) in [
            ("version", 2 as Any), ("phase", "unknown"), ("audience", " bad audience"),
            ("origin", "https://localhost"), ("accessToken", "not-a-token"),
            ("accountID", "00000000-0000-0000-0000-000000000000"),
            ("accessExpiresAt", -1), ("refreshExpiresAt", 1),
            ("accessExpiresAt", 1234.5), ("refreshExpiresAt", Int64.max),
        ] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: base) as? [String: Any])
            object[key] = value
            variants.append(try JSONSerialization.data(withJSONObject: object))
        }
        for bytes in variants {
            secret.setBytes(bytes)
            do { _ = try await store.load(); XCTFail("accepted invalid record") } catch {
                XCTAssertEqual(error as? AccountSessionControllerError, .secureStorage)
            }
            do { try await store.save(valid); XCTFail("overwrote invalid record") } catch {}
            XCTAssertEqual(secret.bytes, bytes)
        }
        secret.setReadFailure(true)
        do { try await store.save(valid); XCTFail("overwrote unreadable storage") } catch {}
        XCTAssertEqual(secret.writes.count, 1)
    }

    func testBindingNormalizationAndTypedRecordValidation() throws {
        let device = UUID()
        let normalized = try AccountSessionBinding(deviceID: device, audience: "app", origin: URL(string: "HTTPS://Example.com:443/")!)
        XCTAssertEqual(normalized.origin.absoluteString, "https://example.com")
        for url in ["http://example.com", "https://example.com/path", "https://user@example.com", "https://example.com?q=1", "https://example.com#f", "https://127.1"] {
            XCTAssertThrowsError(try AccountSessionBinding(deviceID: device, audience: "app", origin: URL(string: url)!))
        }
        let valid = try record()
        XCTAssertThrowsError(try AccountStoredSession(binding: normalized, tokens: valid.tokens))
        for date in [Date(timeIntervalSince1970: .infinity), Date(timeIntervalSince1970: -.infinity), Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: 0)] {
            let invalid = AccountSessionTokens(identity: valid.tokens.identity, accessToken: valid.tokens.accessToken, refreshToken: valid.tokens.refreshToken, accessExpiresAt: date, refreshExpiresAt: valid.tokens.refreshExpiresAt)
            XCTAssertThrowsError(try AccountStoredSession(binding: valid.binding, tokens: invalid))
        }
    }

    private func record() throws -> AccountStoredSession {
        let binding = try AccountSessionBinding(deviceID: UUID(), audience: "test.app", origin: URL(string: "https://example.com")!)
        let token: (UInt8) -> String = { Data(repeating: $0, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "") }
        return try AccountStoredSession(binding: binding, tokens: .init(
            identity: .init(accountID: UUID(), sessionID: UUID(), deviceID: binding.deviceID, audience: binding.audience),
            accessToken: token(1), refreshToken: token(2), accessExpiresAt: Date(timeIntervalSince1970: 2_000_000_000), refreshExpiresAt: Date(timeIntervalSince1970: 2_000_001_000)))
    }
}

private final class NamespacedSessionSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func data(for account: String, policy: KeychainPolicy) throws -> Data? {
        lock.withLock { values[policy.service + "/" + account] }
    }
    func store(_ data: Data, for account: String, policy: KeychainPolicy) throws {
        lock.withLock { values[policy.service + "/" + account] = data }
    }
    func remove(policy: KeychainPolicy) {
        lock.withLock { values = values.filter { !$0.key.hasPrefix(policy.service + "/") } }
    }
}

private final class SessionSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    private var readFailure = false
    private var saved: [Data] = []
    private var seenAccounts: [String] = []
    private var seenPolicies: [KeychainPolicy] = []
    private var removed = 0
    var bytes: Data? { lock.withLock { value } }
    var writes: [Data] { lock.withLock { saved } }
    var accounts: [String] { lock.withLock { seenAccounts } }
    var policies: [KeychainPolicy] { lock.withLock { seenPolicies } }
    var removals: Int { lock.withLock { removed } }
    func setBytes(_ data: Data) { lock.withLock { value = data } }
    func setReadFailure(_ failure: Bool) { lock.withLock { readFailure = failure } }
    func data(for account: String, policy: KeychainPolicy) throws -> Data? {
        try lock.withLock {
            if readFailure { throw KeychainStoreError.unexpectedData }
            seenAccounts.append(account); seenPolicies.append(policy)
            return value
        }
    }
    func store(_ data: Data, for account: String, policy: KeychainPolicy) throws {
        lock.withLock {
            seenAccounts.append(account); seenPolicies.append(policy)
            saved.append(data); value = data
        }
    }
    func remove() { lock.withLock { removed += 1; value = nil } }
}
