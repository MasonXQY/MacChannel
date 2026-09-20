import Foundation
import XCTest
@testable import MacChannelCore

final class AccountSessionGroupTests: XCTestCase {
    func testAcceptedPinnedChainIsReturnedOnlyAfterDurableSave() async throws {
        let checkpoint = GroupCheckpointStorage()
        let f = try SessionGroupFixture(checkpointStorage: checkpoint)
        _ = try await f.history.confirm(f.verifier)
        await f.controller.restore()
        let gate = GroupGate(); await checkpoint.setGate(gate)
        let sync = Task { try await f.controller.syncGroup(groupID: groupID) }
        await gate.wait()
        let before = await checkpoint.record
        XCTAssertEqual(before?.sequence, 1)
        await sessionGroupFailure(.busy) { try await f.controller.syncGroup(groupID: groupID) }
        await gate.resume()
        let result = try await sync.value
        let after = await checkpoint.record
        XCTAssertEqual(result.sequence, 3)
        XCTAssertEqual(result.headHash, after?.headHash)
        XCTAssertFalse(String(reflecting: result).contains(groupToken))
    }

    func testMissingPinWrongAccountAndStorageFailurePublishNothing() async throws {
        let missing = try SessionGroupFixture()
        await missing.controller.restore()
        await checkpointFailure(.missingCheckpoint) { try await missing.controller.syncGroup(groupID: groupID) }
        let wrong = try SessionGroupFixture(accountID: UUID())
        _ = try await wrong.history.confirm(wrong.verifier)
        await wrong.controller.restore()
        await checkpointFailure(.missingCheckpoint) { try await wrong.controller.syncGroup(groupID: groupID) }
        let failure = try SessionGroupFixture()
        _ = try await failure.history.confirm(failure.verifier)
        await failure.controller.restore()
        failure.secret.failWrites(true)
        await checkpointFailure(.secureStorage) { try await failure.controller.syncGroup(groupID: groupID) }
        XCTAssertEqual(failure.secret.writes, 1)
        failure.secret.failWrites(false)
        let accepted = try await failure.controller.syncGroup(groupID: groupID)
        XCTAssertEqual(accepted.sequence, 3)
    }

    func testSignedOutAndUnconfiguredSyncFailBeforeFetch() async throws {
        let signedOut = try SessionGroupFixture(empty: true)
        await sessionGroupFailure(.needsSignIn) { try await signedOut.controller.syncGroup(groupID: groupID) }
        let unconfigured = try SessionGroupFixture(configured: false)
        await unconfigured.controller.restore()
        await sessionGroupFailure(.unavailable) { try await unconfigured.controller.syncGroup(groupID: groupID) }
        let calls = await unconfigured.service.groupCalls
        XCTAssertEqual(calls, 0)
    }

    func testBusyDuringRestoreRefreshLogoutAndLogin() async throws {
        for operation in ["status", "refresh", "logout", "challenge", "complete"] {
            let f = try SessionGroupFixture(empty: operation == "challenge" || operation == "complete")
            if operation != "status" { await f.controller.restore() }
            var login: AccountLoginAttempt?
            if operation == "complete" { login = try await f.controller.beginLogin() }
            let gate = GroupGate(); await f.service.setGate(gate, operation: operation)
            let attemptID = login?.id
            let task = Task {
                switch operation {
                case "status": await f.controller.restore()
                case "refresh": try await f.controller.refresh()
                case "logout": try await f.controller.logout()
                case "challenge": _ = try await f.controller.beginLogin()
                default: try await f.controller.completeLogin(attemptID: attemptID!, code: "synthetic", identityToken: "synthetic")
                }
            }
            await gate.wait()
            await sessionGroupFailure(.busy) { try await f.controller.syncGroup(groupID: groupID) }
            await gate.resume(); try await task.value
        }
    }

    func testSuspendedFetchThenRefreshRejectsOldSessionEvenIfIdentityUnchanged() async throws {
        let f = try SessionGroupFixture()
        _ = try await f.history.confirm(f.verifier); await f.controller.restore()
        let gate = GroupGate(); await f.service.setGate(gate, operation: "group")
        let task = Task { try await f.controller.syncGroup(groupID: groupID) }
        await gate.wait(); try await f.controller.refresh(); await gate.resume()
        await sessionGroupFailure(.needsSignIn) { try await task.value }
        XCTAssertEqual(f.secret.writes, 1)
    }

    func testSuspendedFetchThenLogoutAndReloginRejectsEvenSameAccountAndSessionID() async throws {
        let f = try SessionGroupFixture()
        _ = try await f.history.confirm(f.verifier); await f.controller.restore()
        let gate = GroupGate(); await f.service.setGate(gate, operation: "group")
        let task = Task { try await f.controller.syncGroup(groupID: groupID) }
        await gate.wait(); try await f.controller.logout()
        let login = try await f.controller.beginLogin()
        try await f.controller.completeLogin(attemptID: login.id, code: "synthetic", identityToken: "synthetic")
        await gate.resume()
        await sessionGroupFailure(.needsSignIn) { try await task.value }
        XCTAssertEqual(f.secret.writes, 1)
    }

