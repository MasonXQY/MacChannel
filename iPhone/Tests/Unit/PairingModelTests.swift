@testable import MacChannelCore
import CryptoKit
import DropMeshMobileRuntime
import XCTest
@testable import DropMeshTestHost

@MainActor
final class PairingModelTests: XCTestCase {
    func testHostLeadingZeroRejectAndRoleSwitchAwaitCleanup() async throws {
        let attempt = HostModelAttempt()
        let model = PairingModel(makeAttempt: { attempt })
        addTeardownBlock { await model.cancelAndClose() }
        model.generateCode(); model.generateCode()
        await boundedWait { if case .hosting = model.phase { return true }; return false }
        guard case let .hosting(code, _) = model.phase else { return XCTFail("Expected code") }
        XCTAssertEqual(code, "012345")
        await attempt.request()
        await boundedWait { if case .hostApproval = model.phase { return true }; return false }
        model.rejectHost(); model.rejectHost()
        await boundedWait { !model.isBusy }
        XCTAssertEqual(model.phase, .entry)
        let rejects = await attempt.rejectCount, stops = await attempt.stopCount
        XCTAssertEqual(rejects, 1); XCTAssertEqual(stops, 1)
    }

    func testHostCodeRoleSwitchMakesOldRealCodeUnusable() async throws {
        let identity = try DeviceIdentity.ephemeral()
        let server = MemoryPairingServer()
        let repository = try TrustRepository(ownerIdentity: identity,
            trustStore: TrustStore(owner: identity.id), persistedGeneration: 0)
        let core = try PairingCoordinator(identity: identity, trustRepository: repository,
            transport: MemoryPairingTransport(server: server, observedSource: "switch-host"))
        let session = MobilePairingSession(coordinator: core, persistTrust: {})
        let model = PairingModel(makeAttempt: { MemoryModelAttempt(session: session) })
        addTeardownBlock { await model.cancelAndClose(); await session.stopObservation() }
        model.generateCode()
        await boundedWait { if case .hosting = model.phase { return true }; return false }
        guard case let .hosting(code, _) = model.phase else { return XCTFail("Expected code") }
        await model.returnToEntry()
        XCTAssertEqual(model.phase, .entry)
        XCTAssertFalse(model.mayDismiss)
        do {
            _ = try await MemoryPairingTransport(server: server, observedSource: "lookup-old").lookup(code: code)
            XCTFail("Role switch left old code available")
        } catch { }
    }

    func testHostExpiryAndNetworkFailureRemainActionable() async {
        let expired = HostModelAttempt(expired: true)
        let model = PairingModel(makeAttempt: { expired })
        addTeardownBlock { await model.cancelAndClose() }
        model.generateCode()
        await boundedWait { model.phase == .expired }
        XCTAssertTrue(model.canChangeRole)
        await model.returnToEntry()
        let failed = PairingModel(makeAttempt: { HostModelAttempt(failCreate: true) })
        addTeardownBlock { await failed.cancelAndClose() }
        failed.generateCode()
        await boundedWait { failed.phase == .failed }
        XCTAssertNotNil(failed.errorMessage)
        XCTAssertTrue(failed.canChangeRole)
    }

    func testBackgroundDuringHostFactoryAwaitsReturnedAttemptAndStopsIt() async {
        let attempt = ControlledPairingAttempt()
        let factory = SuspendedAttemptFactory(attempt: attempt)
        let model = PairingModel(makeAttempt: factory.make)
        model.generateCode()
        await factory.waitUntilStarted()
        let background = Task { await model.handleBackground() }
        await boundedWait { model.isClosing }
        XCTAssertFalse(model.mayDismiss)
        factory.release()
        await background.value
        XCTAssertTrue(model.mayDismiss)
        let stops = await attempt.stopCount
        XCTAssertEqual(stops, 1)
    }

    func testCloseDuringHostApprovalJoinsOperationAndRefreshesOnce() async {
        await exerciseHostSuspension(saving: false, failSave: false)
    }

    func testBackgroundDuringHostSavePreservesExactRetryAndBlocksRoleChange() async {
        await exerciseHostSuspension(saving: true, failSave: true)
    }

