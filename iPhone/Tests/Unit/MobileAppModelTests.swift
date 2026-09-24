import DropMeshMobileRuntime
import MacChannelCore
import SwiftUI
import XCTest
@testable import DropMeshTestHost

@MainActor
final class MobileAppModelTests: XCTestCase {
    func testManualRemovalDoesNotRemoveIndependentAccountPeerAfterSave() async {
        let session = InertMobileSession()
        await session.setEffectivePeerIDs([session.peer.id])
        await session.setPresence(.online, peers: [session.peer])
        let model = MobileAppModel(loadSession: { session })
        await model.bootstrap(initialPhase: .active)
        await model.waitForLifecycle()
        await model.refreshDevices()
        model.removeDevice(session.peer.id)
        await model.waitForRemoval()
        XCTAssertEqual(model.removalState, .saved)
        XCTAssertTrue(model.manualPeerIDs.isEmpty)
        XCTAssertEqual(model.pairedDevices.map(\.id), [session.peer.id])
        XCTAssertTrue(model.isEligible(session.peer.id))
        await model.close()
    }

    func testAccountOnlyPeerDisplaysWithoutBecomingManualPairing() async throws {
        let session = InertMobileSession()
        await session.setTrustedIDs([])
        await session.setEffectivePeerIDs([session.peer.id])
        await session.setPresence(.online, peers: [session.peer])
        let model = MobileAppModel(loadSession: { session })
        await model.bootstrap(initialPhase: .active)
        await model.waitForLifecycle()
        await model.refreshDevices()
        XCTAssertEqual(model.pairedDevices.map(\.id), [session.peer.id])
        XCTAssertTrue(model.manualPeerIDs.isEmpty)
        XCTAssertTrue(model.isEligible(session.peer.id))
        model.removeDevice(session.peer.id)
        await model.waitForRemoval()
        let revokes = await session.revokeCount
        XCTAssertEqual(revokes, 0, "account-only peer must not use manual trust revocation")
        await session.setEffectivePeerIDs([])
        await model.refreshDevices()
        XCTAssertTrue(model.pairedDevices.isEmpty)
        XCTAssertEqual(model.currentDevice(session.peer).availability, .offline)
        XCTAssertNotEqual(model.presentation(for: model.currentDevice(session.peer)), .online)
        await model.close()
    }

    func testInvitationOpenURLPrefillsAccountRequestLinkOnlyForValidDropMeshInvite() async throws {
        let session = InertMobileSession()
        let binding = try AccountSessionBinding(deviceID: UUID(),
            audience: "com.example.app", origin: URL(string: "https://accounts.example.com")!)
        await session.setAccountController(AccountSessionController(service: LinkOpenAccountService(),
            storage: LinkOpenAccountStorage(), binding: binding))
        let model = MobileAppModel(loadSession: { session })
        let link = try AccountInvitationLink.generate().shareURL

        let rejected = await model.prepareInvitationFromOpenURL(URL(string: "https://example.com/connect")!)
        let accepted = await model.prepareInvitationFromOpenURL(link)
        XCTAssertFalse(rejected)
        XCTAssertTrue(accepted)

        XCTAssertEqual(model.settings?.account.invitationLinkText, link.absoluteString)
        await model.close()
    }

    func testWithdrawnAuthorityKeepsManualPeerButNotOnline() async {
        let session = InertMobileSession()
        await session.setEffectivePeerIDs([])
        await session.setPresence(.online, peers: [session.peer])
        await session.setAccountConfigurationUnavailable(true)
        let model = MobileAppModel(loadSession: { session })
        await model.bootstrap(initialPhase: .active)
        await model.waitForLifecycle()
        await model.refreshDevices()
        XCTAssertEqual(model.pairedDevices.map(\.id), [session.peer.id])
        XCTAssertEqual(model.pairedDevices.first?.availability, .offline)
        XCTAssertFalse(model.isEligible(session.peer.id))
        XCTAssertTrue(model.accountConfigurationUnavailable)
        await model.close()
    }

    func testFrameworkDismissalBeforeAffirmativeCallbackStillRunsAcceptedRecovery() async {
        let recovery = LockedRecoveryCalls()
        let model = MobileAppModel(
            loadSession: { throw MobileIdentityRecoveryError.orphanedInstallation },
            recoverOrphanedIdentity: { recovery.record() }
        )

        await model.bootstrap(initialPhase: .active)
        model.requestIdentityRecovery()

        let confirmationID = try! XCTUnwrap(model.identityRecoveryConfirmationID)
        // SwiftUI writes `false` to the alert binding before invoking its button callback.
        model.identityRecoveryPresentationDismissed(confirmationID)
        let operationID = try! XCTUnwrap(model.acceptIdentityRecovery(confirmationID))
        await model.performAcceptedIdentityRecovery(operationID)

        XCTAssertEqual(recovery.count, 1)
    }

