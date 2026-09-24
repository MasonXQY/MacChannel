@testable import MacChannelCore
import DropMeshMobileRuntime
import XCTest
@testable import DropMeshTestHost

@MainActor
final class PairingModelTests: XCTestCase {
    func testHeldFirstSaveShowsLocalProgressUntilDurableSuccess() async throws {
        try await exerciseHeldSaving(failFirstSave: false)
    }

    func testHeldRetryImmediatelyLeavesFailureAndPreservesAuthorization() async throws {
        try await exerciseHeldSaving(failFirstSave: true)
    }

    private func exerciseHeldSaving(failFirstSave: Bool) async throws {
        let server = MemoryPairingServer()
        let hostIdentity = try DeviceIdentity.ephemeral()
        let joinIdentity = try DeviceIdentity.ephemeral()
        let hostRepository = try TrustRepository(ownerIdentity: hostIdentity,
            trustStore: TrustStore(owner: hostIdentity.id), persistedGeneration: 0)
        let joinRepository = try TrustRepository(ownerIdentity: joinIdentity,
            trustStore: TrustStore(owner: joinIdentity.id), persistedGeneration: 0)
        let hostCoordinator = try PairingCoordinator(identity: hostIdentity, displayName: "Fixture Mac",
            trustRepository: hostRepository,
            transport: MemoryPairingTransport(server: server, observedSource: "held-host"))
        let joinCoordinator = try PairingCoordinator(identity: joinIdentity, displayName: "Fixture iPhone",
            trustRepository: joinRepository,
            transport: MemoryPairingTransport(server: server, observedSource: "held-join"))
        let host = MobilePairingSession(coordinator: hostCoordinator, persistTrust: {})
        let release = AsyncStream<Bool>.makeStream()
        let saves = SaveCounter()
        let join = MobilePairingSession(coordinator: joinCoordinator, persistTrust: {
            await saves.record()
            var iterator = release.stream.makeAsyncIterator()
            guard await iterator.next() == true else { throw TestFailure.expected }
        })
        var factories = 0
        var refreshes = 0
        let model = PairingModel(makeAttempt: {
            factories += 1
            return MemoryModelAttempt(session: join)
        }, refreshDevices: { refreshes += 1 })
        addTeardownBlock {
            release.continuation.finish()
            await model.cancelAndClose()
            await host.stopObservation()
            await join.stopObservation()
        }
        model.code = try await host.createCode()
        model.submit()
        await boundedWait { if case .active(.approvalRequested) = await host.currentState() { return true }; return false }
        _ = try await host.approve()
        await boundedWait { await saves.count == 1 }
        await boundedWait { !model.showsWaitingProgress }
        XCTAssertFalse(model.showsWaitingProgress, "A held local save must no longer wait for the Mac")
        guard case .saving = model.phase else { return XCTFail("Expected local saving phase") }
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.requiresSaveRecovery)
        XCTAssertTrue(model.isBusy)
        XCTAssertEqual(refreshes, 0)
        let authorization = await joinRepository.authenticationRecords()
        release.continuation.yield(!failFirstSave)
        await boundedWait { !model.isBusy }
        if failFirstSave {
            XCTAssertTrue(model.requiresSaveRecovery)
            for succeeds in [false, true] {
                model.retrySaving()
                XCTAssertFalse(model.requiresSaveRecovery, "Retry must immediately replace failure with saving")
                guard case .saving = model.phase else { return XCTFail("Expected immediate retry saving phase") }
                XCTAssertNil(model.errorMessage)
                XCTAssertTrue(model.isBusy)
                XCTAssertEqual(refreshes, 0)
                model.submit()
                XCTAssertEqual(factories, 1)
                let expectedCount = succeeds ? 3 : 2
                await boundedWait { await saves.count == expectedCount }
                XCTAssertFalse(model.showsWaitingProgress)
                let unchanged = await joinRepository.authenticationRecords()
                XCTAssertEqual(unchanged, authorization)
                release.continuation.yield(succeeds)
                await boundedWait { !model.isBusy }
                if !succeeds { XCTAssertTrue(model.requiresSaveRecovery) }
            }
        }
        guard case .paired = model.phase else { return XCTFail("Only released successful persistence may pair") }
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(factories, 1)
    }

    func testDoubleSubmitCreatesOnlyOneAttempt() async {
        let attempt = ControlledPairingAttempt()
        let factory = AttemptFactory(attempt: attempt)
        let model = PairingModel(makeAttempt: factory.make)
        model.code = "012345"

        model.submit()
        model.submit()
        await attempt.waitUntilJoinStarts()

        XCTAssertEqual(factory.makeCount, 1)
        let joinCount = await attempt.joinCount
        XCTAssertEqual(joinCount, 1)
        await model.cancelAndClose()
    }

    func testFailureNeverPresentsPairedState() async {
        let attempt = ControlledPairingAttempt(joinError: TestFailure.expected)
        let model = PairingModel(makeAttempt: AttemptFactory(attempt: attempt).make)
        model.code = "123456"

        model.submit()
        await waitUntilIdle(model)

        guard case .failed = model.phase else { return XCTFail("Expected failed state") }
    }

    func testDurableSuccessRefreshesDevicesOnlyAfterPairedState() async {
        let peer = fixturePeer
        let attempt = ControlledPairingAttempt(
            joinResult: fixtureJoin(peer: peer), finalState: .paired(peer), approvalResult: peer
        )
        var refreshCount = 0
        let model = PairingModel(
            makeAttempt: AttemptFactory(attempt: attempt).make,
            refreshDevices: { refreshCount += 1 }
        )
        model.code = "123456"

        model.submit()
        await waitUntilIdle(model)

        XCTAssertEqual(model.phase, .paired(peer))
        XCTAssertEqual(refreshCount, 1)
    }

    func testSaveFailureBlocksNewAttemptAndRetrySaveCompletesDurably() async {
        let peer = fixturePeer
        let attempt = ControlledPairingAttempt(
            joinResult: fixtureJoin(peer: peer), finalState: .saveFailed(peer),
            approvalError: TestFailure.expected, retryResult: peer
        )
        let factory = AttemptFactory(attempt: attempt)
        let model = PairingModel(makeAttempt: factory.make)
        model.code = "123456"

        model.submit()
        await waitUntilIdle(model)
        XCTAssertEqual(model.phase, .saveFailed(peer))
        model.submit()
        XCTAssertEqual(factory.makeCount, 1)

        model.retrySaving()
        await waitUntilIdle(model)
        XCTAssertEqual(model.phase, .paired(peer))
        let retryCount = await attempt.retryCount
        XCTAssertEqual(retryCount, 1)
    }

    func testCancellationAwaitsOperationBeforeSessionCancelAndTransportStop() async {
        let recorder = EventRecorder()
        let attempt = ControlledPairingAttempt(recorder: recorder)
        let model = PairingModel(makeAttempt: AttemptFactory(attempt: attempt).make)
        model.code = "123456"
        model.submit()
        await attempt.waitUntilJoinStarts()

        await model.cancelAndClose()

        let events = await recorder.events
        XCTAssertEqual(events, ["operation-ended", "session-cancel", "transport-stop"])
        XCTAssertTrue(model.mayDismiss)
    }

    func testConfirmedButUnsavedCancellationKeepsRetrySaveRecovery() async {
        let peer = fixturePeer
        let attempt = ControlledPairingAttempt(finalState: .saveFailed(peer))
        let model = PairingModel(makeAttempt: AttemptFactory(attempt: attempt).make)
        model.code = "123456"
        model.submit()
        await attempt.waitUntilJoinStarts()

        await model.cancelAndClose()

        XCTAssertEqual(model.phase, .saveFailed(peer))
        XCTAssertFalse(model.mayDismiss)
        let cancelCount = await attempt.cancelCount
        let stopCount = await attempt.stopCount
        XCTAssertEqual(cancelCount, 0)
        XCTAssertEqual(stopCount, 0)
    }

    func testCancellationStillOwnsAndStopsAttemptReturnedByFactoryAfterCancellation() async {
        let attempt = ControlledPairingAttempt()
        let factory = SuspendedAttemptFactory(attempt: attempt)
        let model = PairingModel(makeAttempt: factory.make)
        model.code = "123456"
        model.submit()
        await factory.waitUntilStarted()

        let close = Task { await model.cancelAndClose() }
        await Task.yield()
        factory.release()
        await close.value

        let stopCount = await attempt.stopCount
        XCTAssertEqual(stopCount, 1)
        XCTAssertTrue(model.mayDismiss)
    }

    func testBackgroundDuringRetrySaveDoesNotLeaveModelBusy() async {
        let peer = fixturePeer
        let attempt = ControlledPairingAttempt(
            finalState: .saveFailed(peer), suspendRetry: true
        )
        let model = PairingModel(makeAttempt: AttemptFactory(attempt: attempt).make)
        model.code = "123456"
        model.submit()
        await attempt.waitUntilJoinStarts()
        await model.cancelAndClose()
        XCTAssertEqual(model.phase, .saveFailed(peer))

        model.retrySaving()
        await attempt.waitUntilRetryStarts()
        await model.handleBackground()

        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.phase, .saveFailed(peer))
    }

    func testNewSubmitAfterBackgroundCleanupImmediatelyBlocksDismissalThroughSaveRecovery() async {
        let firstAttempt = ControlledPairingAttempt()
        let secondAttempt = ControlledPairingAttempt(
            finalState: .saveFailed(fixturePeer),
            approvalError: TestFailure.expected
        )
        let factory = SequencedAttemptFactory(attempts: [firstAttempt, secondAttempt])
        let model = PairingModel(makeAttempt: factory.make)
        model.code = "123456"

        model.submit()
        await firstAttempt.waitUntilJoinStarts()
        await model.handleBackground()
        XCTAssertTrue(model.mayDismiss)

        model.submit()
        XCTAssertFalse(model.mayDismiss)
        await secondAttempt.waitUntilJoinStarts()
        XCTAssertFalse(model.mayDismiss)
        await waitUntilIdle(model)

        XCTAssertEqual(model.phase, .saveFailed(fixturePeer))
        XCTAssertFalse(model.mayDismiss)
    }

    func testCleanupFailureWhileWaitingIsRecoverableAndRetryAllowsDismissal() async {
        let attempt = ControlledPairingAttempt(
            finalState: .active(.awaitingHostApproval(fixturePeer)),
            suspendApproval: true,
            cancelErrors: [TestFailure.expected]
        )
        let model = PairingModel(makeAttempt: AttemptFactory(attempt: attempt).make)
        model.code = "123456"
        model.submit()
        await attempt.waitUntilApprovalStarts()
        guard case .waitingForMac = model.phase else { return XCTFail("Expected waiting phase") }

        await model.cancelAndClose()

        XCTAssertEqual(model.errorMessage, String(localized: "pairing.error.cleanup"))
        XCTAssertFalse(model.mayDismiss)
        XCTAssertFalse(model.showsWaitingProgress)
        XCTAssertEqual(
            model.phase,
            PairingPhase.waitingForMac(peer: fixturePeer, fingerprint: "fixture fingerprint")
        )

        await model.cancelAndClose()

        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.mayDismiss)
        XCTAssertEqual(model.phase, PairingPhase.entry)
        let cancelCount = await attempt.cancelCount
        XCTAssertEqual(cancelCount, 2)
    }

    func testModelReachesSuccessThroughRealMemoryPairingSessionsAfterBothSidesPersist() async throws {
        let server = MemoryPairingServer()
        let hostIdentity = try DeviceIdentity.ephemeral()
        let joinIdentity = try DeviceIdentity.ephemeral()
        let hostRepository = try TrustRepository(
            ownerIdentity: hostIdentity, trustStore: TrustStore(owner: hostIdentity.id), persistedGeneration: 0
        )
        let joinRepository = try TrustRepository(
            ownerIdentity: joinIdentity, trustStore: TrustStore(owner: joinIdentity.id), persistedGeneration: 0
        )
        let hostCoordinator = try PairingCoordinator(
            identity: hostIdentity, displayName: "Fixture Mac", trustRepository: hostRepository,
            transport: MemoryPairingTransport(server: server, observedSource: "fixture-host")
        )
        let joinCoordinator = try PairingCoordinator(
            identity: joinIdentity, displayName: "Fixture iPhone", trustRepository: joinRepository,
            transport: MemoryPairingTransport(server: server, observedSource: "fixture-joiner")
        )
        let hostSaves = SaveCounter()
        let joinSaves = SaveCounter()
        let hostSession = MobilePairingSession(
            coordinator: hostCoordinator, persistTrust: { await hostSaves.record() }
        )
        let joinSession = MobilePairingSession(
            coordinator: joinCoordinator, persistTrust: { await joinSaves.record() }
        )
        let code = try await hostSession.createCode()
        let model = PairingModel(makeAttempt: { MemoryModelAttempt(session: joinSession) })
        model.code = code

        model.submit()
        while true {
            if case .active(.approvalRequested) = await hostSession.currentState() { break }
            await Task.yield()
        }
        _ = try await hostSession.approve()
        await waitUntilIdle(model)

        guard case .paired = model.phase else { return XCTFail("Expected durable paired state") }
        let hostSaveCount = await hostSaves.count
        let joinSaveCount = await joinSaves.count
        XCTAssertEqual(hostSaveCount, 1)
        XCTAssertEqual(joinSaveCount, 1)
    }
}