    func testLogoutIntentInvalidatesBeforeLogoutNetworkResponse() async throws {
        let f = try SessionGroupFixture()
        _ = try await f.history.confirm(f.verifier); await f.controller.restore()
        let fetchGate = GroupGate(), logoutGate = GroupGate()
        await f.service.setGate(fetchGate, operation: "group"); await f.service.setGate(logoutGate, operation: "logout")
        let sync = Task { try await f.controller.syncGroup(groupID: groupID) }
        await fetchGate.wait()
        let logout = Task { try await f.controller.logout() }
        await logoutGate.wait(); await fetchGate.resume()
        await sessionGroupFailure(.needsSignIn) { try await sync.value }
        await logoutGate.resume(); try await logout.value
    }

    func testDelayedCheckpointSaveThenLogoutReturnsNothingButRetainsHighWater() async throws {
        let checkpoint = GroupCheckpointStorage()
        let f = try SessionGroupFixture(checkpointStorage: checkpoint)
        _ = try await f.history.confirm(f.verifier); await f.controller.restore()
        let gate = GroupGate(); await checkpoint.setGate(gate)
        let sync = Task { try await f.controller.syncGroup(groupID: groupID) }
        await gate.wait(); try await f.controller.logout(); await gate.resume()
        await sessionGroupFailure(.needsSignIn) { try await sync.value }
        let persisted = await checkpoint.record
        XCTAssertEqual(persisted?.sequence, 3)
        await checkpointFailure(.invalidHistory) { try await f.history.accept(f.verifier, [f.history.events[0]]) }
    }

    func testCancellationDuringFetchAndCheckpointSaveReturnsNoMembership() async throws {
        for checkpointStage in [false, true] {
            let checkpoint = GroupCheckpointStorage()
            let f = try SessionGroupFixture(checkpointStorage: checkpoint)
            _ = try await f.history.confirm(f.verifier); await f.controller.restore()
            let gate = GroupGate()
            if checkpointStage { await checkpoint.setGate(gate) } else { await f.service.setGate(gate, operation: "group") }
            let sync = Task { try await f.controller.syncGroup(groupID: groupID) }
            await gate.wait(); sync.cancel()
            await sessionGroupFailure(.busy) { try await f.controller.syncGroup(groupID: groupID) }
            await gate.resume()
            do { _ = try await sync.value; XCTFail("Expected cancellation") }
            catch { XCTAssertTrue(error is CancellationError) }
            let persisted = await checkpoint.record
            XCTAssertEqual(persisted?.sequence, checkpointStage ? 3 : 1)
        }
    }

    func testAccessExpiryDuringFetchOrCheckpointSaveRejectsLateMembership() async throws {
        for checkpointStage in [false, true] {
            let checkpoint = GroupCheckpointStorage()
            let f = try SessionGroupFixture(checkpointStorage: checkpoint)
            _ = try await f.history.confirm(f.verifier); await f.controller.restore()
            let gate = GroupGate()
            if checkpointStage { await checkpoint.setGate(gate) } else { await f.service.setGate(gate, operation: "group") }
            let sync = Task { try await f.controller.syncGroup(groupID: groupID) }
            await gate.wait(); f.clock.advance(601); await gate.resume()
            await sessionGroupFailure(.needsSignIn) { try await sync.value }
            let persisted = await checkpoint.record
            XCTAssertEqual(persisted?.sequence, checkpointStage ? 3 : 1)
        }
    }

    func testExpiredAccessTokenRefreshesBeforeGroupCapture() async throws {
        let f = try SessionGroupFixture()
        _ = try await f.history.confirm(f.verifier); await f.controller.restore()
        f.clock.advance(601)
        await f.service.setRefreshExpiry(Date(timeIntervalSince1970: 2_000_001_200))
        let result = try await f.controller.syncGroup(groupID: groupID)
        XCTAssertEqual(result.sequence, 3)
        let calls = await f.service.calls
        XCTAssertEqual(calls, ["status", "refresh", "group"])
    }

    func testSuspendedFetchThenLogoutCannotReturnMembership() async throws {
        let f = try SessionGroupFixture()
        _ = try await f.history.confirm(f.verifier)
        await f.controller.restore()
        let gate = GroupGate()
        await f.service.setGate(gate, operation: "group")
        let sync = Task { try await f.controller.syncGroup(groupID: groupID) }
        await gate.wait()
        try await f.controller.logout()
        await gate.resume()
        await sessionGroupFailure(.needsSignIn) { try await sync.value }
        XCTAssertEqual(f.secret.writes, 1)
    }
}