    func testExplicitCancelNeverAcceptsRecovery() async throws {
        let recovery = LockedRecoveryCalls()
        let model = MobileAppModel(
            loadSession: { throw MobileIdentityRecoveryError.orphanedInstallation },
            recoverOrphanedIdentity: { recovery.record() }
        )
        await model.bootstrap(initialPhase: .active)
        model.requestIdentityRecovery()
        let confirmationID = try XCTUnwrap(model.identityRecoveryConfirmationID)

        model.cancelIdentityRecovery(confirmationID)
        XCTAssertNil(model.acceptIdentityRecovery(confirmationID))
        XCTAssertEqual(recovery.count, 0)
    }

    func testStaleDismissalAndAcceptanceCannotAffectNewPresentation() async throws {
        let recovery = LockedRecoveryCalls()
        let model = MobileAppModel(
            loadSession: { throw MobileIdentityRecoveryError.orphanedInstallation },
            recoverOrphanedIdentity: { recovery.record() }
        )
        await model.bootstrap(initialPhase: .active)
        model.requestIdentityRecovery()
        let oldID = try XCTUnwrap(model.identityRecoveryConfirmationID)
        model.cancelIdentityRecovery(oldID)
        model.requestIdentityRecovery()
        let newID = try XCTUnwrap(model.identityRecoveryConfirmationID)

        model.identityRecoveryPresentationDismissed(oldID)
        XCTAssertNil(model.acceptIdentityRecovery(oldID))
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(model.identityRecoveryConfirmationID, newID)
        let operationID = try XCTUnwrap(model.acceptIdentityRecovery(newID))
        await model.performAcceptedIdentityRecovery(operationID)
        XCTAssertEqual(recovery.count, 1)
    }

    func testDuplicateAcceptanceRunsRecoveryOnce() async throws {
        let recovery = LockedRecoveryCalls()
        let model = MobileAppModel(
            loadSession: { throw MobileIdentityRecoveryError.orphanedInstallation },
            recoverOrphanedIdentity: { recovery.record() }
        )
        await model.bootstrap(initialPhase: .active)
        model.requestIdentityRecovery()
        let confirmationID = try XCTUnwrap(model.identityRecoveryConfirmationID)

        let operationID = try XCTUnwrap(model.acceptIdentityRecovery(confirmationID))
        XCTAssertNil(model.acceptIdentityRecovery(confirmationID))
        await model.performAcceptedIdentityRecovery(operationID)
        await model.performAcceptedIdentityRecovery(operationID)

        XCTAssertEqual(recovery.count, 1)
    }

    func testRecoveryRemainsInProgressWhileAcceptedOperationIsSuspended() async throws {
        let session = InertMobileSession()
        let loads = LockedRecoveryCalls()
        let recovery = LockedRecoveryCalls()
        let gate = LockedRecoveryGate()
        let entered = expectation(description: "recovery closure entered")
        let model = MobileAppModel(
            loadSession: {
                if loads.recordAndReturnCount() == 1 {
                    throw MobileIdentityRecoveryError.orphanedInstallation
                }
                return session
            },
            recoverOrphanedIdentity: {
                recovery.record()
                entered.fulfill()
                await gate.waitForRelease()
            }
        )
        defer { gate.release() }

        await model.bootstrap(initialPhase: .active)
        model.requestIdentityRecovery()
        let confirmationID = try XCTUnwrap(model.identityRecoveryConfirmationID)
        let operationID = try XCTUnwrap(model.acceptIdentityRecovery(confirmationID))
        let operation = Task { await model.performAcceptedIdentityRecovery(operationID) }
        await fulfillment(of: [entered], timeout: 2)

        XCTAssertTrue(model.identityRecoveryInProgress)
        XCTAssertNil(model.acceptIdentityRecovery(confirmationID))
        await model.performAcceptedIdentityRecovery(operationID)
        XCTAssertEqual(recovery.count, 1)

        gate.release()
        await operation.value
        XCTAssertEqual(model.bootstrapState, .ready)
        XCTAssertFalse(model.identityRecoveryInProgress)
        XCTAssertEqual(recovery.count, 1)
    }

    func testRecoveryFailureIsVisibleAndOffersSafeBootstrapRetry() async throws {
        struct FixtureFailure: Error {}
        let loads = LockedRecoveryCalls()
        let model = MobileAppModel(
            loadSession: {
                loads.record()
                throw MobileIdentityRecoveryError.orphanedInstallation
            },
            recoverOrphanedIdentity: { throw FixtureFailure() }
        )
        await model.bootstrap(initialPhase: .active)
        model.requestIdentityRecovery()
        let confirmationID = try XCTUnwrap(model.identityRecoveryConfirmationID)
        let operationID = try XCTUnwrap(model.acceptIdentityRecovery(confirmationID))

        XCTAssertTrue(model.identityRecoveryInProgress)
        await model.performAcceptedIdentityRecovery(operationID)

        XCTAssertFalse(model.identityRecoveryInProgress)
        XCTAssertFalse(model.identityRecoveryAvailable)
        XCTAssertEqual(model.bootstrapState, .failed)
        XCTAssertEqual(model.bootstrapError, String(localized: "identity.recovery.failed"))
        await model.retryBootstrap()
        XCTAssertEqual(loads.count, 2)
    }

