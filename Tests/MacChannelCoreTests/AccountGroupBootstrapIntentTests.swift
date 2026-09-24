import Foundation
import XCTest
@testable import MacChannelCore

final class AccountGroupBootstrapIntentTests: XCTestCase, @unchecked Sendable {
    func testLocallySignedIntentRequiresExactDeviceAndGenerationOne() throws {
        let identity = try DeviceIdentity.ephemeral()
        let binding = try checkpointBinding(device: identity.id.rawValue)
        let event = try bootstrapEvent(identity)
        let intent = try AccountGroupBootstrapIntent(binding: binding, event: event)
        XCTAssertEqual(intent.event, event)
        XCTAssertThrowsError(try AccountGroupBootstrapIntent(binding: checkpointBinding(), event: event))
        XCTAssertThrowsError(try AccountGroupBootstrapIntent(binding: binding, event: bootstrapEvent(identity, generation: 2)))
        XCTAssertThrowsError(try AccountGroupBootstrapIntent(binding: binding, event: bootstrapEvent(identity, signed: false)))
        XCTAssertThrowsError(try AccountGroupBootstrapIntent(binding: binding, event: bootstrapEvent(identity, action: "remove", sequence: 2, previous: event.digest())))
    }

    func testDedicatedImmutableRoundtripSurvivesReconstruction() async throws {
        let secret = CheckpointSecretStore()
        let storage = KeychainAccountGroupBootstrapIntentStorage(store: secret)
        let identity = try DeviceIdentity.ephemeral()
        let intent = try AccountGroupBootstrapIntent(binding: checkpointBinding(device: identity.id.rawValue), event: bootstrapEvent(identity))
        let absent = try await storage.load(binding: intent.binding, accountID: groupAccount)
        XCTAssertNil(absent)
        try await storage.save(intent)
        try await storage.save(intent)
        let loaded = try await KeychainAccountGroupBootstrapIntentStorage(store: secret).load(binding: intent.binding, accountID: groupAccount)
        XCTAssertEqual(loaded, intent)
        XCTAssertEqual(secret.writes, 1)
        let replacement = try AccountGroupBootstrapIntent(binding: intent.binding, event: bootstrapEvent(identity, group: UUID().uuidString.lowercased()))
        await enrollmentFailure(.secureStorage) { try await storage.save(replacement) }
        XCTAssertEqual(secret.writes, 1)
        XCTAssertEqual(Set(secret.policies.map(\.service)), ["com.zensystech.dropmesh.account-group-bootstrap"])
        for policy in secret.policies {
            XCTAssertNil(policy.accessGroup)
            XCTAssertEqual(policy.accessibility, .afterFirstUnlockThisDeviceOnly)
            XCTAssertFalse(policy.synchronizable)
        }
    }

    func testNormalizedScopeIsolationAndCopiedRecordRejection() async throws {
        let secret = CheckpointSecretStore()
        let storage = KeychainAccountGroupBootstrapIntentStorage(store: secret)
        let identity = try DeviceIdentity.ephemeral(), other = try DeviceIdentity.ephemeral()
        let binding = try checkpointBinding(device: identity.id.rawValue)
        let intent = try AccountGroupBootstrapIntent(binding: binding, event: bootstrapEvent(identity))
        try await storage.save(intent)
        let normalized = try checkpointBinding(device: identity.id.rawValue, origin: "HTTPS://EXAMPLE.COM:443/")
        let loaded = try await storage.load(binding: normalized, accountID: groupAccount)
        XCTAssertEqual(loaded, intent)
        let variants = [try AccountGroupBootstrapIntent(binding: checkpointBinding(device: other.id.rawValue), event: bootstrapEvent(other)),
            try AccountGroupBootstrapIntent(binding: checkpointBinding(device: identity.id.rawValue, audience: "other.app"), event: bootstrapEvent(identity)),
            try AccountGroupBootstrapIntent(binding: checkpointBinding(device: identity.id.rawValue, origin: "https://other.example.com"), event: bootstrapEvent(identity)),
            try AccountGroupBootstrapIntent(binding: binding, event: bootstrapEvent(identity, account: groupID))]
        let original = try XCTUnwrap(secret.records.first)
        for variant in variants {
            let absent = try await storage.load(binding: variant.binding, accountID: variant.event.accountID)
            XCTAssertNil(absent)
            try await storage.save(variant)
        }
        XCTAssertEqual(secret.records.count, 5)
        XCTAssertTrue(secret.records.keys.allSatisfy { !$0.contains("example.com") && !$0.contains(groupAccount) })
        let copied = try XCTUnwrap(secret.records.first { $0.key != original.key })
        secret.set(copied.value, for: original.key)
        await enrollmentFailure(.secureStorage) { try await storage.load(binding: binding, accountID: groupAccount) }
        await enrollmentFailure(.secureStorage) { try await storage.save(intent) }
        XCTAssertEqual(secret.records[original.key], copied.value)
    }