struct SessionGroupFixture {
    let history: CheckpointHistory
    let secret: CheckpointSecretStore
    let verifier: AccountGroupHistoryVerifier
    let service: SessionGroupService
    let controller: AccountSessionController
    let storage: SessionGroupStorage
    let clock: GroupClock
    init(empty: Bool = false, configured: Bool = true, accountID: UUID = UUID(uuidString: groupAccount)!, checkpointStorage: (any AccountGroupCheckpointStorage)? = nil) throws {
        history = try CheckpointHistory()
        secret = CheckpointSecretStore()
        verifier = AccountGroupHistoryVerifier(storage: checkpointStorage ?? KeychainAccountGroupCheckpointStorage(store: secret))
        let tokens = AccountSessionTokens(identity: .init(accountID: accountID, sessionID: UUID(), deviceID: history.binding.deviceID, audience: history.binding.audience), accessToken: groupToken, refreshToken: Data(repeating: 2, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: ""), accessExpiresAt: Date(timeIntervalSince1970: 2_000_000_600), refreshExpiresAt: Date(timeIntervalSince1970: 2_000_006_000))
        storage = SessionGroupStorage(empty ? nil : try AccountStoredSession(binding: history.binding, tokens: tokens))
        service = SessionGroupService(tokens: tokens, events: history.events)
        let clock = GroupClock(); self.clock = clock
        controller = AccountSessionController(service: service, storage: storage, binding: history.binding, groupVerifier: configured ? verifier : nil, now: { clock.now() })
    }
}
actor SessionGroupStorage: AccountSessionStorage {
    var record: AccountStoredSession?
    init(_ record: AccountStoredSession?) { self.record = record }
    func load() -> AccountStoredSession? { record }
    func save(_ record: AccountStoredSession) { self.record = record }
    func remove() { record = nil }
}
actor SessionGroupService: AccountSessionService, AccountGroupService {
    let tokens: AccountSessionTokens
    let events: [AccountGroupEvent]
    var gates: [String: GroupGate] = [:]
    var groupCalls = 0
    var calls: [String] = []
    var refreshExpiry: Date?
    func setRefreshExpiry(_ value: Date) { refreshExpiry = value }
    init(tokens: AccountSessionTokens, events: [AccountGroupEvent]) { self.tokens = tokens; self.events = events }
    func setGate(_ gate: GroupGate, operation: String) { gates[operation] = gate }
    func pause(_ operation: String) async { calls.append(operation); if let gate = gates[operation] { await gate.block() } }
    func groupHistory(accessToken: String, groupID: String) async throws -> [AccountGroupEvent] { groupCalls += 1; await pause("group"); return events }
    func challenge() async throws -> AccountLoginChallenge { await pause("challenge"); return .init(challengeID: groupToken, nonce: tokens.refreshToken, expiresAt: Date(timeIntervalSince1970: 2_000_000_060)) }
    func complete(challengeID: String, code: String, identityToken: String) async throws -> AccountSessionTokens { await pause("complete"); return tokens }
    func status(accessToken: String) async throws -> AccountSessionIdentity { await pause("status"); return tokens.identity }
    func refresh(refreshToken: String) async throws -> AccountSessionTokens {
        await pause("refresh")
        return .init(identity: tokens.identity, accessToken: tokens.accessToken, refreshToken: tokens.refreshToken, accessExpiresAt: refreshExpiry ?? tokens.accessExpiresAt, refreshExpiresAt: tokens.refreshExpiresAt)
    }
    func logout(accessToken: String) async throws { await pause("logout") }
}
final class GroupClock: @unchecked Sendable {
    let lock = NSLock()
    var date = Date(timeIntervalSince1970: 2_000_000_000)
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: Double) { lock.withLock { date = date.addingTimeInterval(seconds) } }
}
actor GroupCheckpointStorage: AccountGroupCheckpointStorage {
    var record: AccountGroupCheckpoint?
    var gate: GroupGate?
    func setGate(_ value: GroupGate) { gate = value }
    func load(binding: AccountSessionBinding, accountID: String, groupID: String) -> AccountGroupCheckpoint? {
        guard record?.binding == binding, record?.accountID == accountID, record?.groupID == groupID else { return nil }
        return record
    }
    func save(_ checkpoint: AccountGroupCheckpoint) async {
        if let gate { self.gate = nil; await gate.block() }
        record = checkpoint
    }
}
func sessionGroupFailure<T>(_ expected: AccountSessionControllerError, file: StaticString = #filePath, line: UInt = #line, _ operation: () async throws -> T) async {
    do { _ = try await operation(); XCTFail("Expected rejection", file: file, line: line) }
    catch { XCTAssertEqual(error as? AccountSessionControllerError, expected, file: file, line: line) }
}
