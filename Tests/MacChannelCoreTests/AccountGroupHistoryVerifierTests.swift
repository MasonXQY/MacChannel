import CryptoKit
import Foundation
import XCTest
@testable import MacChannelCore

final class AccountGroupHistoryVerifierTests: XCTestCase, @unchecked Sendable {
    func testMissingPinAndEmptyOrOversizedHistoryFailClosed() async throws {
        let fixture = try CheckpointHistory()
        let secret = CheckpointSecretStore()
        let verifier = AccountGroupHistoryVerifier(storage: KeychainAccountGroupCheckpointStorage(store: secret))
        await checkpointFailure(.missingCheckpoint) { try await fixture.accept(verifier, fixture.events) }
        _ = try await fixture.confirm(verifier)
        await checkpointFailure(.invalidHistory) { try await fixture.accept(verifier, []) }
        await checkpointFailure(.invalidHistory) { try await fixture.accept(verifier, Array(repeating: fixture.events[0], count: 8193)) }
        XCTAssertEqual(secret.writes, 1)
    }

    func testMaximumCompleteJournalIsAccepted() async throws {
        let fixture = try CheckpointHistory()
        var events = [fixture.events[0]]
        var previous = try fixture.events[0].digest()
        for sequence in 2...8192 {
            let event = try groupEvent(actor: fixture.a, subject: fixture.b,
                action: sequence.isMultiple(of: 2) ? "approve" : "remove", sequence: UInt64(sequence), previous: previous)
            previous = try event.digest()
            events.append(event)
        }
        let verifier = AccountGroupHistoryVerifier(storage: KeychainAccountGroupCheckpointStorage(store: CheckpointSecretStore()))
        _ = try await fixture.confirm(verifier)
        let full = try await fixture.accept(verifier, events)
        XCTAssertEqual(full.sequence, 8192)
        XCTAssertEqual(full.headHash, previous)
        XCTAssertEqual(full.members.count, 2)
    }

    func testWrongConfirmationPinsAndUnsignedAnchorNeverPersist() async throws {
        let fixture = try CheckpointHistory()
        let secret = CheckpointSecretStore()
        let verifier = AccountGroupHistoryVerifier(storage: KeychainAccountGroupCheckpointStorage(store: secret))
        let digest = try fixture.events[0].digest()
        for (account, group, generation, hash) in [(groupID, groupID, UInt64(1), digest),
            (groupAccount, groupAccount, 1, digest), (groupAccount, groupID, 2, digest),
            (groupAccount, groupID, 1, Data(repeating: 0, count: 32))] {
            await checkpointFailure(.invalidHistory) {
                try await verifier.confirm(anchor: fixture.events[0], expectedAccountID: account,
                    expectedGroupID: group, expectedGeneration: generation, expectedAnchorHash: hash, binding: fixture.binding)
            }
        }
        let unsigned = try groupEvent(actor: fixture.a, subject: fixture.a, signed: false)
        await checkpointFailure(.invalidHistory) {
            try await verifier.confirm(anchor: unsigned, expectedAccountID: groupAccount, expectedGroupID: groupID,
                expectedGeneration: 1, expectedAnchorHash: digest, binding: fixture.binding)
        }
        XCTAssertEqual(secret.writes, 0)
    }

    func testRepeatConfirmationIsIdempotentButCannotResetAdvancedHeadOrReplacePin() async throws {
        let fixture = try CheckpointHistory()
        let secret = CheckpointSecretStore()
        let verifier = AccountGroupHistoryVerifier(storage: KeychainAccountGroupCheckpointStorage(store: secret))
        let first = try await fixture.confirm(verifier)
        let again = try await fixture.confirm(verifier)
        XCTAssertEqual(first, again)
        XCTAssertEqual(secret.writes, 1)
        let otherAnchor = try groupEvent(actor: fixture.b, subject: fixture.b)
        await checkpointFailure(.invalidHistory) {
            try await verifier.confirm(anchor: otherAnchor, expectedAccountID: groupAccount, expectedGroupID: groupID,
                expectedGeneration: 1, expectedAnchorHash: otherAnchor.digest(), binding: fixture.binding)
        }
        _ = try await fixture.accept(verifier, fixture.events)
        await checkpointFailure(.invalidHistory) { try await fixture.confirm(verifier) }
        XCTAssertEqual(secret.writes, 2)
    }