private enum TestFailure: Error { case expected }

@MainActor
private func boundedWait(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { XCTFail("Condition did not arrive", file: file, line: line); return }
        await Task.yield()
    }

}

@MainActor
private func waitUntilIdle(_ model: PairingModel) async {
    while model.isBusy { await Task.yield() }
}

private let fixturePeer = DeviceSummary(
    id: DeviceID(rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!),
    displayName: "Fixture Mac", availability: .offline
)

private func fixtureJoin(peer: DeviceSummary) -> PairingJoinResult {
    PairingJoinResult(
        sessionID: PairingSessionID(), peer: peer, fingerprint: "fixture fingerprint",
        hostEphemeralPublicKey: Data([1]), joiningEphemeralPublicKey: Data([2])
    )
}

@MainActor
private final class AttemptFactory {
    let attempt: ControlledPairingAttempt
    var makeCount = 0
    init(attempt: ControlledPairingAttempt) { self.attempt = attempt }
    func make() async throws -> any PairingAttempt {
        makeCount += 1
        return attempt
    }
}

@MainActor
private final class SequencedAttemptFactory {
    private var attempts: [ControlledPairingAttempt]
    init(attempts: [ControlledPairingAttempt]) { self.attempts = attempts }
    func make() async throws -> any PairingAttempt {
        guard !attempts.isEmpty else { throw TestFailure.expected }
        return attempts.removeFirst()
    }
}

