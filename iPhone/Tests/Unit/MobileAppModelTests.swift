import DropMeshMobileRuntime
import MacChannelCore
import SwiftUI
import XCTest
@testable import DropMeshTestHost

@MainActor
final class MobileAppModelTests: XCTestCase {
    func testInterruptedStartCannotOverwriteSuccessfulForeground() async throws {
        let session = InertMobileSession()
        let gate = BootstrapGate()
        await session.setBeforeStart { await gate.wait(); throw MobileRuntimeError.interrupted }
        let model = MobileAppModel(loadSession: { session })
        await model.bootstrap(initialPhase: .active)
        try await gate.entered()
        model.scenePhaseChanged(.background)
        let deadline = ContinuousClock.now + .seconds(3)
        while await session.stopCount == 0 && ContinuousClock.now < deadline { await Task.yield() }
        expectEqual(await session.stopCount, 1)
        await session.setBeforeStart {}
        model.scenePhaseChanged(.active)
        while await session.startCount < 2 && ContinuousClock.now < deadline { await Task.yield() }
        expectEqual(await session.startCount, 2)
        while model.serviceState != .online && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(model.serviceState, .online)
        await gate.release()
        await model.waitForLifecycle()
        XCTAssertNil(model.serviceFailure)
        XCTAssertEqual(model.serviceState, .online)
        await model.close()
    }

    func testBackgroundInterruptionFinishesBeforeSuccessfulForegroundWithoutFalseError() async throws {
        let session = InertMobileSession()
        let gate = BootstrapGate()
        await session.setBeforeStart { await gate.wait(); throw MobileRuntimeError.interrupted }
        let model = MobileAppModel(loadSession: { session })
        await model.bootstrap(initialPhase: .active)
        try await gate.entered()
        model.scenePhaseChanged(.background)
        await gate.release()
        await model.waitForLifecycle()
        XCTAssertNil(model.serviceFailure)
        await session.setBeforeStart {}
        model.scenePhaseChanged(.active)
        await model.waitForLifecycle()
        XCTAssertNil(model.serviceFailure)
        XCTAssertEqual(model.serviceState, .online)
        await model.close()
    }

    func testSupersededFailedStartCannotOverwriteSuccessfulForeground() async throws {
        let session = InertMobileSession()
        let gate = BootstrapGate()
        await session.setBeforeStart { await gate.wait(); throw MobileRuntimeError.notReady }
        let model = MobileAppModel(loadSession: { session })
        await model.bootstrap(initialPhase: .active)
        try await gate.entered()
        model.scenePhaseChanged(.background)
        let deadline = ContinuousClock.now + .seconds(3)
        while await session.stopCount == 0 && ContinuousClock.now < deadline { await Task.yield() }
        expectEqual(await session.stopCount, 1)
        await session.setBeforeStart {}
        model.scenePhaseChanged(.active)
        while model.serviceState != .online && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(model.serviceState, .online)
        await gate.release()
        await model.waitForLifecycle()
        XCTAssertNil(model.serviceFailure)
        await model.close()
    }

    func testSuccessfulForegroundClearsRecoveredStartFailure() async {
        let session = InertMobileSession()
        await session.setBeforeStart { throw MobileRuntimeError.notReady }
        let model = MobileAppModel(loadSession: { session })
        await model.bootstrap(initialPhase: .active)
        await model.waitForLifecycle()
        XCTAssertEqual(model.serviceFailure, .network)
        model.scenePhaseChanged(.background)
        await model.waitForLifecycle()
        await session.setBeforeStart {}
        model.scenePhaseChanged(.active)
        await model.waitForLifecycle()
        XCTAssertNil(model.serviceFailure)
        await model.close()
    }

    func testSuccessfulForegroundPreservesExplicitTrustRefreshFailure() async {
        let session = InertMobileSession()
        await session.setRefreshFailure(true)
        await session.setPairingAttempt(AlreadyPairedAttempt(peer: session.peer))
        let model = MobileAppModel(loadSession: { session })
        await model.bootstrap(initialPhase: .active)
        await model.waitForLifecycle()
        model.presentPairing()
        let pairing = model.pairing!
        pairing.code = "123456"
        pairing.submit()
        let deadline = ContinuousClock.now + .seconds(3)
        while pairing.isBusy && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertFalse(pairing.isBusy)
        XCTAssertEqual(model.serviceFailure, .network)
        model.scenePhaseChanged(.background)
        await model.waitForLifecycle()
        model.scenePhaseChanged(.active)
        await model.waitForLifecycle()
        XCTAssertEqual(model.serviceFailure, .network)
        await model.close()
    }