    func testRestartRejectsEarlierValidPrefixAfterApprovalAndRemoval() async throws {
        let fixture = try CheckpointHistory()
        let secret = CheckpointSecretStore()
        let first = AccountGroupHistoryVerifier(storage: KeychainAccountGroupCheckpointStorage(store: secret))
        let initial = try await fixture.confirm(first)
        XCTAssertEqual(initial.sequence, 1)
        let removed = try await fixture.accept(first, fixture.events)
        XCTAssertEqual(removed.sequence, 3)
        XCTAssertEqual(removed.members.count, 1)
        let restarted = AccountGroupHistoryVerifier(storage: KeychainAccountGroupCheckpointStorage(store: secret))
        await checkpointFailure(.invalidHistory) { try await fixture.accept(restarted, Array(fixture.events.prefix(2))) }
        let restored = try await fixture.accept(restarted, fixture.events)
        XCTAssertEqual(restored, removed)
    }

    func testForkAtPersistedHeadAndLongerBypassAreRejected() async throws {
        let fixture = try CheckpointHistory()
        let secret = CheckpointSecretStore()
        let verifier = AccountGroupHistoryVerifier(storage: KeychainAccountGroupCheckpointStorage(store: secret))
        _ = try await fixture.confirm(verifier)
        _ = try await fixture.accept(verifier, fixture.events)
        // A fully signed, internally valid fork changes sequence 2 while keeping the original anchor.
        let c = P256.Signing.PrivateKey()
        let forkApproval = try groupEvent(actor: fixture.a, subject: c, action: "approve", sequence: 2, previous: fixture.events[0].digest())
        let forkRemoval = try groupEvent(actor: fixture.a, subject: c, action: "remove", sequence: 3, previous: forkApproval.digest())
        let forkAdvance = try groupEvent(actor: fixture.a, subject: fixture.b, action: "approve", sequence: 4, previous: forkRemoval.digest())
        await checkpointFailure(.invalidHistory) { try await fixture.accept(verifier, [fixture.events[0], forkApproval, forkRemoval]) }
        await checkpointFailure(.invalidHistory) { try await fixture.accept(verifier, [fixture.events[0], forkApproval, forkRemoval, forkAdvance]) }
        let restored = try await fixture.accept(verifier, fixture.events)
        XCTAssertEqual(restored.headHash, try fixture.events[2].digest())
        XCTAssertEqual(secret.writes, 2)
    }

    func testAccountGroupGenerationAndBindingMismatchRejected() async throws {
        let fixture = try CheckpointHistory()
        let verifier = AccountGroupHistoryVerifier(storage: KeychainAccountGroupCheckpointStorage(store: CheckpointSecretStore()))
        _ = try await fixture.confirm(verifier)
        for (binding, account, group) in [(try checkpointBinding(audience: "other"), groupAccount, groupID),
                                        (fixture.binding, groupID, groupID), (fixture.binding, groupAccount, groupAccount)] {
            await checkpointFailure(.missingCheckpoint) {
                try await verifier.accept(history: fixture.events, binding: binding, accountID: account, groupID: group)
            }
        }
        let wrongGeneration = try groupEvent(actor: fixture.a, subject: fixture.a, generation: 2)
        await checkpointFailure(.invalidHistory) { try await fixture.accept(verifier, [wrongGeneration]) }
        let wrongContinuation = try groupEvent(actor: fixture.a, subject: fixture.b, action: "approve", sequence: 2,
            previous: fixture.events[0].digest(), generation: 2)
        await checkpointFailure(.invalidHistory) { try await fixture.accept(verifier, [fixture.events[0], wrongContinuation]) }
    }

