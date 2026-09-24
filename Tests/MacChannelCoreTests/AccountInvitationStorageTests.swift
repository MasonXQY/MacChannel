import Foundation
import XCTest
@testable import MacChannelCore

final class AccountInvitationStorageTests: XCTestCase, @unchecked Sendable {
    func testCheckpointCannotAliasRequestAndGrantIdentity() {
        let id = "11111111-1111-1111-1111-111111111111"
        XCTAssertThrowsError(try AccountInvitationCheckpoint(requestID: id, grantID: id, revision: 1, state: .requested, proofDigest: Data()))
    }
    func testNewerCheckpointFencesOldSigningCompletion() async throws {
        for state: AccountInvitationState in [.selected, .cancelled] {
            let f = try InvitationProofFixture(), original = try invitationIntent(f)
            let store = KeychainAccountInvitationStorage(store: CheckpointSecretStore())
            try await store.insert(original)
            try await store.saveCheckpoint(invitationCheckpoint(original, revision: 3, state: state), binding: original.binding, accountID: original.accountID)
            let signed = try original.signed(signature: f.sender.signature(for: original.pair.payload).derRepresentation, atMilliseconds: original.preparedAtMilliseconds)
            do { try await store.replace(expected: original, with: signed); XCTFail("late signing revision") } catch {}
        }
    }
    func testCorruptAndUnavailableProtectedStorageNeverBecomesAbsenceOrOverwrite() async throws {
        let original = try invitationIntent(InvitationProofFixture()), secret = CheckpointSecretStore()
        let store = KeychainAccountInvitationStorage(store: secret)
        try await store.insert(original)
        let entry = try XCTUnwrap(secret.records.first), before = secret.records
        secret.failReads(true)
        do { try await store.insert(original); XCTFail("read error") } catch {}
        secret.failReads(false); secret.failWrites(true)
        do { try await store.replace(expected: original, with: original.cancelled()); XCTFail("write error") } catch {}
        XCTAssertEqual(secret.records, before); secret.failWrites(false)
        let json = String(decoding: entry.value, as: UTF8.self)
        for corrupt in [Data(), Data("{}".utf8), entry.value + Data(" ".utf8),
            Data(json.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"version\":1").utf8),
            Data(json.replacingOccurrences(of: "\"version\":1", with: "\"other\":1,\"version\":1").utf8), Data(repeating: 0, count: 1_048_577)] {
            secret.set(corrupt, for: entry.key)
            do { _ = try await store.loadIntent(binding: original.binding, accountID: original.accountID, requestID: original.pair.requestID); XCTFail("corrupt read") } catch {}
            do { try await store.insert(original); XCTFail("corrupt overwrite") } catch {}
            XCTAssertEqual(secret.records[entry.key], corrupt)
        }
        XCTAssertTrue(secret.policies.allSatisfy { $0.service == KeychainAccountInvitationStorage.policy.service && !$0.synchronizable && $0.accessGroup == nil })
    }
    func testOriginAccountDeviceAudienceIsolationAndExactCleanupPreserveOtherSources() async throws {
        let original = try invitationIntent(InvitationProofFixture()), secret = InvitationRemovalStore()
        let store = KeychainAccountInvitationStorage(store: secret), checkpoint = try invitationCheckpoint(original, revision: 3, state: .active)
        let otherOrigin = try AccountSessionBinding(deviceID: original.binding.deviceID, audience: original.binding.audience, origin: URL(string: "https://other.example.com")!)
        let otherDevice = try AccountSessionBinding(deviceID: UUID(), audience: original.binding.audience, origin: original.binding.origin)
        let otherAudience = try AccountSessionBinding(deviceID: original.binding.deviceID, audience: "other-app", origin: original.binding.origin)
        let otherAccount = UUID().uuidString.lowercased()
        for (binding, account) in [(original.binding, original.accountID), (otherOrigin, original.accountID), (otherDevice, original.accountID), (otherAudience, original.accountID), (original.binding, otherAccount)] {
            try await store.saveCheckpoint(checkpoint, binding: binding, accountID: account)
        }
        let manual = Data("manual sentinel".utf8)
        try secret.store(manual, for: "manual", policy: KeychainStore.identityPolicy)
        try await store.removeForAccount(binding: original.binding, accountID: original.accountID)
        let absent = try await store.loadCheckpoint(binding: original.binding, accountID: original.accountID, requestID: checkpoint.requestID)
        XCTAssertNil(absent)
        for (binding, account) in [(otherOrigin, original.accountID), (otherDevice, original.accountID), (otherAudience, original.accountID), (original.binding, otherAccount)] {
            let retained = try await store.loadCheckpoint(binding: binding, accountID: account, requestID: checkpoint.requestID)
            XCTAssertEqual(retained, checkpoint)
        }
        XCTAssertEqual(try secret.data(for: "manual", policy: KeychainStore.identityPolicy), manual)
    }
    func testCancelledIntentAndLateActiveCheckpointCannotBothWin() async throws {
        let original = try invitationIntent(InvitationProofFixture())
        let store = KeychainAccountInvitationStorage(store: CheckpointSecretStore())
        try await store.insert(original)
        let active = try invitationCheckpoint(original, revision: 3, state: .active)
        let successes = await withTaskGroup(of: Bool.self) { tasks in
            tasks.addTask { do { try await store.replace(expected: original, with: original.cancelled()); return true } catch { return false } }
            tasks.addTask { do { try await store.saveCheckpoint(active, binding: original.binding, accountID: original.accountID); return true } catch { return false } }
            var count = 0; for await success in tasks { if success { count += 1 } }; return count
        }
        XCTAssertEqual(successes, 1)
    }
    func testBoundedTombstonesFailClosedInsteadOfEvictingHighWater() async throws {
        let original = try invitationIntent(InvitationProofFixture()), secret = CheckpointSecretStore()
        let store = KeychainAccountInvitationStorage(store: secret)
        for index in 1...256 {
            let request = String(format: "11111111-1111-1111-1111-%012x", index)
            let grant = String(format: "22222222-2222-2222-2222-%012x", index)
            let checkpoint = try AccountInvitationCheckpoint(requestID: request, grantID: grant, revision: 1, state: .cancelled, proofDigest: Data())
            try await store.saveCheckpoint(checkpoint, binding: original.binding, accountID: original.accountID)
        }
        let before = secret.records
        do { try await store.saveCheckpoint(invitationCheckpoint(original, revision: 3, state: .active), binding: original.binding, accountID: original.accountID); XCTFail("capacity must not prune tombstones") } catch {}
        XCTAssertEqual(secret.records, before)
    }
    func testRestartAndCancellationRejectLateSignatureAndOperationReplacement() async throws {
        let f = try InvitationProofFixture(), original = try invitationIntent(f)
        let secret = CheckpointSecretStore(), store = KeychainAccountInvitationStorage(store: secret)
        try await store.insert(original)
        let signed = try original.signed(signature: f.sender.signature(for: original.pair.payload).derRepresentation,
            atMilliseconds: original.preparedAtMilliseconds)
        let cancelled = original.cancelled()
        try await store.replace(expected: original, with: cancelled)
        do { try await store.replace(expected: original, with: signed); XCTFail("late signature") } catch {}
        do { try await store.insert(invitationIntent(f)); XCTFail("new operation cannot resurrect same request") } catch {}
        let restored = try await KeychainAccountInvitationStorage(store: secret).loadIntent(binding: original.binding,
            accountID: original.accountID, requestID: original.pair.requestID)
        XCTAssertEqual(restored, cancelled)
    }
    func testCheckpointTombstoneNeverRollsBackOrChangesPair() async throws {
        let f = try InvitationProofFixture(), original = try invitationIntent(f)
        let store = KeychainAccountInvitationStorage(store: CheckpointSecretStore())
        let active = try invitationCheckpoint(original, revision: 3, state: .active)
        try await store.saveCheckpoint(active, binding: original.binding, accountID: original.accountID)
        let revoked = try invitationCheckpoint(original, revision: 4, state: .revoked)
        try await store.saveCheckpoint(revoked, binding: original.binding, accountID: original.accountID)
        for value in [active, try invitationCheckpoint(original, revision: 4, state: .active), try invitationCheckpoint(original, revision: 5, state: .active)] {
            do { try await store.saveCheckpoint(value, binding: original.binding, accountID: original.accountID); XCTFail("revival") } catch {}
        }
        let restored = try await store.loadCheckpoint(binding: original.binding, accountID: original.accountID, requestID: original.pair.requestID)
        XCTAssertEqual(restored, revoked)
    }
}