    func testSuccessfulRetryClearsRecoveredStartFailureAfterOnlineSnapshot() async {
        let session = InertMobileSession()
        await session.setBeforeStart { throw MobileRuntimeError.notReady }
        let model = MobileAppModel(loadSession: { session })
        await model.bootstrap(initialPhase: .active)
        await model.waitForLifecycle()
        XCTAssertEqual(model.serviceFailure, .network)

        await session.setBeforeStart {}
        model.retryConnection()
        await model.waitForLifecycle()

        XCTAssertEqual(model.serviceState, .online)
        XCTAssertNil(model.serviceFailure)
        await model.close()
    }

    func testDelayedRetryClearsRecoveredStartFailureOnlyWhenSnapshotBecomesOnline() async {
        let session = InertMobileSession()
        await session.setBeforeStart { throw MobileRuntimeError.notReady }
        await session.setRetryState(.reconnecting)
        let model = MobileAppModel(loadSession: { session })
        await model.bootstrap(initialPhase: .active)
        await model.waitForLifecycle()

        model.retryConnection()
        await model.waitForLifecycle()
        XCTAssertEqual(model.serviceState, .reconnecting)
        XCTAssertEqual(model.serviceFailure, .network)

        await session.setPresence(.online, peers: [])
        await model.refreshDevices()
        XCTAssertNil(model.serviceFailure)
        await model.close()
    }

    func testFailedRetryKeepsRecoveredStartFailure() async {
        let session = InertMobileSession()
        await session.setBeforeStart { throw MobileRuntimeError.notReady }
        await session.setRetryState(.reconnecting)
        let model = MobileAppModel(loadSession: { session })
        await model.bootstrap(initialPhase: .active)
        await model.waitForLifecycle()

        model.retryConnection()
        await model.waitForLifecycle()

        XCTAssertEqual(model.serviceFailure, .network)
        await model.close()
    }

    func testBackgroundSupersedesHeldRetryRecovery() async throws {
        let session = InertMobileSession()
        let gate = BootstrapGate()
        await session.setBeforeStart { throw MobileRuntimeError.notReady }
        await session.setBeforeRetry { await gate.wait() }
        let model = MobileAppModel(loadSession: { session })
        await model.bootstrap(initialPhase: .active)
        await model.waitForLifecycle()

        model.retryConnection()
        try await gate.entered()
        model.scenePhaseChanged(.background)
        await gate.release()
        await model.waitForLifecycle()

        XCTAssertEqual(model.serviceFailure, .network)
        await model.close()
    }

    func testNewerRetrySupersedesHeldRetryRecovery() async throws {
        let session = InertMobileSession()
        let gate = BootstrapGate()
        await session.setBeforeStart { throw MobileRuntimeError.notReady }
        await session.setBeforeRetry { await gate.wait() }
        let model = MobileAppModel(loadSession: { session })
        await model.bootstrap(initialPhase: .active)
        await model.waitForLifecycle()

        model.retryConnection()
        try await gate.entered()
        await session.setBeforeRetry {}
        await session.setRetryState(.reconnecting)
        model.retryConnection()
        await gate.release()
        await model.waitForLifecycle()

        XCTAssertEqual(model.serviceFailure, .network)
        await model.close()
    }

    func testSuccessfulRetryPreservesExplicitTrustRefreshFailure() async {
        let session = InertMobileSession()
        await session.setBeforeStart { throw MobileRuntimeError.notReady }
        await session.setRefreshFailure(true)
        let model = MobileAppModel(loadSession: { session })
        await model.bootstrap(initialPhase: .active)
        await model.waitForLifecycle()

        model.retryConnection()
        await model.waitForLifecycle()

        XCTAssertEqual(model.serviceState, .online)
        XCTAssertEqual(model.serviceFailure, .network)

        await session.setRefreshFailure(false)
        model.retryConnection()
        await model.waitForLifecycle()
        XCTAssertNil(model.serviceFailure)
        await model.close()
    }

