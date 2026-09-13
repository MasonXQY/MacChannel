import XCTest
@testable import MacChannelCore

final class DurablePairingSessionTests: XCTestCase {
    func testDeliveredApprovalWaitsForBilateralConfirmationAndDisk() async throws {
        let core = try DurableCoordinatorProbe()
        let disk = DurableDiskProbe()
        let gate = DurablePairingSession(coordinator: core) { _ in try await disk.save() }
        let operation = Task { try await gate.approve() }
        await core.waitForApproval()
        let before = await gate.currentState()
        XCTAssertEqual(before, .active(.committing(core.peer)))
        assertValue( await disk.calls, 0)
        await core.confirm()
        await disk.waitForSave()
        assertValue( await gate.currentState(), .saving(core.peer))
        await disk.release()
        _ = try await operation.value
        assertValue( await gate.currentState(), .paired(core.peer))
    }

    func testFailedSaveBlocksNewPairAndRetryDoesNotSignAgain() async throws {
        let core = try DurableCoordinatorProbe()
        let disk = DurableDiskProbe()
        await disk.release(failing: true)
        let gate = DurablePairingSession(coordinator: core) { _ in try await disk.save() }
        let operation = Task { try await gate.approve() }
        await core.waitForApproval()
        await core.confirm()
        do { _ = try await operation.value; XCTFail("Expected disk failure") } catch { }
        assertValue( await gate.currentState(), .saveFailed(core.peer))
        do { _ = try await gate.createCode(); XCTFail("Must recover saving first") }
        catch DurablePairingError.saveRequired { }
        await disk.release()
        _ = try await gate.retrySaving()
        assertValue( await core.approvals, 1)
        assertValue( await gate.currentState(), .paired(core.peer))
    }

    func testLateConfirmationAfterTimeoutRequiresSaveBeforeNewPair() async throws {
        let core = try DurableCoordinatorProbe()
        let gate = DurablePairingSession(coordinator: core, confirmationTimeout: .milliseconds(30)) { _ in }
        do { _ = try await gate.approve(); XCTFail("Expected timeout") }
        catch DurablePairingError.confirmationTimedOut { }
        await core.confirm()
        do { _ = try await gate.createCode(); XCTFail("Late confirmation cannot be discarded") }
        catch DurablePairingError.saveRequired { }
        _ = try await gate.retrySaving()
        assertValue( await core.approvals, 1)
    }

    func testCancelledSaveThatCompletesRemainsLocallyDurable() async throws {
        let core = try DurableCoordinatorProbe()
        let disk = DurableDiskProbe()
        let gate = DurablePairingSession(coordinator: core) { _ in try await disk.save() }
        let operation = Task { try await gate.approve() }
        await core.waitForApproval()
        await core.confirm()
        await disk.waitForSave()
        operation.cancel()
        do { try await gate.cancel(); XCTFail("Save must be joined first") }
        catch PairingError.operationInProgress { }
        await disk.release()
        _ = try await operation.value
        try await gate.cancel()
        assertValue( await gate.currentState(), .paired(core.peer))
    }

    func testCancelledWaitMustReconcileBeforeNewPair() async throws {
        let core = try DurableCoordinatorProbe()
        let gate = DurablePairingSession(coordinator: core) { _ in }
        let operation = Task { try await gate.approve() }
        await core.waitForApproval()
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        do { _ = try await gate.createCode(); XCTFail("Pending authorization must reconcile") }
        catch PairingError.operationInProgress { }
        try await gate.cancel()
        _ = try await gate.createCode()
    }

    func testTerminalCoreFailureCanReconcileBeforeNewPair() async throws {
        let core = try DurableCoordinatorProbe()
        let gate = DurablePairingSession(coordinator: core) { _ in }
        let operation = Task { try await gate.approve() }
        await core.waitForApproval()
        await core.failTerminally()
        do { _ = try await operation.value; XCTFail("Expected terminal failure") }
        catch PairingError.invalidHandshake { }
        try await gate.cancel()
        _ = try await gate.createCode()
    }

    func testObservationNeverPublishesRawConfirmedAsSuccess() async throws {
        let core = try DurableCoordinatorProbe()
        let gate = DurablePairingSession(coordinator: core) { _ in }
        await gate.startObservation()
        await core.confirm()
        var iterator = gate.states.makeAsyncIterator()
        var found = false
        for _ in 0..<4 {
            if case .saveFailed = await iterator.next() { found = true; break }
        }
        XCTAssertTrue(found)
        await gate.stopObservation()
        assertValue( await gate.currentState(), .saveFailed(core.peer))
    }

