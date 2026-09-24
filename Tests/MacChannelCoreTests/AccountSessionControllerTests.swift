import Foundation
import XCTest
@testable import MacChannelCore

final class AccountSessionControllerTests: XCTestCase {
    func testRestoredPendingRefreshNeverReusesOldToken() async throws {
        let fixture = try AccountControllerFixture(storedPhase: .refreshPending)
        await fixture.controller.restore()
        let calls = await fixture.service.calls
        XCTAssertEqual(calls, [])
        let state = await fixture.controller.snapshot()
        XCTAssertEqual(state.phase, .needsSignIn)
        XCTAssertNil(state.identity)
    }

    func testRestoreVerifiesBeforePublishingAndCoalesces() async throws {
        let f = try AccountControllerFixture()
        let gate = AsyncGate()
        await f.service.setGate(gate, for: "status")
        let first = Task { await f.controller.restore() }
        await gate.entered()
        let state = await f.controller.snapshot()
        XCTAssertEqual(state.phase, .restoring)
        XCTAssertNil(state.identity)
        let second = Task { await f.controller.restore() }
        await f.operations.wait(for: .restoreJoined)
        await gate.release()
        await first.value; await second.value
        let calls = await f.service.calls
        let loads = await f.storage.loads
        XCTAssertEqual(calls, ["status"])
        XCTAssertEqual(loads, 1)
        let final = await f.controller.snapshot()
        XCTAssertEqual(final.phase, .signedIn)
    }

    func testRefreshDurablePendingAndConcurrentWaitersRotateOnce() async throws {
        let f = try AccountControllerFixture()
        await f.controller.restore()
        let gate = AsyncGate()
        await f.service.setGate(gate, for: "refresh")
        let first = Task { try await f.controller.refresh() }
        await gate.entered()
        let pending = await f.storage.record
        XCTAssertEqual(pending?.phase, .refreshPending)
        let second = Task { try await f.controller.refresh() }
        await f.operations.wait(for: .refreshJoined)
        second.cancel()
        await gate.release()
        try await first.value; try await second.value
        let calls = await f.service.calls
        XCTAssertEqual(calls.filter { $0 == "refresh" }.count, 1)
        let active = await f.storage.record
        XCTAssertEqual(active?.phase, .active)
        XCTAssertEqual(active?.tokens.accessToken, AccountControllerFixture.token(5))
    }

    func testPendingWriteFailureSendsNoRefresh() async throws {
        let f = try AccountControllerFixture()
        await f.controller.restore()
        await f.storage.failSave(number: 1)
        await expectError(.secureStorage) { try await f.controller.refresh() }
        let calls = await f.service.calls
        XCTAssertEqual(calls, ["status"])
    }

    func testLostRefreshAndReplacementWriteFailureNeverReplayAfterRestart() async throws {
        for failWrite in [false, true] {
            let f = try AccountControllerFixture()
            await f.controller.restore()
            await f.storage.setRemoveFailure(true)
            if failWrite { await f.storage.failSave(number: 2) }
            else { await f.service.setError(.transport, for: "refresh") }
            await expectError(.secureStorage) { try await f.controller.refresh() }
            let pending = await f.storage.record
            XCTAssertEqual(pending?.phase, .refreshPending)
            await f.storage.setRemoveFailure(false)
            let restarted = f.newController()
            await restarted.restore()
            let state = await restarted.snapshot()
            XCTAssertEqual(state.phase, .needsSignIn)
            let calls = await f.service.calls
            XCTAssertEqual(calls, ["status", "refresh"])
        }
    }

    func testLogoutWaitsForRefreshAndUsesNewToken() async throws {
        let f = try AccountControllerFixture()
        await f.controller.restore()
        let gate = AsyncGate()
        await f.service.setGate(gate, for: "refresh")
        let logoutGate = AsyncGate()
        await f.service.setGate(logoutGate, for: "logout")
        let refresh = Task { try await f.controller.refresh() }
        await gate.entered()
        let logout = Task { try await f.controller.logout() }
        await f.operations.wait(for: .logoutStarted)
        await expectError(.busy) { try await f.controller.refresh() }
        await expectError(.busy) { _ = try await f.controller.beginLogin() }
        await gate.release()
        await logoutGate.entered()
        await expectError(.busy) { _ = try await f.controller.beginLogin() }
        let duplicate = Task { try await f.controller.logout() }
        await f.operations.wait(for: .logoutJoined)
        await logoutGate.release()
        try await refresh.value; try await logout.value; try await duplicate.value
        let sent = await f.service.logoutTokens
        XCTAssertEqual(sent, [AccountControllerFixture.token(5)])
        let state = await f.controller.snapshot()
        XCTAssertEqual(state.phase, .signedOut)
    }