    func testRemovalOwnsCheckpointEvenWhenPresentationOwnerIsReleased() async throws {
        let session = InertMobileSession()
        let gate = BootstrapGate()
        await session.setBeforeRevoke { await gate.wait() }
        var model: MobileAppModel? = MobileAppModel(loadSession: { session })
        await model?.bootstrap(initialPhase: .background)
        await model?.waitForLifecycle()
        model?.removeDevice(session.peer.id)
        try await gate.entered()
        weak var retained = model
        model = nil
        XCTAssertNotNil(retained, "Removal must own its model until the signed checkpoint is saved")
        await gate.release()
        let deadline = ContinuousClock.now + .seconds(3)
        while await session.persistCount == 0 && ContinuousClock.now < deadline { await Task.yield() }
        expectEqual(await session.persistCount, 1)
        await retained?.close()
    }

    func testDurablePairingRetainsNameAndTrustWhenNetworkRefreshFails() async {
        let session = InertMobileSession()
        await session.setNames([:])
        await session.setRefreshFailure(true)
        await session.setPairingAttempt(AlreadyPairedAttempt(peer: session.peer))
        let model = MobileAppModel(loadSession: { session })
        await model.bootstrap(initialPhase: .active)
        await model.waitForLifecycle()
        model.presentPairing()
        let pairing = model.pairing!
        pairing.code = "123456"
        pairing.submit()
        let deadline = ContinuousClock.now + .seconds(3)
        while pairing.isBusy && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertFalse(pairing.isBusy)
        XCTAssertEqual(pairing.phase, .paired(session.peer))
        XCTAssertEqual(model.pairedDevices.first?.displayName, session.peer.displayName)
        XCTAssertEqual(model.serviceFailure, .network, "A snapshot must not erase a failed explicit trust refresh")
        expectEqual(await session.refreshCount, 1)
        await model.close()
    }

    func testNamesNeverAuthorizeUnknownPeersAndSelfIsExcluded() async {
        let session = InertMobileSession()
        let snapshot = await session.snapshot()
        let unknown = DeviceID(rawValue: UUID())
        await session.setNames([unknown: "Untrusted name"])
        await session.setTrustedIDs([snapshot.localID, session.peer.id])
        let model = MobileAppModel(loadSession: { session })
        await model.bootstrap(initialPhase: .background)
        XCTAssertEqual(model.pairedDevices.map(\.id), [session.peer.id])
        XCTAssertEqual(model.pairedDevices.first?.displayName, "")
        await model.close()
    }

    func testBackgroundBeforeBootstrapFinishesNeverStartsNetwork() async throws {
        let gate = BootstrapGate()
        let session = InertMobileSession()
        let model = MobileAppModel(loadSession: { await gate.wait(); return session })
        let boot = Task { await model.bootstrap(initialPhase: .active) }
        try await gate.entered()
        model.scenePhaseChanged(.background)
        await gate.release()
        await boot.value
        await model.waitForLifecycle()
        expectEqual(await session.startCount, 0)
        XCTAssertEqual(model.bootstrapState, .ready)
        await model.close()
    }

    func testInitialActiveStartsOnceAndInactiveDoesNotStop() async {
        let session = InertMobileSession()
        let model = MobileAppModel(loadSession: { session })
        await model.bootstrap(initialPhase: .active)
        await model.waitForLifecycle()
        model.scenePhaseChanged(.inactive)
        await model.waitForLifecycle()
        expectEqual(await session.startCount, 1)
        expectEqual(await session.stopCount, 0)
        await model.close()
    }

    func testReachableSnapshotCannotDropPairedRowsOrRetainOldOnlineState() async {
        let session = InertMobileSession()
        let model = MobileAppModel(loadSession: { session })
        await model.bootstrap(initialPhase: .active)
        await model.waitForLifecycle()
        await session.setPresence(.online, peers: [session.peer])
        await model.refreshDevices()
        XCTAssertTrue(model.isEligible(session.peer.id))
        await session.setPresence(.online, peers: [])
        await model.refreshDevices()
        XCTAssertEqual(model.pairedDevices.count, 1)
        XCTAssertEqual(model.pairedDevices.first?.availability, .offline)
        XCTAssertFalse(model.isEligible(session.peer.id))
        await session.setPresence(.reconnecting, peers: [session.peer])
        await model.refreshDevices()
        XCTAssertFalse(model.isEligible(session.peer.id))
        await model.close()
    }

