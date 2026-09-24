import MacChannelCore
import XCTest
import UIKit
@testable import DropMeshTestHost

@MainActor final class MobileAccountApprovalModelTests: XCTestCase {
    func testOwnRequestRefreshAvoidsMemberOnlyListAndPreservesRestartRecovery() async throws {
        let f = try AccountApprovalEvidenceFixture(); await f.controller.restore()
        do { _ = try await f.controller.pendingDeviceApprovals(); XCTFail("Unjoined subject must not list member requests") }
        catch { XCTAssertEqual(error as? AccountGroupEnrollmentError, .conflict) }
        let baselineLists = await f.service.calls.filter { $0 == "list" }.count
        let m = MobileAccountApprovalModel(controller: f.controller)
        await m.refresh()
        XCTAssertEqual(m.phase, .ready, "Own request entry must not invoke member-only list")
        guard m.phase == .ready else { return }
        await m.prepareJoin(); await m.accept(id: try XCTUnwrap(m.confirmation).id)?.value
        let request = try XCTUnwrap(m.detail).summary.requestID
        let restarted = f.reconstructed(); await restarted.restore()
        let recovered = MobileAccountApprovalModel(controller: restarted)
        await recovered.refresh()
        XCTAssertEqual(recovered.phase, .ready); XCTAssertEqual(recovered.recoveryRequestIDs, [request])
        XCTAssertTrue(recovered.requests.isEmpty)
        let writes = await f.intents.writes
        await recovered.open(requestID: request); await recovered.refresh()
        XCTAssertEqual(recovered.detail?.phase, .waitingForMember)
        let afterWrites = await f.intents.writes; XCTAssertEqual(afterWrites, writes)
        let calls = await f.service.calls
        XCTAssertEqual(calls.filter { $0 == "list" }.count, baselineLists)
        XCTAssertEqual(calls.filter { $0 == "create" }.count, 1)
        let pins = await f.group.checkpoints.writes; XCTAssertEqual(pins, 0)
        await f.intents.protect(true); await recovered.refresh()
        XCTAssertEqual(recovered.phase, .secureStorageError, "Own scope must not hide storage failure")
    }
    func testAccountReplacementCannotReceiveFormerGatedCompletion() async throws {
        let first = try AccountApprovalEvidenceFixture(), second = try AccountApprovalEvidenceFixture()
        let loader = ApprovalControllerLoader(first.controller)
        let account = MobileAccountModel(loadController: { await loader.load() }, apple: ApprovalTestApple())
        await account.load()
        let old = try XCTUnwrap(account.approvals); await old.refresh(); await old.prepareJoin()
        let gate = GroupEvidenceGate(); await first.service.gate("create", gate)
        let accepted = old.accept(id: try XCTUnwrap(old.confirmation).id)
        await entered(gate)
        await loader.set(second.controller); await account.load()
        let current = try XCTUnwrap(account.approvals)
        XCTAssertFalse(current === old)
        await gate.release(); await accepted?.value
        XCTAssertNil(old.detail)
        await current.refresh(); XCTAssertTrue(current.requests.isEmpty); XCTAssertNil(current.detail)
    }
    func testOldScreenDisappearanceCannotClearReturnedList() async throws {
        let f = try AccountApprovalEvidenceFixture(); await f.controller.restore()
        let m = MobileAccountApprovalModel(controller: f.controller)
        let list = UUID(), detail = UUID()
        m.beginPresentation(owner: detail); await m.refresh()
        m.beginPresentation(owner: list); await m.open(requestID: nil)
        m.leave(owner: detail)
        XCTAssertEqual(m.phase, .ready)
    }
    func testAccountNavigationCancelPreservesChildAndLogoutFencesGatedCreate() async throws {
        let f = try AccountApprovalEvidenceFixture()
        let account = MobileAccountModel(loadController: { f.controller }, apple: ApprovalTestApple())
        await account.load()
        let m = try XCTUnwrap(account.approvals)
        await m.refresh(); await m.prepareJoin()
        account.cancel() // Parent disappearance on navigation must not dismiss the child.
        let choice = try XCTUnwrap(m.confirmation)
        let gate = GroupEvidenceGate(); await f.service.gate("create", gate)
        let operation = m.accept(id: choice.id)
        await entered(gate)
        await account.signOut()
        XCTAssertNil(account.approvals)
        await gate.release(); await operation?.value
        XCTAssertNil(m.detail); XCTAssertNil(m.confirmation)
        await m.refresh(); XCTAssertEqual(m.phase, .disabled)
    }

