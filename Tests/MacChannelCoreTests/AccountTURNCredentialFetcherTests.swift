import XCTest
@testable import MacChannelCore

final class AccountTURNCredentialFetcherTests: XCTestCase, @unchecked Sendable {
    func testCancelledNoncooperativeRequestsRemainBoundedUntilDrained() async throws {
        let f = try AccountTURNFixture()
        try await f.grant()
        let gate = NativeProducerGate()
        await f.service.setGate(gate)
        var tasks: [Task<RendezvousTURNCredentials, Error>] = []
        for expected in 1...8 {
            tasks.append(Task { try await f.fetcher.fetch() })
            for _ in 0..<1000 {
                if await f.service.requests.count == expected { break }
                await Task.yield()
            }
        }
        let count = await f.service.requests.count
        XCTAssertEqual(count, 8)
        await f.controller.suspendAccountRuntime()
        _ = try await f.controller.syncGroup(groupID: groupID)
        do { _ = try await f.fetcher.fetch(); XCTFail("noncooperative work exceeded bound") }
        catch { XCTAssertEqual(error as? AccountRouteBindingError, .busy) }
        await gate.release()
        for task in tasks { do { _ = try await task.value; XCTFail("retired response escaped") } catch {} }
        _ = try await f.fetcher.fetch()
    }

    func testUnverifiedContextNeverIssuesRequest() async throws {
        let f = try AccountTURNFixture()
        await f.controller.restore()
        do { _ = try await f.fetcher.fetch(); XCTFail("unapproved context") } catch {}
        let count = await f.service.requests.count
        XCTAssertEqual(count, 0)
    }

    func testVerifiedPrivateRequestClipsServerExpiryToAuthority() async throws {
        for access: TimeInterval in [10, 100] {
            let f = try AccountTURNFixture(access: access)
            try await f.grant()
            let credentials: RendezvousTURNCredentials
            do { credentials = try await f.fetcher.fetch() }
            catch { XCTFail("verified context must fetch usable credentials: \(error)"); return }
            XCTAssertEqual(credentials.expiresAt, NativeProducerFixture.start.addingTimeInterval(min(access, 20)))
            let first = await f.service.requests.first
            let request = try XCTUnwrap(first)
            XCTAssertEqual(request.token, nativeProducerToken(1))
            XCTAssertEqual(request.group, groupID)
            XCTAssertEqual(request.generation, 1)
        }
    }

    func testLateResponsesCannotCrossWithdrawalRefreshOrInvalidHistory() async throws {
        for change in ["background", "replacement", "refresh", "generation", "remove", "expiry"] {
            let f = try AccountTURNFixture()
            try await f.grant()
            let gate = NativeProducerGate()
            await f.service.setGate(gate)
            let task = Task { try await f.fetcher.fetch() }
            await gate.entered()
            switch change {
            case "background": await f.controller.suspendAccountRuntime()
            case "replacement":
                await f.controller.suspendAccountRuntime()
                _ = try await f.controller.syncGroup(groupID: groupID)
            case "refresh": try await f.controller.refresh()
            case "generation":
                await f.base.service.setHistory([try nativeProducerEvent(actor: f.base.local, subject: f.base.local, generation: 2)])
                _ = try? await f.controller.syncGroup(groupID: groupID)
            case "remove":
                await f.base.service.setHistory(f.base.events + [try nativeProducerEvent(actor: f.base.local,
                    subject: f.base.local, action: "remove", sequence: 3, previous: f.base.events[1].digest())])
                _ = try? await f.controller.syncGroup(groupID: groupID)
            default: f.base.clock.update { $0 = $0.addingTimeInterval(20) }
            }
            await gate.release()
            do { _ = try await task.value; XCTFail("released stale TURN: \(change)") } catch {}
        }
    }

    func testCallerCancellationRejectsNoncooperativeResponse() async throws {
        let f = try AccountTURNFixture()
        try await f.grant()
        let gate = NativeProducerGate()
        await f.service.setGate(gate)
        let task = Task { try await f.fetcher.fetch() }
        await gate.entered()
        task.cancel()
        await gate.release()
        do { _ = try await task.value; XCTFail("cancelled fetch returned credentials") } catch {}
        let cancelled = await f.service.sawCancellation
        XCTAssertTrue(cancelled)
    }

