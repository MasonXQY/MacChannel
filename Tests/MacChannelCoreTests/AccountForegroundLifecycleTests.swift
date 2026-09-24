import XCTest
@testable import MacChannelCore

final class AccountForegroundLifecycleTests: XCTestCase, @unchecked Sendable {
    func testInitialStatusOutageRecoversWithoutOpeningSettings() async throws {
        let f = try ForegroundFixture()
        try await f.base.pin()
        await f.service.setStatusFailure(true)
        await f.lifecycle.start()
        let unavailable = await f.lifecycle.requestRefresh()
        XCTAssertEqual(unavailable, .unavailable)
        await f.service.setStatusFailure(false)
        _ = await f.lifecycle.requestRefresh()
        XCTAssertNoThrow(try f.owner.acquire(for: f.base.peer.id))
        await f.lifecycle.stop()
    }

    func testCadenceAndOutageRetryAreBoundedAndInjectable() async throws {
        let pauses = PeerTestBox<[Duration]>([])
        let f = try ForegroundFixture(sleep: { duration in
            pauses.update { $0.append(duration) }
            try await Task.sleep(for: .seconds(3600))
        })
        try await f.base.pin()
        await f.lifecycle.start()
        _ = await f.lifecycle.requestRefresh()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(pauses.value, [.seconds(60)])
        await f.service.setOutage(true)
        _ = await f.lifecycle.requestRefresh()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(pauses.value, [.seconds(60), .seconds(5)])
        await f.lifecycle.stop()
    }

    func testEarlySessionRefreshKeepsCredentialsPrivateAndUsesCurrentEpoch() async throws {
        let f = try ForegroundFixture()
        try await f.base.pin()
        await f.lifecycle.start()
        _ = await f.lifecycle.requestRefresh()
        f.base.clock.update { $0 = $0.addingTimeInterval(950) }
        _ = await f.lifecycle.requestRefresh()
        let refreshes = await f.service.refreshes
        XCTAssertEqual(refreshes, 1)
        XCTAssertNoThrow(try f.owner.acquire(for: f.base.peer.id))
        f.base.clock.update { $0 = $0.addingTimeInterval(50) }
        XCTAssertThrowsError(try f.owner.acquire(for: f.base.peer.id))
        await f.lifecycle.stop()
    }

    func testForegroundGrantsWithoutSettingsAndRepeatedStartDoesNotLoop() async throws {
        let f = try ForegroundFixture()
        try await f.base.pin()
        await f.lifecycle.start()
        await f.lifecycle.start()
        _ = await f.lifecycle.requestRefresh()
        XCTAssertNoThrow(try f.owner.acquire(for: f.base.peer.id))
        try await Task.sleep(for: .milliseconds(20))
        let count = await f.service.discoveries
        XCTAssertEqual(count, 1, "sync wakeups must not feed another refresh")
        await f.lifecycle.stop()
        XCTAssertThrowsError(try f.owner.acquire(for: f.base.peer.id))
        let record = try await f.base.storage.load()
        XCTAssertNotNil(record)
    }

    func testDismissedRefreshCallerDoesNotWithdrawOwnedWork() async throws {
        let f = try ForegroundFixture()
        try await f.base.pin()
        let gate = NativeProducerGate()
        await f.base.service.setGate(gate, operation: "history")
        await f.lifecycle.start()
        await gate.entered()
        let presentation = Task { await f.lifecycle.requestRefresh() }
        presentation.cancel()
        await gate.release()
        _ = await presentation.value
        XCTAssertNoThrow(try f.owner.acquire(for: f.base.peer.id))
        await f.lifecycle.stop()
    }

    func testBackgroundFencesNoncooperativeHistoryAndRestartJoinsOldWork() async throws {
        let f = try ForegroundFixture()
        try await f.base.pin()
        let gate = NativeProducerGate()
        await f.base.service.setGate(gate, operation: "history")
        await f.lifecycle.start()
        await gate.entered()
        let stopped = PeerTestBox(false)
        let stop = Task { await f.lifecycle.stop(); stopped.update { $0 = true } }
        for _ in 0..<100 { await Task.yield() }
        let start = Task { await f.lifecycle.start() }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(stopped.value)
        XCTAssertTrue(f.owner.snapshot().peers.isEmpty)
        let count = await f.service.discoveries
        XCTAssertEqual(count, 1)
        await gate.release()
        await stop.value
        await start.value
        _ = await f.lifecycle.requestRefresh()
        XCTAssertNoThrow(try f.owner.acquire(for: f.base.peer.id))
        await f.lifecycle.stop()
    }