    func testEveryProofIsReplayedBeforeSavingAndTerminalEmptyCannotRollBack() async throws {
        let fixture = try CheckpointHistory()
        let secret = CheckpointSecretStore()
        let verifier = AccountGroupHistoryVerifier(storage: KeychainAccountGroupCheckpointStorage(store: secret))
        _ = try await fixture.confirm(verifier)
        let unsigned = try groupEvent(actor: fixture.a, subject: fixture.b, action: "approve", sequence: 2,
            previous: fixture.events[0].digest(), signed: false)
        await checkpointFailure(.invalidHistory) { try await fixture.accept(verifier, [fixture.events[0], unsigned]) }
        XCTAssertEqual(secret.writes, 1)
        let terminalEvent = try groupEvent(actor: fixture.a, subject: fixture.a, action: "remove", sequence: 4,
            previous: fixture.events[2].digest())
        let history = fixture.events + [terminalEvent]
        let terminal = try await fixture.accept(verifier, history)
        XCTAssertTrue(terminal.members.isEmpty)
        let restarted = AccountGroupHistoryVerifier(storage: KeychainAccountGroupCheckpointStorage(store: secret))
        await checkpointFailure(.invalidHistory) { try await fixture.accept(restarted, fixture.events) }
        let restored = try await fixture.accept(restarted, history)
        XCTAssertEqual(restored, terminal)
        let resurrection = try groupEvent(actor: fixture.a, subject: fixture.b, action: "approve", sequence: 5, previous: terminalEvent.digest())
        await checkpointFailure(.invalidHistory) { try await fixture.accept(restarted, history + [resurrection]) }
    }

    func testFailedSavePublishesNothingAndRetrySucceeds() async throws {
        let fixture = try CheckpointHistory()
        let secret = CheckpointSecretStore()
        let verifier = AccountGroupHistoryVerifier(storage: KeychainAccountGroupCheckpointStorage(store: secret))
        secret.failWrites(true)
        await checkpointFailure(.secureStorage) { try await fixture.confirm(verifier) }
        XCTAssertTrue(secret.records.isEmpty)
        secret.failWrites(false)
        _ = try await fixture.confirm(verifier)
        let before = secret.records
        secret.failWrites(true)
        await checkpointFailure(.secureStorage) { try await fixture.accept(verifier, fixture.events) }
        XCTAssertEqual(secret.records, before)
        secret.failWrites(false)
        let accepted = try await fixture.accept(verifier, fixture.events)
        XCTAssertEqual(accepted.sequence, 3)
    }

    func testUnreadableExistingPinCannotBeConfirmedAsNew() async throws {
        let fixture = try CheckpointHistory()
        let secret = CheckpointSecretStore()
        let verifier = AccountGroupHistoryVerifier(storage: KeychainAccountGroupCheckpointStorage(store: secret))
        _ = try await fixture.confirm(verifier)
        secret.failReads(true)
        await checkpointFailure(.secureStorage) { try await fixture.confirm(verifier) }
        await checkpointFailure(.secureStorage) { try await fixture.accept(verifier, fixture.events) }
        secret.failReads(false)
        let key = try XCTUnwrap(secret.records.keys.first)
        secret.set(Data("malformed".utf8), for: key)
        await checkpointFailure(.secureStorage) { try await fixture.confirm(verifier) }
        await checkpointFailure(.secureStorage) { try await fixture.accept(verifier, fixture.events) }
        XCTAssertEqual(secret.records[key], Data("malformed".utf8))
        XCTAssertEqual(secret.writes, 1)
    }

    func testOverlappingAcceptIsRejectedUntilEarlierWriteCompletes() async throws {
        let fixture = try CheckpointHistory()
        let storage = SuspendedCheckpointStorage()
        let verifier = AccountGroupHistoryVerifier(storage: storage)
        _ = try await fixture.confirm(verifier)
        await storage.suspendNext(.write)
        let first = Task { try await fixture.accept(verifier, Array(fixture.events.prefix(2))) }
        await storage.waitUntilSuspended()
        await checkpointFailure(.operationInProgress) { try await fixture.accept(verifier, fixture.events) }
        let pending = try await storage.persisted(binding: fixture.binding)
        XCTAssertEqual(pending?.sequence, 1)
        await storage.resume()
        let earlier = try await first.value
        XCTAssertEqual(earlier.sequence, 2)
        let later = try await fixture.accept(verifier, fixture.events)
        XCTAssertEqual(later.sequence, 3)
        await checkpointFailure(.invalidHistory) { try await fixture.accept(verifier, Array(fixture.events.prefix(2))) }
    }