    func testRemovalWhileSavingCannotPublishStaleSuccess() async throws {
        let core = try DurableCoordinatorProbe()
        let disk = DurableDiskProbe()
        let gate = DurablePairingSession(coordinator: core) { _ in try await disk.save() }
        let operation = Task { try await gate.approve() }
        await core.waitForApproval()
        await core.confirm()
        await disk.waitForSave()
        await core.removePeer()
        await disk.release()
        do { _ = try await operation.value; XCTFail("Removed device cannot become paired") }
        catch PairingError.staleOperation { }
        assertValue(await gate.currentState(), .active(.idle))
    }

    func testRemovalBeforeRetryDoesNotSaveAgain() async throws {
        let core = try DurableCoordinatorProbe()
        let disk = DurableDiskProbe()
        await disk.release(failing: true)
        let gate = DurablePairingSession(coordinator: core) { _ in try await disk.save() }
        let operation = Task { try await gate.approve() }
        await core.waitForApproval()
        await core.confirm()
        do { _ = try await operation.value } catch { }
        await core.removePeer()
        do { _ = try await gate.retrySaving(); XCTFail("Removed peer cannot retry saving") }
        catch PairingError.staleOperation { }
        assertValue(await disk.calls, 1)
        assertValue(await gate.currentState(), .active(.idle))
    }

    func testStoppingObservationJoinsSuspendedStateRead() async throws {
        let core = try DurableCoordinatorProbe()
        let gate = DurablePairingSession(coordinator: core) { _ in }
        let stopped = ObservationStopProbe()
        await core.blockStateReads()
        await gate.startObservation()
        await core.waitForStateRead()
        let stopping = Task { await gate.stopObservation(); await stopped.finish() }
        for _ in 0..<100 { await Task.yield() }
        assertValue(await stopped.finished, false)
        await core.releaseStateReads()
        await stopping.value
        assertValue(await stopped.finished, true)
    }

    func testJoinedStopPermanentlyRetiresRuntimeObservation() async throws {
        let core = try DurableCoordinatorProbe()
        let gate = DurablePairingSession(coordinator: core) { _ in }
        let recorder = DurableStateRecorder()
        let consumer = Task { for await state in gate.states { await recorder.record(state) } }
        await gate.startObservation()
        await core.waitForStateRead()
        await gate.stopObservation()
        await consumer.value
        let beforeRetirement = await recorder.last
        await gate.startObservation()
        await core.confirm()
        assertValue(await recorder.last, beforeRetirement)
        do { _ = try await gate.createCode(); XCTFail("Retired gate must not be reused") }
        catch PairingError.staleOperation { }
    }

    func testRetirementDrainsSuspendedHostPersistenceBeforeReplacement() async throws {
        try await assertRetirementDrainsPersistence(retrying: false)
    }

    func testRetirementDrainsSuspendedRetryPersistenceBeforeReplacement() async throws {
        try await assertRetirementDrainsPersistence(retrying: true)
    }

    func testRetirementPreservesAlreadyStartedSaveFailure() async throws {
        try await assertRetirementDrainsPersistence(retrying: false, finalSaveFails: true)
    }