    func testInvalidExpiryAndTransportFailureReturnNoCredentials() async throws {
        for expiry in [Double.nan, 0, -1] {
            let f = try AccountTURNFixture()
            try await f.grant()
            await f.service.setExpiry(NativeProducerFixture.start.addingTimeInterval(expiry))
            do { _ = try await f.fetcher.fetch(); XCTFail("invalid expiry") } catch {}
        }
        let f = try AccountTURNFixture()
        try await f.grant()
        await f.service.setFailure()
        do { _ = try await f.fetcher.fetch(); XCTFail("transport failure") } catch {}
    }

    func testSameContextRefreshDoesNotExtendInFlightCredentialWindow() async throws {
        let f = try AccountTURNFixture()
        try await f.grant()
        let gate = NativeProducerGate()
        await f.service.setGate(gate)
        let task = Task { try await f.fetcher.fetch() }
        await gate.entered()
        f.base.clock.update { $0 = $0.addingTimeInterval(5) }
        _ = try await f.controller.syncGroup(groupID: groupID)
        await gate.release()
        let credentials = try await task.value
        XCTAssertEqual(credentials.expiresAt, NativeProducerFixture.start.addingTimeInterval(20))
    }
}

private struct AccountTURNFixture: Sendable {
    let base: NativeProducerFixture
    let service: AccountTURNFixtureService
    let controller: AccountSessionController
    let fetcher: AccountTURNCredentialFetcher
    init(access: TimeInterval = 100) throws {
        let base = try NativeProducerFixture(access: access); self.base = base
        service = AccountTURNFixtureService(base: base.service)
        let owner = PeerAuthorizationOwner(local: base.local.id, now: { base.clock.value }, schedule: base.timer.schedule)
        let configuration = try AccountPeerAuthorization(owner: owner, identity: base.local, binding: base.binding, freshness: 20)
        controller = try AccountSessionController(service: service, storage: base.storage, binding: base.binding,
            groupVerifier: base.verifier, peerAuthorization: configuration, now: { base.clock.value })
        fetcher = AccountTURNCredentialFetcher(controller: controller)
    }
    func grant() async throws {
        try await base.pin(); await controller.restore()
        _ = try await controller.syncGroup(groupID: groupID)
    }
}

private actor AccountTURNFixtureService: AccountSessionService, AccountGroupService, AccountTURNCredentialService {
    let base: NativeProducerService
    var requests: [(token: String, group: String, generation: UInt64)] = []
    var gate: NativeProducerGate?
    var sawCancellation = false, failed = false
    var expiry = NativeProducerFixture.start.addingTimeInterval(90)
    init(base: NativeProducerService) { self.base = base }
    func setGate(_ gate: NativeProducerGate) { self.gate = gate }
    func setExpiry(_ expiry: Date) { self.expiry = expiry }
    func setFailure() { failed = true }
    func turnCredentials(accessToken: String, groupID: String, generation: UInt64) async throws -> RendezvousTURNCredentials {
        requests.append((accessToken, groupID, generation))
        await gate?.block()
        sawCancellation = Task.isCancelled
        if failed { throw AccountServiceError.transport }
        return .init(urls: ["turn:relay.example.com:3478"], username: "fixture", credential: "fixture-secret", expiresAt: expiry)
    }
    func challenge() async throws -> AccountLoginChallenge { try await base.challenge() }
    func complete(challengeID: String, code: String, identityToken: String) async throws -> AccountSessionTokens {
        try await base.complete(challengeID: challengeID, code: code, identityToken: identityToken)
    }
    func status(accessToken: String) async throws -> AccountSessionIdentity { try await base.status(accessToken: accessToken) }
    func refresh(refreshToken: String) async throws -> AccountSessionTokens { try await base.refresh(refreshToken: refreshToken) }
    func logout(accessToken: String) async throws { try await base.logout(accessToken: accessToken) }
    func groupHistory(accessToken: String, groupID: String) async throws -> [AccountGroupEvent] {
        try await base.groupHistory(accessToken: accessToken, groupID: groupID)
    }
}
