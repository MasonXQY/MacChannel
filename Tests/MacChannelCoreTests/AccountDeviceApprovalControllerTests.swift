import Foundation
import XCTest
@testable import MacChannelCore

final class AccountDeviceApprovalControllerTests: XCTestCase, @unchecked Sendable {
    func testRetainedDiscoveryAfterCommittedRestartIsReadOnlyAndStorageFailureIsNotEmpty() async throws {
        let pair = try await completedPair()
        let f = pair.subject
        f.clock.advance(301)
        let restarted = f.reconstructed(); await restarted.restore()
        let calls = await f.service.calls, writes = f.secret.writes, pins = f.pins.writes
        let ids = try await restarted.retainedDeviceApprovalRequestIDs()
        XCTAssertEqual(ids, [pair.receipt.summary.requestID])
        let after = await f.service.calls
        XCTAssertEqual(after, calls); XCTAssertEqual(f.secret.writes, writes); XCTAssertEqual(f.pins.writes, pins)
        let read = try await restarted.deviceApproval(requestID: ids[0])
        XCTAssertEqual(read.phase, .verifyingHistory); XCTAssertNil(read.snapshot)
        f.secret.failReads(true)
        do { _ = try await restarted.retainedDeviceApprovalRequestIDs(); XCTFail("Protected storage appeared empty") }
        catch { XCTAssertEqual(error as? AccountDeviceApprovalValueError, .secureStorage) }
        XCTAssertEqual(f.secret.writes, writes); XCTAssertEqual(f.pins.writes, pins)
    }

    func testRetainedDiscoveryRejectsForeignAndOverCapacityStorageResponses() async throws {
        let pair = try await completedPair()
        let foreign = try await pair.actor.intents.list(binding: pair.actor.binding, accountID: groupAccount)
        await pair.subject.intents.overrideList(foreign)
        await approvalFailure(.secureStorage) { try await pair.subject.controller.retainedDeviceApprovalRequestIDs() }
        await pair.subject.intents.overrideList(Array(repeating: foreign[0], count: 33))
        await approvalFailure(.secureStorage) { try await pair.subject.controller.retainedDeviceApprovalRequestIDs() }
    }

    func testReceiptExpiryKnownSubjectTimesCannotBeSubstitutedBeforeSigning() async throws {
        for delta: Int64 in [-300_001, -1_000, 1_000] {
            let f = try await approvalAwaitingSubject()
            let changed = try approvalReceipt(f.proposal, createdAtMilliseconds: UInt64(2_000_000_000_000 + delta))
            await f.subject.service.set(changed)
            let writes = f.subject.secret.writes, calls = await f.subject.service.calls
            await approvalFailure(.requestConflict) { try await f.subject.controller.confirmDeviceJoinConfirmation(ticketID: f.ticket.id) }
            let after = await f.subject.service.calls
            XCTAssertEqual(f.subject.secret.writes, writes)
            XCTAssertEqual(after.filter { $0 == "countersign" }.count, calls.filter { $0 == "countersign" }.count)
            XCTAssertEqual(after.filter { $0 == "history" }.count, calls.filter { $0 == "history" }.count,
                "Substituted acknowledgment must be rejected at refetch before later dependencies")
        }
    }

    func testReceiptExpiryLostAcknowledgmentCannotPersistSignedProofAfterLearningExpiredTime() async throws {
        let f = try await approvalAwaitingSubject(lostCreateAcknowledgment: true)
        let before = try await f.subject.intents.list(binding: f.subject.binding, accountID: groupAccount)
        XCTAssertNil(before.first?.acknowledgment)
        await f.subject.service.set(try approvalReceipt(f.proposal, createdAtMilliseconds: 1_999_999_699_999))
        let writes = f.subject.secret.writes
        do { _ = try await f.subject.controller.confirmDeviceJoinConfirmation(ticketID: f.ticket.id); XCTFail("Expired receipt") } catch {}
        let after = try await f.subject.intents.list(binding: f.subject.binding, accountID: groupAccount)
        XCTAssertEqual(f.subject.secret.writes, writes, "Expired receipt must not persist the signed phase")
        XCTAssertTrue(after == before, "Exact original unsigned intent must remain")
        let calls = await f.subject.service.calls; XCTAssertFalse(calls.contains("countersign"))
    }