final class InvitationRemovalStore: ScopedSecretStoreRecords, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: [String: Data]] = [:]
    func data(for account: String, policy: KeychainPolicy) throws -> Data? { lock.withLock { values[policy.service]?[account] } }
    func dataForRemoval(for account: String, policy: KeychainPolicy) throws -> Data? { try data(for: account, policy: policy) }
    func store(_ data: Data, for account: String, policy: KeychainPolicy) throws { lock.withLock { values[policy.service, default: [:]][account] = data } }
    func accounts(policy: KeychainPolicy, maximumCount: Int) throws -> [String] { lock.withLock { Array(values[policy.service, default: [:]].keys) } }
    func removeData(for account: String, policy: KeychainPolicy) throws { lock.withLock { _ = values[policy.service]?.removeValue(forKey: account) } }
}

func invitationIntent(_ f: InvitationProofFixture) throws -> AccountInvitationIntent {
    let pair = try AccountInvitationPair(canonicalPayload: f.payload)
    let binding = try AccountSessionBinding(deviceID: UUID(uuidString: pair.sender.deviceID)!, audience: pair.sender.audience, origin: URL(string: pair.origin)!)
    return try AccountInvitationIntent(binding: binding, accountID: pair.sender.accountID, operationID: UUID(), sessionID: UUID(),
        role: .sender, pair: pair, preparedAtMilliseconds: pair.issuedAtMilliseconds, observedRevision: 2)
}
func invitationCheckpoint(_ intent: AccountInvitationIntent, revision: UInt64, state: AccountInvitationState) throws -> AccountInvitationCheckpoint {
    try AccountInvitationCheckpoint(requestID: intent.pair.requestID, grantID: intent.pair.grantID, revision: revision,
        state: state, proofDigest: state == .requested ? Data() : intent.pair.digest)
}