    func testExpiredAndWrongTicketDoNotCreate() async throws {
        let f = try AccountApprovalEvidenceFixture(); await f.controller.restore()
        let m = MobileAccountApprovalModel(controller: f.controller); await m.refresh(); await m.prepareJoin()
        let choice = try XCTUnwrap(m.confirmation)
        XCTAssertNil(m.accept(id: UUID()))
        f.clock.advance(301); await m.accept(id: choice.id)?.value
        XCTAssertEqual(m.phase, .unavailable)
        let calls = await f.service.calls; XCTAssertFalse(calls.contains("create"))
    }

    func testBothDeviceModelsRequireIndependentCodesAndHistoricalRecoveryIsVerificationOnly() async throws {
        let actor = try AccountApprovalEvidenceFixture(member: true)
        let anchor = await actor.service.history[0]
        let subject = try AccountApprovalEvidenceFixture(anchor: anchor)
        _ = try await AccountGroupHistoryVerifier(storage: actor.group.checkpoints).confirm(anchor: anchor,
            expectedAccountID: anchor.accountID, expectedGroupID: anchor.groupID, expectedGeneration: 1,
            expectedAnchorHash: anchor.digest(), binding: actor.group.binding)
        await actor.controller.restore(); await subject.controller.restore()
        let a = MobileAccountApprovalModel(controller: actor.controller), s = MobileAccountApprovalModel(controller: subject.controller)
        await s.refresh(); await s.prepareJoin(); await s.accept(id: try XCTUnwrap(s.confirmation).id)?.value
        let requestID = try XCTUnwrap(s.detail).summary.requestID
        let request = try await subject.service.groupJoin(accessToken: "", accountID: anchor.accountID, requestID: requestID)
        await actor.service.set(request); await a.open(requestID: requestID)
        await a.prepareApproval(code: "wrong-independent-code")
        await a.accept(id: try XCTUnwrap(a.confirmation).id)?.value
        let noSign = await actor.intents.writes; XCTAssertEqual(noSign, 0)
        let noPropose = await actor.service.calls; XCTAssertFalse(noPropose.contains("propose"))
        await a.refresh(); await a.prepareApproval(code: try XCTUnwrap(s.detail?.requestCode))
        await a.accept(id: try XCTUnwrap(a.confirmation).id)?.value
        XCTAssertEqual(a.detail?.phase, .waitingForSubject)
        let capsule = try XCTUnwrap(a.detail?.memberCode)
        let proposal = try await actor.service.groupJoin(accessToken: "", accountID: anchor.accountID, requestID: requestID)
        await subject.service.set(proposal); await s.refresh()
        await s.prepareSubject(code: capsule); await s.accept(id: try XCTUnwrap(s.confirmation).id)?.value
        XCTAssertEqual(s.detail?.phase, .waitingForActor)
        let countersigned = try await subject.service.groupJoin(accessToken: "", accountID: anchor.accountID, requestID: requestID)
        await actor.service.set(countersigned); await a.resume()
        XCTAssertEqual(a.detail?.phase, .joined)
        let committed = try await actor.service.groupJoin(accessToken: "", accountID: anchor.accountID, requestID: requestID)
        await subject.service.set(committed); await subject.service.setHistory(await actor.service.history)
        await s.refresh(); XCTAssertEqual(s.detail?.phase, .verifyingHistory)
        let unpinned = await subject.group.checkpoints.writes; XCTAssertEqual(unpinned, 0)
        subject.clock.advance(301)
        let restartedController = subject.reconstructed(); await restartedController.restore()
        let recovered = MobileAccountApprovalModel(controller: restartedController)
        let retainedWrites = await subject.intents.writes
        await recovered.refresh()
        XCTAssertEqual(recovered.recoveryRequestIDs, [requestID])
        XCTAssertTrue(recovered.requests.isEmpty)
        await recovered.open(requestID: requestID)
        XCTAssertEqual(recovered.detail?.phase, .verifyingHistory)
        let afterReadWrites = await subject.intents.writes; XCTAssertEqual(afterReadWrites, retainedWrites)
        let afterReadPins = await subject.group.checkpoints.writes; XCTAssertEqual(afterReadPins, 0)
        await recovered.prepareSubject(code: capsule)
        let choice = try XCTUnwrap(recovered.confirmation)
        if case .ticket(let ticket, _) = choice.action { XCTAssertEqual(ticket.operation, .verifyCommitted) }
        else { XCTFail("Expected verification-only ticket") }
        let before = await subject.service.calls
        await recovered.accept(id: choice.id)?.value
        XCTAssertEqual(recovered.detail?.phase, .joined)
        let after = await subject.service.calls
        for operation in ["create", "propose", "countersign", "commit"] {
            XCTAssertEqual(before.filter { $0 == operation }.count, after.filter { $0 == operation }.count)
        }
    }
    func testRefreshAndDismissNeverCreateAndConfirmationIsConsumedSynchronously() async throws {
        let f = try AccountApprovalEvidenceFixture(); await f.controller.restore()
        let m = MobileAccountApprovalModel(controller: f.controller)
        await m.refresh(); XCTAssertEqual(m.phase, .ready)
        await m.prepareJoin()
        let old = try XCTUnwrap(m.confirmation)
        m.dismiss(id: old.id)
        XCTAssertNil(m.accept(id: old.id))
        await m.prepareJoin()
        let current = try XCTUnwrap(m.confirmation)
        m.dismiss(id: old.id)
        XCTAssertNotNil(m.confirmation)
        let accepted = m.accept(id: current.id)
        XCTAssertNil(m.accept(id: current.id))
        m.dismiss(id: current.id)
        await accepted?.value
        XCTAssertEqual(m.detail?.phase, .waitingForMember)
        let actionPresentation = try XCTUnwrap(m.actionPresentationID)
        await m.refresh()
        XCTAssertEqual(m.actionPresentationID, actionPresentation, "Read-only refresh must not steal scroll position")
        let calls = await f.service.calls
        XCTAssertEqual(calls.filter { $0 == "create" }.count, 1)
        XCTAssertFalse(calls.contains("cancel"))
        let writes = await f.group.checkpoints.writes; XCTAssertEqual(writes, 0)
    }