    func testLogoutUnavailableRetriesAndAcknowledgedRemovalFailureOnlyRetriesRemoval() async throws {
        let f = try AccountControllerFixture()
        await f.controller.restore()
        await f.service.setError(.transport, for: "logout")
        await expectError(.unavailable) { try await f.controller.logout() }
        let retained = await f.storage.record
        XCTAssertNotNil(retained)
        await f.service.setError(nil, for: "logout")
        await f.storage.setRemoveFailure(true)
        await expectError(.secureStorage) { try await f.controller.logout() }
        let state = await f.controller.snapshot()
        XCTAssertNil(state.identity)
        await f.storage.setRemoveFailure(false)
        try await f.controller.logout()
        let calls = await f.service.calls
        XCTAssertEqual(calls, ["status", "logout", "logout"])
    }

    func testExplicitLocalDiscardAfterLogoutFailureUnblocksLogin() async throws {
        let f = try AccountControllerFixture()
        await f.controller.restore()
        await f.service.setError(.transport, for: "logout")

        await expectError(.unavailable) { try await f.controller.logout() }
        let retained = await f.storage.record
        XCTAssertNotNil(retained)

        try await f.controller.discardLocalSessionAfterLogoutFailure()

        let discarded = await f.storage.record
        XCTAssertNil(discarded)
        let state = await f.controller.snapshot()
        XCTAssertEqual(state.phase, .signedOut)
        let attempt = try await f.controller.beginLogin()
        await f.controller.cancelLogin(attemptID: attempt.id)
    }

    func testLoginLifecycleRejectsStaleAndDuplicateCallbacks() async throws {
        let f = try AccountControllerFixture(empty: true)
        let attempt = try await f.controller.beginLogin()
        await expectError(.invalidAttempt) { try await f.controller.completeLogin(attemptID: UUID(), code: "code", identityToken: "jwt") }
        try await f.controller.completeLogin(attemptID: attempt.id, code: "code", identityToken: "jwt")
        await expectError(.invalidAttempt) { try await f.controller.completeLogin(attemptID: attempt.id, code: "code", identityToken: "jwt") }
        let state = await f.controller.snapshot()
        XCTAssertEqual(state.phase, .signedIn)
        let calls = await f.service.calls
        XCTAssertEqual(calls, ["challenge", "complete"])
    }

    func testWebLoginPersistsOnlyAfterOneTimeReadyResult() async throws {
        let f = try AccountControllerFixture(empty: true)
        let handoff = try await f.controller.beginWebLogin()
        XCTAssertEqual(handoff.attemptID, AccountControllerFixture.token(8))
        let awaiting = await f.controller.snapshot()
        XCTAssertEqual(awaiting.phase, .awaitingApple)

        let pending = try await f.controller.pollWebLogin(attemptID: handoff.attemptID)
        XCTAssertNil(pending)
        let beforeReady = await f.storage.record
        XCTAssertNil(beforeReady)
        await f.service.makeWebLoginReady()
        let ready = try await f.controller.pollWebLogin(attemptID: handoff.attemptID)
        XCTAssertEqual(ready?.phase, .signedIn)
        let stored = await f.storage.record
        XCTAssertEqual(stored?.tokens.identity, f.tokens.identity)
        await expectError(.invalidAttempt) {
            _ = try await f.controller.pollWebLogin(attemptID: handoff.attemptID)
        }
        let calls = await f.service.calls
        XCTAssertEqual(calls, ["web-start", "web-poll", "web-poll"])
    }

    func testCancelledWebLoginCannotPublishSession() async throws {
        let f = try AccountControllerFixture(empty: true)
        let handoff = try await f.controller.beginWebLogin()
        await f.service.makeWebLoginReady()
        await f.controller.cancelWebLogin(attemptID: handoff.attemptID)
        await expectError(.invalidAttempt) {
            _ = try await f.controller.pollWebLogin(attemptID: handoff.attemptID)
        }
        let signedOut = await f.controller.snapshot()
        let stored = await f.storage.record
        XCTAssertEqual(signedOut.phase, .signedOut)
        XCTAssertNil(stored)
    }