    func testMalformedCanonicalStorageFailsClosedAndCannotOverwrite() async throws {
        let secret = CheckpointSecretStore()
        let storage = KeychainAccountGroupBootstrapIntentStorage(store: secret)
        let identity = try DeviceIdentity.ephemeral()
        let intent = try AccountGroupBootstrapIntent(binding: checkpointBinding(device: identity.id.rawValue), event: bootstrapEvent(identity))
        try await storage.save(intent)
        let (key, original) = try XCTUnwrap(secret.records.first)
        let string = String(decoding: original, as: UTF8.self)
        var invalid = [Data(), Data("{}".utf8), Data(repeating: 32, count: 8193), original + Data("{}".utf8),
            original + Data(" ".utf8), Data(string.replacingOccurrences(of: "{", with: "{\"version\":1,").utf8),
            Data(string.replacingOccurrences(of: "\"version\":1", with: "\"version\":1.0").utf8),
            Data(string.replacingOccurrences(of: "\"version\":1", with: "\"version\":1e0").utf8)]
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        for field in object.keys {
            var missing = object; missing.removeValue(forKey: field)
            invalid.append(try JSONSerialization.data(withJSONObject: missing, options: [.sortedKeys, .withoutEscapingSlashes]))
            var null = object; null[field] = NSNull()
            invalid.append(try JSONSerialization.data(withJSONObject: null, options: [.sortedKeys, .withoutEscapingSlashes]))
        }
        for (field, value) in [("version", 2 as Any), ("version", true), ("version", "1"), ("extra", 1),
            ("deviceID", UUID().uuidString), ("audience", "bad audience"), ("origin", "https://EXAMPLE.COM/"),
            ("origin", "http://example.com"), ("event", ["payload": "", "signature": "", "subjectSignature": ""])] {
            var wrong = object; wrong[field] = value
            invalid.append(try JSONSerialization.data(withJSONObject: wrong, options: [.sortedKeys, .withoutEscapingSlashes]))
        }
        for bytes in invalid {
            secret.set(bytes, for: key)
            await enrollmentFailure(.secureStorage) { try await storage.load(binding: intent.binding, accountID: groupAccount) }
            await enrollmentFailure(.secureStorage) { try await storage.save(intent) }
            XCTAssertEqual(secret.records[key], bytes)
        }
        XCTAssertEqual(secret.writes, 1)
    }

    func testProtectedReadsAndFailedWritesNeverBecomeAbsence() async throws {
        let secret = CheckpointSecretStore()
        let storage = KeychainAccountGroupBootstrapIntentStorage(store: secret)
        let identity = try DeviceIdentity.ephemeral()
        let intent = try AccountGroupBootstrapIntent(binding: checkpointBinding(device: identity.id.rawValue), event: bootstrapEvent(identity))
        secret.failWrites(true)
        await enrollmentFailure(.secureStorage) { try await storage.save(intent) }
        XCTAssertTrue(secret.records.isEmpty)
        secret.failWrites(false)
        try await storage.save(intent)
        let before = secret.records
        secret.failReads(true)
        await enrollmentFailure(.secureStorage) { try await storage.load(binding: intent.binding, accountID: groupAccount) }
        await enrollmentFailure(.secureStorage) { try await storage.save(intent) }
        XCTAssertEqual(secret.records, before)
        XCTAssertEqual(secret.writes, 1)
    }
}

func bootstrapEvent(_ identity: DeviceIdentity, account: String = groupAccount, group: String = groupID,
                    generation: UInt64 = 1, signed: Bool = true, action: String = "bootstrap",
                    sequence: UInt64 = 1, previous: Data = Data()) throws -> AccountGroupEvent {
    let id = identity.id.rawValue.uuidString.lowercased(), key = identity.publicKey.rawRepresentation
    let unsigned = try AccountGroupEvent(accountID: account, groupID: group, generation: generation, sequence: sequence,
        previousHash: previous, action: action, actorDeviceID: id, actorPublicKey: key,
        subjectDeviceID: id, subjectPublicKey: key, epochMilliseconds: 2_000_000_000_000)
    guard signed else { return unsigned }
    return try AccountGroupEvent(accountID: account, groupID: group, generation: generation, sequence: sequence,
        previousHash: previous, action: action, actorDeviceID: id, actorPublicKey: key,
        subjectDeviceID: id, subjectPublicKey: key, epochMilliseconds: unsigned.epochMilliseconds,
        signature: identity.sign(unsigned.canonicalPayload()).derRepresentation)
}

func enrollmentFailure<T>(_ expected: AccountFirstDeviceEnrollmentError, file: StaticString = #filePath, line: UInt = #line,
                          _ operation: () async throws -> T) async {
    do { _ = try await operation(); XCTFail("Expected rejection", file: file, line: line) }
    catch { XCTAssertEqual(error as? AccountFirstDeviceEnrollmentError, expected, file: file, line: line) }
}