    func testDisabledCapabilityAndReadOnlyRefreshHaveNoMutation() async throws {
        let f = try AccountApprovalEvidenceFixture(enabled: false); await f.controller.restore()
        let m = MobileAccountApprovalModel(controller: f.controller)
        await m.refresh(); await m.prepareJoin()
        XCTAssertEqual(m.phase, .disabled)
        let calls = await f.service.calls; XCTAssertTrue(calls.isEmpty)
    }

    func testLostCreateAcknowledgmentResumesExactRequestOnlyExplicitly() async throws {
        let f = try AccountApprovalEvidenceFixture(); await f.controller.restore()
        let m = MobileAccountApprovalModel(controller: f.controller)
        await m.refresh(); await m.prepareJoin()
        let ticket = try XCTUnwrap(m.confirmation)
        await f.service.lose("create"); await m.accept(id: ticket.id)?.value
        XCTAssertEqual(m.phase, .unavailable)
        XCTAssertNotNil(m.selectedRequestID, "A lost acknowledgment retains a reachable explicit Resume action")
        await m.refresh()
        let request = try XCTUnwrap(m.recoveryRequestIDs.first)
        await m.open(requestID: request)
        let before = await f.service.calls.filter { $0 == "create" }.count
        XCTAssertEqual(before, 1)
        await m.resume()
        let after = await f.service.calls.filter { $0 == "create" }.count
        XCTAssertEqual(after, 2)
        let records = await f.service.records; XCTAssertEqual(records.count, 1)
    }

    func testLeavingDuringPreparationDiscardsLateTicketWithoutCancellingRequest() async throws {
        let f = try AccountApprovalEvidenceFixture(); await f.controller.restore()
        let m = MobileAccountApprovalModel(controller: f.controller); await m.refresh()
        let gate = GroupEvidenceGate(); await f.service.gate("discover", gate)
        let pending = Task { await m.prepareJoin() }
        await entered(gate)
        m.leave(); await gate.release(); await pending.value
        XCTAssertNil(m.confirmation); XCTAssertNil(m.detail)
        let calls = await f.service.calls
        XCTAssertFalse(calls.contains("create")); XCTAssertFalse(calls.contains("cancel"))
    }