    func testCancelPreparingAndAppleSheetNeverCompletesSession() async throws {
        let f = try AccountControllerFixture(empty: true)
        let gate = AsyncGate()
        await f.service.setGate(gate, for: "challenge")
        let preparation = Task { try await f.controller.beginLogin() }
        await gate.entered()
        preparation.cancel()
        await gate.release()
        do { _ = try await preparation.value; XCTFail("cancelled preparation returned attempt") } catch {}
        let afterCancel = await f.controller.snapshot()
        XCTAssertEqual(afterCancel.phase, .signedOut)
        let attempt = try await f.controller.beginLogin()
        await f.controller.cancelLogin(attemptID: attempt.id)
        await expectError(.invalidAttempt) { try await f.controller.completeLogin(attemptID: attempt.id, code: "code", identityToken: "jwt") }
        let calls = await f.service.calls
        XCTAssertEqual(calls, ["challenge", "challenge"])
    }

    func testFailedLoginSaveRevokesOnceAndWithholdsIdentity() async throws {
        let f = try AccountControllerFixture(empty: true)
        await f.storage.failSave(number: 1)
        let attempt = try await f.controller.beginLogin()
        await expectError(.secureStorage) { try await f.controller.completeLogin(attemptID: attempt.id, code: "code", identityToken: "jwt") }
        let state = await f.controller.snapshot()
        XCTAssertEqual(state.phase, .secureStorageError)
        XCTAssertNil(state.identity)
        let calls = await f.service.calls
        XCTAssertEqual(calls, ["challenge", "complete", "logout"])
    }

    func testRestoreUnavailableRetainsRecordAndExplicitRetryVerifiesAgain() async throws {
        let f = try AccountControllerFixture()
        await f.service.setError(.invalidResponse, for: "status")
        await f.controller.restore()
        let failed = await f.controller.snapshot()
        XCTAssertEqual(failed.phase, .unavailable)
        XCTAssertNil(failed.identity)
        let retained = await f.storage.record
        XCTAssertNotNil(retained)
        await f.service.setError(nil, for: "status")
        await f.controller.restore()
        let state = await f.controller.snapshot()
        XCTAssertEqual(state.phase, .signedIn)
    }

    func testRestoreSubstitutedIdentityNeverPublishesSignedIn() async throws {
        for field in ["account", "session", "device", "audience"] {
            let f = try AccountControllerFixture()
            await f.service.setReturnedIdentity(f.changedIdentity(field))
            await f.controller.restore()
            let state = await f.controller.snapshot()
            XCTAssertEqual(state.phase, .unavailable)
            XCTAssertNil(state.identity)
            let calls = await f.service.calls
            XCTAssertEqual(calls, ["status"])
        }
    }

    func testRestoreMismatchedBindingDiscardsOnlyAccountRecord() async throws {
        for field in ["device", "audience", "origin"] {
            let f = try AccountControllerFixture()
            let other = try AccountSessionBinding(deviceID: field == "device" ? UUID() : f.binding.deviceID,
                                                  audience: field == "audience" ? "other" : f.binding.audience,
                                                  origin: field == "origin" ? URL(string: "https://other.example.com")! : f.binding.origin)
            let controller = AccountSessionController(service: f.service, storage: f.storage, binding: other)
            await controller.restore()
            let state = await controller.snapshot()
            XCTAssertEqual(state.phase, .signedOut)
            let calls = await f.service.calls
            XCTAssertEqual(calls, [])
            let record = await f.storage.record
            XCTAssertNil(record)
        }
    }

    func testExpiredAccessOrRejectedStatusRefreshesOnceAndExpiredRefreshNeverCallsService() async throws {
        for expiredAccess in [false, true] {
            let f = try AccountControllerFixture()
            if expiredAccess {
                await f.storage.replace(try AccountStoredSession(binding: f.binding, tokens: f.copyTokens(accessExpiry: AccountControllerFixture.date)))
            } else { await f.service.setError(.authenticationRejected, for: "status") }
            await f.controller.restore()
            let state = await f.controller.snapshot()
            XCTAssertEqual(state.phase, .signedIn)
            let calls = await f.service.calls
            XCTAssertEqual(calls, expiredAccess ? ["refresh"] : ["status", "refresh"])
        }
        let f = try AccountControllerFixture()
        await f.storage.replace(try AccountStoredSession(binding: f.binding, tokens: f.copyTokens(accessExpiry: AccountControllerFixture.date, refreshExpiry: AccountControllerFixture.date)))
        await f.controller.restore()
        let state = await f.controller.snapshot()
        XCTAssertEqual(state.phase, .needsSignIn)
        let calls = await f.service.calls
        XCTAssertEqual(calls, [])
    }

