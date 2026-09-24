import Foundation
import XCTest
@testable import MacChannelCore

final class NativeAccountProducerTests: XCTestCase {
    func testFullyVerifiedHistoryWithDifferentLocalKeyCannotGrant() async throws {
        let f = try NativeProducerFixture()
        let otherLocal = try DeviceIdentity.ephemeral()
        let anchor = try nativeProducerEvent(actor: otherLocal, subject: otherLocal)
        let approval = try nativeProducerEvent(actor: otherLocal, subject: f.peer, action: "approve", sequence: 2, previous: anchor.digest())
        _ = try await f.verifier.confirm(anchor: anchor, expectedAccountID: groupAccount, expectedGroupID: groupID,
            expectedGeneration: 1, expectedAnchorHash: anchor.digest(), binding: f.binding)
        await f.service.setHistory([anchor, approval])
        await f.controller.restore()
        do { _ = try await f.controller.syncGroup(groupID: groupID); XCTFail("wrong local membership granted") } catch {}
        XCTAssertTrue(f.owner.snapshot().peers.isEmpty)
        // Full verification still advances the independent anti-rollback checkpoint.
        let checkpoint = await f.checkpointStorage.checkpoint
        XCTAssertEqual(checkpoint?.sequence, 2)
    }

    func testFreshnessAlsoIncludesCheckpointStorageDelay() async throws {
        let f = try NativeProducerFixture(freshness: 10)
        try await f.prepare()
        let gate = NativeProducerGate()
        defer { Task { await gate.release() } }
        await f.checkpointStorage.suspendSave(gate)
        let task = Task { try await f.controller.syncGroup(groupID: groupID) }
        await gate.entered()
        f.clock.update { $0 = $0.addingTimeInterval(10) }
        await gate.release()
        do { _ = try await task.value; XCTFail("storage delay renewed freshness") } catch {}
        XCTAssertTrue(f.owner.snapshot().peers.isEmpty)
    }

    func testPresentationRevisionOnlyCancelsThisInstallationNotPriorFreshGrant() async throws {
        let f = try NativeProducerFixture()
        try await f.grant()
        let lease = try f.owner.acquire(for: f.peer.id)
        let gate = NativeProducerGate()
        defer { Task { await gate.release() } }
        await f.service.setGate(gate, operation: "history")
        let task = Task { try await f.controller.syncGroup(groupID: groupID) }
        await gate.entered()
        // This real consent entry revises presentation before rejecting the
        // unsupported approval configuration; it is not a session lifecycle.
        do { _ = try await f.controller.cancelDeviceJoin(requestID: UUID().uuidString.lowercased()) } catch {}
        XCTAssertNoThrow(try f.owner.validate(lease))
        await gate.release()
        do { _ = try await task.value; XCTFail("superseded attempt installed") } catch {}
        XCTAssertNoThrow(try f.owner.validate(lease))
    }

    func testSourceOverlapSurvivesEitherWithdrawalWithoutBreakingContinuity() async throws {
        let f = try NativeProducerFixture()
        try await f.grant()
        let repository = try TrustRepository(ownerIdentity: f.local, trustStore: TrustStore(owner: f.local.id),
            persistedGeneration: 0, authorizationOwner: f.owner)
        _ = try await repository.issueAuthorization(subject: f.peer.id, subjectPublicKey: f.peer.publicKey.rawRepresentation, timestamp: NativeProducerFixture.start)
        let calls = PeerTestBox(0)
        let registration = try f.owner.claim(f.owner.acquire(for: f.peer.id)) { calls.update { $0 += 1 } }
        _ = try await repository.revoke(f.peer.id)
        XCTAssertNoThrow(try registration.requireCurrent())
        _ = try await repository.issueAuthorization(subject: f.peer.id, subjectPublicKey: f.peer.publicKey.rawRepresentation, timestamp: NativeProducerFixture.start)
        try await f.controller.logout()
        XCTAssertNoThrow(try registration.requireCurrent())
        _ = try await repository.revoke(f.peer.id)
        XCTAssertThrowsError(try registration.requireCurrent())
        XCTAssertEqual(calls.value, 1)
    }

