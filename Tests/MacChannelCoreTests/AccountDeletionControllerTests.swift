import XCTest
@testable import MacChannelCore

final class AccountDeletionControllerTests: XCTestCase, @unchecked Sendable {
    func testOldMinimalReceiptCannotDescribeNewSessionOrFailedNewSubmission() async throws {
        let f = try DeletionFixture(); try await f.grant()
        await f.service.setStatus(.completedManualRevocationRequired)
        let first = try await f.controller.beginDeletionReauthentication()
        _ = try await f.controller.confirmAccountDeletion(attemptID: first.id, code: "code", identityToken: "id", confirmation: true)
        let retained = await f.receipts.load()
        let login = try await f.controller.beginLogin()
        try await f.controller.completeLogin(attemptID: login.id, code: "new-code", identityToken: "id")
        let visible = await f.controller.deletionSnapshot(); XCTAssertNil(visible)
        let next = try await f.controller.beginDeletionReauthentication()
        await f.receipts.failSaves(true)
        do { _ = try await f.controller.confirmAccountDeletion(attemptID: next.id, code: "code", identityToken: "id", confirmation: true); XCTFail("save fails") } catch {}
        let snapshot = await f.controller.snapshot(); XCTAssertEqual(snapshot.phase, .secureStorageError)
        let status = await f.controller.deletionSnapshot(); XCTAssertNil(status)
        let after = await f.receipts.load(); XCTAssertEqual(after?.receipt, retained?.receipt)
        let calls = await f.service.begins; XCTAssertEqual(calls, 1)
    }
    func testRestartWithoutSessionRetainsOriginalReceiptAcrossRejectedStatusAndRecovery() async throws {
        let f = try DeletionFixture(); try await f.grant()
        let ticket = try await f.controller.beginDeletionReauthentication()
        await f.service.setFailure(true)
        do { _ = try await f.controller.confirmAccountDeletion(attemptID: ticket.id, code: "code", identityToken: "id", confirmation: true) } catch {}
        let original = await f.receipts.load()
        try await f.base.storage.remove()
        let restarted = try f.makeController(); await restarted.restore()
        do { _ = try await restarted.resumeAccountDeletion(); XCTFail("unknown receipt") } catch {}
        do { _ = try await restarted.beginLogin(); XCTFail("no session regrant") } catch {}
        let fresh = try await restarted.beginDeletionReauthentication()
        do { _ = try await restarted.confirmAccountDeletion(attemptID: fresh.id, code: "fresh", identityToken: "id", confirmation: true); XCTFail("recovery rejected") } catch {}
        let retained = await f.receipts.load()
        XCTAssertEqual(retained?.receipt, original?.receipt)
        XCTAssertEqual(retained?.accountID, original?.accountID)
        XCTAssertTrue(f.cleanupIDs.value.isEmpty)
        await f.service.setFailure(false)
        let retry = try await restarted.beginDeletionReauthentication()
        _ = try await restarted.confirmAccountDeletion(attemptID: retry.id, code: "fresh-again", identityToken: "id", confirmation: true)
        let session = try await f.base.storage.load(); XCTAssertNil(session)
    }
    func testUncertainDeletionRecoversAfterAccessExpiryWithoutRefreshingOrGrantingSession() async throws {
        let f = try DeletionFixture(access: 10); try await f.grant()
        let original = try await f.controller.beginDeletionReauthentication()
        await f.service.setFailure(true)
        do { _ = try await f.controller.confirmAccountDeletion(attemptID: original.id, code: "code", identityToken: "identity", confirmation: true) } catch {}
        f.base.clock.update { $0 = $0.addingTimeInterval(11) }
        await f.base.service.fail("refresh")
        await f.service.setFailure(false)
        await f.service.setStatus(.completed)
        let fresh: AccountDeletionAttempt
        do { fresh = try await f.controller.beginDeletionReauthentication() }
        catch { XCTFail("fresh Apple deletion recovery must not require session refresh: \(error)"); return }
        let result = try await f.controller.confirmAccountDeletion(attemptID: fresh.id, code: "fresh", identityToken: "fresh-id", confirmation: true)
        XCTAssertEqual(result, .completed)
        let recoveries = await f.service.recoveries; XCTAssertEqual(recoveries, 1)
        XCTAssertThrowsError(try f.owner.acquire(for: f.base.peer.id))
    }
    func testTerminalMustPersistBeforeEveryCleanupAttempt() async throws {
        let f = try DeletionFixture(); try await f.grant()
        let attempt = try await f.controller.beginDeletionReauthentication()
        _ = try await f.controller.confirmAccountDeletion(attemptID: attempt.id, code: "code", identityToken: "identity", confirmation: true)
        await f.service.setStatus(.completed)
        await f.receipts.failSaves(true)
        for _ in 0..<2 {
            do { _ = try await f.controller.resumeAccountDeletion(); XCTFail("terminal save must fail") } catch {}
            XCTAssertTrue(f.cleanupIDs.value.isEmpty, "cleanup cannot run before terminal persistence")
        }
        await f.receipts.failSaves(false)
        _ = try await f.controller.resumeAccountDeletion()
        XCTAssertEqual(f.cleanupIDs.value.count, 1)
    }