    func testConfirmationCannotOverlapPendingAcceptOrResetCompletedHead() async throws {
        let fixture = try CheckpointHistory()
        let storage = SuspendedCheckpointStorage()
        let verifier = AccountGroupHistoryVerifier(storage: storage)
        _ = try await fixture.confirm(verifier)
        await storage.suspendNext(.write)
        let acceptance = Task { try await fixture.accept(verifier, fixture.events) }
        await storage.waitUntilSuspended()
        await checkpointFailure(.operationInProgress) { try await fixture.confirm(verifier) }
        await storage.resume()
        _ = try await acceptance.value
        await checkpointFailure(.invalidHistory) { try await fixture.confirm(verifier) }
        let persisted = try await storage.persisted(binding: fixture.binding)
        XCTAssertEqual(persisted?.sequence, 3)
    }

    func testCancellationDoesNotReleaseAdmissionDuringPendingWrite() async throws {
        let fixture = try CheckpointHistory()
        let storage = SuspendedCheckpointStorage()
        let verifier = AccountGroupHistoryVerifier(storage: storage)
        _ = try await fixture.confirm(verifier)
        await storage.suspendNext(.write)
        let acceptance = Task { try await fixture.accept(verifier, fixture.events) }
        await storage.waitUntilSuspended()
        acceptance.cancel()
        await checkpointFailure(.operationInProgress) { try await fixture.confirm(verifier) }
        await checkpointFailure(.operationInProgress) { try await fixture.accept(verifier, fixture.events) }
        await storage.resume()
        await checkpointFailure(.invalidHistory) { try await acceptance.value }
        let persisted = try await storage.persisted(binding: fixture.binding)
        XCTAssertEqual(persisted?.sequence, 3)
        await checkpointFailure(.invalidHistory) { try await fixture.accept(verifier, Array(fixture.events.prefix(2))) }
        let retried = try await fixture.accept(verifier, fixture.events)
        XCTAssertEqual(retried.sequence, 3)
    }

    func testPendingFailedWriteReturnsNoSnapshotAndReleasesAdmissionForRetry() async throws {
        let fixture = try CheckpointHistory()
        let storage = SuspendedCheckpointStorage()
        let verifier = AccountGroupHistoryVerifier(storage: storage)
        _ = try await fixture.confirm(verifier)
        await storage.suspendNext(.write)
        let acceptance = Task { try await fixture.accept(verifier, fixture.events) }
        await storage.waitUntilSuspended()
        await checkpointFailure(.operationInProgress) { try await fixture.accept(verifier, fixture.events) }
        await storage.resume(failing: true)
        await checkpointFailure(.secureStorage) { try await acceptance.value }
        let persisted = try await storage.persisted(binding: fixture.binding)
        XCTAssertEqual(persisted?.sequence, 1)
        let retried = try await fixture.accept(verifier, fixture.events)
        XCTAssertEqual(retried.sequence, 3)
    }

    func testPendingLoadHoldsAdmissionAndCancelledReadCannotWrite() async throws {
        let fixture = try CheckpointHistory()
        let storage = SuspendedCheckpointStorage()
        let verifier = AccountGroupHistoryVerifier(storage: storage)
        _ = try await fixture.confirm(verifier)
        await storage.suspendNext(.read)
        let acceptance = Task { try await fixture.accept(verifier, fixture.events) }
        await storage.waitUntilSuspended()
        acceptance.cancel()
        await checkpointFailure(.operationInProgress) { try await fixture.confirm(verifier) }
        await storage.resume()
        await checkpointFailure(.invalidHistory) { try await acceptance.value }
        let persisted = try await storage.persisted(binding: fixture.binding)
        XCTAssertEqual(persisted?.sequence, 1)
        let retried = try await fixture.accept(verifier, fixture.events)
        XCTAssertEqual(retried.sequence, 3)
    }