    func testInvalidClockAtSyncAdmissionWithdrawsBeforeReturningFailure() async throws {
        let f = try NativeProducerFixture()
        try await f.grant()
        let calls = PeerTestBox(0)
        let registration = try f.owner.claim(f.owner.acquire(for: f.peer.id)) { calls.update { $0 += 1 } }
        f.clock.update { $0 = Date(timeIntervalSince1970: .nan) }
        do { _ = try await f.controller.syncGroup(groupID: groupID); XCTFail("invalid clock accepted") } catch {}
        XCTAssertEqual(calls.value, 1)
        f.clock.update { $0 = NativeProducerFixture.start }
        XCTAssertThrowsError(try registration.requireCurrent())
    }

    func testLogoutStorageFailureAndRefreshServiceFailureNeverRegrant() async throws {
        for operation in ["logoutRemove", "refreshService", "refreshPending"] {
            let f = try NativeProducerFixture()
            try await f.grant()
            let calls = PeerTestBox(0)
            let registration = try f.owner.claim(f.owner.acquire(for: f.peer.id)) { calls.update { $0 += 1 } }
            let gate = NativeProducerGate()
            defer { Task { await gate.release() } }
            if operation == "logoutRemove" {
                await f.storage.setGate(gate, operation: "remove"); await f.storage.fail("remove")
            } else if operation == "refreshPending" {
                await f.storage.setGate(gate, operation: "save"); await f.storage.fail("save")
            } else {
                await f.storage.setGate(gate, operation: "remove"); await f.service.fail("refresh")
            }
            let task = Task { if operation == "logoutRemove" { try await f.controller.logout() } else { try await f.controller.refresh() } }
            await gate.entered()
            XCTAssertEqual(calls.value, 1)
            XCTAssertThrowsError(try registration.requireCurrent())
            await gate.release()
            do { try await task.value; XCTFail("failure accepted") } catch {}
            XCTAssertThrowsError(try f.owner.acquire(for: f.peer.id))
        }
    }

    func testControllerDeinitWithdrawsAccountAndReplacementStartsEmpty() async throws {
        let f = try NativeProducerFixture()
        // Release the fixture's controller attachment only by constructing the
        // short-lived producer on a separate explicit owner.
        let owner = PeerAuthorizationOwner(local: f.local.id, now: { f.clock.value }, schedule: f.timer.schedule)
        let configuration = try AccountPeerAuthorization(owner: owner, identity: f.local, binding: f.binding, freshness: 20)
        var controller: AccountSessionController? = try AccountSessionController(service: f.service, storage: f.storage,
            binding: f.binding, groupVerifier: f.verifier, peerAuthorization: configuration, now: { f.clock.value })
        try await f.pin()
        await controller?.restore()
        _ = try await controller?.syncGroup(groupID: groupID)
        let lease = try owner.acquire(for: f.peer.id)
        controller = nil
        XCTAssertThrowsError(try owner.validate(lease))
        let replacement = try AccountSessionController(service: f.service, storage: f.storage, binding: f.binding,
            groupVerifier: f.verifier, peerAuthorization: configuration, now: { f.clock.value })
        await replacement.restore()
        XCTAssertThrowsError(try owner.acquire(for: f.peer.id))
    }

    func testInvalidConfigurationAndDuplicateControllerCannotOverwriteSource() async throws {
        let f = try NativeProducerFixture()
        for duration in [0, -1, .nan, .infinity, 300.001] {
            XCTAssertThrowsError(try AccountPeerAuthorization(owner: f.owner, identity: f.local, binding: f.binding, freshness: duration))
        }
        XCTAssertNoThrow(try AccountPeerAuthorization(owner: f.owner, identity: f.local, binding: f.binding, freshness: 300))
        XCTAssertThrowsError(try AccountPeerAuthorization(owner: f.owner, identity: f.peer, binding: f.binding, freshness: 20))
        let wrong = PeerAuthorizationOwner(local: f.peer.id, now: Date.init, schedule: { _, _ in {} })
        XCTAssertThrowsError(try AccountPeerAuthorization(owner: wrong, identity: f.local, binding: f.binding, freshness: 20))
        let wrongBinding = try AccountSessionBinding(deviceID: f.local.id.rawValue, audience: "other", origin: f.binding.origin)
        XCTAssertThrowsError(try AccountSessionController(service: f.service, storage: f.storage, binding: wrongBinding,
            groupVerifier: f.verifier, peerAuthorization: f.configuration, now: { f.clock.value }))
        try await f.grant()
        XCTAssertThrowsError(try AccountSessionController(service: f.service, storage: f.storage, binding: f.binding,
            groupVerifier: f.verifier, peerAuthorization: f.configuration, now: { f.clock.value }))
        XCTAssertNoThrow(try f.owner.acquire(for: f.peer.id))
    }