    func testRefreshRejectsChangedAccountDeviceAndAudienceButAllowsNewSession() async throws {
        for field in ["account", "device", "audience", "session"] {
            let f = try AccountControllerFixture()
            await f.controller.restore()
            await f.service.setReturnedIdentity(f.changedIdentity(field))
            if field == "session" { try await f.controller.refresh() }
            else { await expectError(.needsSignIn) { try await f.controller.refresh() } }
            let state = await f.controller.snapshot()
            XCTAssertEqual(state.phase, field == "session" ? .signedIn : .needsSignIn)
            let record = await f.storage.record
            XCTAssertEqual(record != nil, field == "session")
        }
    }

    func testLoginRejectsWrongDeviceOrAudienceAndCancellationCannotUndoCompletion() async throws {
        for field in ["device", "audience"] {
            let f = try AccountControllerFixture(empty: true)
            let attempt = try await f.controller.beginLogin()
            await f.service.setReturnedIdentity(f.changedIdentity(field))
            await expectError(.unavailable) { try await f.controller.completeLogin(attemptID: attempt.id, code: "code", identityToken: "jwt") }
            let record = await f.storage.record
            XCTAssertNil(record)
        }
        let f = try AccountControllerFixture(empty: true)
        let attempt = try await f.controller.beginLogin()
        let gate = AsyncGate()
        await f.service.setGate(gate, for: "complete")
        let completion = Task { try await f.controller.completeLogin(attemptID: attempt.id, code: "code", identityToken: "jwt") }
        await gate.entered()
        await f.controller.cancelLogin(attemptID: attempt.id)
        let progress = await f.controller.snapshot()
        XCTAssertEqual(progress.phase, .signingIn)
        await gate.release()
        try await completion.value
        let state = await f.controller.snapshot()
        XCTAssertEqual(state.phase, .signedIn)
    }

    func testRejectedLogoutRequiresRefreshRejectionBeforeNeedsSignIn() async throws {
        let f = try AccountControllerFixture()
        await f.controller.restore()
        await f.service.setError(.authenticationRejected, for: "logout")
        await f.service.setError(.authenticationRejected, for: "refresh")
        await expectError(.needsSignIn) { try await f.controller.logout() }
        let calls = await f.service.calls
        XCTAssertEqual(calls, ["status", "logout", "refresh"])
        let state = await f.controller.snapshot()
        XCTAssertEqual(state.phase, .needsSignIn)
    }

    func testLogoutOnNewControllerDoesNotClaimSuccessOverStoredCredentials() async throws {
        let f = try AccountControllerFixture()
        try await f.controller.logout()
        let calls = await f.service.calls
        XCTAssertEqual(calls, ["status", "logout"])
        let record = await f.storage.record
        XCTAssertNil(record)
    }

    func testCorruptReadAndPendingRemovalFailureCannotPublishIdentity() async throws {
        let corrupt = try AccountControllerFixture()
        await corrupt.storage.setLoadFailure(true)
        await corrupt.controller.restore()
        let corruptState = await corrupt.controller.snapshot()
        XCTAssertEqual(corruptState.phase, .secureStorageError)
        await expectError(.secureStorage) { _ = try await corrupt.controller.beginLogin() }
        let pending = try AccountControllerFixture(storedPhase: .refreshPending)
        await pending.storage.setRemoveFailure(true)
        await pending.controller.restore()
        let pendingState = await pending.controller.snapshot()
        XCTAssertEqual(pendingState.phase, .secureStorageError)
        XCTAssertNil(pendingState.identity)
        let calls = await pending.service.calls
        XCTAssertEqual(calls, [])
    }

    func testExpiredAttemptConsumesCallbackWithoutCompletionRequest() async throws {
        let f = try AccountControllerFixture(empty: true)
        let attempt = try await f.controller.beginLogin()
        f.clock.set(AccountControllerFixture.date.addingTimeInterval(61))
        await expectError(.invalidAttempt) { try await f.controller.completeLogin(attemptID: attempt.id, code: "code", identityToken: "jwt") }
        let calls = await f.service.calls
        XCTAssertEqual(calls, ["challenge"])
    }

