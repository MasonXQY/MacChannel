import Foundation
import XCTest
@testable import MacChannelCore

final class AccountFirstDeviceEnrollmentTests: XCTestCase, @unchecked Sendable {
    func testDiscoveryAndPreparationNeverPersistSignPinOrTransmit() async throws {
        let f = try EnrollmentFixture(); await f.controller.restore()
        let discovery = try await f.controller.discoverAccountGroup()
        XCTAssertEqual(discovery, .absent)
        await enrollmentFailure(.invalidAttempt) { try await f.controller.confirmFirstDeviceJoin(attemptID: UUID()) }
        _ = try await f.controller.prepareFirstDeviceJoin()
        XCTAssertTrue(f.secret.records.isEmpty)
        XCTAssertTrue(f.checkpointSecret.records.isEmpty)
        let events = await f.service.recorded
        XCTAssertTrue(events.isEmpty)
        let requests = await f.service.discoveryRequests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.0 == f.tokens.accessToken && $0.1 == groupAccount })
    }

    func testExplicitConfirmationPersistsBeforeHTTPAndReturnsVerifiedMembership() async throws {
        let f = try EnrollmentFixture(); await f.controller.restore()
        let ticket = try await f.controller.prepareFirstDeviceJoin()
        let gate = EnrollmentGate(); await f.service.setGate(gate, operation: "record")
        let task = Task { try await f.controller.confirmFirstDeviceJoin(attemptID: ticket) }
        await entered(gate)
        let stored = try await f.intent.load(binding: f.binding, accountID: groupAccount)
        let retained = try XCTUnwrap(stored)
        let recorded = await f.service.recorded
        XCTAssertEqual(recorded, [retained.event])
        XCTAssertEqual(retained.event.actorPublicKey, f.identity.publicKey.rawRepresentation)
        XCTAssertEqual(retained.event.generation, 1)
        XCTAssertEqual(retained.event.epochMilliseconds, 2_000_000_000_000)
        XCTAssertTrue(f.checkpointSecret.records.isEmpty)
        await gate.resume()
        let result = try await task.value
        XCTAssertEqual(result.sequence, 1)
        XCTAssertEqual(result.members.count, 1)
        XCTAssertEqual(result.headHash, try retained.event.digest())
        XCTAssertFalse(String(reflecting: result).contains(f.tokens.accessToken))
        await enrollmentFailure(.invalidAttempt) { try await f.controller.confirmFirstDeviceJoin(attemptID: ticket) }
    }

    func testRepreparationExpiryRefreshAndLogoutInvalidateTickets() async throws {
        for reason in ["replace", "expiry", "refresh", "logout"] {
            let f = try EnrollmentFixture(); await f.controller.restore()
            let ticket = try await f.controller.prepareFirstDeviceJoin()
            switch reason {
            case "replace": _ = try await f.controller.prepareFirstDeviceJoin()
            case "expiry": f.clock.advance(300)
            case "refresh": try await f.controller.refresh()
            default: try await f.controller.logout()
            }
            await enrollmentFailure(.invalidAttempt) { try await f.controller.confirmFirstDeviceJoin(attemptID: ticket) }
            XCTAssertTrue(f.secret.records.isEmpty)
            let events = await f.service.recorded; XCTAssertTrue(events.isEmpty)
        }
    }

    func testTicketExpiryIsCappedByAccessExpiry() async throws {
        let f = try EnrollmentFixture(); await f.controller.restore()
        f.clock.advance(500)
        let ticket = try await f.controller.prepareFirstDeviceJoin()
        f.clock.advance(100)
        await enrollmentFailure(.invalidAttempt) { try await f.controller.confirmFirstDeviceJoin(attemptID: ticket) }
        XCTAssertTrue(f.secret.records.isEmpty)
    }

    func testExpiredAccessRefreshesBeforePreparingAndCapturesNewRevision() async throws {
        let f = try EnrollmentFixture(); await f.controller.restore()
        f.clock.advance(601)
        let ticket = try await f.controller.prepareFirstDeviceJoin()
        _ = try await f.controller.confirmFirstDeviceJoin(attemptID: ticket)
        let calls = await f.service.calls
        XCTAssertEqual(calls, ["status", "refresh", "discover", "record", "history"])
    }

    func testSignedOutUnconfiguredAndMismatchedIdentityNeverReachService() async throws {
        let f = try EnrollmentFixture()
        await sessionGroupFailure(.needsSignIn) { try await f.controller.discoverAccountGroup() }
        for mode in ["unconfigured", "verifier", "identity", "protocol"] {
            let controller = f.makeController(mode: mode)
            await controller.restore()
            await enrollmentFailure(.unavailable) { try await controller.discoverAccountGroup() }
            await enrollmentFailure(.unavailable) { try await controller.prepareFirstDeviceJoin() }
        }
        let requests = await f.service.discoveryRequests; XCTAssertTrue(requests.isEmpty)
    }

    func testDiscoveredForeignAnchorNeverAuthorizesPinOrJoin() async throws {
        let f = try EnrollmentFixture(); await f.controller.restore()
        let foreign = try bootstrapEvent(DeviceIdentity.ephemeral())
        await f.service.setDiscovery(try discovery(foreign))
        let found = try await f.controller.discoverAccountGroup()
        XCTAssertEqual(found, try discovery(foreign))
        await enrollmentFailure(.approvalRequired) { try await f.controller.prepareFirstDeviceJoin() }
        XCTAssertTrue(f.secret.records.isEmpty)
        XCTAssertTrue(f.checkpointSecret.records.isEmpty)
        let events = await f.service.recorded; XCTAssertTrue(events.isEmpty)
    }

    func testUncheckedDiscoveryMetadataIsRevalidatedAtControllerBoundary() async throws {
        let f = try EnrollmentFixture(); await f.controller.restore()
        let event = try bootstrapEvent(f.identity)
        let hash = try event.digest()
        let invalid: [AccountGroupDiscoveryMetadata] = [
            .init(groupID: groupAccount, generation: 1, anchor: event, anchorHash: hash, headSequence: 1, headHash: hash),
            .init(groupID: groupID, generation: 2, anchor: event, anchorHash: hash, headSequence: 1, headHash: hash),
            .init(groupID: groupID, generation: 1, anchor: event, anchorHash: Data(), headSequence: 1, headHash: hash),
            .init(groupID: groupID, generation: 1, anchor: event, anchorHash: hash, headSequence: 0, headHash: hash),
            .init(groupID: groupID, generation: 1, anchor: event, anchorHash: hash, headSequence: 8193, headHash: hash),
            .init(groupID: groupID, generation: 1, anchor: event, anchorHash: hash, headSequence: 2, headHash: Data()),
            .init(groupID: groupID, generation: 1, anchor: event, anchorHash: hash, headSequence: 1, headHash: Data(repeating: 0, count: 32)),
            .init(groupID: groupID, generation: 1, anchor: try bootstrapEvent(f.identity, signed: false), anchorHash: hash, headSequence: 1, headHash: hash),
            .init(groupID: groupID, generation: 1, anchor: try bootstrapEvent(f.identity, account: groupID), anchorHash: hash, headSequence: 1, headHash: hash)]
        for metadata in invalid {
            await f.service.setDiscovery(.present(metadata))
            do { _ = try await f.controller.discoverAccountGroup(); XCTFail("Accepted invalid discovery") }
            catch { XCTAssertEqual(error as? AccountServiceError, .invalidResponse) }
            do { _ = try await f.controller.prepareFirstDeviceJoin(); XCTFail("Prepared invalid discovery") }
            catch { XCTAssertEqual(error as? AccountServiceError, .invalidResponse) }
        }
        XCTAssertTrue(f.secret.records.isEmpty)
        XCTAssertTrue(f.checkpointSecret.records.isEmpty)
    }

    func testFailedHTTPRetainsExactSignedEventAcrossExplicitRetryAndRestart() async throws {
        let f = try EnrollmentFixture(); await f.controller.restore()
        await f.service.fail("record")
        let ticket = try await f.controller.prepareFirstDeviceJoin()
        do { _ = try await f.controller.confirmFirstDeviceJoin(attemptID: ticket); XCTFail("Expected HTTP failure") }
        catch { XCTAssertEqual(error as? AccountServiceError, .transport) }
        let stored = try await f.intent.load(binding: f.binding, accountID: groupAccount)
        let intent = try XCTUnwrap(stored)
        XCTAssertTrue(f.checkpointSecret.records.isEmpty)
        await f.service.fail(nil)
        await f.service.setDiscovery(try discovery(intent.event))
        let restarted = f.makeController(); await restarted.restore()
        let retry = try await restarted.prepareFirstDeviceJoin()
        let result = try await restarted.confirmFirstDeviceJoin(attemptID: retry)
        XCTAssertEqual(result.groupID, intent.event.groupID)
        let events = await f.service.recorded
        XCTAssertEqual(events, [intent.event, intent.event])
        XCTAssertEqual(f.secret.writes, 1)
    }

    func testRetainedIntentOnlyPermitsExactDiscoveredGroup() async throws {
        let f = try EnrollmentFixture(); await f.controller.restore()
        let retained = try AccountGroupBootstrapIntent(binding: f.binding, event: bootstrapEvent(f.identity))
        try await f.intent.save(retained)
        for event in [try bootstrapEvent(f.identity, group: UUID().uuidString.lowercased()),
                      try bootstrapEvent(f.identity, generation: 2), try bootstrapEvent(DeviceIdentity.ephemeral())] {
            await f.service.setDiscovery(try discovery(event))
            await enrollmentFailure(.approvalRequired) { try await f.controller.prepareFirstDeviceJoin() }
        }
        let events = await f.service.recorded; XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(f.secret.writes, 1)
    }

    func testProtectedSaveAndReadHaltBeforeNetwork() async throws {
        for failure in ["read", "write"] {
            let f = try EnrollmentFixture(); await f.controller.restore()
            let ticket = try await f.controller.prepareFirstDeviceJoin()
            if failure == "read" { f.secret.failReads(true) } else { f.secret.failWrites(true) }
            await enrollmentFailure(.secureStorage) { try await f.controller.confirmFirstDeviceJoin(attemptID: ticket) }
            let events = await f.service.recorded; XCTAssertTrue(events.isEmpty)
            XCTAssertTrue(f.checkpointSecret.records.isEmpty)
            await enrollmentFailure(.invalidAttempt) { try await f.controller.confirmFirstDeviceJoin(attemptID: ticket) }
        }
    }

    func testFailedHistoryAndProtectedCheckpointNeverResetOrPublish() async throws {
        let f = try EnrollmentFixture(); await f.controller.restore()
        var ticket = try await f.controller.prepareFirstDeviceJoin()
        await f.service.fail("history")
        do { _ = try await f.controller.confirmFirstDeviceJoin(attemptID: ticket); XCTFail("Expected history failure") }
        catch { XCTAssertEqual(error as? AccountServiceError, .transport) }
        XCTAssertTrue(f.checkpointSecret.records.isEmpty)
        await f.service.fail(nil)
        f.checkpointSecret.failReads(true)
        ticket = try await f.controller.prepareFirstDeviceJoin()
        await checkpointFailure(.secureStorage) { try await f.controller.confirmFirstDeviceJoin(attemptID: ticket) }
        XCTAssertTrue(f.checkpointSecret.records.isEmpty)
    }

    func testHistoricalRetryReturnsRemovedMembershipAndCannotDowngradeCheckpoint() async throws {
        let f = try EnrollmentFixture(); await f.controller.restore()
        let ticket = try await f.controller.prepareFirstDeviceJoin()
        _ = try await f.controller.confirmFirstDeviceJoin(attemptID: ticket)
        let stored = try await f.intent.load(binding: f.binding, accountID: groupAccount)
        let retained = try XCTUnwrap(stored)
        let remove = try bootstrapEvent(f.identity, group: retained.event.groupID, action: "remove", sequence: 2, previous: retained.event.digest())
        await f.service.setHistory([retained.event, remove])
        await f.service.setDiscovery(try discovery(retained.event, head: remove))
        let retry = try await f.controller.prepareFirstDeviceJoin()
        let removed = try await f.controller.confirmFirstDeviceJoin(attemptID: retry)
        XCTAssertTrue(removed.members.isEmpty)
        XCTAssertEqual(removed.sequence, 2)
        let writes = f.checkpointSecret.writes
        let restarted = f.makeController(); await restarted.restore()
        let again = try await restarted.prepareFirstDeviceJoin()
        let afterRestart = try await restarted.confirmFirstDeviceJoin(attemptID: again)
        XCTAssertEqual(afterRestart, removed)
        XCTAssertEqual(f.checkpointSecret.writes, writes)
        await f.service.setHistory([retained.event])
        let stale = try await restarted.prepareFirstDeviceJoin()
        await checkpointFailure(.invalidHistory) { try await restarted.confirmFirstDeviceJoin(attemptID: stale) }
        XCTAssertEqual(f.checkpointSecret.writes, writes)
    }

    func testEverySuspendedDependencyFencesCancellationLogoutAndRefresh() async throws {
        for change in ["cancel", "logout", "refresh"] {
            for stage in ["discovery", "prepare-load", "prepare-discover", "confirm-load", "save", "record", "history", "verify-load", "verify-save"] {
                let f = try EnrollmentFixture(); await f.controller.restore()
                let isConfirmation = !["discovery", "prepare-load", "prepare-discover"].contains(stage)
                let ticket = isConfirmation ? try await f.controller.prepareFirstDeviceJoin() : nil
                let gate = EnrollmentGate()
                switch stage {
                case "prepare-load", "confirm-load": await f.intent.setGate(gate, operation: "load")
                case "save": await f.intent.setGate(gate, operation: "save")
                case "verify-load": await f.checkpoint.setGate(gate, operation: "load")
                case "verify-save": await f.checkpoint.setGate(gate, operation: "save")
                default: await f.service.setGate(gate, operation: stage == "discovery" || stage == "prepare-discover" ? "discover" : stage)
                }
                let task = Task {
                    if let ticket { _ = try await f.controller.confirmFirstDeviceJoin(attemptID: ticket) }
                    else if stage == "discovery" { _ = try await f.controller.discoverAccountGroup() }
                    else { _ = try await f.controller.prepareFirstDeviceJoin() }
                }
                await entered(gate)
                // Admission is shared with known-group sync and stays held even
                // when a cancelled dependency ignores cancellation.
                await sessionGroupFailure(.busy) { try await f.controller.syncGroup(groupID: groupID) }
                await sessionGroupFailure(.busy) { try await f.controller.discoverAccountGroup() }
                if change == "cancel" { task.cancel() }
                else if change == "logout" { try await f.controller.logout() }
                else { try await f.controller.refresh() }
                let callsBefore = await f.service.calls
                let checkpointLoadsBefore = await f.checkpoint.loads
                await gate.resume()
                do { try await task.value; XCTFail("Published stale result at \(stage)/\(change)") }
                catch {
                    if change == "cancel" { XCTAssertTrue(error is CancellationError, "\(stage): \(error)") }
                    else { XCTAssertEqual(error as? AccountSessionControllerError, .needsSignIn, stage) }
                }
                let callsAfter = await f.service.calls
                XCTAssertEqual(callsAfter, callsBefore, "Late network side effect at \(stage)/\(change)")
                let loadsAfter = await f.checkpoint.loads
                XCTAssertEqual(loadsAfter, checkpointLoadsBefore, "Late verifier operation at \(stage)/\(change)")
                if ["discovery", "prepare-load", "prepare-discover", "confirm-load"].contains(stage) { XCTAssertTrue(f.secret.records.isEmpty) }
                if stage != "verify-save" { XCTAssertTrue(f.checkpointSecret.records.isEmpty) }
            }
        }
    }

    func testConfirmationExpiryAcrossEveryAwaitStopsLaterEffects() async throws {
        for stage in ["load", "save", "record", "history", "verify-load", "verify-save"] {
            let f = try EnrollmentFixture(); await f.controller.restore()
            let ticket = try await f.controller.prepareFirstDeviceJoin()
            let gate = EnrollmentGate()
            switch stage {
            case "load", "save": await f.intent.setGate(gate, operation: stage)
            case "verify-load": await f.checkpoint.setGate(gate, operation: "load")
            case "verify-save": await f.checkpoint.setGate(gate, operation: "save")
            default: await f.service.setGate(gate, operation: stage)
            }
            let task = Task { try await f.controller.confirmFirstDeviceJoin(attemptID: ticket) }
            await entered(gate)
            f.clock.advance(300)
            let calls = await f.service.calls
            await gate.resume()
            await enrollmentFailure(.invalidAttempt) { try await task.value }
            let after = await f.service.calls
            XCTAssertEqual(after, calls)
        }
    }

    func testLogoutIntentFencesBeforeLogoutResponseAndReloginCannotReviveTicket() async throws {
        let f = try EnrollmentFixture(); await f.controller.restore()
        let ticket = try await f.controller.prepareFirstDeviceJoin()
        let recordGate = EnrollmentGate(), logoutGate = EnrollmentGate()
        await f.service.setGate(recordGate, operation: "record")
        let task = Task { try await f.controller.confirmFirstDeviceJoin(attemptID: ticket) }
        await entered(recordGate)
        await f.service.setGate(logoutGate, operation: "logout")
        let logout = Task { try await f.controller.logout() }
        await entered(logoutGate)
        await recordGate.resume()
        await sessionGroupFailure(.needsSignIn) { try await task.value }
        XCTAssertTrue(f.checkpointSecret.records.isEmpty)
        await logoutGate.resume(); try await logout.value
        let login = try await f.controller.beginLogin()
        try await f.controller.completeLogin(attemptID: login.id, code: "synthetic", identityToken: "synthetic")
        await enrollmentFailure(.invalidAttempt) { try await f.controller.confirmFirstDeviceJoin(attemptID: ticket) }
    }

    func testConfirmSecondCheckpointLoadCannotStartWriteAfterLifecycleChange() async throws {
        try await assertCheckpointLifecycleFence(stage: "confirm-second-load")
    }

    func testAcceptExistingCheckpointLoadCannotStartWriteAfterLifecycleChange() async throws {
        try await assertCheckpointLifecycleFence(stage: "accept-load")
    }

    func testKnownGroupSyncCheckpointLoadCannotStartWriteAfterLifecycleChange() async throws {
        try await assertCheckpointLifecycleFence(stage: "sync-load")
    }

    func testAlreadyIssuedCheckpointSavesCanFinishButReturnNoSnapshot() async throws {
        try await assertCheckpointLifecycleFence(stage: "accept-save")
        try await assertCheckpointLifecycleFence(stage: "sync-save")
    }

    private func assertCheckpointLifecycleFence(stage: String) async throws {
        for change in ["logout", "refresh", "expiry"] {
            let f = try EnrollmentFixture(); await f.controller.restore()
            var group = groupID
            let firstPin = stage == "confirm-second-load"
            if !firstPin {
                let initial = try await f.controller.prepareFirstDeviceJoin()
                let snapshot = try await f.controller.confirmFirstDeviceJoin(attemptID: initial)
                group = snapshot.groupID
                let retained = try await f.intent.load(binding: f.binding, accountID: groupAccount)
                let anchor = try XCTUnwrap(retained).event
                let remove = try bootstrapEvent(f.identity, group: group, action: "remove", sequence: 2, previous: anchor.digest())
                await f.service.setHistory([anchor, remove])
            }
            // Exercise the existing sync API with first-device configuration nil.
            let sync = stage.hasPrefix("sync")
            let controller = sync ? f.makeController(mode: "unconfigured") : f.controller
            if sync { await controller.restore() }
            let ticket = sync ? nil : try await controller.prepareFirstDeviceJoin()
            let gate = EnrollmentGate()
            let issuedSave = stage.hasSuffix("save")
            await f.checkpoint.setGate(gate, operation: issuedSave ? "save" : "load", afterLoads: firstPin ? 1 : 0)
            let groupID = group
            let task = Task {
                if let ticket { return try await controller.confirmFirstDeviceJoin(attemptID: ticket) }
                return try await controller.syncGroup(groupID: groupID)
            }
            await entered(gate)
            let writesBefore = f.checkpointSecret.writes
            await sessionGroupFailure(.busy) { try await controller.syncGroup(groupID: groupID) }
            switch change {
            case "logout": try await controller.logout()
            case "refresh": try await controller.refresh()
            default: f.clock.advance(sync ? 600 : 300)
            }
            await gate.resume()
            do { _ = try await task.value; XCTFail("Returned stale snapshot at \(stage)/\(change)") }
            catch {
                if !sync && change == "expiry" { XCTAssertEqual(error as? AccountFirstDeviceEnrollmentError, .invalidAttempt) }
                else { XCTAssertEqual(error as? AccountSessionControllerError, .needsSignIn) }
            }
            XCTAssertEqual(f.checkpointSecret.writes, writesBefore + (issuedSave ? 1 : 0), "Late write at \(stage)/\(change)")
            if firstPin { XCTAssertTrue(f.checkpointSecret.records.isEmpty, change) }
        }
    }

    private func entered(_ gate: EnrollmentGate, file: StaticString = #filePath, line: UInt = #line) async {
        let arrived = expectation(description: "dependency reached")
        let observer = Task { await gate.wait(); arrived.fulfill() }
        await fulfillment(of: [arrived], timeout: 5)
        observer.cancel()
    }
}

