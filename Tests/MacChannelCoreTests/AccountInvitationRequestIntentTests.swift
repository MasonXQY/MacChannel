import Foundation
import XCTest
@testable import MacChannelCore

final class AccountInvitationRequestIntentTests: XCTestCase, @unchecked Sendable {
    func testRequestCapacityAndCorruptionNeverDiscardRetainedConsent() async throws {
        let f = try InvitationProofFixture(), p = try invitationIntent(f), bytes = try invitationRequestFixture(f)
        let base = try AccountInvitationRequest(canonicalPayload: bytes.payload)
        let secret = CheckpointSecretStore(), storage = KeychainAccountInvitationStorage(store: secret)
        for index in 1...128 {
            let request = try AccountInvitationRequest(sender: base.sender, origin: p.binding.origin,
                requestID: String(format: "11111111-1111-1111-1111-%012x", index),
                grantID: String(format: "22222222-2222-2222-2222-%012x", index), targetLinkHash: base.targetLinkHash,
                issuedAtMilliseconds: base.issuedAtMilliseconds)
            try await storage.insertRequest(AccountInvitationRequestIntent(binding: p.binding, accountID: p.accountID,
                operationID: UUID(), sessionID: UUID(), request: request, preparedAtMilliseconds: p.preparedAtMilliseconds))
        }
        let before = secret.records
        let extra = try AccountInvitationRequestIntent(binding: p.binding, accountID: p.accountID, operationID: UUID(), sessionID: UUID(), request: base, preparedAtMilliseconds: p.preparedAtMilliseconds)
        do { try await storage.insertRequest(extra); XCTFail("capacity pruned existing consent") } catch {}
        XCTAssertEqual(secret.records, before)
        let entry = try XCTUnwrap(before.first)
        secret.set(entry.value + Data(" ".utf8), for: entry.key)
        do { _ = try await storage.listRequests(binding: p.binding, accountID: p.accountID); XCTFail("noncanonical ledger") } catch {}
        do { try await storage.insertRequest(extra); XCTFail("corrupt overwrite") } catch {}
        XCTAssertEqual(secret.records[entry.key], entry.value + Data(" ".utf8))
    }
    func testCheckpointAndFinalPairCannotRetargetOrReviveInitialConsent() async throws {
        let f = try InvitationProofFixture(), p = try invitationIntent(f), bytes = try invitationRequestFixture(f)
        let initial = try AccountInvitationRequestIntent(binding: p.binding, accountID: p.accountID, operationID: UUID(), sessionID: UUID(),
            request: AccountInvitationRequest(canonicalPayload: bytes.payload), preparedAtMilliseconds: p.preparedAtMilliseconds)
        let signed = try initial.signed(signature: bytes.signature, atMilliseconds: initial.preparedAtMilliseconds)
        let secret = CheckpointSecretStore(), storage = KeychainAccountInvitationStorage(store: secret)
        try await storage.insertRequest(initial)
        try await storage.saveCheckpoint(invitationCheckpoint(p, revision: 3, state: .cancelled), binding: p.binding, accountID: p.accountID)
        let before = secret.records
        do { try await storage.replaceRequest(expected: initial, with: signed); XCTFail("terminal checkpoint revived") } catch {}
        XCTAssertEqual(secret.records, before)
        let clean = KeychainAccountInvitationStorage(store: CheckpointSecretStore())
        try await clean.insertRequest(initial); try await clean.replaceRequest(expected: initial, with: signed)
        var substituted = f; substituted.fields["targetLinkHash"] = Data(repeating: 4, count: 32).base64EncodedString()
        do { try await clean.insert(invitationIntent(substituted)); XCTFail("final pair retargeted initial link") } catch {}
        try await clean.insert(p)
        do { try await clean.replaceRequest(expected: signed, with: signed.cancelled()); XCTFail("active local pair intent and cancellation both won") } catch {}
    }
    func testRequestStoreFailureAndAccountCleanupPreserveOtherScope() async throws {
        let f = try InvitationProofFixture(), p = try invitationIntent(f), bytes = try invitationRequestFixture(f)
        let initial = try AccountInvitationRequestIntent(binding: p.binding, accountID: p.accountID, operationID: UUID(), sessionID: UUID(),
            request: AccountInvitationRequest(canonicalPayload: bytes.payload), preparedAtMilliseconds: p.preparedAtMilliseconds)
        let failing = CheckpointSecretStore(), storage = KeychainAccountInvitationStorage(store: failing)
        failing.failWrites(true)
        do { try await storage.insertRequest(initial); XCTFail("pre-send persistence failure") } catch {}
        XCTAssertTrue(failing.records.isEmpty)
        failing.failWrites(false); try await storage.insertRequest(initial)
        let before = failing.records; failing.failReads(true)
        do { try await storage.replaceRequest(expected: initial, with: initial.cancelled()); XCTFail("protected read unavailable") } catch {}
        XCTAssertEqual(failing.records, before)
        let secret = InvitationRemovalStore(), removable = KeychainAccountInvitationStorage(store: secret)
        try await removable.insertRequest(initial)
        let otherAccount = UUID().uuidString.lowercased(), checkpoint = try invitationCheckpoint(p, revision: 3, state: .cancelled)
        try await removable.saveCheckpoint(checkpoint, binding: p.binding, accountID: otherAccount)
        try await removable.removeForAccount(binding: p.binding, accountID: p.accountID)
        let removed = try await removable.listRequests(binding: p.binding, accountID: p.accountID)
        let retained = try await removable.loadCheckpoint(binding: p.binding, accountID: otherAccount, requestID: checkpoint.requestID)
        XCTAssertTrue(removed.isEmpty); XCTAssertEqual(retained, checkpoint)
    }
    func testDurableRequestSurvivesLostCreateResponseAndFencesSessionReplacement() async throws {
        let f = try InvitationProofFixture(), p = try invitationIntent(f), bytes = try invitationRequestFixture(f)
        let request = try AccountInvitationRequest(canonicalPayload: bytes.payload)
        let initial = try AccountInvitationRequestIntent(binding: p.binding, accountID: p.accountID, operationID: UUID(), sessionID: UUID(), request: request, preparedAtMilliseconds: p.preparedAtMilliseconds)
        let secret = CheckpointSecretStore(), storage = KeychainAccountInvitationStorage(store: secret)
        try await storage.insertRequest(initial)
        let signed = try initial.signed(signature: bytes.signature, atMilliseconds: initial.preparedAtMilliseconds)
        try await storage.replaceRequest(expected: initial, with: signed)
        let restarted = KeychainAccountInvitationStorage(store: secret)
        let restored = try await restarted.loadRequest(binding: p.binding, accountID: p.accountID, requestID: request.requestID)
        XCTAssertEqual(restored, signed)
        XCTAssertEqual(try restored?.signedProof().payload, bytes.payload)
        let changedSession = try AccountInvitationRequestIntent(binding: p.binding, accountID: p.accountID, operationID: initial.operationID, sessionID: UUID(), request: request, preparedAtMilliseconds: initial.preparedAtMilliseconds)
        do { try await restarted.insertRequest(changedSession); XCTFail("new session replaced consent") } catch {}
        try await restarted.replaceRequest(expected: signed, with: signed.cancelled())
        do { try await restarted.replaceRequest(expected: initial, with: signed); XCTFail("late signature revived cancellation") } catch {}
        let cancelled = try await restarted.loadRequest(binding: p.binding, accountID: p.accountID, requestID: request.requestID)
        XCTAssertEqual(cancelled, signed.cancelled())
    }
    func testInitialConsentBindsSessionAndRetainsExactSignedRequestOnly() throws {
        let f = try InvitationProofFixture(), pairIntent = try invitationIntent(f), bytes = try invitationRequestFixture(f)
        let request = try AccountInvitationRequest(canonicalPayload: bytes.payload)
        let intent = try AccountInvitationRequestIntent(binding: pairIntent.binding, accountID: pairIntent.accountID,
            operationID: UUID(), sessionID: UUID(), request: request, preparedAtMilliseconds: pairIntent.preparedAtMilliseconds)
        XCTAssertThrowsError(try intent.signedProof())
        let signed = try intent.signed(signature: bytes.signature, atMilliseconds: intent.preparedAtMilliseconds)
        XCTAssertEqual(try signed.signedProof().payload, bytes.payload)
        XCTAssertEqual(try signed.signedProof().signature, bytes.signature)
        XCTAssertEqual(signed.sessionID, intent.sessionID)
        XCTAssertThrowsError(try signed.cancelled().signedProof())
        XCTAssertThrowsError(try intent.cancelled().signed(signature: bytes.signature, atMilliseconds: intent.preparedAtMilliseconds))
        XCTAssertThrowsError(try intent.signed(signature: bytes.signature, atMilliseconds: request.expiresAtMilliseconds))
        XCTAssertThrowsError(try AccountInvitationRequestIntent(binding: pairIntent.binding, accountID: UUID().uuidString.lowercased(),
            operationID: UUID(), sessionID: UUID(), request: request, preparedAtMilliseconds: intent.preparedAtMilliseconds))
    }
}
