import Foundation
import XCTest
@testable import MacChannelCore

final class AccountGroupApprovalIntentStorageTests: XCTestCase, @unchecked Sendable {
    func testReconstructedCollectionIdempotenceCASAndExactPrune() async throws {
        let secret = CheckpointSecretStore(), original = try approvalIntent()
        let store = KeychainAccountGroupApprovalIntentStorage(store: secret)
        let empty = try await store.list(binding: original.scope.binding, accountID: original.scope.accountID)
        XCTAssertTrue(empty.isEmpty)
        try await store.insert(original); try await store.insert(original)
        XCTAssertEqual(secret.writes, 1)
        let restored = try await KeychainAccountGroupApprovalIntentStorage(store: secret).load(scope: original.scope)
        XCTAssertTrue(restored == original)
        let uncertain = try original.replacing(phase: .terminal(.subjectRequested, .locallyAbandoned))
        try await store.replace(scope: original.scope, expected: original, with: uncertain)
        await approvalFailure { try await store.pruneTerminal(scope: original.scope, expected: uncertain) }
        let cancelled = try uncertain.replacing(phase: .terminal(.subjectRequested, .acknowledged(.cancelled)))
        try await store.replace(scope: original.scope, expected: uncertain, with: cancelled)
        try await store.replace(scope: original.scope, expected: uncertain, with: cancelled)
        await approvalFailure { try await store.pruneTerminal(scope: original.scope, expected: uncertain) }
        try await store.pruneTerminal(scope: original.scope, expected: cancelled)
        let absent = try await store.load(scope: original.scope)
        XCTAssertNil(absent)
        XCTAssertEqual(secret.records.count, 1)
        XCTAssertTrue(secret.policies.allSatisfy { $0.service == "com.zensystech.dropmesh.account-group-approval" && $0.accessGroup == nil && $0.accessibility == .afterFirstUnlockThisDeviceOnly && !$0.synchronizable })
    }

    func testCapacityAndSameKeyRacesPreserveEveryOtherEntry() async throws {
        let secret = CheckpointSecretStore(), store = KeychainAccountGroupApprovalIntentStorage(store: secret)
        let intents = try (0..<33).map { try approvalIntent(requestID: String(format: "%08x-3333-3333-3333-333333333333", $0)) }
        for intent in intents.prefix(32) { try await store.insert(intent) }
        await approvalFailure { try await store.insert(intents[32]) }
        let original = intents[0]
        let a = try original.replacing(phase: .terminal(.subjectRequested, .acknowledged(.cancelled)))
        let b = try original.replacing(phase: .terminal(.subjectRequested, .acknowledged(.rejected)))
        let successes = await withTaskGroup(of: Bool.self) { group in
            for replacement in [a, b] { group.addTask { do { try await store.replace(scope: original.scope, expected: original, with: replacement); return true } catch { return false } } }
            var count = 0; for await ok in group { if ok { count += 1 } }; return count
        }
        XCTAssertEqual(successes, 1)
        let list = try await store.list(binding: original.scope.binding, accountID: original.scope.accountID)
        XCTAssertEqual(list.count, 32)
        XCTAssertTrue(list.dropFirst().elementsEqual(intents[1..<32]))
        let winner = try XCTUnwrap(list.first)
        try await store.pruneTerminal(scope: winner.scope, expected: winner)
        try await store.insert(intents[32])
        let rebuilt = try await KeychainAccountGroupApprovalIntentStorage(store: secret).list(binding: original.scope.binding, accountID: original.scope.accountID)
        XCTAssertTrue(rebuilt.elementsEqual(intents[1...32]))
    }