    private func exerciseHostSuspension(saving: Bool, failSave: Bool) async {
        let attempt = HostModelAttempt(holdApproval: true, holdAsSaving: saving, failSave: failSave)
        var refreshes = 0
        let model = PairingModel(makeAttempt: { attempt }, refreshDevices: { refreshes += 1 })
        addTeardownBlock { await attempt.releaseApproval(); await model.cancelAndClose() }
        model.generateCode()
        await boundedWait { if case .hosting = model.phase { return true }; return false }
        await attempt.request()
        await boundedWait { if case .hostApproval = model.phase { return true }; return false }
        model.approveHost(); model.approveHost()
        await boundedWait { await attempt.approveCount == 1 }
        let close = Task {
            if saving { await model.handleBackground() } else { await model.cancelAndClose() }
        }
        await boundedWait { model.isClosing }
        XCTAssertFalse(model.mayDismiss)
        XCTAssertFalse(model.canChangeRole)
        model.generateCode(); model.approveHost()
        await attempt.releaseApproval()
        await close.value
        if failSave {
            XCTAssertTrue(model.requiresSaveRecovery)
            XCTAssertFalse(model.mayDismiss)
            await model.returnToEntry()
            XCTAssertTrue(model.requiresSaveRecovery)
            model.retrySaving()
            await boundedWait { !model.isBusy }
        }
        guard case .paired = model.phase else { return XCTFail("Expected durable state after save") }
        XCTAssertEqual(refreshes, 1)
        let approvals = await attempt.approveCount
        XCTAssertEqual(approvals, 1)
    }

    func testStaleDisplayedApprovalCannotApproveReplacementRequest() async {
        let attempt = HostModelAttempt()
        let model = PairingModel(makeAttempt: { attempt })
        addTeardownBlock { await model.cancelAndClose() }
        model.generateCode()
        await boundedWait { if case .hosting = model.phase { return true }; return false }
        await attempt.request()
        await boundedWait { if case .hostApproval = model.phase { return true }; return false }
        await attempt.replaceRequest()
        model.approveHost()
        await boundedWait { !model.isBusy }
        XCTAssertEqual(model.phase, .failed)
        let approvals = await attempt.approveCount
        XCTAssertEqual(approvals, 0)
    }

    func testTwoMobileModelsHostAndJoinRequireExplicitBoundApprovalAndBothSaves() async throws {
        try await exerciseTwoModels()
    }

    func testRealHostSaveFailureRetriesIdenticalAuthorizationWithoutAnotherApproval() async throws {
        try await exerciseTwoModels(failHostSave: true)
    }

    func testRealHostRejectionLeavesBothRepositoriesUntrusted() async throws {
        try await exerciseTwoModels(reject: true)
    }