    func testReceiptExpiryNewEarlierDeadlineSurvivesSuspendedHistory() async throws {
        let f = try await approvalAwaitingSubject(lostCreateAcknowledgment: true)
        await f.subject.service.set(try approvalReceipt(f.proposal, createdAtMilliseconds: 1_999_999_705_000))
        let gate = ApprovalGate(), writes = f.subject.secret.writes
        await f.subject.service.gate("history", gate)
        let task = Task { try await f.subject.controller.confirmDeviceJoinConfirmation(ticketID: f.ticket.id) }
        await gate.wait()
        f.subject.clock.advance(6)
        await gate.release()
        do { _ = try await task.value; XCTFail("Newly learned deadline expired during history") } catch {}
        XCTAssertEqual(f.subject.secret.writes, writes)
        let records = try await f.subject.intents.list(binding: f.subject.binding, accountID: groupAccount)
        guard case .active(.subjectRequested) = records.first?.phase else { return XCTFail("Expired consent signed") }
        let calls = await f.subject.service.calls; XCTAssertFalse(calls.contains("countersign"))
    }

    func testReceiptExpiryActorRefetchRejectsEarlierAndLaterTimesBeforeCommit() async throws {
        for delta: Int64 in [-300_001, -1_000, 1_000] {
            let f = try await approvalAwaitingSubject()
            _ = try await f.subject.controller.confirmDeviceJoinConfirmation(ticketID: f.ticket.id)
            let signed = try await f.subject.service.groupJoin(accessToken: "", accountID: groupAccount, requestID: f.proposal.summary.requestID)
            await f.actor.service.set(try approvalReceipt(signed, createdAtMilliseconds: UInt64(2_000_000_000_000 + delta)))
            let writes = f.actor.secret.writes
            await approvalFailure(.requestConflict) { try await f.actor.controller.resumeDeviceApproval(requestID: signed.summary.requestID) }
            let calls = await f.actor.service.calls
            XCTAssertFalse(calls.contains("commit"), "Changed acknowledgment reached Commit")
            XCTAssertEqual(f.actor.secret.writes, writes)
        }
    }
    func testCodeLessCommittedReadNeverPublishesMembershipEvenWithRetainedProof() async throws {
        let pair = try await completedPair()
        let pins = pair.actor.pins.writes, intents = pair.actor.secret.writes
        let view = try await pair.actor.controller.deviceApproval(requestID: pair.receipt.summary.requestID)
        XCTAssertEqual(view.phase, .verifyingHistory)
        XCTAssertNil(view.snapshot)
        XCTAssertEqual(pair.actor.pins.writes, pins); XCTAssertEqual(pair.actor.secret.writes, intents)
    }
    func testSessionRotationCannotResumeUnfinishedConsentOrCreateMissingPin() async throws {
        let pair = try await completedPair()
        let writes = pair.subject.secret.writes, calls = await pair.subject.service.calls
        await pair.subject.service.rotateSession(); try await pair.subject.controller.refresh()
        _ = try await pair.subject.controller.resumeDeviceApproval(requestID: pair.receipt.summary.requestID)
        let after = await pair.subject.service.calls
        XCTAssertEqual(after.filter { $0 == "countersign" }.count, calls.filter { $0 == "countersign" }.count)
        XCTAssertEqual(pair.subject.secret.writes, writes); XCTAssertEqual(pair.subject.pins.writes, 0)
    }