@MainActor
private final class SuspendedAttemptFactory {
    let attempt: ControlledPairingAttempt
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(attempt: ControlledPairingAttempt) { self.attempt = attempt }
    func make() async throws -> any PairingAttempt {
        started = true
        await withCheckedContinuation { continuation = $0 }
        return attempt
    }
    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor EventRecorder {
    var events: [String] = []
    func append(_ event: String) { events.append(event) }
}

private actor SaveCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

private actor MemoryModelAttempt: PairingAttempt {
    let session: MobilePairingSession
    init(session: MobilePairingSession) { self.session = session }
    func join(code: String) async throws -> PairingJoinResult { try await session.join(code: code) }
    func awaitApproval() async throws -> DeviceSummary { try await session.awaitApproval() }
    func currentState() async -> MobilePairingState { await session.currentState() }
    func retrySaving() async throws -> DeviceSummary { try await session.retrySaving() }
    func cancel() async throws { try await session.cancel() }
    func stop() async {}
}

private actor ControlledPairingAttempt: PairingAttempt {
    private let recorder: EventRecorder?
    private let joinResult: PairingJoinResult
    private let joinError: Error?
    private let finalState: MobilePairingState
    private let approvalResult: DeviceSummary
    private let approvalError: Error?
    private let retryResult: DeviceSummary
    private let suspendRetry: Bool
    private let suspendApproval: Bool
    private var cancelErrors: [Error]
    private var joinContinuation: CheckedContinuation<Void, Error>?
    private var joinStarted = false
    private var retryStarted = false
    private var retryContinuation: CheckedContinuation<Void, Error>?
    private var approvalContinuation: CheckedContinuation<Void, Error>?
    private var approvalStarted = false
    private(set) var joinCount = 0
    private(set) var retryCount = 0
    private(set) var cancelCount = 0
    private(set) var stopCount = 0

    init(
        recorder: EventRecorder? = nil,
        joinResult: PairingJoinResult = fixtureJoin(peer: fixturePeer),
        joinError: Error? = nil,
        finalState: MobilePairingState = .active(.joining),
        approvalResult: DeviceSummary = fixturePeer,
        approvalError: Error? = nil,
        retryResult: DeviceSummary = fixturePeer,
        suspendRetry: Bool = false,
        suspendApproval: Bool = false,
        cancelErrors: [Error] = []
    ) {
        self.recorder = recorder
        self.joinResult = joinResult
        self.joinError = joinError
        self.finalState = finalState
        self.approvalResult = approvalResult
        self.approvalError = approvalError
        self.retryResult = retryResult
        self.suspendRetry = suspendRetry
        self.suspendApproval = suspendApproval
        self.cancelErrors = cancelErrors
    }

    func join(code: String) async throws -> PairingJoinResult {
        joinCount += 1
        joinStarted = true
        if let joinError { throw joinError }
        if case .active(.joining) = finalState {
            do {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { joinContinuation = $0 }
                } onCancel: {
                    Task { await self.endCancelledJoin() }
                }
            } catch {
                await recorder?.append("operation-ended")
                throw error
            }
        }
        return joinResult
    }

