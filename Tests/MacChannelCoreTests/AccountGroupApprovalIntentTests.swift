import Foundation
import XCTest
@testable import MacChannelCore

final class AccountGroupApprovalIntentTests: XCTestCase {
    func testBoundedPhasesRetainExactProofAndOriginalSession() throws {
        let original = try approvalIntent()
        let proof = try approvalProof()
        let final = try approvalFixtures()[0].final
        let signed = try original.replacing(phase: .active(.subjectCountersigned(proof, final)))
        XCTAssertTrue(original.canReplace(with: signed))
        XCTAssertFalse(signed.canReplace(with: original))
        XCTAssertEqual(signed.confirmationDeadlineMilliseconds, original.confirmationDeadlineMilliseconds)
        let uncertain = try signed.replacing(phase: .terminal(.subjectCountersigned(proof, final), .locallyAbandoned))
        XCTAssertFalse(uncertain.isAcknowledgedTerminal)
        let cancelled = try uncertain.replacing(phase: .terminal(.subjectCountersigned(proof, final), .acknowledged(.cancelled)))
        XCTAssertTrue(uncertain.canReplace(with: cancelled))
        XCTAssertTrue(cancelled.isAcknowledgedTerminal)
        XCTAssertFalse(cancelled.canReplace(with: uncertain))
        XCTAssertThrowsError(try original.replacing(phase: .terminal(.subjectRequested, .acknowledged(.committed))))
        XCTAssertThrowsError(try original.replacing(phase: .terminal(.subjectRequested, .acknowledged(.requested))))
        XCTAssertThrowsError(try original.replacing(phase: .active(.actorProposed(proof))))
        XCTAssertFalse(String(reflecting: signed).contains(original.originalSessionIdentity.sessionID.uuidString))
        let otherSession = try approvalIntent(sessionID: UUID())
        XCTAssertFalse(original.canReplace(with: otherSession))
        let acknowledged = try original.replacing(phase: original.phase,
            acknowledgment: AccountGroupApprovalIntent.Acknowledgment(createdAtMilliseconds: 1_700_000_000_100, expiresAtMilliseconds: 1_700_000_300_100))
        XCTAssertTrue(original.canReplace(with: acknowledged))
        XCTAssertLessThanOrEqual(acknowledged.confirmationDeadlineMilliseconds, original.confirmationDeadlineMilliseconds)
    }

    func testMismatchedProofScopeKeySessionAndAcknowledgmentFail() throws {
        let original = try approvalIntent()
        let other = try approvalProof(index: 1)
        XCTAssertThrowsError(try original.replacing(phase: .active(.subjectCountersigned(other, approvalFixtures()[1].final))))
        XCTAssertThrowsError(try AccountGroupApprovalIntent(scope: original.scope, intentID: original.intentID,
            originalSessionIdentity: AccountSessionIdentity(accountID: UUID(), sessionID: UUID(), deviceID: original.scope.binding.deviceID, audience: original.scope.binding.audience),
            localPublicKey: original.localPublicKey, request: original.request, preparedAtMilliseconds: original.preparedAtMilliseconds,
            originalAccessExpiresAtMilliseconds: original.originalAccessExpiresAtMilliseconds, phase: original.phase))
        XCTAssertThrowsError(try AccountGroupApprovalIntent(scope: original.scope, intentID: original.intentID,
            originalSessionIdentity: original.originalSessionIdentity, localPublicKey: Data([4]) + original.localPublicKey,
            request: original.request, preparedAtMilliseconds: original.preparedAtMilliseconds,
            originalAccessExpiresAtMilliseconds: original.originalAccessExpiresAtMilliseconds, phase: original.phase))
        XCTAssertThrowsError(try AccountGroupApprovalIntent.Acknowledgment(createdAtMilliseconds: UInt64.max, expiresAtMilliseconds: 1))
        let unsigned = try AccountGroupEvent(canonicalPayload: approvalFixtures()[0].final.canonicalPayload(), signature: approvalFixtures()[0].draft.event.signature, subjectSignature: Data([1]))
        XCTAssertThrowsError(try original.replacing(phase: .active(.subjectCountersigned(approvalProof(), unsigned))))
    }

    func testZeroAccountSessionCannotCreateDurableConsent() throws {
        let original = try approvalIntent(), zero = "00000000-0000-0000-0000-000000000000"
        let scope = try AccountGroupApprovalIntent.Scope(binding: original.scope.binding, accountID: zero, requestID: original.scope.requestID, role: .subject)
        let request = try AccountDeviceApprovalRequestContext(origin: original.request.origin, requestID: scope.requestID, accountID: zero,
            groupID: original.groupID, generation: original.generation, subjectDeviceID: original.request.subjectDeviceID, subjectPublicKey: original.localPublicKey)
        XCTAssertThrowsError(try AccountGroupApprovalIntent(scope: scope, intentID: original.intentID,
            originalSessionIdentity: AccountSessionIdentity(accountID: UUID(uuidString: zero)!, sessionID: original.originalSessionIdentity.sessionID, deviceID: scope.binding.deviceID, audience: scope.binding.audience),
            localPublicKey: original.localPublicKey, request: request, preparedAtMilliseconds: original.preparedAtMilliseconds,
            originalAccessExpiresAtMilliseconds: original.originalAccessExpiresAtMilliseconds, phase: original.phase))
    }
}

func approvalProof(index: Int = 0, requestID: String = "33333333-3333-3333-3333-333333333333") throws -> AccountGroupApprovalIntent.Proof {
    let draft = try approvalFixtures()[index].draft, request = try approvalContext(draft, requestID: requestID)
    let capsule = try AccountDeviceApprovalCapsule(origin: request.origin, requestID: requestID, draft: draft, expectedAnchorHash: Data(repeating: 65, count: 32))
    return try .init(request: request, draft: draft, capsule: capsule)
}

func approvalIntent(requestID: String = "33333333-3333-3333-3333-333333333333", role: AccountGroupApprovalIntent.Role = .subject,
                    sessionID: UUID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!) throws -> AccountGroupApprovalIntent {
    let f = try approvalFixtures()[0], request = try approvalContext(f.draft, requestID: requestID)
    let key = role == .subject ? f.draft.event.subjectPublicKey : f.draft.event.actorPublicKey
    let binding = try AccountSessionBinding(deviceID: UUID(uuidString: AccountGroupEvent.deviceID(publicKey: key))!, audience: "com.example.app", origin: request.origin)
    let scope = try AccountGroupApprovalIntent.Scope(binding: binding, accountID: request.accountID, requestID: requestID, role: role)
    return try AccountGroupApprovalIntent(scope: scope, intentID: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
        originalSessionIdentity: AccountSessionIdentity(accountID: UUID(uuidString: request.accountID)!, sessionID: sessionID, deviceID: binding.deviceID, audience: binding.audience),
        localPublicKey: key, request: request, preparedAtMilliseconds: 1_700_000_000_000,
        originalAccessExpiresAtMilliseconds: 1_700_000_200_000,
        phase: .active(role == .subject ? .subjectRequested : .actorProposed(approvalProof(requestID: requestID))))
}