    func testCurrentMemberMayRejectWithoutCreatingApprovalIntent() async throws {
        let member = try DeviceIdentity.ephemeral(), anchor = try approvalAnchor(member)
        let actor = try ApprovalControllerFixture(identity: member, history: [anchor])
        let subject = try ApprovalControllerFixture(history: [anchor])
        await actor.controller.restore(); await subject.controller.restore()
        _ = try await actor.verifier.confirm(anchor: anchor, expectedAccountID: groupAccount, expectedGroupID: groupID,
            expectedGeneration: 1, expectedAnchorHash: anchor.digest(), binding: actor.binding)
        let ticket = try await subject.controller.prepareDeviceJoin()
        let request = try await subject.controller.confirmDeviceJoin(ticketID: ticket.id)
        await actor.service.set(try await subject.service.groupJoin(accessToken: "", accountID: groupAccount, requestID: request.summary.requestID))
        let result = try await actor.controller.rejectDeviceJoin(requestID: request.summary.requestID)
        XCTAssertEqual(result.phase, .rejected); XCTAssertEqual(actor.secret.writes, 0)
    }

    func testMemberPreparationSuspensionCannotSurviveRefreshOrCreateConsent() async throws {
        let member = try DeviceIdentity.ephemeral(), anchor = try approvalAnchor(member)
        let actor = try ApprovalControllerFixture(identity: member, history: [anchor])
        let subject = try ApprovalControllerFixture(history: [anchor])
        await actor.controller.restore(); await subject.controller.restore()
        _ = try await actor.verifier.confirm(anchor: anchor, expectedAccountID: groupAccount, expectedGroupID: groupID,
            expectedGeneration: 1, expectedAnchorHash: anchor.digest(), binding: actor.binding)
        let ticket = try await subject.controller.prepareDeviceJoin()
        let request = try await subject.controller.confirmDeviceJoin(ticketID: ticket.id)
        await actor.service.set(try await subject.service.groupJoin(accessToken: "", accountID: groupAccount, requestID: request.summary.requestID))
        let gate = ApprovalGate(); await actor.service.gate("history", gate)
        let task = Task { try await actor.controller.prepareDeviceApproval(requestID: request.summary.requestID) }
        await gate.wait(); try await actor.controller.refresh(); await gate.release()
        do { _ = try await task.value; XCTFail("Old preparation published") } catch {}
        XCTAssertEqual(actor.secret.writes, 0); XCTAssertEqual(actor.pins.writes, 1)
        let calls = await actor.service.calls; XCTAssertFalse(calls.contains("propose"))
    }
    func testSubstitutedFinalizedEventCannotReplaceRetainedSubjectProof() async throws {
        let pair = try await completedPair()
        let original = pair.receipt.event!
        let alternate = try pair.receipt.draft!.finalize(subjectSignature: pair.subject.identity.sign(original.canonicalPayload()).derRepresentation)
        XCTAssertFalse(alternate == original)
        let receipt = try AccountGroupPendingRequest(summary: pair.receipt.summary, draft: pair.receipt.draft,
            event: alternate, eventHash: alternate.digest())
        await pair.subject.service.set(receipt)
        let anchor = await pair.actor.service.history[0]
        await pair.subject.service.setHistory([anchor, alternate])
        await approvalFailure(.requestConflict) { try await pair.subject.controller.deviceApproval(requestID: receipt.summary.requestID) }
        XCTAssertEqual(pair.subject.pins.writes, 0)
    }
    func testHistoricalTerminalResumeCannotAdvanceCheckpointWithoutNewConsent() async throws {
        let pair = try await completedPair()
        var events = await pair.actor.service.history
        events.append(try removal(pair.actor.identity, subject: pair.subject.identity, previous: events.last!))
        await pair.actor.service.setHistory(events)
        pair.actor.clock.advance(301)
        let writes = pair.actor.pins.writes
        let view = try await pair.actor.controller.resumeDeviceApproval(requestID: pair.receipt.summary.requestID)
        XCTAssertEqual(view.snapshot?.sequence, 3)
        XCTAssertEqual(pair.actor.pins.writes, writes)
    }