    func testLogoutRefreshesExpiredAccessBeforeSendingLogout() async throws {
        let f = try AccountControllerFixture()
        await f.controller.restore()
        f.clock.set(AccountControllerFixture.date.addingTimeInterval(601))
        await f.service.setExpiry(AccountControllerFixture.date.addingTimeInterval(1200))
        try await f.controller.logout()
        let calls = await f.service.calls
        XCTAssertEqual(calls, ["status", "refresh", "logout"])
        let tokens = await f.service.logoutTokens
        XCTAssertEqual(tokens, [AccountControllerFixture.token(5)])
    }

    func testServiceCancellationAfterRefreshPendingRequiresFreshLogin() async throws {
        let f = try AccountControllerFixture()
        await f.controller.restore()
        await f.service.setCancelledRefresh()
        await expectError(.needsSignIn) { try await f.controller.refresh() }
        await f.newController().restore()
        let calls = await f.service.calls
        XCTAssertEqual(calls, ["status", "refresh"])
        let record = await f.storage.record
        XCTAssertNil(record)
    }

    private func expectError(_ expected: AccountSessionControllerError, operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? AccountSessionControllerError, expected) }
    }
}

private struct AccountControllerFixture {
    static let date = Date(timeIntervalSince1970: 2_000_000_000)
    let storage: SessionMemoryStore
    let service: SessionServiceStub
    let controller: AccountSessionController
    let binding: AccountSessionBinding
    let tokens: AccountSessionTokens
    let clock: SessionClock
    let operations: SessionOperations