    private func assertRetirementDrainsPersistence(retrying: Bool, finalSaveFails: Bool = false) async throws {
        let core = try DurableCoordinatorProbe()
        let disk = DurableDiskProbe()
        let gate = DurablePairingSession(coordinator: core) { _ in try await disk.save() }
        let recorder = DurableStateRecorder()
        let consumer = Task { for await state in gate.states { await recorder.record(state) } }
        let operation: Task<DeviceSummary, Error>
        if retrying {
            await disk.release(failing: true)
            let approval = Task { try await gate.approve() }
            await core.waitForApproval()
            await core.confirm()
            do { _ = try await approval.value; XCTFail("Expected initial save failure") }
            catch DurableDiskProbe.Failure.disk { }
            await disk.block()
            operation = Task { try await gate.retrySaving() }
        } else {
            operation = Task { try await gate.approve() }
            await core.waitForApproval()
            await core.confirm()
        }
        await disk.waitForSave(count: retrying ? 2 : 1)
        let replaced = ObservationStopProbe()
        let retirement = Task {
            await gate.stopObservation()
            // A replacement storage owner may only be built after this boundary.
            await replaced.finish()
        }
        var retirementEntered = false
        for _ in 0..<1000 {
            do { _ = try await gate.createCode(); XCTFail("No new operation during retirement") }
            catch PairingError.staleOperation { retirementEntered = true; break }
            catch PairingError.operationInProgress { await Task.yield() }
        }
        XCTAssertTrue(retirementEntered)
        assertValue(await replaced.finished, false)
        await disk.release(failing: finalSaveFails)
        if finalSaveFails {
            do { _ = try await operation.value; XCTFail("The failed save must remain a failure") }
            catch DurableDiskProbe.Failure.disk { }
        } else { _ = try await operation.value }
        await retirement.value
        await consumer.value
        assertValue(await replaced.finished, true)
        assertValue(await gate.currentState(), finalSaveFails ? .saveFailed(core.peer) : .paired(core.peer))
        assertValue(await recorder.last, .saving(core.peer))
    }
}

private extension XCTestCase {
    func assertValue<T: Equatable>(_ value: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(value, expected, file: file, line: line)
    }
}

private actor DurableCoordinatorProbe: DurablePairingCoordinating {
    nonisolated let peer: DeviceSummary
    nonisolated let states: AsyncStream<PairingState>
    private let continuation: AsyncStream<PairingState>.Continuation
    private let record: SignedTrustRecord
    private var state: PairingState
    var approvals = 0
    private var trusted = false
    private var blockedStateRead = false
    private var readingState = false
    init() throws {
        let owner = try DeviceIdentity.ephemeral()
        let remote = try DeviceIdentity.ephemeral()
        peer = DeviceSummary(id: remote.id, displayName: "Phone", availability: .internet)
        record = try SignedTrustRecord.authorizing(subject: remote.id, subjectPublicKey: remote.publicKey.rawRepresentation, signedBy: owner, sequence: 1, timestamp: Date())
        state = .approvalRequested(peer)
        let stream = AsyncStream<PairingState>.makeStream()
        states = stream.stream
        continuation = stream.continuation
    }
    func createCode() async throws -> String { state = .displayingCode(expiresAt: Date()); return "123456" }
    func join(code: String) async throws -> PairingJoinResult { throw PairingError.noPendingConfirmation }
    func approvePendingPairing() async throws -> SignedTrustRecord { approvals += 1; state = .committing(peer); continuation.yield(state); return record }
    func awaitHostApproval() async throws -> SignedTrustRecord { try await approvePendingPairing() }
    func rejectPendingPairing() async throws { state = .idle }
    func cancelPendingPairing() async throws {
        if case .confirmed = state { return }
        if case .failed = state { return }
        state = .idle
    }
    func pendingPeerSummary() async -> DeviceSummary? {
        if case .failed = state { return nil }
        return peer
    }
    func failTerminally() { state = .failed(.pairingHandshakeFailed); continuation.yield(state) }
    func currentState() async -> PairingState {
        readingState = true
        while blockedStateRead { await Task.yield() }
        return state
    }
    func blockStateReads() { blockedStateRead = true }
    func releaseStateReads() { blockedStateRead = false }
    func waitForStateRead() async { while !readingState { await Task.yield() } }
    func confirm() { trusted = true; state = .confirmed(peer); continuation.yield(state) }
    func isTrusted(_ id: DeviceID) async -> Bool { trusted && peer.id == id }
    func removePeer() { trusted = false }
    func waitForApproval() async { while approvals == 0 { await Task.yield() } }
}

private actor ObservationStopProbe {
    var finished = false
    func finish() { finished = true }
}

private actor DurableStateRecorder {
    var last: DurablePairingState?
    func record(_ state: DurablePairingState) { last = state }
}

private actor DurableDiskProbe {
    enum Failure: Error { case disk }
    var calls = 0
    private var ready = false
    private var failing = false
    func save() async throws { calls += 1; while !ready { await Task.yield() }; if failing { throw Failure.disk } }
    func release(failing: Bool = false) { self.failing = failing; ready = true }
    func block() { ready = false; failing = false }
    func waitForSave(count: Int = 1) async { while calls < count { await Task.yield() } }
}