    func testCommittedCapsuleSubstitutionCannotInstallPin() async throws {
        let pair = try await completedPair()
        let f = try ApprovalControllerFixture(identity: pair.subject.identity, history: await pair.actor.service.history)
        await f.service.set(pair.receipt); await f.controller.restore()
        let alternate = try AccountDeviceApprovalCapsule(origin: f.binding.origin, requestID: pair.receipt.summary.requestID,
            draft: pair.receipt.draft!, expectedAnchorHash: Data(repeating: 7, count: 32))
        do { _ = try await f.controller.prepareDeviceJoinConfirmation(requestID: pair.receipt.summary.requestID, memberCode: alternate.code); XCTFail("Alternate anchor") } catch {}
        await approvalFailure(.verificationMismatch) {
            try await f.controller.prepareDeviceJoinConfirmation(requestID: pair.receipt.summary.requestID, memberCode: "DMJA1:invalid")
        }
        XCTAssertEqual(f.pins.writes, 0); XCTAssertEqual(f.secret.writes, 0)
    }

    func testExistingRequestNeverRefreshesAndDismissedTicketCannotMutate() async throws {
        let f = try ApprovalControllerFixture(); await f.controller.restore()
        let ticket = try await f.controller.prepareDeviceJoin()
        await f.controller.dismissDeviceApprovalTicket(ticketID: ticket.id)
        await approvalFailure(.invalidTicket) { try await f.controller.confirmDeviceJoin(ticketID: ticket.id) }
        f.clock.advance(601)
        do { _ = try await f.controller.deviceApproval(requestID: ticket.presentation.requestID); XCTFail("Expired access") } catch {}
        let calls = await f.service.calls
        XCTAssertFalse(calls.contains("refresh")); XCTAssertEqual(f.secret.writes, 0)
    }

    func testLostCancellationRetainsAbandonmentUntilAcknowledged() async throws {
        let f = try ApprovalControllerFixture(); await f.controller.restore()
        let ticket = try await f.controller.prepareDeviceJoin()
        _ = try await f.controller.confirmDeviceJoin(ticketID: ticket.id)
        await f.service.lose("cancel")
        do { _ = try await f.controller.cancelDeviceJoin(requestID: ticket.presentation.requestID); XCTFail("Lost acknowledgment") } catch {}
        let records = try await f.intents.list(binding: f.binding, accountID: groupAccount)
        guard case .terminal(_, .locallyAbandoned) = records.first?.phase else { return XCTFail("Uncertainty was discarded") }
        await approvalFailure(.requestConflict) { try await f.controller.prepareDeviceJoin() }
        _ = try await f.controller.resumeDeviceApproval(requestID: ticket.presentation.requestID)
        let after = try await f.intents.list(binding: f.binding, accountID: groupAccount)
        XCTAssertTrue(after.isEmpty)
    }
    func testLifecycleFencesEveryCreateStorageAndNetworkBoundary() async throws {
        for stage in ["list", "insert", "create", "replace"] {
            for change in ["logout", "refresh", "cancel"] {
                let f = try ApprovalControllerFixture(); await f.controller.restore()
                let ticket = try await f.controller.prepareDeviceJoin(), gate = ApprovalGate()
                if stage == "create" { await f.service.gate(stage, gate) }
                else { await f.intents.gate(stage, gate) }
                let task = Task { try await f.controller.confirmDeviceJoin(ticketID: ticket.id) }
                await gate.wait()
                let callsBefore = await f.service.calls
                switch change {
                case "logout": try await f.controller.logout()
                case "refresh": try await f.controller.refresh()
                default:
                    do { _ = try await f.controller.cancelDeviceJoin(requestID: ticket.presentation.requestID); XCTFail("Admission released") }
                    catch { XCTAssertEqual(error as? AccountSessionControllerError, .busy) }
                }
                await approvalFailure(.invalidTicket) { try await f.controller.confirmDeviceJoin(ticketID: ticket.id) }
                await gate.release()
                do { _ = try await task.value; XCTFail("Stale result at \(stage)/\(change)") } catch {}
                let calls = await f.service.calls
                XCTAssertEqual(calls.filter { $0 == "create" }.count, callsBefore.filter { $0 == "create" }.count)
                XCTAssertEqual(f.pins.writes, 0)
            }
        }
    }