private func discovery(_ anchor: AccountGroupEvent, head: AccountGroupEvent? = nil) throws -> AccountGroupDiscovery {
    .present(.init(groupID: anchor.groupID, generation: anchor.generation, anchor: anchor,
        anchorHash: try anchor.digest(), headSequence: head?.sequence ?? 1, headHash: try (head ?? anchor).digest()))
}

private struct EnrollmentFixture: Sendable {
    let identity: DeviceIdentity
    let binding: AccountSessionBinding
    let tokens: AccountSessionTokens
    let secret = CheckpointSecretStore()
    let checkpointSecret = CheckpointSecretStore()
    let intent: EnrollmentIntentStorage
    let checkpoint: EnrollmentCheckpointStorage
    let service: EnrollmentService
    let session: SessionGroupStorage
    let clock = GroupClock()
    let controller: AccountSessionController

    init() throws {
        identity = try DeviceIdentity.ephemeral()
        binding = try checkpointBinding(device: identity.id.rawValue)
        tokens = AccountSessionTokens(identity: .init(accountID: UUID(uuidString: groupAccount)!, sessionID: UUID(),
            deviceID: identity.id.rawValue, audience: binding.audience), accessToken: groupToken,
            refreshToken: Data(repeating: 2, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: ""),
            accessExpiresAt: Date(timeIntervalSince1970: 2_000_000_600), refreshExpiresAt: Date(timeIntervalSince1970: 2_000_006_000))
        session = SessionGroupStorage(try AccountStoredSession(binding: binding, tokens: tokens))
        service = EnrollmentService(tokens: tokens)
        intent = EnrollmentIntentStorage(secret: secret)
        checkpoint = EnrollmentCheckpointStorage(secret: checkpointSecret)
        let clock = clock
        controller = AccountSessionController(service: service, storage: session, binding: binding,
            groupVerifier: AccountGroupHistoryVerifier(storage: checkpoint),
            firstDeviceEnrollment: .init(identity: identity, intentStorage: intent), now: { clock.now() })
    }