    private func exerciseTwoModels(failHostSave: Bool = false, reject: Bool = false) async throws {
        let server = MemoryPairingServer()
        let hostIdentity = try DeviceIdentity.ephemeral()
        let joinIdentity = try DeviceIdentity.ephemeral()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PairingHost-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: folder) }
        let hostSecrets = PairingTestSecrets(), joinSecrets = PairingTestSecrets()
        let hostURL = folder.appendingPathComponent("host.trust"), joinURL = folder.appendingPathComponent("join.trust")
        let hostDisk = AuthenticatedTrustSnapshotStore(url: hostURL, secrets: hostSecrets)
        let joinDisk = AuthenticatedTrustSnapshotStore(url: joinURL, secrets: joinSecrets)
        let hostRepository = try await hostDisk.load(identity: hostIdentity)
        let joinRepository = try await joinDisk.load(identity: joinIdentity)
        let hostCore = try PairingCoordinator(identity: hostIdentity, displayName: "Fixture iPad",
            trustRepository: hostRepository, transport: MemoryPairingTransport(server: server, observedSource: "mobile-host"))
        let joinCore = try PairingCoordinator(identity: joinIdentity, displayName: "Fixture iPhone",
            trustRepository: joinRepository, transport: MemoryPairingTransport(server: server, observedSource: "mobile-join"))
        let hostSaves = SaveCounter(), joinSaves = SaveCounter()
        let hostSession = MobilePairingSession(coordinator: hostCore, persistTrust: {
            await hostSaves.record()
            if failHostSave, await hostSaves.count == 1 { throw TestFailure.expected }
            try await hostDisk.persistLatest(from: hostRepository)
        })
        let joinSession = MobilePairingSession(coordinator: joinCore, persistTrust: {
            await joinSaves.record()
            try await joinDisk.persistLatest(from: joinRepository)
        })
        var hostRefreshes = 0, joinRefreshes = 0, hostFactories = 0
        let host = PairingModel(makeAttempt: {
            hostFactories += 1
            return MemoryModelAttempt(session: hostSession)
        }, refreshDevices: { hostRefreshes += 1 })
        let join = PairingModel(makeAttempt: { MemoryModelAttempt(session: joinSession) },
            refreshDevices: { joinRefreshes += 1 })
        addTeardownBlock {
            await host.cancelAndClose(); await join.cancelAndClose()
            await hostSession.stopObservation(); await joinSession.stopObservation()
        }
        host.generateCode()
        host.generateCode()
        await boundedWait { if case .hosting = host.phase { return true }; return false }
        guard case let .hosting(code, _) = host.phase else { return XCTFail("Host code missing") }
        XCTAssertNotNil(PairingCode(code))
        XCTAssertEqual(hostFactories, 1)
        join.code = code
        join.submit()
        await boundedWait { if case .hostApproval = host.phase { return true }; return false }
        guard case let .hostApproval(confirmation) = host.phase,
              case let .waitingForMac(_, fingerprint) = join.phase else { return XCTFail("Both verification views required") }
        XCTAssertEqual(confirmation.fingerprint, fingerprint)
        let beforeHost = await hostRepository.authenticationRecords()
        let beforeJoin = await joinRepository.authenticationRecords()
        XCTAssertTrue(beforeHost.isEmpty); XCTAssertTrue(beforeJoin.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: hostURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: joinURL.path))
        if reject {
            host.rejectHost()
            await boundedWait { !host.isBusy && !join.isBusy }
            XCTAssertEqual(host.phase, .entry)
            XCTAssertEqual(join.phase, .failed)
            let hostAfter = await hostRepository.authenticationRecords()
            let joinAfter = await joinRepository.authenticationRecords()
            XCTAssertTrue(hostAfter.isEmpty); XCTAssertTrue(joinAfter.isEmpty)
            XCTAssertEqual(hostRefreshes, 0); XCTAssertEqual(joinRefreshes, 0)
            return
        }
        host.approveHost()
        host.approveHost()
        if failHostSave {
            await boundedWait { host.requiresSaveRecovery && !host.isBusy }
            XCTAssertFalse(host.canGenerate)
            XCTAssertFalse(host.canChangeRole)
            let signed = await hostRepository.authenticationRecords()
            XCTAssertEqual(signed.count, 1)
            host.retrySaving()
            await boundedWait { !host.isBusy }
            let retried = await hostRepository.authenticationRecords()
            XCTAssertEqual(retried, signed)
        }
        await boundedWait { if case .paired = host.phase, case .paired = join.phase { return true }; return false }
        await boundedWait { !host.isBusy && !join.isBusy }
        let hostCount = await hostSaves.count, joinCount = await joinSaves.count
        XCTAssertEqual(hostCount, failHostSave ? 2 : 1); XCTAssertEqual(joinCount, 1)
        XCTAssertEqual(hostRefreshes, 1); XCTAssertEqual(joinRefreshes, 1)
        let hostTrusted = await hostRepository.isTrusted(joinIdentity.id)
        let joinTrusted = await joinRepository.isTrusted(hostIdentity.id)
        XCTAssertTrue(hostTrusted); XCTAssertTrue(joinTrusted)
        let reloadedHost = try await AuthenticatedTrustSnapshotStore(url: hostURL, secrets: hostSecrets).load(identity: hostIdentity)
        let reloadedJoin = try await AuthenticatedTrustSnapshotStore(url: joinURL, secrets: joinSecrets).load(identity: joinIdentity)
        let hostDiskTrust = await reloadedHost.isTrusted(joinIdentity.id)
        let joinDiskTrust = await reloadedJoin.isTrusted(hostIdentity.id)
        XCTAssertTrue(hostDiskTrust); XCTAssertTrue(joinDiskTrust)
        let savedHostProofs = await reloadedHost.authenticationRecords()
        let savedJoinProofs = await reloadedJoin.authenticationRecords()
        XCTAssertEqual(savedHostProofs.count, 1); XCTAssertEqual(savedJoinProofs.count, 1)
    }

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
final class ProductionPairingAttemptTests: XCTestCase {
    func testKnownHostPollingFailureSuppressesSnapshotAndRejectsApprovalBeforeCoordinator() async throws {
        let fixture = try AdapterFixture()
        addTeardownBlock { await fixture.close() }
        _ = try await fixture.attempt.createCode()
        await fixture.core.setState(.approvalRequested(fixture.core.peer))
        let before = await fixture.attempt.pendingHostConfirmation()
        XCTAssertEqual(before, fixture.core.confirmation)
        try await fixture.failHostPolling()

        let after = await fixture.attempt.pendingHostConfirmation()
        XCTAssertNil(after)
        do {
            _ = try await fixture.attempt.approve(fixture.core.confirmation)
            XCTFail("Known failed host must not approve the displayed snapshot")
        } catch { XCTAssertEqual(error as? PairingError, .invalidHandshake) }
        let calls = await fixture.core.approvals
        XCTAssertEqual(calls, 0, "Failure must stop before the shared signing flow")
        let state = await fixture.attempt.currentState()
        XCTAssertEqual(state, .active(.failed(.pairingHandshakeFailed)))
    }