    func testFirstConfirmationPublishesOnlyAfterDurableWrite() async throws {
        let fixture = try CheckpointHistory()
        let storage = SuspendedCheckpointStorage()
        let verifier = AccountGroupHistoryVerifier(storage: storage)
        await storage.suspendNext(.write)
        let confirmation = Task { try await fixture.confirm(verifier) }
        await storage.waitUntilSuspended()
        let absent = try await storage.persisted(binding: fixture.binding)
        XCTAssertNil(absent)
        await checkpointFailure(.operationInProgress) { try await fixture.accept(verifier, fixture.events) }
        await storage.resume()
        let confirmed = try await confirmation.value
        XCTAssertEqual(confirmed.sequence, 1)
        let persisted = try await storage.persisted(binding: fixture.binding)
        XCTAssertEqual(persisted?.headHash, confirmed.headHash)
    }
}

/// A controllable I/O boundary around the real codec/monotonic store. No timers,
/// live Keychain, or mocked proof verification; suspension ignores cancellation
/// deliberately to prove that the coordinator retains admission until I/O settles.
private actor SuspendedCheckpointStorage: AccountGroupCheckpointStorage {
    enum Operation { case read, write }
    private let base = KeychainAccountGroupCheckpointStorage(store: CheckpointSecretStore())
    private var next: Operation?
    private var suspended: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private var failure = false

    func suspendNext(_ operation: Operation) { next = operation }
    func waitUntilSuspended() async {
        if suspended != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func resume(failing: Bool = false) {
        failure = failing
        let continuation = suspended
        suspended = nil
        continuation?.resume()
    }
    private func pause(_ operation: Operation) async throws {
        guard next == operation else { return }
        next = nil
        await withCheckedContinuation { continuation in
            suspended = continuation
            observer?.resume()
            observer = nil
        }
        if failure { failure = false; throw KeychainStoreError.unexpectedData }
    }
    func load(binding: AccountSessionBinding, accountID: String, groupID: String) async throws -> AccountGroupCheckpoint? {
        try await pause(.read)
        return try await base.load(binding: binding, accountID: accountID, groupID: groupID)
    }
    func save(_ checkpoint: AccountGroupCheckpoint) async throws {
        try await pause(.write)
        try await base.save(checkpoint)
    }
    func persisted(binding: AccountSessionBinding) async throws -> AccountGroupCheckpoint? {
        try await base.load(binding: binding, accountID: groupAccount, groupID: groupID)
    }
}

struct CheckpointHistory: Sendable {
    let a = P256.Signing.PrivateKey()
    let b = P256.Signing.PrivateKey()
    let binding: AccountSessionBinding
    let events: [AccountGroupEvent]
    init() throws {
        binding = try checkpointBinding()
        let anchor = try groupEvent(actor: a, subject: a)
        let approval = try groupEvent(actor: a, subject: b, action: "approve", sequence: 2, previous: anchor.digest())
        let removal = try groupEvent(actor: a, subject: b, action: "remove", sequence: 3, previous: approval.digest())
        events = [anchor, approval, removal]
    }
    func confirm(_ verifier: AccountGroupHistoryVerifier) async throws -> AccountGroupSnapshot {
        try await verifier.confirm(anchor: events[0], expectedAccountID: groupAccount, expectedGroupID: groupID,
            expectedGeneration: 1, expectedAnchorHash: events[0].digest(), binding: binding)
    }
    func accept(_ verifier: AccountGroupHistoryVerifier, _ history: [AccountGroupEvent]) async throws -> AccountGroupSnapshot {
        try await verifier.accept(history: history, binding: binding, accountID: groupAccount, groupID: groupID)
    }
}

func checkpointFailure<T>(_ expected: AccountGroupCheckpointError,
                          file: StaticString = #filePath, line: UInt = #line,
                          _ operation: () async throws -> T) async {
    do { _ = try await operation(); XCTFail("Expected rejection", file: file, line: line) }
    catch { XCTAssertEqual(error as? AccountGroupCheckpointError, expected, file: file, line: line) }
}