    func testHistoricalRecoveryLifecycleFencesHistoryAndNestedCheckpointBoundaries() async throws {
        let pair = try await completedPair()
        for stage in ["get", "history", "inspect-load", "accept-load", "confirm-load", "confirm-save"] {
            let f = try ApprovalControllerFixture(identity: pair.subject.identity, history: await pair.actor.service.history)
            await f.service.set(pair.receipt); await f.controller.restore()
            let ticket = try await f.controller.prepareDeviceJoinConfirmation(requestID: pair.receipt.summary.requestID, memberCode: pair.code)
            let gate = ApprovalGate()
            switch stage {
            case "get", "history": await f.service.gate(stage, gate)
            case "inspect-load": await f.checkpoint.gate("load", gate)
            case "accept-load": await f.checkpoint.gate("load", gate, skip: 1)
            case "confirm-load": await f.checkpoint.gate("load", gate, skip: 2)
            default: await f.checkpoint.gate("save", gate)
            }
            let task = Task { try await f.controller.confirmDeviceJoinConfirmation(ticketID: ticket.id) }
            await gate.wait()
            try await f.controller.refresh()
            await gate.release()
            do { _ = try await task.value; XCTFail("Stale recovery at \(stage)") } catch {}
            XCTAssertEqual(f.pins.writes, stage == "confirm-save" ? 1 : 0)
        }
    }

    func testCancelCommitRaceIsNeverReportedAsCancellation() async throws {
        let pair = try await completedPair()
        let view = try await pair.subject.controller.cancelDeviceJoin(requestID: pair.receipt.summary.requestID)
        XCTAssertNotEqual(view.phase, .cancelled)
        XCTAssertEqual(pair.subject.pins.writes, 0)
    }
    func testResumeExpiryDuringNoncooperativeHTTPDiscardsReceiptAndDoesNotPin() async throws {
        let pair = try await completedPair(), gate = ApprovalGate()
        await pair.subject.service.gate("countersign", gate)
        let task = Task { try await pair.subject.controller.resumeDeviceApproval(requestID: pair.receipt.summary.requestID) }
        await gate.wait()
        pair.subject.clock.advance(301)
        await gate.release()
        do { _ = try await task.value; XCTFail("Expired retained consent published") } catch {}
        XCTAssertEqual(pair.subject.pins.writes, 0)
    }
    func testTwoDevicesRequireBothIndependentConfirmationsAndExactRetries() async throws {
        for loss in ["none", "propose", "countersign", "commit"] {
            let pair = try await completedPair(loss: loss)
            XCTAssertEqual(pair.view.phase, .joined)
            let subjectView = try await pair.subject.controller.resumeDeviceApproval(requestID: pair.receipt.summary.requestID)
            XCTAssertEqual(subjectView.phase, .joined)
            XCTAssertEqual(subjectView.snapshot?.members.count, 2)
            let subjectIntents = try await pair.subject.intents.list(binding: pair.subject.binding, accountID: groupAccount)
            guard case .subjectCountersigned(_, let signed) = subjectIntents.first?.activePredecessor else { return XCTFail("Exact final proof lost") }
            XCTAssertTrue(signed == pair.receipt.event)
        }
    }