    func testRemovalFailureKeepsCheckpointAndRetryDoesNotRevokeAgain() async {
        let session = InertMobileSession()
        await session.setSaveFailure(true)
        let model = MobileAppModel(loadSession: { session })
        await model.bootstrap(initialPhase: .background)
        model.removeDevice(session.peer.id)
        model.removeDevice(session.peer.id)
        await model.waitForRemoval()
        XCTAssertTrue(model.pairedDevices.isEmpty)
        XCTAssertEqual(model.removalState, .saveFailed)
        expectEqual(await session.revokeCount, 1)
        await session.setSaveFailure(false)
        model.retryRemovalSave()
        await model.waitForRemoval()
        expectEqual(await session.revokeCount, 1)
        expectEqual(await session.persistCount, 2)
        XCTAssertEqual(model.removalState, .saved)
        await model.close()
    }

    func testFreshDurableTrustCanPairPreviouslyRemovedIDAgain() async {
        let session = InertMobileSession()
        let model = MobileAppModel(loadSession: { session })
        await model.bootstrap(initialPhase: .background)
        model.removeDevice(session.peer.id)
        await model.waitForRemoval()
        await session.setTrustedIDs([session.peer.id])
        await model.refreshDevices()
        XCTAssertEqual(model.pairedDevices.map(\.id), [session.peer.id])
        await model.close()
    }

    func testBackgroundStopsNetworkWhilePairingCleanupIsStillHeld() async throws {
        let session = InertMobileSession()
        let gate = BootstrapGate()
        let model = MobileAppModel(loadSession: { session })
        await model.bootstrap(initialPhase: .active)
        await model.waitForLifecycle()
        let pairing = PairingModel(makeAttempt: { await gate.wait(); throw CancellationError() })
        pairing.code = "123456"
        model.pairing = pairing
        pairing.submit()
        try await gate.entered()
        model.scenePhaseChanged(.background)
        let deadline = ContinuousClock.now + .seconds(3)
        while await session.stopCount == 0 && ContinuousClock.now < deadline { await Task.yield() }
        while !pairing.isClosing && ContinuousClock.now < deadline { await Task.yield() }
        expectEqual(await session.stopCount, 1)
        XCTAssertTrue(pairing.isClosing)
        await gate.release()
        await model.waitForLifecycle()
        await model.close()
    }

    func testCloseJoinsObservationTermination() async {
        let session = InertMobileSession()
        let model = MobileAppModel(loadSession: { session })
        await model.bootstrap(initialPhase: .background)
        let deadline = ContinuousClock.now + .seconds(3)
        while await session.observerCount == 0 && ContinuousClock.now < deadline { await Task.yield() }
        expectEqual(await session.observerCount, 1)
        await model.close()
        expectEqual(await session.observerCount, 0)
    }

    private func expectEqual(_ actual: Int, _ expected: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
}

private actor AlreadyPairedAttempt: PairingAttempt {
    let peer: DeviceSummary
    init(peer: DeviceSummary) { self.peer = peer }
    func join(code: String) -> PairingJoinResult {
        PairingJoinResult(sessionID: PairingSessionID(), peer: peer, fingerprint: "fixture fingerprint",
            hostEphemeralPublicKey: Data([1]), joiningEphemeralPublicKey: Data([2]))
    }
    func awaitApproval() -> DeviceSummary { peer }
    func currentState() -> MobilePairingState { .paired(peer) }
    func retrySaving() -> DeviceSummary { peer }
    func cancel() {}
    func stop() {}
}

actor BootstrapGate {
    private var waiting = false
    private var released = false
    func wait() async {
        waiting = true
        let deadline = ContinuousClock.now + .seconds(3)
        while !released && !Task.isCancelled && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        if !released && !Task.isCancelled { XCTFail("Fixture gate timed out") }
        waiting = false
    }
    func entered() async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !waiting && !Task.isCancelled && ContinuousClock.now < deadline { await Task.yield() }
        if !waiting { throw CancellationError() }
    }
    func release() { released = true }
}