    func testDeadlineExpiryInvalidatesAndSnapshotCannotRegrant() async throws {
        for (freshness, access) in [(10.0, 100.0), (100.0, 10.0)] {
            let f = try NativeProducerFixture(freshness: freshness, access: access)
            try await f.grant()
            let calls = PeerTestBox(0)
            let registration = try f.owner.claim(f.owner.acquire(for: f.peer.id)) { calls.update { $0 += 1 } }
            f.clock.update { $0 = $0.addingTimeInterval(10) }
            f.timer.fire()
            XCTAssertEqual(calls.value, 1)
            XCTAssertThrowsError(try registration.requireCurrent())
            _ = await f.controller.snapshot()
            XCTAssertThrowsError(try f.owner.acquire(for: f.peer.id))
            if freshness < access {
                _ = try await f.controller.syncGroup(groupID: groupID)
                XCTAssertNoThrow(try f.owner.acquire(for: f.peer.id))
                XCTAssertThrowsError(try registration.requireCurrent())
            }
        }
    }

    func testInvalidRemovedForkedLowerAndGenerationHistoryWithdrawOnlyAccount() async throws {
        for variant in ["empty", "lower", "fork", "generation", "removedLocal", "removedPeer", "transport", "storage"] {
            let f = try NativeProducerFixture()
            try await f.grant()
            let manual = try TrustRepository(ownerIdentity: f.local, trustStore: TrustStore(owner: f.local.id),
                persistedGeneration: 0, authorizationOwner: f.owner)
            _ = try await manual.issueAuthorization(subject: f.peer.id, subjectPublicKey: f.peer.publicKey.rawRepresentation, timestamp: NativeProducerFixture.start)
            switch variant {
            case "empty": await f.service.setHistory([])
            case "lower": await f.service.setHistory([f.events[0]])
            case "fork":
                let other = try DeviceIdentity.ephemeral()
                await f.service.setHistory([f.events[0], try nativeProducerEvent(actor: f.local, subject: other, action: "approve", sequence: 2, previous: f.events[0].digest())])
            case "generation": await f.service.setHistory([try nativeProducerEvent(actor: f.local, subject: f.local, generation: 2)])
            case "removedLocal", "removedPeer":
                await f.service.setHistory(f.events + [try nativeProducerEvent(actor: f.local, subject: variant == "removedLocal" ? f.local : f.peer,
                    action: "remove", sequence: 3, previous: f.events[1].digest())])
            case "transport": await f.service.fail("history")
            default:
                await f.service.setHistory(f.events + [try nativeProducerEvent(actor: f.local, subject: f.peer,
                    action: "remove", sequence: 3, previous: f.events[1].digest())])
                await f.checkpointStorage.setFailure()
            }
            do { _ = try await f.controller.syncGroup(groupID: groupID); if variant != "removedPeer" { XCTFail("invalid history accepted: \(variant)") } } catch {}
            XCTAssertNoThrow(try f.owner.acquire(for: f.peer.id), variant)
            _ = try await manual.revoke(f.peer.id)
            XCTAssertThrowsError(try f.owner.acquire(for: f.peer.id), variant)
        }
    }

    func testDelayedCheckpointSaveAfterRefreshCannotRegrant() async throws {
        let f = try NativeProducerFixture()
        try await f.grant()
        let gate = NativeProducerGate()
        await f.checkpointStorage.suspendSave(gate)
        defer { Task { await gate.release() } }
        let third = try DeviceIdentity.ephemeral()
        await f.service.setHistory(f.events + [try nativeProducerEvent(actor: f.local, subject: third,
            action: "approve", sequence: 3, previous: f.events[1].digest())])
        let sync = Task { try await f.controller.syncGroup(groupID: groupID) }
        await gate.entered()
        try await f.controller.refresh()
        XCTAssertThrowsError(try f.owner.acquire(for: f.peer.id))
        await gate.release()
        do { _ = try await sync.value; XCTFail("superseded storage result installed") } catch {}
        XCTAssertThrowsError(try f.owner.acquire(for: f.peer.id))
    }