    func testCancellationRequiresOwnConfirmationAndSecureStorageFailureCanRetry() async throws {
        let f = try AccountApprovalEvidenceFixture(); await f.controller.restore()
        let m = MobileAccountApprovalModel(controller: f.controller); await m.refresh(); await m.prepareJoin()
        await m.accept(id: try XCTUnwrap(m.confirmation).id)?.value
        let request = try XCTUnwrap(m.detail).summary.requestID
        await m.open(requestID: request); await m.refresh()
        m.prepareCancellation()
        let first = try XCTUnwrap(m.confirmation); m.dismiss(id: first.id)
        let before = await f.service.calls; XCTAssertFalse(before.contains("cancel"))
        m.prepareCancellation(); await m.accept(id: try XCTUnwrap(m.confirmation).id)?.value
        XCTAssertEqual(m.detail?.phase, .cancelled)
        await f.intents.protect(true); await m.refresh()
        XCTAssertEqual(m.phase, .secureStorageError)
        await f.intents.protect(false); await m.refresh(); XCTAssertEqual(m.phase, .ready)
    }
    func testMemberRejectionRequiresConfirmationAndAcceptsExactlyOnce() async throws {
        let f = try await AccountApprovalEvidenceFixture.memberEvidence(proposed: false)
        let m = MobileAccountApprovalModel(controller: f.controller)
        m.beginPresentation(owner: UUID(), readScope: .memberRequests)
        await m.refresh()
        let request = try XCTUnwrap(m.requests.first).requestID
        await m.open(requestID: request)
        m.prepareRejection()
        let dismissed = try XCTUnwrap(m.confirmation)
        m.dismiss(id: dismissed.id)
        XCTAssertNil(m.accept(id: dismissed.id))
        let before = await f.service.calls
        XCTAssertEqual(before.filter { $0 == "reject" }.count, 0)
        m.prepareRejection()
        let accepted = try XCTUnwrap(m.confirmation)
        let operation = try XCTUnwrap(m.accept(id: accepted.id))
        XCTAssertNil(m.accept(id: accepted.id))
        await operation.value
        XCTAssertEqual(m.detail?.phase, .rejected)
        let after = await f.service.calls
        XCTAssertEqual(after.filter { $0 == "reject" }.count, 1)
    }
    func testMemberReadScopePreservesDenialAndTransportErrorsAndClearsOnLeave() async throws {
        let member = try AccountApprovalEvidenceFixture(member: true); await member.controller.restore()
        let m = MobileAccountApprovalModel(controller: member.controller)
        let owner = UUID(); m.beginPresentation(owner: owner, readScope: .memberRequests)
        await m.refresh(); XCTAssertEqual(m.phase, .ready)
        let listed = await member.service.calls.filter { $0 == "list" }.count; XCTAssertEqual(listed, 1)
        await member.service.lose("list"); await m.refresh()
        XCTAssertEqual(m.phase, .unavailable); XCTAssertNotNil(m.messageKey)
        await m.refresh(); XCTAssertEqual(m.phase, .ready)
        m.leave(owner: owner); XCTAssertEqual(m.readScope, .ownRequests)
        let before = await member.service.calls.filter { $0 == "list" }.count
        await m.refresh()
        let after = await member.service.calls.filter { $0 == "list" }.count; XCTAssertEqual(after, before)

        let subject = try AccountApprovalEvidenceFixture(); await subject.controller.restore()
        let denied = MobileAccountApprovalModel(controller: subject.controller)
        denied.beginPresentation(owner: UUID(), readScope: .memberRequests)
        await denied.refresh()
        XCTAssertEqual(denied.phase, .unavailable, "A member-route409 must not become ready")
        XCTAssertNotNil(denied.messageKey)
        denied.leave(); await denied.refresh(); XCTAssertEqual(denied.phase, .ready)
    }
    private func entered(_ gate: GroupEvidenceGate) async {
        for _ in 0..<200 {
            if await gate.entered { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected gated dependency within two seconds"); await gate.release()
    }
}

@MainActor private final class ApprovalTestApple: MobileAppleAuthorizing {
    func authorize(attempt: AccountLoginAttempt, anchor: UIWindow) throws -> MobileAppleCredential { throw CancellationError() }
    func cancel() {}
}

private actor ApprovalControllerLoader {
    var controller: AccountSessionController
    init(_ controller: AccountSessionController) { self.controller = controller }
    func load() -> AccountSessionController { controller }
    func set(_ controller: AccountSessionController) { self.controller = controller }
}