    init(storedPhase: AccountStoredSession.Phase = .active, empty: Bool = false) throws {
        let device = UUID()
        binding = try AccountSessionBinding(deviceID: device, audience: "test.audience", origin: URL(string: "https://accounts.example.com")!)
        tokens = AccountSessionTokens(identity: .init(accountID: UUID(), sessionID: UUID(), deviceID: device, audience: binding.audience), accessToken: Self.token(1), refreshToken: Self.token(2), accessExpiresAt: Self.date.addingTimeInterval(600), refreshExpiresAt: Self.date.addingTimeInterval(6000))
        storage = SessionMemoryStore(record: empty ? nil : try AccountStoredSession(binding: binding, tokens: tokens, phase: storedPhase))
        service = SessionServiceStub(tokens: tokens)
        let clock = SessionClock(Self.date)
        self.clock = clock
        let operations = SessionOperations()
        self.operations = operations
        controller = AccountSessionController(service: service, storage: storage, binding: binding, now: { clock.get() }, operationObserver: { operations.observe($0) })
    }
    func newController() -> AccountSessionController {
        AccountSessionController(service: service, storage: storage, binding: binding, now: { clock.get() })
    }
    func changedIdentity(_ field: String) -> AccountSessionIdentity {
        .init(accountID: field == "account" ? UUID() : tokens.identity.accountID,
              sessionID: field == "session" ? UUID() : tokens.identity.sessionID,
              deviceID: field == "device" ? UUID() : binding.deviceID,
              audience: field == "audience" ? "wrong.audience" : binding.audience)
    }
    func copyTokens(accessExpiry: Date, refreshExpiry: Date? = nil) -> AccountSessionTokens {
        .init(identity: tokens.identity, accessToken: tokens.accessToken, refreshToken: tokens.refreshToken, accessExpiresAt: accessExpiry, refreshExpiresAt: refreshExpiry ?? tokens.refreshExpiresAt)
    }
    static func token(_ byte: UInt8) -> String {
        Data(repeating: byte, count: 32).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

private actor SessionMemoryStore: AccountSessionStorage {
    var record: AccountStoredSession?
    init(record: AccountStoredSession?) { self.record = record }
    var loads = 0
    var saves = 0
    var failingSave: Int?
    var failingRemove = false
    var failingLoad = false
    func failSave(number: Int) { failingSave = number }
    func setRemoveFailure(_ value: Bool) { failingRemove = value }
    func replace(_ value: AccountStoredSession) { record = value }
    func setLoadFailure(_ value: Bool) { failingLoad = value }
    func load() async throws -> AccountStoredSession? {
        loads += 1
        if failingLoad { throw AccountSessionControllerError.secureStorage }
        return record
    }
    func save(_ record: AccountStoredSession) async throws {
        saves += 1
        if saves == failingSave { throw AccountSessionControllerError.secureStorage }
        self.record = record
    }
    func remove() async throws {
        if failingRemove { throw AccountSessionControllerError.secureStorage }
        record = nil
    }
}

private actor SessionServiceStub: AccountSessionService, AccountWebLoginService {
    var calls: [String] = []
    let tokens: AccountSessionTokens
    var gates: [String: AsyncGate] = [:]
    var errors: [String: AccountServiceError] = [:]
    var logoutTokens: [String] = []
    var returnedIdentity: AccountSessionIdentity?
    var expiry: Date?
    var cancelRefresh = false
    var webLoginReady = false
    func setCancelledRefresh() { cancelRefresh = true }
    func makeWebLoginReady() { webLoginReady = true }
    func setExpiry(_ value: Date) { expiry = value }
    func setReturnedIdentity(_ identity: AccountSessionIdentity) { returnedIdentity = identity }
    func setGate(_ gate: AsyncGate, for name: String) { gates[name] = gate }
    func setError(_ error: AccountServiceError?, for name: String) { errors[name] = error }
    func called(_ name: String) async throws {
        calls.append(name)
        if let gate = gates[name] { await gate.block() }
        if let error = errors[name] { throw error }
    }
    init(tokens: AccountSessionTokens) { self.tokens = tokens }
    func challenge() async throws -> AccountLoginChallenge {
        try await called("challenge")
        return .init(challengeID: AccountControllerFixture.token(3), nonce: AccountControllerFixture.token(4), expiresAt: AccountControllerFixture.date.addingTimeInterval(60))
    }
    func complete(challengeID: String, code: String, identityToken: String) async throws -> AccountSessionTokens {
        try await called("complete")
        return .init(identity: returnedIdentity ?? tokens.identity, accessToken: tokens.accessToken, refreshToken: tokens.refreshToken, accessExpiresAt: tokens.accessExpiresAt, refreshExpiresAt: tokens.refreshExpiresAt)
    }
    func status(accessToken: String) async throws -> AccountSessionIdentity { try await called("status"); return returnedIdentity ?? tokens.identity }
    func refresh(refreshToken: String) async throws -> AccountSessionTokens {
        try await called("refresh")
        if cancelRefresh { throw CancellationError() }
        return .init(identity: returnedIdentity ?? tokens.identity, accessToken: AccountControllerFixture.token(5), refreshToken: AccountControllerFixture.token(6), accessExpiresAt: expiry ?? tokens.accessExpiresAt, refreshExpiresAt: tokens.refreshExpiresAt)
    }
    func logout(accessToken: String) async throws { logoutTokens.append(accessToken); try await called("logout") }
    func beginWebLogin() async throws -> AccountWebLoginAttempt {
        try await called("web-start")
        return .init(
            attemptID: AccountControllerFixture.token(8),
            authorizationURL: URL(string: "https://appleid.apple.com/auth/authorize")!,
            expiresAt: AccountControllerFixture.date.addingTimeInterval(60))
    }
    func pollWebLogin(attemptID: String) async throws -> AccountWebLoginPollResult {
        try await called("web-poll")
        return webLoginReady ? .ready(tokens) : .pending
    }
}

private final class SessionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    func get() -> Date { lock.withLock { date } }
    func set(_ date: Date) { lock.withLock { self.date = date } }
}

/// A synchronous observer records actual actor entry; waiting tests never guess
/// whether a newly created Task has reached the controller yet.
private final class SessionOperations: @unchecked Sendable {
    private let lock = NSLock()
    private var observed: Set<AccountSessionOperation> = []
    private var waiters: [AccountSessionOperation: [CheckedContinuation<Void, Never>]] = [:]
    func observe(_ operation: AccountSessionOperation) {
        let ready = lock.withLock {
            observed.insert(operation)
            return waiters.removeValue(forKey: operation) ?? []
        }
        ready.forEach { $0.resume() }
    }
    func wait(for operation: AccountSessionOperation) async {
        await withCheckedContinuation { continuation in
            let alreadyObserved = lock.withLock {
                if observed.contains(operation) { return true }
                waiters[operation, default: []].append(continuation)
                return false
            }
            if alreadyObserved { continuation.resume() }
        }
    }
}

private actor AsyncGate {
    private var reached = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var blockers: [CheckedContinuation<Void, Never>] = []
    func block() async {
        reached = true
        entryWaiters.forEach { $0.resume() }; entryWaiters = []
        if !released { await withCheckedContinuation { blockers.append($0) } }
    }
    func entered() async {
        if !reached { await withCheckedContinuation { entryWaiters.append($0) } }
    }
    func release() {
        released = true
        blockers.forEach { $0.resume() }; blockers = []
    }
}