    func makeController(mode: String = "normal") -> AccountSessionController {
        AccountSessionController(service: mode == "protocol" ? SessionGroupService(tokens: tokens, events: []) : service,
            storage: session, binding: binding,
            groupVerifier: mode == "verifier" ? nil : AccountGroupHistoryVerifier(storage: checkpoint),
            firstDeviceEnrollment: mode == "unconfigured" ? nil : .init(
                identity: mode == "identity" ? try! DeviceIdentity.ephemeral() : identity,
                intentStorage: EnrollmentIntentStorage(secret: secret)), now: { clock.now() })
    }
}

private actor EnrollmentService: AccountSessionService, AccountGroupEnrollmentService, AccountGroupService {
    let tokens: AccountSessionTokens
    var calls: [String] = []
    var discoveryRequests: [(String, String)] = []
    var recorded: [AccountGroupEvent] = []
    var found: AccountGroupDiscovery = .absent
    var history: [AccountGroupEvent]?
    var gates: [String: EnrollmentGate] = [:]
    var failure: String?
    init(tokens: AccountSessionTokens) { self.tokens = tokens }
    func setGate(_ gate: EnrollmentGate, operation: String) { gates[operation] = gate }
    func setDiscovery(_ value: AccountGroupDiscovery) { found = value }
    func setHistory(_ value: [AccountGroupEvent]) { history = value }
    func fail(_ operation: String?) { failure = operation }
    func pause(_ operation: String) async throws {
        calls.append(operation)
        if let gate = gates.removeValue(forKey: operation) { await gate.block() }
        if failure == operation { throw AccountServiceError.transport }
    }
    func discoverGroup(accessToken: String, accountID: String) async throws -> AccountGroupDiscovery {
        discoveryRequests.append((accessToken, accountID)); try await pause("discover"); return found
    }
    func recordGroupBootstrap(accessToken: String, event: AccountGroupEvent) async throws {
        recorded.append(event); try await pause("record")
        if history == nil { history = [event] }
    }
    func groupHistory(accessToken: String, groupID: String) async throws -> [AccountGroupEvent] {
        try await pause("history"); return history ?? []
    }
    func challenge() async throws -> AccountLoginChallenge {
        .init(challengeID: groupToken, nonce: tokens.refreshToken, expiresAt: Date(timeIntervalSince1970: 2_000_000_060))
    }
    func complete(challengeID: String, code: String, identityToken: String) async throws -> AccountSessionTokens { tokens }
    func status(accessToken: String) async throws -> AccountSessionIdentity { try await pause("status"); return tokens.identity }
    func refresh(refreshToken: String) async throws -> AccountSessionTokens {
        try await pause("refresh")
        return .init(identity: tokens.identity, accessToken: tokens.accessToken, refreshToken: tokens.refreshToken,
            accessExpiresAt: tokens.accessExpiresAt.addingTimeInterval(1200), refreshExpiresAt: tokens.refreshExpiresAt)
    }
    func logout(accessToken: String) async throws { try await pause("logout") }
}