    func testHistoricalCommittedRecoveryUsesFreshTicketAndDoesNotMutateRequest() async throws {
        let pair = try await completedPair()
        for removed in [false, true] {
            var events = await pair.actor.service.history
            if removed { events.append(try removal(pair.actor.identity, subject: pair.subject.identity, previous: events.last!)) }
            let f = try ApprovalControllerFixture(identity: pair.subject.identity, history: events)
            f.clock.advance(301)
            await f.service.set(pair.receipt); await f.controller.restore()
            let read = try await f.controller.deviceApproval(requestID: pair.receipt.summary.requestID)
            XCTAssertEqual(read.phase, .verifyingHistory); XCTAssertEqual(f.pins.writes, 0)
            let ticket = try await f.controller.prepareDeviceJoinConfirmation(requestID: pair.receipt.summary.requestID, memberCode: pair.code)
            XCTAssertEqual(ticket.operation, .verifyCommitted)
            XCTAssertEqual(ticket.expiresAt, f.tokens.accessExpiresAt)
            XCTAssertEqual(f.pins.writes, 0)
            let result = try await f.controller.confirmDeviceJoinConfirmation(ticketID: ticket.id)
            XCTAssertEqual(result.phase, removed ? .removed : .joined)
            XCTAssertEqual(f.secret.writes, 0)
            let calls = await f.service.calls
            XCTAssertFalse(calls.contains { ["create", "propose", "countersign", "commit"].contains($0) })
            await approvalFailure(.invalidTicket) { try await f.controller.confirmDeviceJoinConfirmation(ticketID: ticket.id) }
        }
    }

    func testTicketKindsMutualExclusionAndRefreshInvalidation() async throws {
        let f = try ApprovalControllerFixture(); await f.controller.restore()
        await f.service.setAbsent(true)
        let first = try await f.controller.prepareFirstDeviceJoin()
        await f.service.setAbsent(false)
        let second = try await f.controller.prepareDeviceJoin()
        await enrollmentFailure(.invalidAttempt) { try await f.controller.confirmFirstDeviceJoin(attemptID: first) }
        await approvalFailure(.invalidTicket) { try await f.controller.confirmDeviceApproval(ticketID: second.id, joiningCode: "") }
        await f.service.setAbsent(true)
        _ = try await f.controller.prepareFirstDeviceJoin()
        await approvalFailure(.invalidTicket) { try await f.controller.confirmDeviceJoin(ticketID: second.id) }
        await f.service.setAbsent(false)
        let third = try await f.controller.prepareDeviceJoin()
        try await f.controller.refresh()
        await approvalFailure(.invalidTicket) { try await f.controller.confirmDeviceJoin(ticketID: third.id) }
        XCTAssertEqual(f.secret.writes, 0)
    }

    func testCancelDuringSuspendedCreateRevokesAllLaterWorkAndRetainsUncertainty() async throws {
        let f = try ApprovalControllerFixture(); await f.controller.restore()
        let ticket = try await f.controller.prepareDeviceJoin(), gate = ApprovalGate()
        await f.service.gate("create", gate)
        let task = Task { try await f.controller.confirmDeviceJoin(ticketID: ticket.id) }
        await gate.wait()
        do { _ = try await f.controller.cancelDeviceJoin(requestID: ticket.presentation.requestID); XCTFail("Must retain admission") }
        catch { XCTAssertEqual(error as? AccountSessionControllerError, .busy) }
        await gate.release()
        do { _ = try await task.value; XCTFail("Cancelled operation published") } catch {}
        let intents = try await f.intents.list(binding: f.binding, accountID: groupAccount)
        XCTAssertEqual(intents.count, 1); XCTAssertNil(intents[0].acknowledgment)
        let cancelled = try await f.controller.cancelDeviceJoin(requestID: ticket.presentation.requestID)
        XCTAssertEqual(cancelled.phase, .cancelled)
        let retained = try await f.intents.list(binding: f.binding, accountID: groupAccount)
        XCTAssertTrue(retained.isEmpty)
    }