    private func endCancelledJoin() {
        joinContinuation?.resume(throwing: CancellationError())
        joinContinuation = nil
    }

    func awaitApproval() async throws -> DeviceSummary {
        approvalStarted = true
        if suspendApproval {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { approvalContinuation = $0 }
            } onCancel: {
                Task { await self.endCancelledApproval() }
            }
        }
        if let approvalError { throw approvalError }
        return approvalResult
    }
    private func endCancelledApproval() {
        approvalContinuation?.resume(throwing: CancellationError())
        approvalContinuation = nil
    }
    func currentState() async -> MobilePairingState { finalState }
    func retrySaving() async throws -> DeviceSummary {
        retryCount += 1
        retryStarted = true
        if suspendRetry {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { retryContinuation = $0 }
            } onCancel: {
                Task { await self.endCancelledRetry() }
            }
        }
        return retryResult
    }
    private func endCancelledRetry() {
        retryContinuation?.resume(throwing: CancellationError())
        retryContinuation = nil
    }
    func cancel() async throws {
        cancelCount += 1
        await recorder?.append("session-cancel")
        if !cancelErrors.isEmpty { throw cancelErrors.removeFirst() }
    }
    func stop() async { stopCount += 1; await recorder?.append("transport-stop") }

    func waitUntilJoinStarts() async {
        while !joinStarted { await Task.yield() }
    }
    func waitUntilRetryStarts() async {
        while !retryStarted { await Task.yield() }
    }
    func waitUntilApprovalStarts() async {
        while !approvalStarted { await Task.yield() }
    }
}