private actor EnrollmentIntentStorage: AccountGroupBootstrapIntentStorage {
    let base: KeychainAccountGroupBootstrapIntentStorage
    var gates: [String: EnrollmentGate] = [:]
    init(secret: CheckpointSecretStore) { base = .init(store: secret) }
    func setGate(_ gate: EnrollmentGate, operation: String) { gates[operation] = gate }
    func load(binding: AccountSessionBinding, accountID: String) async throws -> AccountGroupBootstrapIntent? {
        if let gate = gates.removeValue(forKey: "load") { await gate.block() }
        return try await base.load(binding: binding, accountID: accountID)
    }
    func save(_ intent: AccountGroupBootstrapIntent) async throws {
        if let gate = gates.removeValue(forKey: "save") { await gate.block() }
        try await base.save(intent)
    }
}

private actor EnrollmentCheckpointStorage: AccountGroupCheckpointStorage {
    let base: KeychainAccountGroupCheckpointStorage
    var gates: [String: EnrollmentGate] = [:]
    var loads = 0
    var loadGateSkip = 0
    init(secret: CheckpointSecretStore) { base = .init(store: secret) }
    func setGate(_ gate: EnrollmentGate, operation: String, afterLoads: Int = 0) {
        gates[operation] = gate
        loadGateSkip = afterLoads
    }
    func load(binding: AccountSessionBinding, accountID: String, groupID: String) async throws -> AccountGroupCheckpoint? {
        loads += 1
        if loadGateSkip > 0 { loadGateSkip -= 1 }
        else if let gate = gates.removeValue(forKey: "load") { await gate.block() }
        return try await base.load(binding: binding, accountID: accountID, groupID: groupID)
    }
    func save(_ checkpoint: AccountGroupCheckpoint) async throws {
        if let gate = gates.removeValue(forKey: "save") { await gate.block() }
        try await base.save(checkpoint)
    }
}

private actor EnrollmentGate {
    private var held: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private var released = false
    func block() async {
        if released { return }
        await withCheckedContinuation { held = $0; observer?.resume(); observer = nil }
    }
    func wait() async { if held != nil || released { return }; await withCheckedContinuation { observer = $0 } }
    func resume() { released = true; held?.resume(); held = nil; observer?.resume(); observer = nil }
}