    func testRestoreAloneNeverGrantsButVerifiedCurrentHistoryDoes() async throws {
        let f = try NativeProducerFixture()
        try await f.prepare()
        XCTAssertTrue(f.owner.snapshot().peers.isEmpty)
        _ = try await f.controller.syncGroup(groupID: groupID)
        XCTAssertEqual(f.owner.snapshot().peers[f.peer.id], f.peer.publicKey.rawRepresentation)
        XCTAssertNil(f.owner.snapshot().peers[f.local.id])
    }

    func testLoginAloneNeverGrants() async throws {
        let f = try NativeProducerFixture(empty: true)
        let attempt = try await f.controller.beginLogin()
        try await f.controller.completeLogin(attemptID: attempt.id, code: "fixture-code", identityToken: "fixture-token")
        XCTAssertTrue(f.owner.snapshot().peers.isEmpty)
        try await f.pin()
        _ = try await f.controller.syncGroup(groupID: groupID)
        XCTAssertNoThrow(try f.owner.acquire(for: f.peer.id))
    }

    func testRefreshIntentWithdrawsBeforePendingStorageWriteAndDoesNotRegrant() async throws {
        let f = try NativeProducerFixture()
        try await f.grant()
        let lease = try f.owner.acquire(for: f.peer.id)
        let calls = PeerTestBox(0)
        let registration = try f.owner.claim(lease) { calls.update { $0 += 1 } }
        let gate = NativeProducerGate()
        await f.storage.setGate(gate, operation: "save")
        defer { Task { await gate.release() } }
        let task = Task { try await f.controller.refresh() }
        await gate.entered()
        XCTAssertEqual(calls.value, 1)
        XCTAssertThrowsError(try registration.requireCurrent())
        await gate.release()
        try await task.value
        XCTAssertThrowsError(try f.owner.acquire(for: f.peer.id))
        _ = try await f.controller.syncGroup(groupID: groupID)
        XCTAssertNoThrow(try f.owner.acquire(for: f.peer.id))
    }

    func testLogoutIntentWithdrawsBeforeServiceAwaitAndDelayedHistoryCannotReinstall() async throws {
        let f = try NativeProducerFixture()
        try await f.grant()
        let historyGate = NativeProducerGate(), logoutGate = NativeProducerGate()
        defer { Task { await historyGate.release(); await logoutGate.release() } }
        await f.service.setGate(historyGate, operation: "history")
        await f.service.setGate(logoutGate, operation: "logout")
        let sync = Task { try await f.controller.syncGroup(groupID: groupID) }
        await historyGate.entered()
        let logout = Task { try await f.controller.logout() }
        await logoutGate.entered()
        XCTAssertThrowsError(try f.owner.acquire(for: f.peer.id))
        await historyGate.release()
        do { _ = try await sync.value; XCTFail("old history installed") } catch {}
        await logoutGate.release()
        try await logout.value
        XCTAssertThrowsError(try f.owner.acquire(for: f.peer.id))
    }

    func testFreshnessStartsBeforeHistoryRequestAndNeverExtendsAcrossAwait() async throws {
        let f = try NativeProducerFixture(freshness: 10)
        try await f.prepare()
        let gate = NativeProducerGate()
        await f.service.setGate(gate, operation: "history")
        defer { Task { await gate.release() } }
        let task = Task { try await f.controller.syncGroup(groupID: groupID) }
        await gate.entered()
        f.clock.update { $0 = $0.addingTimeInterval(10) }
        await gate.release()
        do { _ = try await task.value; XCTFail("stale observation granted") } catch {}
        XCTAssertThrowsError(try f.owner.acquire(for: f.peer.id))
    }