    func testOrphanedIdentityRequiresExplicitConfirmationBeforeRecovery() async {
        let recovery = LockedRecoveryCalls()
        let model = MobileAppModel(
            loadSession: { throw MobileIdentityRecoveryError.orphanedInstallation },
            recoverOrphanedIdentity: { recovery.record() }
        )

        await model.bootstrap(initialPhase: .active)
        XCTAssertTrue(model.identityRecoveryAvailable)
        XCTAssertFalse(model.identityRecoveryConfirmationPresented)
        XCTAssertEqual(recovery.count, 0)

        model.requestIdentityRecovery()
        XCTAssertTrue(model.identityRecoveryConfirmationPresented)
        model.cancelIdentityRecovery()
        XCTAssertFalse(model.identityRecoveryConfirmationPresented)
        XCTAssertEqual(recovery.count, 0)
    }

    func testConfirmedIdentityRecoveryRunsOnceThenRetriesBootstrap() async {
        let session = InertMobileSession()
        let loads = LockedRecoveryCalls()
        let recovery = LockedRecoveryCalls()
        let model = MobileAppModel(
            loadSession: {
                if loads.recordAndReturnCount() == 1 {
                    throw MobileIdentityRecoveryError.orphanedInstallation
                }
                return session
            },
            recoverOrphanedIdentity: { recovery.record() }
        )

        await model.bootstrap(initialPhase: .inactive)
        model.requestIdentityRecovery()
        await model.confirmIdentityRecovery()

        XCTAssertEqual(recovery.count, 1)
        XCTAssertEqual(loads.count, 2)
        XCTAssertEqual(model.bootstrapState, .ready)
        XCTAssertFalse(model.identityRecoveryAvailable)
    }
    func testPresentationUsesSyncWithoutChangingEligibilityAndPreservesDistinctNames() async {
        let session = InertMobileSession()
        let model = MobileAppModel(loadSession: { session })
        await model.bootstrap(initialPhase: .active)
        await model.waitForLifecycle()
        let other = DeviceID(rawValue: UUID())
        await session.setPresentation(state: .online, sync: .needsAttention,
            names: [session.peer.id: "Same name", other: "Same name"], reachable: [session.peer])
        await model.refreshDevices()
        XCTAssertEqual(model.pairedDevices.count, 2)
        XCTAssertEqual(model.presentation(for: session.peer), .online)
        XCTAssertTrue(model.isEligible(session.peer.id))
        let missing = model.pairedDevices.first { $0.id == other }!
        XCTAssertEqual(model.presentation(for: missing), .statusPending)
        await session.setPresentation(state: .reconnecting, sync: .synchronized,
            names: [session.peer.id: " "], reachable: [session.peer])
        await model.refreshDevices()
        XCTAssertEqual(model.presentation(for: session.peer), .statusPending)
        XCTAssertFalse(model.isEligible(session.peer.id))
        await model.close()
    }

    func testRemovalDismissesVisiblePairingSuccess() async throws {
        let session = InertMobileSession()
        await session.setPairingAttempt(AlreadyPairedAttempt(peer: session.peer))
        let model = MobileAppModel(loadSession: { session })
        await model.bootstrap(initialPhase: .active)
        await model.waitForLifecycle()
        model.presentPairing()
        model.pairing?.code = "123456"
        model.pairing?.submit()
        let deadline = ContinuousClock.now + .seconds(3)
        while model.pairing?.phase != .paired(session.peer), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(model.pairing?.phase, .paired(session.peer))
        model.removeDevice(session.peer.id)
        XCTAssertNil(model.pairing)
        await model.close()
    }
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

private final class LockedRecoveryCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func record() { lock.withLock { value += 1 } }
    func recordAndReturnCount() -> Int { lock.withLock { value += 1; return value } }
}

private final class LockedRecoveryGate: @unchecked Sendable {
    private let releases: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        releases = stream.stream
        continuation = stream.continuation
    }

    func waitForRelease() async {
        var iterator = releases.makeAsyncIterator()
        _ = await iterator.next()
    }

    func release() { continuation.yield(()) }
}

private actor LinkOpenAccountStorage: AccountSessionStorage {
    func load() -> AccountStoredSession? { nil }
    func save(_ record: AccountStoredSession) {}
    func remove() {}
}

private struct LinkOpenAccountService: AccountSessionService {
    func challenge() async throws -> AccountLoginChallenge { throw AccountServiceError.unavailable }
    func complete(challengeID: String, code: String, identityToken: String) async throws -> AccountSessionTokens {
        throw AccountServiceError.unavailable
    }
    func status(accessToken: String) async throws -> AccountSessionIdentity { throw AccountServiceError.unavailable }
    func refresh(refreshToken: String) async throws -> AccountSessionTokens { throw AccountServiceError.unavailable }
    func logout(accessToken: String) async throws {}
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