    func testMissingPinDoesNotBootstrapThenExplicitConsentActivates() async throws {
        let f = try ForegroundFixture()
        await f.lifecycle.start()
        let missing = await f.lifecycle.requestRefresh()
        XCTAssertEqual(missing, .approvalRequired)
        XCTAssertTrue(f.owner.snapshot().peers.isEmpty)
        let writes = await f.service.bootstraps
        XCTAssertEqual(writes, 0)
        try await f.base.pin() // Models independently confirmed local consent.
        _ = await f.lifecycle.requestRefresh()
        XCTAssertNoThrow(try f.owner.acquire(for: f.base.peer.id))
        await f.lifecycle.stop()
    }

    func testOutageAndRemovalDoNotExtendEvidence() async throws {
        let f = try ForegroundFixture()
        try await f.base.pin()
        await f.lifecycle.start()
        _ = await f.lifecycle.requestRefresh()
        XCTAssertNoThrow(try f.owner.acquire(for: f.base.peer.id))
        await f.service.setOutage(true)
        _ = await f.lifecycle.requestRefresh()
        XCTAssertThrowsError(try f.owner.acquire(for: f.base.peer.id))
        await f.service.setOutage(false)
        await f.base.service.setHistory(f.base.events + [try nativeProducerEvent(actor: f.base.local, subject: f.base.local,
            action: "remove", sequence: 3, previous: f.base.events[1].digest())])
        _ = await f.lifecycle.requestRefresh()
        XCTAssertThrowsError(try f.owner.acquire(for: f.base.peer.id))
        await f.lifecycle.stop()
    }
}

private struct ForegroundFixture {
    let base: NativeProducerFixture
    let owner: PeerAuthorizationOwner
    let service: ForegroundService
    let controller: AccountSessionController
    let lifecycle: AccountForegroundLifecycle
    init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) throws {
        let base = try NativeProducerFixture(access: 1000); self.base = base
        owner = PeerAuthorizationOwner(local: base.local.id, now: { base.clock.value }, schedule: base.timer.schedule)
        service = ForegroundService(base)
        controller = try AccountSessionController(service: service, storage: base.storage, binding: base.binding,
            groupVerifier: base.verifier, peerAuthorization: AccountPeerAuthorization(owner: owner, identity: base.local,
                binding: base.binding, freshness: 300), firstDeviceEnrollment: AccountFirstDeviceEnrollment(identity: base.local),
            now: { base.clock.value })
        lifecycle = AccountForegroundLifecycle(controller: controller, sleep: sleep, now: { base.clock.value })
    }
}

private actor ForegroundService: AccountSessionService, AccountGroupService, AccountGroupEnrollmentService {
    let base: NativeProducerFixture
    var discoveries = 0, bootstraps = 0, refreshes = 0
    var outage = false
    var statusFailure = false
    init(_ base: NativeProducerFixture) { self.base = base }
    func setOutage(_ value: Bool) { outage = value }
    func setStatusFailure(_ value: Bool) { statusFailure = value }
    func challenge() async throws -> AccountLoginChallenge { try await base.service.challenge() }
    func complete(challengeID: String, code: String, identityToken: String) async throws -> AccountSessionTokens {
        try await base.service.complete(challengeID: challengeID, code: code, identityToken: identityToken)
    }
    func status(accessToken: String) async throws -> AccountSessionIdentity {
        if statusFailure { throw AccountServiceError.transport }
        return try await base.service.status(accessToken: accessToken)
    }
    func refresh(refreshToken: String) async throws -> AccountSessionTokens {
        refreshes += 1
        return try await base.service.refresh(refreshToken: refreshToken)
    }
    func logout(accessToken: String) async throws { try await base.service.logout(accessToken: accessToken) }
    func groupHistory(accessToken: String, groupID: String) async throws -> [AccountGroupEvent] {
        try await base.service.groupHistory(accessToken: accessToken, groupID: groupID)
    }
    func discoverGroup(accessToken: String, accountID: String) async throws -> AccountGroupDiscovery {
        discoveries += 1
        if outage { throw AccountServiceError.transport }
        return .present(.init(groupID: groupID, generation: 1, anchor: base.events[0], anchorHash: try base.events[0].digest(),
            headSequence: 2, headHash: try base.events[1].digest()))
    }
    func recordGroupBootstrap(accessToken: String, event: AccountGroupEvent) async throws { bootstraps += 1 }
}