    func testProtectedMalformedAndWriteFailuresPreserveOldBytes() async throws {
        let secret = CheckpointSecretStore(), store = KeychainAccountGroupApprovalIntentStorage(store: secret)
        let original = try approvalIntent()
        try await store.insert(original)
        let records = secret.records, pair = try XCTUnwrap(records.first)
        let terminal = try original.replacing(phase: .terminal(.subjectRequested, .acknowledged(.cancelled)))
        secret.failWrites(true)
        await approvalFailure { try await store.replace(scope: original.scope, expected: original, with: terminal) }
        XCTAssertTrue(secret.records == records)
        secret.failWrites(false); secret.failReads(true)
        await approvalFailure { try await store.load(scope: original.scope) }
        await approvalFailure { try await store.insert(original) }
        secret.failReads(false)
        let json = String(decoding: pair.value, as: UTF8.self)
        for bytes in [Data(), Data("{}".utf8), pair.value + Data(" ".utf8), Data(repeating: 32, count: 1_048_577),
            Data(json.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"version\":1").utf8),
            Data(json.replacingOccurrences(of: "\"version\":1", with: "\"extra\":1,\"version\":1").utf8)] {
            secret.set(bytes, for: pair.key)
            await approvalFailure { try await store.list(binding: original.scope.binding, accountID: original.scope.accountID) }
            await approvalFailure { try await store.insert(original) }
            XCTAssertTrue(secret.records[pair.key] == bytes)
        }
        XCTAssertEqual(secret.writes, 1)
    }

    func testSignedPhasesRestartIsolationAndFailedPrune() async throws {
        let secret = CheckpointSecretStore(), store = KeychainAccountGroupApprovalIntentStorage(store: secret)
        let original = try approvalIntent(), actor = try approvalIntent(role: .actor)
        let proof = try approvalProof(), final = try approvalFixtures()[0].final
        let signed = try original.replacing(phase: .active(.subjectCountersigned(proof, final)))
        await approvalFailure { try await store.insert(signed) }
        try await store.insert(original); try await store.insert(actor)
        try await store.replace(scope: original.scope, expected: original, with: signed)
        let restored = try await KeychainAccountGroupApprovalIntentStorage(store: secret).load(scope: signed.scope)
        XCTAssertTrue(restored == signed)
        let actorRestored = try await KeychainAccountGroupApprovalIntentStorage(store: secret).load(scope: actor.scope)
        XCTAssertTrue(actorRestored == actor)
        let sentinel = try approvalRemap(original, accountID: groupAccount)
        try await store.insert(sentinel)
        let before = secret.records
        await approvalFailure { try await store.replace(scope: original.scope, expected: signed, with: original) }
        await approvalFailure { try await store.insert(approvalIntent(sessionID: UUID())) }
        XCTAssertTrue(secret.records == before)
        let terminal = try signed.replacing(phase: .terminal(signed.activePredecessor, .acknowledged(.committed)))
        try await store.replace(scope: signed.scope, expected: signed, with: terminal)
        let beforePrune = secret.records
        secret.failWrites(true)
        await approvalFailure { try await store.pruneTerminal(scope: terminal.scope, expected: terminal) }
        XCTAssertTrue(secret.records == beforePrune)
        secret.failWrites(false)
        try await store.pruneTerminal(scope: terminal.scope, expected: terminal)
        let actorAfter = try await store.load(scope: actor.scope), sentinelAfter = try await store.load(scope: sentinel.scope)
        XCTAssertTrue(actorAfter == actor); XCTAssertTrue(sentinelAfter == sentinel)
        // Same binding/account/request but distinct roles are never overwritten.
        let sameCollectionSubject = try approvalRemap(actor, accountID: actor.scope.accountID)
        try await store.insert(sameCollectionSubject)
        let both = try await store.list(binding: actor.scope.binding, accountID: actor.scope.accountID)
        XCTAssertEqual(both.map(\.scope.role), [.actor, .subject])
    }

    func testStrictCollectionOwnershipDuplicatesBoundsAndStoredProofTampering() async throws {
        let secret = CheckpointSecretStore(), store = KeychainAccountGroupApprovalIntentStorage(store: secret)
        let actor = try approvalIntent(role: .actor)
        try await store.insert(actor)
        let pair = try XCTUnwrap(secret.records.first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: pair.value) as? [String: Any])
        let records = try XCTUnwrap(object["records"] as? [[String: Any]])
        var invalid: [Data] = []
        func encode(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) }
        for name in object.keys {
            var missing = object; missing.removeValue(forKey: name); invalid.append(try encode(missing))
            var null = object; null[name] = NSNull(); invalid.append(try encode(null))
        }
        for (field, value) in [("deviceID", groupID as Any), ("accountID", groupAccount), ("origin", "https://other.example.com"),
            ("audience", "other.app"), ("version", 2), ("records", records + records), ("records", Array(repeating: records[0], count: 33))] {
            var changed = object; changed[field] = value; invalid.append(try encode(changed))
        }
        for (field, value) in [("sessionID", "00000000-0000-0000-0000-000000000000" as Any), ("activePhase", "subjectRequested"),
            ("role", "subject"), ("generation", "18446744073709551616"), ("preparedAtMilliseconds", 0),
            ("canonicalPayloadDigest", Data(repeating: 0, count: 32).base64EncodedString()),
            ("requestComparisonDigest", Data(repeating: 0, count: 32).base64EncodedString()),
            ("capsule", String(repeating: "A", count: 16_385)), ("extra", "x")] {
            var changed = records[0]; changed[field] = value
            var collection = object; collection["records"] = [changed]; invalid.append(try encode(collection))
        }
        let raw = String(decoding: pair.value, as: UTF8.self)
        invalid += [Data(raw.replacingOccurrences(of: "\"version\":1", with: "\"version\":1e0").utf8),
            Data(raw.replacingOccurrences(of: "\"version\":1", with: "\"ver\\u0073ion\":1,\"version\":1").utf8)]
        for bad in invalid {
            secret.set(bad, for: pair.key)
            await approvalFailure { try await store.load(scope: actor.scope) }
            await approvalFailure { try await store.insert(actor) }
            XCTAssertTrue(secret.records[pair.key] == bad)
        }
        XCTAssertEqual(secret.writes, 1)
    }
}
private func approvalRemap(_ value: AccountGroupApprovalIntent, accountID: String) throws -> AccountGroupApprovalIntent {
    let binding = value.scope.binding
    let scope = try AccountGroupApprovalIntent.Scope(binding: binding, accountID: accountID, requestID: value.scope.requestID, role: .subject)
    let request = try AccountDeviceApprovalRequestContext(origin: binding.origin, requestID: scope.requestID, accountID: accountID,
        groupID: value.groupID, generation: value.generation, subjectDeviceID: binding.deviceID.uuidString.lowercased(), subjectPublicKey: value.localPublicKey)
    return try AccountGroupApprovalIntent(scope: scope, intentID: value.intentID,
        originalSessionIdentity: AccountSessionIdentity(accountID: UUID(uuidString: accountID)!, sessionID: value.originalSessionIdentity.sessionID, deviceID: binding.deviceID, audience: binding.audience),
        localPublicKey: value.localPublicKey, request: request, preparedAtMilliseconds: value.preparedAtMilliseconds,
        originalAccessExpiresAtMilliseconds: value.originalAccessExpiresAtMilliseconds, phase: .active(.subjectRequested))
}
func approvalFailure<T>(file: StaticString = #filePath, line: UInt = #line, _ operation: () async throws -> T) async {
    do { _ = try await operation(); XCTFail("Expected rejection", file: file, line: line) }
    catch { XCTAssertNotNil(error as? AccountDeviceApprovalValueError, file: file, line: line) }
}