    func testKnownHostFailureOverlaysWaitingOnlyAndPreservesEveryDurablePhase() async throws {
        let fixture = try AdapterFixture()
        addTeardownBlock { await fixture.close() }
        _ = try await fixture.attempt.createCode()
        try await fixture.failHostPolling()
        let waiting = await fixture.attempt.currentState()
        XCTAssertEqual(waiting, .active(.failed(.pairingHandshakeFailed)))

        let peer = fixture.core.peer
        await fixture.core.setState(.committing(peer))
        let committing = await fixture.attempt.currentState()
        XCTAssertEqual(committing, .active(.committing(peer)))
        await fixture.core.setState(.confirmed(peer))
        let unsaved = await fixture.attempt.currentState()
        XCTAssertEqual(unsaved, .saveFailed(peer))

        let save = Task { try await fixture.session.retrySaving() }
        await boundedWait { await fixture.disk.calls == 1 }
        let saving = await fixture.attempt.currentState()
        XCTAssertEqual(saving, .saving(peer))
        await fixture.disk.release(false)
        do { _ = try await save.value; XCTFail("Expected controlled disk failure") }
        catch { XCTAssertTrue(error is TestFailure) }
        let failed = await fixture.attempt.currentState()
        XCTAssertEqual(failed, .saveFailed(peer))
        await fixture.disk.release(true)
        _ = try await fixture.attempt.retrySaving()
        let paired = await fixture.attempt.currentState()
        XCTAssertEqual(paired, .paired(peer))
        let failureStillPresent = await fixture.transport.hostFailure(for: "012345")
        XCTAssertEqual(failureStillPresent, .pairingHandshakeFailed,
            "Durable phases must survive an actual retained transport failure")
    }
}

private struct AdapterFixture: Sendable {
    let identity: DeviceIdentity
    let transport: RendezvousPairingTransport
    let core = AdapterCoordinator()
    let disk = AdapterDisk()
    let session: MobilePairingSession
    let attempt: ProductionPairingAttempt
    init() throws {
        identity = try DeviceIdentity.ephemeral()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AdapterFailureURLProtocol.self]
        transport = try RendezvousPairingTransport(identity: identity,
            origin: URL(string: "https://adapter.test")!, session: URLSession(configuration: config))
        let disk = self.disk
        session = MobilePairingSession(coordinator: core, persistTrust: { _ in try await disk.save() })
        attempt = ProductionPairingAttempt(session: session, transport: transport)
    }
    @MainActor func failHostPolling() async throws {
        let key = P256.KeyAgreement.PrivateKey()
        try await transport.publish(.init(code: "012345", expiresAt: Date().addingTimeInterval(300),
            hostID: identity.id, hostIdentityPublicKey: identity.publicKey.rawRepresentation,
            hostEphemeralPublicKey: key.publicKey.rawRepresentation, hostDisplayName: "Fixture"), endpoint: core)
        await boundedWait { await transport.hostFailure(for: "012345") != nil }
    }
    func close() async {
        await disk.release(true)
        await session.stopObservation()
        await transport.stop()
    }
}

private actor AdapterCoordinator: DurablePairingCoordinating, PairingHostEndpoint {
    nonisolated let peer = fixturePeer
    nonisolated let confirmation = PairingHostConfirmation(sessionID: PairingSessionID(),
        peer: fixturePeer, fingerprint: "fixture comparison", expiresAt: Date().addingTimeInterval(300))
    nonisolated let states = AsyncStream<PairingState> { $0.finish() }
    private var state: PairingState = .idle
    private(set) var approvals = 0
    func setState(_ value: PairingState) { state = value }
    func currentState() async -> PairingState { state }
    func isTrusted(_ device: DeviceID) async -> Bool { device == peer.id }
    func createCode() async throws -> String { state = .displayingCode(expiresAt: confirmation.expiresAt); return "012345" }
    func join(code: String) async throws -> PairingJoinResult { throw TestFailure.expected }
    func pendingHostConfirmation() async -> PairingHostConfirmation? { confirmation }
    func approvePendingPairing(_ expected: PairingHostConfirmation) async throws -> SignedTrustRecord {
        approvals += 1
        throw TestFailure.expected
    }
    func approvePendingPairing() async throws -> SignedTrustRecord { throw TestFailure.expected }
    func awaitHostApproval() async throws -> SignedTrustRecord { throw TestFailure.expected }
    func rejectPendingPairing() async throws {}
    func cancelPendingPairing() async throws {}
    func pendingPeerSummary() async -> DeviceSummary? { peer }
    func accept(_ request: PairingJoinRequest) async throws -> PairingJoinResponse { throw TestFailure.expected }
}