    private func completedPair(loss: String = "none") async throws -> (actor: ApprovalControllerFixture, subject: ApprovalControllerFixture, receipt: AccountGroupPendingRequest, code: String, view: AccountDeviceApprovalView) {
        let member = try DeviceIdentity.ephemeral(), anchor = try approvalAnchor(member)
        let actor = try ApprovalControllerFixture(identity: member, history: [anchor])
        let subject = try ApprovalControllerFixture(history: [anchor])
        await actor.controller.restore(); await subject.controller.restore()
        _ = try await actor.verifier.confirm(anchor: anchor, expectedAccountID: groupAccount, expectedGroupID: groupID,
            expectedGeneration: 1, expectedAnchorHash: anchor.digest(), binding: actor.binding)
        let ticket = try await subject.controller.prepareDeviceJoin()
        let joining = try await subject.controller.confirmDeviceJoin(ticketID: ticket.id)
        let id = joining.summary.requestID
        let requested = try await subject.service.groupJoin(accessToken: "", accountID: groupAccount, requestID: id)
        await actor.service.set(requested)
        let wrong = try await actor.controller.prepareDeviceApproval(requestID: id)
        await approvalFailure(.verificationMismatch) { try await actor.controller.confirmDeviceApproval(ticketID: wrong.id, joiningCode: "DMJR1-0000") }
        XCTAssertEqual(actor.secret.writes, 0)
        let approval = try await actor.controller.prepareDeviceApproval(requestID: id)
        if loss == "propose" { await actor.service.lose("propose") }
        let proposed: AccountDeviceApprovalView
        if loss == "propose" {
            do { _ = try await actor.controller.confirmDeviceApproval(ticketID: approval.id, joiningCode: joining.requestCode!); XCTFail("Lost acknowledgment") } catch {}
            proposed = try await actor.controller.resumeDeviceApproval(requestID: id)
        } else { proposed = try await actor.controller.confirmDeviceApproval(ticketID: approval.id, joiningCode: joining.requestCode!) }
        XCTAssertEqual(proposed.phase, .waitingForSubject); XCTAssertNil(proposed.snapshot)
        let proposal = try await actor.service.groupJoin(accessToken: "", accountID: groupAccount, requestID: id)
        await subject.service.set(proposal)
        let before = subject.secret.writes
        let confirmation = try await subject.controller.prepareDeviceJoinConfirmation(requestID: id, memberCode: proposed.memberCode!)
        XCTAssertEqual(subject.secret.writes, before); XCTAssertEqual(subject.pins.writes, 0)
        if loss == "countersign" { await subject.service.lose("countersign") }
        let signed: AccountDeviceApprovalView
        if loss == "countersign" {
            do { _ = try await subject.controller.confirmDeviceJoinConfirmation(ticketID: confirmation.id); XCTFail("Lost acknowledgment") } catch {}
            signed = try await subject.controller.resumeDeviceApproval(requestID: id)
        } else { signed = try await subject.controller.confirmDeviceJoinConfirmation(ticketID: confirmation.id) }
        XCTAssertEqual(signed.phase, .waitingForActor); XCTAssertEqual(subject.pins.writes, 0)
        let countersigned = try await subject.service.groupJoin(accessToken: "", accountID: groupAccount, requestID: id)
        await actor.service.set(countersigned)
        if loss == "commit" { await actor.service.lose("commit") }
        let joined: AccountDeviceApprovalView
        if loss == "commit" {
            do { _ = try await actor.controller.resumeDeviceApproval(requestID: id); XCTFail("Lost acknowledgment") } catch {}
            joined = try await actor.controller.resumeDeviceApproval(requestID: id)
        } else { joined = try await actor.controller.resumeDeviceApproval(requestID: id) }
        let receipt = try await actor.service.groupJoin(accessToken: "", accountID: groupAccount, requestID: id)
        await subject.service.set(receipt); await subject.service.setHistory(await actor.service.history)
        return (actor, subject, receipt, proposed.memberCode!, joined)
    }