    func testCancellationWithdrawsExistingAccountEvenWhileHistoryIgnoresCancellation() async throws {
        let f = try NativeProducerFixture()
        try await f.grant()
        let invalidated = expectation(description: "synchronous owner cancellation")
        let registration = try f.owner.claim(f.owner.acquire(for: f.peer.id)) { invalidated.fulfill() }
        let gate = NativeProducerGate()
        await f.service.setGate(gate, operation: "history")
        defer { Task { await gate.release() } }
        let task = Task { try await f.controller.syncGroup(groupID: groupID) }
        await gate.entered()
        task.cancel()
        await fulfillment(of: [invalidated], timeout: 1)
        XCTAssertThrowsError(try registration.requireCurrent())
        await gate.release()
        do { _ = try await task.value; XCTFail("cancelled history installed") } catch {}
    }
}

struct NativeProducerFixture: Sendable {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)
    let local: DeviceIdentity
    let peer: DeviceIdentity
    let binding: AccountSessionBinding
    let events: [AccountGroupEvent]
    let owner: PeerAuthorizationOwner
    let clock: PeerTestBox<Date>
    let timer: PeerTestTimer
    let storage: NativeProducerStorage
    let service: NativeProducerService
    let checkpointStorage: NativeProducerCheckpointStorage
    let verifier: AccountGroupHistoryVerifier
    let configuration: AccountPeerAuthorization
    let controller: AccountSessionController

    init(empty: Bool = false, freshness: TimeInterval = 20, access: TimeInterval = 100) throws {
        local = try .ephemeral(); peer = try .ephemeral()
        binding = try AccountSessionBinding(deviceID: local.id.rawValue, audience: "test", origin: URL(string: "https://accounts.example.com")!)
        let anchor = try nativeProducerEvent(actor: local, subject: local)
        let approval = try nativeProducerEvent(actor: local, subject: peer, action: "approve", sequence: 2, previous: anchor.digest())
        events = [anchor, approval]
        let clock = PeerTestBox(Self.start); self.clock = clock
        timer = PeerTestTimer()
        owner = PeerAuthorizationOwner(local: local.id, now: { clock.value }, schedule: timer.schedule)
        let tokens = AccountSessionTokens(identity: .init(accountID: UUID(uuidString: groupAccount)!, sessionID: UUID(),
            deviceID: local.id.rawValue, audience: binding.audience), accessToken: nativeProducerToken(1), refreshToken: nativeProducerToken(2),
            accessExpiresAt: Self.start.addingTimeInterval(access), refreshExpiresAt: Self.start.addingTimeInterval(1000))
        storage = NativeProducerStorage(record: empty ? nil : try AccountStoredSession(binding: binding, tokens: tokens))
        service = NativeProducerService(tokens: tokens, history: events)
        checkpointStorage = NativeProducerCheckpointStorage()
        verifier = AccountGroupHistoryVerifier(storage: checkpointStorage)
        configuration = try AccountPeerAuthorization(owner: owner, identity: local, binding: binding, freshness: freshness)
        controller = try AccountSessionController(service: service, storage: storage, binding: binding, groupVerifier: verifier,
            peerAuthorization: configuration, now: { clock.value })
    }
    func pin() async throws {
        _ = try await verifier.confirm(anchor: events[0], expectedAccountID: groupAccount, expectedGroupID: groupID,
            expectedGeneration: 1, expectedAnchorHash: events[0].digest(), binding: binding)
    }
    func prepare() async throws { try await pin(); await controller.restore() }
    func grant() async throws { try await prepare(); _ = try await controller.syncGroup(groupID: groupID) }
}

actor NativeProducerStorage: AccountSessionStorage {
    var record: AccountStoredSession?
    var gates: [String: NativeProducerGate] = [:]
    var failing: Set<String> = []
    init(record: AccountStoredSession?) { self.record = record }
    func setGate(_ gate: NativeProducerGate, operation: String) { gates[operation] = gate }
    func fail(_ operation: String) { failing.insert(operation) }
    private func enter(_ operation: String) async throws {
        if let gate = gates[operation] { await gate.block() }
        if failing.contains(operation) { throw AccountSessionControllerError.secureStorage }
    }
    func load() async throws -> AccountStoredSession? { try await enter("load"); return record }
    func save(_ record: AccountStoredSession) async throws { try await enter("save"); self.record = record }
    func remove() async throws { try await enter("remove"); record = nil }
}