    func testTerminalCleanupJoinsNoncooperativeGroupWriter() async throws {
        let f = try DeletionFixture(); try await f.grant()
        let gate = NativeProducerGate()
        await f.base.service.setGate(gate, operation: "history")
        let writer = Task { try await f.controller.syncGroup(groupID: groupID) }
        await gate.entered()
        await f.service.setStatus(.completed)
        let attempt = try await f.controller.beginDeletionReauthentication()
        let deletion = Task { try await f.controller.confirmAccountDeletion(attemptID: attempt.id, code: "code", identityToken: "identity", confirmation: true) }
        for _ in 0..<1000 {
            if await f.receipts.load()?.status == .completed { break }
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(f.cleanupIDs.value.isEmpty, "an old writer must drain before removing its records")
        await gate.release()
        _ = try? await writer.value
        _ = try await deletion.value
        XCTAssertEqual(f.cleanupIDs.value.count, 1)
    }

    func testUnknownOutcomeCanOnlyRetryWithFreshConfirmationAndSameReceipt() async throws {
        let f = try DeletionFixture(); try await f.grant()
        let first = try await f.controller.beginDeletionReauthentication()
        await f.service.setFailure(true)
        do { _ = try await f.controller.confirmAccountDeletion(attemptID: first.id, code: "code", identityToken: "identity", confirmation: true) } catch {}
        let before = await awaitRecord(f.receipts)
        let restarted = try f.makeController(); await restarted.restore()
        do { _ = try await restarted.beginLogin(); XCTFail("uncertain deletion cannot sign back in") } catch {}
        await f.service.setFailure(false)
        let fresh = try await restarted.beginDeletionReauthentication()
        XCTAssertNotEqual(first.id, fresh.id)
        let result = try await restarted.confirmAccountDeletion(attemptID: fresh.id, code: "fresh-code", identityToken: "fresh-identity", confirmation: true)
        XCTAssertEqual(result, .pending)
        let after = await awaitRecord(f.receipts)
        XCTAssertEqual(after?.receipt, before?.receipt)
    }

    func testConcurrentReceiptRecoveryJoinsOneOwnedStatusRequest() async throws {
        let f = try DeletionFixture(); try await f.grant()
        let attempt = try await f.controller.beginDeletionReauthentication()
        _ = try await f.controller.confirmAccountDeletion(attemptID: attempt.id, code: "code", identityToken: "identity", confirmation: true)
        let gate = NativeProducerGate(); await f.service.setStatusGate(gate)
        let first = Task { try await f.controller.resumeAccountDeletion() }
        await gate.entered()
        let second = Task { try await f.controller.resumeAccountDeletion() }
        for _ in 0..<100 { await Task.yield() }
        await gate.release()
        _ = try await first.value; _ = try await second.value
        let polls = await f.service.polls; XCTAssertEqual(polls, 1)
    }

    func testExplicitConfirmationAndPersistBeforeBegin() async throws {
        let f = try DeletionFixture()
        try await f.grant()
        let attempt = try await f.controller.beginDeletionReauthentication()
        do { _ = try await f.controller.confirmAccountDeletion(attemptID: attempt.id, code: "code", identityToken: "identity", confirmation: false); XCTFail("unconfirmed deletion") } catch {}
        let initialCalls = await f.service.begins; XCTAssertEqual(initialCalls, 0)
        let result = try await f.controller.confirmAccountDeletion(attemptID: attempt.id, code: "code", identityToken: "identity", confirmation: true)
        XCTAssertEqual(result, .pending)
        let saved = await awaitRecord(f.receipts)
        let record = try XCTUnwrap(saved)
        XCTAssertTrue(AccountServiceClient.validToken(record.receipt))
        let persisted = await f.service.persistedBeforeBegin; XCTAssertTrue(persisted)
        XCTAssertThrowsError(try f.owner.acquire(for: f.base.peer.id))
        do { _ = try await f.controller.confirmAccountDeletion(attemptID: attempt.id, code: "code", identityToken: "identity", confirmation: true); XCTFail("duplicate callback") } catch {}
    }

    func testReceiptSaveFailureNeverSends() async throws {
        let f = try DeletionFixture(); try await f.grant()
        let attempt = try await f.controller.beginDeletionReauthentication()
        await f.receipts.failSaves(true)
        do { _ = try await f.controller.confirmAccountDeletion(attemptID: attempt.id, code: "code", identityToken: "identity", confirmation: true); XCTFail("save failed") } catch {}
        let calls = await f.service.begins; XCTAssertEqual(calls, 0)
    }

    func testCancelledPresentationCannotLoseAcceptedDeletionReceipt() async throws {
        let f = try DeletionFixture(); try await f.grant()
        let attempt = try await f.controller.beginDeletionReauthentication(), gate = NativeProducerGate()
        await f.service.setGate(gate)
        let task = Task { try await f.controller.confirmAccountDeletion(attemptID: attempt.id, code: "code", identityToken: "identity", confirmation: true) }
        await gate.entered(); task.cancel(); await gate.release()
        _ = try await task.value
        let record = await awaitRecord(f.receipts)
        XCTAssertEqual(record?.status, .pending)
    }

    func testRestartRecoversWithoutSessionAndRetriesTerminalCleanup() async throws {
        let f = try DeletionFixture(); try await f.grant()
        let attempt = try await f.controller.beginDeletionReauthentication()
        _ = try await f.controller.confirmAccountDeletion(attemptID: attempt.id, code: "code", identityToken: "identity", confirmation: true)
        await f.service.setStatus(.completedManualRevocationRequired)
        try await f.base.storage.remove() // Status recovery must not depend on any session token.
        f.cleanupFail.update { $0 = true }
        let restarted = try f.makeController()
        await restarted.restore()
        let ready = await awaitReady(restarted); XCTAssertFalse(ready)
        do { _ = try await restarted.resumeAccountDeletion(); XCTFail("cleanup failure") } catch {}
        let failedCleanup = await awaitRecord(f.receipts)
        XCTAssertEqual(failedCleanup?.status, .completedManualRevocationRequired)
        f.cleanupFail.update { $0 = false }
        let retry = try f.makeController(); await retry.restore()
        let status = await awaitStatus(retry), cleaned = await awaitRecord(f.receipts)
        XCTAssertEqual(status, .completedManualRevocationRequired)
        XCTAssertNil(cleaned?.accountID)
        let session = try await f.base.storage.load(); XCTAssertNil(session)
        XCTAssertFalse(f.cleanupIDs.value.isEmpty)
        XCTAssertTrue(f.cleanupIDs.value.allSatisfy { $0 == UUID(uuidString: groupAccount)! })
    }

    func testUnknownBeginOutcomeRetainsReceiptAndNeverRegrantsOnRestore() async throws {
        let f = try DeletionFixture(); try await f.grant()
        let attempt = try await f.controller.beginDeletionReauthentication()
        await f.service.setFailure(true)
        do { _ = try await f.controller.confirmAccountDeletion(attemptID: attempt.id, code: "code", identityToken: "identity", confirmation: true); XCTFail("network failure") } catch {}
        let receipt = await awaitRecord(f.receipts)?.receipt
        let restarted = try f.makeController(); await restarted.restore()
        let ready = await awaitReady(restarted), saved = await awaitRecord(f.receipts)
        XCTAssertFalse(ready)
        XCTAssertEqual(saved?.receipt, receipt)
    }

    func testDisabledControllerNeverIssuesDeletionChallenge() async throws {
        let f = try NativeProducerFixture(); try await f.grant()
        do { _ = try await f.controller.beginDeletionReauthentication(); XCTFail("not opted in") } catch {}
        XCTAssertNoThrow(try f.owner.acquire(for: f.peer.id))
    }
}

private func awaitRecord(_ storage: DeletionMemoryStorage) async -> AccountDeletionRecord? { await storage.load() }
private func awaitReady(_ controller: AccountSessionController) async -> Bool { await controller.isAccountRouteReady() }
private func awaitStatus(_ controller: AccountSessionController) async -> AccountDeletionStatus? { await controller.deletionSnapshot() }

private struct DeletionFixture: Sendable {
    let base: NativeProducerFixture
    let owner: PeerAuthorizationOwner
    let service: DeletionFixtureService
    let receipts: DeletionMemoryStorage
    let cleanupFail: PeerTestBox<Bool>
    let cleanupIDs: PeerTestBox<[UUID]>
    let controller: AccountSessionController
    init(access: TimeInterval = 100) throws {
        let base = try NativeProducerFixture(access: access); self.base = base
        let receipts = DeletionMemoryStorage(); self.receipts = receipts
        let service = DeletionFixtureService(base: base.service, receipts: receipts); self.service = service
        let failure = PeerTestBox(false); cleanupFail = failure
        let ids = PeerTestBox<[UUID]>([]); cleanupIDs = ids
        let owner = PeerAuthorizationOwner(local: base.local.id, now: { base.clock.value }, schedule: base.timer.schedule); self.owner = owner
        controller = try AccountSessionController(service: service, storage: base.storage, binding: base.binding,
            groupVerifier: base.verifier, peerAuthorization: AccountPeerAuthorization(owner: owner, identity: base.local, binding: base.binding, freshness: 20),
            deletion: AccountDeletionConfiguration(storage: receipts, clearAccountCheckpoints: { binding, account in
                guard binding == base.binding else { throw AccountSessionControllerError.secureStorage }
                ids.update { $0.append(account) }
                if failure.value { throw AccountSessionControllerError.secureStorage }
            }), now: { base.clock.value })
    }
    func makeController() throws -> AccountSessionController {
        AccountSessionController(service: service, storage: base.storage, binding: base.binding,
            deletion: AccountDeletionConfiguration(storage: receipts, clearAccountCheckpoints: { binding, account in
                guard binding == base.binding else { throw AccountSessionControllerError.secureStorage }
                cleanupIDs.update { $0.append(account) }
                if cleanupFail.value { throw AccountSessionControllerError.secureStorage }
            }), now: { base.clock.value })
    }
    func grant() async throws { try await base.pin(); await controller.restore(); _ = try await controller.syncGroup(groupID: groupID) }
}

private actor DeletionMemoryStorage: AccountDeletionStorage {
    var record: AccountDeletionRecord?, fail = false
    func failSaves(_ value: Bool) { fail = value }
    func load() -> AccountDeletionRecord? { record }
    func save(_ record: AccountDeletionRecord) throws {
        if fail { throw AccountSessionControllerError.secureStorage }; self.record = record
    }
}
private actor DeletionFixtureService: AccountSessionService, AccountGroupService, AccountDeletionService {
    let base: NativeProducerService, receipts: DeletionMemoryStorage
    var begins = 0, polls = 0, recoveries = 0, persistedBeforeBegin = false, failure = false
    var result = AccountDeletionStatus.pending, gate: NativeProducerGate?, statusGate: NativeProducerGate?
    init(base: NativeProducerService, receipts: DeletionMemoryStorage) { self.base = base; self.receipts = receipts }
    func setGate(_ value: NativeProducerGate) { gate = value }
    func setStatusGate(_ value: NativeProducerGate) { statusGate = value }
    func setStatus(_ value: AccountDeletionStatus) { result = value }
    func setFailure(_ value: Bool) { failure = value }
    func beginDeletion(receipt: String, accessToken: String, challengeID: String, code: String, identityToken: String, confirmation: Bool) async throws -> AccountDeletionStatus {
        begins += 1; persistedBeforeBegin = await receipts.load()?.receipt == receipt
        await gate?.block()
        if failure { throw AccountServiceError.transport }; return result
    }
    func deletionStatus(receipt: String) async throws -> AccountDeletionStatus {
        polls += 1; await statusGate?.block()
        if failure { throw AccountServiceError.authenticationRejected }; return result
    }
    func recoverDeletion(receipt: String, accountID: UUID, challengeID: String, code: String, identityToken: String, confirmation: Bool) async throws -> AccountDeletionStatus {
        recoveries += 1
        guard await receipts.load()?.accountID == accountID else { throw AccountServiceError.authenticationRejected }
        if failure { throw AccountServiceError.transport }; return result
    }
    func challenge() async throws -> AccountLoginChallenge { try await base.challenge() }
    func complete(challengeID: String, code: String, identityToken: String) async throws -> AccountSessionTokens { try await base.complete(challengeID: challengeID, code: code, identityToken: identityToken) }
    func status(accessToken: String) async throws -> AccountSessionIdentity { try await base.status(accessToken: accessToken) }
    func refresh(refreshToken: String) async throws -> AccountSessionTokens { try await base.refresh(refreshToken: refreshToken) }
    func logout(accessToken: String) async throws { try await base.logout(accessToken: accessToken) }
    func groupHistory(accessToken: String, groupID: String) async throws -> [AccountGroupEvent] { try await base.groupHistory(accessToken: accessToken, groupID: groupID) }
}