private actor AdapterDisk {
    private var releaseBeforeEntry: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?
    private(set) var calls = 0
    func save() async throws {
        calls += 1
        let success: Bool
        if let released = releaseBeforeEntry { releaseBeforeEntry = nil; success = released }
        else { success = await withCheckedContinuation { continuation = $0 } }
        if !success { throw TestFailure.expected }
    }
    func release(_ success: Bool) {
        if let continuation { self.continuation = nil; continuation.resume(returning: success) }
        else { releaseBeforeEntry = success }
    }
}

private final class AdapterFailureURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        if url.path.hasSuffix("/host") {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        } else {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 201,
                httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

private final class PairingTestSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func data(for account: String, policy: KeychainPolicy) throws -> Data? {
        lock.withLock { values[account] }
    }
    func store(_ data: Data, for account: String, policy: KeychainPolicy) throws {
        lock.withLock { values[account] = data }
    }
}

private actor HostModelAttempt: PairingAttempt {
    private var approvalGate: CheckedContinuation<Void, Never>?
    private let expiry: Date
    private let failCreate: Bool
    private let holdApproval: Bool
    private let holdAsSaving: Bool
    private var failSave: Bool
    private var confirmation: PairingHostConfirmation
    private var state: MobilePairingState = .active(.idle)
    private(set) var approveCount = 0
    private(set) var rejectCount = 0
    private(set) var stopCount = 0
    init(expired: Bool = false, failCreate: Bool = false, holdApproval: Bool = false,
         holdAsSaving: Bool = false, failSave: Bool = false) {
        expiry = Date().addingTimeInterval(expired ? -1 : 300)
        self.failCreate = failCreate; self.holdApproval = holdApproval
        self.holdAsSaving = holdAsSaving; self.failSave = failSave
        confirmation = .init(sessionID: PairingSessionID(), peer: fixturePeer,
            fingerprint: "fixture host fingerprint", expiresAt: expiry)
    }
    func createCode() async throws -> String {
        if failCreate { throw URLError(.notConnectedToInternet) }
        state = .active(.displayingCode(expiresAt: expiry))
        return "012345"
    }
    func request() { state = .active(.approvalRequested(fixturePeer)) }
    func replaceRequest() {
        confirmation = .init(sessionID: PairingSessionID(), peer: fixturePeer,
            fingerprint: "new fingerprint", expiresAt: expiry)
    }
    func pendingHostConfirmation() -> PairingHostConfirmation? { confirmation }
    func approve(_ expected: PairingHostConfirmation) async throws -> DeviceSummary {
        guard expected == confirmation else { throw PairingError.staleOperation }
        approveCount += 1
        state = holdAsSaving ? .saving(fixturePeer) : .active(.committing(fixturePeer))
        if holdApproval {
            await withCheckedContinuation { approvalGate = $0 }
        }
        if failSave {
            state = .saveFailed(fixturePeer)
            throw MobilePairingError.saveRequired
        }
        state = .paired(fixturePeer)
        return fixturePeer
    }
    func reject() async throws { rejectCount += 1; state = .active(.idle) }
    func releaseApproval() { approvalGate?.resume(); approvalGate = nil }
    func join(code: String) async throws -> PairingJoinResult { throw TestFailure.expected }
    func awaitApproval() async throws -> DeviceSummary { throw TestFailure.expected }
    func currentState() async -> MobilePairingState { state }
    func retrySaving() async throws -> DeviceSummary { failSave = false; state = .paired(fixturePeer); return fixturePeer }
    func cancel() async throws { state = .active(.idle) }
    func stop() async { stopCount += 1 }
}

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
    func createCode() async throws -> String { try await session.createCode() }
    func pendingHostConfirmation() async -> PairingHostConfirmation? { await session.pendingHostConfirmation() }
    func approve(_ expected: PairingHostConfirmation) async throws -> DeviceSummary { try await session.approve(expected) }
    func reject() async throws { try await session.reject() }
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