actor NativeProducerService: AccountSessionService, AccountGroupService {
    let tokens: AccountSessionTokens
    var history: [AccountGroupEvent]
    var gates: [String: NativeProducerGate] = [:]
    var failing: Set<String> = []
    init(tokens: AccountSessionTokens, history: [AccountGroupEvent]) { self.tokens = tokens; self.history = history }
    func setGate(_ gate: NativeProducerGate, operation: String) { gates[operation] = gate }
    func setHistory(_ history: [AccountGroupEvent]) { self.history = history }
    func fail(_ operation: String) { failing.insert(operation) }
    private func enter(_ operation: String) async throws {
        if let gate = gates[operation] { await gate.block() }
        if failing.contains(operation) { throw AccountServiceError.transport }
    }
    func challenge() async throws -> AccountLoginChallenge {
        .init(challengeID: nativeProducerToken(3), nonce: nativeProducerToken(4), expiresAt: NativeProducerFixture.start.addingTimeInterval(60))
    }
    func complete(challengeID: String, code: String, identityToken: String) async throws -> AccountSessionTokens { try await enter("complete"); return tokens }
    func status(accessToken: String) async throws -> AccountSessionIdentity { try await enter("status"); return tokens.identity }
    func refresh(refreshToken: String) async throws -> AccountSessionTokens {
        try await enter("refresh")
        return .init(identity: tokens.identity, accessToken: nativeProducerToken(5), refreshToken: nativeProducerToken(6),
            accessExpiresAt: tokens.accessExpiresAt, refreshExpiresAt: tokens.refreshExpiresAt)
    }
    func logout(accessToken: String) async throws { try await enter("logout") }
    func groupHistory(accessToken: String, groupID: String) async throws -> [AccountGroupEvent] { try await enter("history"); return history }
}

actor NativeProducerCheckpointStorage: AccountGroupCheckpointStorage {
    var checkpoint: AccountGroupCheckpoint?
    var gate: NativeProducerGate?
    var failSave = false
    func suspendSave(_ gate: NativeProducerGate) { self.gate = gate }
    func setFailure() { failSave = true }
    func load(binding: AccountSessionBinding, accountID: String, groupID: String) async throws -> AccountGroupCheckpoint? { checkpoint }
    func save(_ value: AccountGroupCheckpoint) async throws {
        if let gate { await gate.block() }
        if failSave { throw AccountGroupCheckpointError.secureStorage }
        checkpoint = value
    }
}

actor NativeProducerGate {
    private var reached = false, released = false
    private var waiters: [CheckedContinuation<Void, Never>] = [], blockers: [CheckedContinuation<Void, Never>] = []
    func block() async {
        reached = true; waiters.forEach { $0.resume() }; waiters = []
        if !released { await withCheckedContinuation { blockers.append($0) } }
    }
    func entered() async { if !reached { await withCheckedContinuation { waiters.append($0) } } }
    func release() { released = true; blockers.forEach { $0.resume() }; blockers = [] }
}

func nativeProducerToken(_ byte: UInt8) -> String {
    Data(repeating: byte, count: 32).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

func nativeProducerEvent(actor: DeviceIdentity, subject: DeviceIdentity, action: String = "bootstrap", sequence: UInt64 = 1,
                         previous: Data = Data(), generation: UInt64 = 1) throws -> AccountGroupEvent {
    func make(_ signature: Data = Data(), _ subjectSignature: Data = Data()) throws -> AccountGroupEvent {
        try AccountGroupEvent(accountID: groupAccount, groupID: groupID, generation: generation, sequence: sequence,
            previousHash: previous, action: action, actorDeviceID: actor.id.rawValue.uuidString.lowercased(), actorPublicKey: actor.publicKey.rawRepresentation,
            subjectDeviceID: subject.id.rawValue.uuidString.lowercased(), subjectPublicKey: subject.publicKey.rawRepresentation,
            epochMilliseconds: 1_800_000_000_000, signature: signature, subjectSignature: subjectSignature)
    }
    let unsigned = try make(), payload = try unsigned.canonicalPayload()
    return try make(actor.sign(payload).derRepresentation, action == "approve" ? subject.sign(payload).derRepresentation : Data())
}