    private func removal(_ actor: DeviceIdentity, subject: DeviceIdentity, previous: AccountGroupEvent) throws -> AccountGroupEvent {
        let event = try AccountGroupEvent(accountID: groupAccount, groupID: groupID, generation: 1, sequence: previous.sequence + 1,
            previousHash: previous.digest(), action: "remove", actorDeviceID: actor.id.rawValue.uuidString.lowercased(),
            actorPublicKey: actor.publicKey.rawRepresentation, subjectDeviceID: subject.id.rawValue.uuidString.lowercased(),
            subjectPublicKey: subject.publicKey.rawRepresentation, epochMilliseconds: 2_000_000_100_000)
        return try .init(canonicalPayload: event.canonicalPayload(), signature: actor.sign(event.canonicalPayload()).derRepresentation, subjectSignature: Data())
    }
    func testUnavailableNeverTouchesDependencies() async throws {
        let f = try ApprovalControllerFixture(configured: false); await f.controller.restore()
        let supported = await f.controller.supportsDeviceApproval(); XCTAssertFalse(supported)
        await approvalFailure(.unavailable) { try await f.controller.prepareDeviceJoin() }
        await approvalFailure(.unavailable) { try await f.controller.pendingDeviceApprovals() }
        let calls = await f.service.calls; XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(f.secret.writes, 0); XCTAssertEqual(f.pins.writes, 0)
    }
    func testPreparationAndReadsHaveNoDurableConsentOrPin() async throws {
        let f = try ApprovalControllerFixture(); await f.controller.restore()
        let ticket = try await f.controller.prepareDeviceJoin()
        XCTAssertEqual(ticket.operation, .requestJoin)
        XCTAssertEqual(f.secret.writes, 0); XCTAssertEqual(f.pins.writes, 0)
        let view = try await f.controller.confirmDeviceJoin(ticketID: ticket.id)
        XCTAssertEqual(view.phase, .waitingForMember)
        XCTAssertNotNil(view.requestCode); XCTAssertNil(view.snapshot)
        let writes = f.secret.writes
        _ = try await f.controller.deviceApproval(requestID: view.summary.requestID)
        _ = try await f.controller.pendingDeviceApprovals()
        XCTAssertEqual(f.secret.writes, writes); XCTAssertEqual(f.pins.writes, 0)
        await approvalFailure(.invalidTicket) { try await f.controller.confirmDeviceJoin(ticketID: ticket.id) }
    }
    func testLostCreateRetainsExactRequestAndBlocksReplacement() async throws {
        let f = try ApprovalControllerFixture(); await f.controller.restore()
        let ticket = try await f.controller.prepareDeviceJoin()
        await f.service.lose("create")
        do { _ = try await f.controller.confirmDeviceJoin(ticketID: ticket.id); XCTFail("Expected lost acknowledgment") } catch {}
        let saved = try await f.intents.list(binding: f.binding, accountID: groupAccount)
        XCTAssertEqual(saved.count, 1)
        await approvalFailure(.requestConflict) { try await f.controller.prepareDeviceJoin() }
        let restarted = f.reconstructed(); await restarted.restore()
        let view = try await restarted.resumeDeviceApproval(requestID: saved[0].scope.requestID)
        XCTAssertEqual(view.summary.requestID, saved[0].scope.requestID)
        let all = try await f.intents.list(binding: f.binding, accountID: groupAccount)
        XCTAssertEqual(all.count, 1); XCTAssertEqual(all[0].request, saved[0].request)
    }
    func testLogoutDuringCreateRetainsAdmissionAndCannotPublishOrAcknowledge() async throws {
        let f = try ApprovalControllerFixture(); await f.controller.restore()
        let ticket = try await f.controller.prepareDeviceJoin(), gate = ApprovalGate()
        await f.service.gate("create", gate)
        let task = Task { try await f.controller.confirmDeviceJoin(ticketID: ticket.id) }
        await gate.wait()
        try await f.controller.logout()
        do { _ = try await f.controller.pendingDeviceApprovals(); XCTFail("Admission released") }
        catch { XCTAssertEqual(error as? AccountSessionControllerError, .busy) }
        await gate.release()
        do { _ = try await task.value; XCTFail("Stale publication") } catch {}
        let saved = try await f.intents.list(binding: f.binding, accountID: groupAccount)
        XCTAssertNil(saved.first?.acknowledgment); XCTAssertEqual(f.pins.writes, 0)
    }
}

func approvalFailure<T>(_ expected: AccountDeviceApprovalError, file: StaticString = #filePath, line: UInt = #line,
                        _ operation: () async throws -> T) async {
    do { _ = try await operation(); XCTFail("Expected rejection", file: file, line: line) }
    catch { XCTAssertEqual(error as? AccountDeviceApprovalError, expected, file: file, line: line) }
}
