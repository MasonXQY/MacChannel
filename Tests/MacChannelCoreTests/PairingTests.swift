import CryptoKit
import Foundation
import XCTest
@testable import MacChannelCore

final class PairingTests: XCTestCase {
    func testCreateCodePublishesSixDigitsForFiveMinutes() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let server = MemoryPairingServer(clock: clock)
        let identity = try DeviceIdentity.ephemeral()
        let host = try makeCoordinator(identity: identity, displayName: "Host Mac", server: server, source: "host", clock: clock)

        let code = try await host.createCode()

        XCTAssertEqual(code.count, 6)
        XCTAssertTrue(code.allSatisfy(\.isNumber))
        let hostState = await host.currentState()
        XCTAssertEqual(hostState, .displayingCode(expiresAt: Date(timeIntervalSince1970: 1_300)))
        let _: AsyncStream<PairingState> = host.states
    }

    func testCodeExpiresAndCannotBeReplayed() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let server = MemoryPairingServer(clock: clock)
        let identity = try DeviceIdentity.ephemeral()
        let host = try makeCoordinator(identity: identity, server: server, source: "host", clock: clock)
        let code = try await host.createCode()

        clock.advance(seconds: 300)
        await XCTAssertThrowsErrorAsync(try await host.accept(code: code)) { error in
            XCTAssertEqual(error as? PairingError, .codeExpired)
        }

        clock.rewind(seconds: 300)
        _ = try await host.accept(code: code)
        await XCTAssertThrowsErrorAsync(try await host.accept(code: code)) { error in
            XCTAssertEqual(error as? PairingError, .codeAlreadyUsed)
        }
    }

    func testWrongCodeUsesTransportObservedSourceAndTypedFailureState() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let server = MemoryPairingServer(clock: clock)
        let hostIdentity = try DeviceIdentity.ephemeral()
        let joinerIdentity = try DeviceIdentity.ephemeral()
        let host = try makeCoordinator(identity: hostIdentity, server: server, source: "host", clock: clock)
        let joiner = try makeCoordinator(identity: joinerIdentity, server: server, source: "server-observed-192.0.2.10", clock: clock)
        let code = try await host.createCode()
        let wrongCode = code == "000000" ? "000001" : "000000"

        await XCTAssertThrowsErrorAsync(try await joiner.join(code: wrongCode)) { error in
            XCTAssertEqual(error as? PairingError, .invalidCode)
        }
        let joinerState = await joiner.currentState()
        XCTAssertEqual(joinerState, .failed(.pairingInvalidCode))
    }

    func testSixthFailedJoinFromSameObservedSourceIsRateLimitedForTenMinutes() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let server = MemoryPairingServer(clock: clock)
        let joinerIdentity = try DeviceIdentity.ephemeral()
        let joiner = try makeCoordinator(identity: joinerIdentity, server: server, source: "server-observed-192.0.2.20", clock: clock)

        for _ in 0..<5 {
            await XCTAssertThrowsErrorAsync(try await joiner.join(code: "111111")) { error in
                XCTAssertEqual(error as? PairingError, .invalidCode)
            }
        }
        await XCTAssertThrowsErrorAsync(try await joiner.join(code: "111111")) { error in
            XCTAssertEqual(error as? PairingError, .rateLimited)
        }

        clock.advance(seconds: 601)
        await XCTAssertThrowsErrorAsync(try await joiner.join(code: "111111")) { error in
            XCTAssertEqual(error as? PairingError, .invalidCode)
        }
    }

    func testRotatingSourcesHitPerCodeAndGlobalBackstopsWithBoundedStorage() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let server = MemoryPairingServer(clock: clock)

        for index in 0..<20 {
            let connection = MemoryPairingTransport(server: server, observedSource: "rotating-code-source-\(index)")
            await XCTAssertThrowsErrorAsync(try await connection.lookup(code: "111111")) { error in
                XCTAssertEqual(error as? PairingError, .invalidCode)
            }
        }
        let codeBlocked = MemoryPairingTransport(server: server, observedSource: "rotating-code-source-20")
        await XCTAssertThrowsErrorAsync(try await codeBlocked.lookup(code: "111111")) { error in
            XCTAssertEqual(error as? PairingError, .rateLimited)
        }

        clock.advance(seconds: 601)
        for index in 0..<100 {
            let connection = MemoryPairingTransport(server: server, observedSource: "rotating-global-source-\(index)")
            let code = String(format: "%06d", index + 200_000)
            await XCTAssertThrowsErrorAsync(try await connection.lookup(code: code)) { error in
                XCTAssertEqual(error as? PairingError, .invalidCode)
            }
        }
        let globallyBlocked = MemoryPairingTransport(server: server, observedSource: "rotating-global-source-100")
        await XCTAssertThrowsErrorAsync(try await globallyBlocked.lookup(code: "999999")) { error in
            XCTAssertEqual(error as? PairingError, .rateLimited)
        }

        let counts = await server.limiterStorageCounts()
        XCTAssertLessThanOrEqual(counts.sources, 100)
        XCTAssertLessThanOrEqual(counts.codes, 100)
        XCTAssertLessThanOrEqual(counts.globalEvents, 100)
    }

    func testConcurrentBurstReservesBeforeAwaitAndOnlyFiveReachHandler() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let server = MemoryPairingServer(clock: clock)
        let endpoint = BlockingRejectingEndpoint()
        let transport = MemoryPairingTransport(server: server, observedSource: "burst-source")
        let offer = PairingOffer.testValue(code: "123456", expiresAt: Date(timeIntervalSince1970: 1_300))
        try await transport.publish(offer, endpoint: endpoint)
        let request = PairingJoinRequest.testValue(code: offer.code)

        let burst = Task {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<10 {
                    group.addTask {
                        _ = try? await transport.submit(code: offer.code, request: request)
                    }
                }
            }
        }

        for _ in 0..<1_000 where await endpoint.attemptCount < 5 {
            await Task.yield()
        }
        let attemptsBeforeRelease = await endpoint.attemptCount
        XCTAssertEqual(attemptsBeforeRelease, 5)
        await endpoint.releaseAll()
        await burst.value
        let attemptsAfterRelease = await endpoint.attemptCount
        XCTAssertEqual(attemptsAfterRelease, 5)
    }

    func testAuthorizationDoesNotExistOrEscapeUntilHostConfirmation() async throws {
        let context = try PairingTestContext()
        let code = try await context.host.createCode()
        let result = try await context.joiner.join(code: code)
        let expectedFingerprint = fingerprint(for: result)

        XCTAssertEqual(result.fingerprint, expectedFingerprint)
        let deliveriesBefore = await context.server.deliveredAuthorizationCount
        let hostTrustedBefore = await context.host.isTrusted(context.joinerID)
        let joinerTrustedBefore = await context.joiner.isTrusted(context.hostID)
        XCTAssertEqual(deliveriesBefore, 0)
        XCTAssertFalse(hostTrustedBefore)
        XCTAssertFalse(joinerTrustedBefore)

        await XCTAssertThrowsErrorAsync(try await context.joiner.confirmFingerprint(expectedFingerprint)) { error in
            XCTAssertEqual(error as? PairingError, .authorizationPending)
        }
        let trustedWhilePending = await context.joiner.isTrusted(context.hostID)
        XCTAssertFalse(trustedWhilePending)

        let issued = try await context.host.confirmFingerprint(expectedFingerprint)
        try issued.validated()
        XCTAssertEqual(issued.issuer, context.hostID)
        XCTAssertEqual(issued.subject, context.joinerID)
        let deliveriesAfter = await context.server.deliveredAuthorizationCount
        let hostTrustedAfterIssue = await context.host.isTrusted(context.joinerID)
        let joinerTrustedBeforeReceipt = await context.joiner.isTrusted(context.hostID)
        XCTAssertEqual(deliveriesAfter, 1)
        XCTAssertTrue(hostTrustedAfterIssue)
        XCTAssertFalse(joinerTrustedBeforeReceipt)

        let received = try await context.joiner.confirmFingerprint(expectedFingerprint)
        let joinerTrustedAfterReceipt = await context.joiner.isTrusted(context.hostID)
        XCTAssertEqual(received.signature, issued.signature)
        XCTAssertTrue(joinerTrustedAfterReceipt)
        await XCTAssertThrowsErrorAsync(
            try await context.joinerTransport.authorization(for: result.sessionID)
        ) { error in
            XCTAssertEqual(error as? PairingError, .invalidHandshake)
        }
    }

    func testAuthenticatedECDHHandshakeShowsMatchingFingerprintAndConfirmationEstablishesTrust() async throws {
        let context = try PairingTestContext()
        let result = try await context.joiner.join(code: try await context.host.createCode())
        let expectedFingerprint = fingerprint(for: result)
        let hostAwaitingState = await context.host.currentState()
        let joinerAwaitingState = await context.joiner.currentState()
        let hostPendingPeer = await context.host.pendingPeerSummary()
        let joinerPendingPeer = await context.joiner.pendingPeerSummary()

        XCTAssertEqual(result.fingerprint, expectedFingerprint)
        XCTAssertEqual(hostAwaitingState, .awaitingFingerprint(local: expectedFingerprint, remote: expectedFingerprint))
        XCTAssertEqual(joinerAwaitingState, .awaitingFingerprint(local: expectedFingerprint, remote: expectedFingerprint))
        XCTAssertEqual(
            hostPendingPeer,
            DeviceSummary(
                id: context.joinerID,
                displayName: "Joining Mac",
                availability: .internet
            )
        )
        XCTAssertEqual(
            joinerPendingPeer,
            DeviceSummary(
                id: context.hostID,
                displayName: "Host Mac",
                availability: .internet
            )
        )

        _ = try await context.host.confirmFingerprint(expectedFingerprint)
        _ = try await context.joiner.confirmFingerprint(expectedFingerprint)

        let hostTrustsJoiner = await context.host.isTrusted(context.joinerID)
        let joinerTrustsHost = await context.joiner.isTrusted(context.hostID)
        XCTAssertTrue(hostTrustsJoiner)
        XCTAssertTrue(joinerTrustsHost)
        let hostState = await context.host.currentState()
        let joinerState = await context.joiner.currentState()
        XCTAssertEqual(hostState, .confirmed(DeviceSummary(id: context.joinerID, displayName: "Joining Mac", availability: .internet)))
        XCTAssertEqual(joinerState, .confirmed(DeviceSummary(id: context.hostID, displayName: "Host Mac", availability: .internet)))
    }

    func testAlteredSignatureTagAndTranscriptAreRejectedWithTypedState() async throws {
        for mutation in [HandshakeMutation.signature, .responseTag, .transcript] {
            let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
            let server = MemoryPairingServer(clock: clock)
            let hostIdentity = try DeviceIdentity.ephemeral()
            let joinerIdentity = try DeviceIdentity.ephemeral()
            let host = try makeCoordinator(identity: hostIdentity, server: server, source: "host-\(mutation)", clock: clock)
            let baseTransport = MemoryPairingTransport(server: server, observedSource: "joiner-\(mutation)")
            let joinerRepository = try TrustRepository(
                ownerIdentity: joinerIdentity,
                trustStore: TrustStore(owner: joinerIdentity.id),
                persistedGeneration: 0
            )
            let joiner = try PairingCoordinator(
                identity: joinerIdentity,
                trustRepository: joinerRepository,
                transport: MutatingPairingTransport(base: baseTransport, mutation: mutation),
                clock: clock
            )

            await XCTAssertThrowsErrorAsync(try await joiner.join(code: try await host.createCode())) { error in
                XCTAssertEqual(error as? PairingError, .invalidHandshake)
            }
            let state = await joiner.currentState()
            XCTAssertEqual(state, .failed(.pairingHandshakeFailed))
        }
    }

    func testAlteredAuthorizationTagIsRejectedWithoutTrustMutation() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let server = MemoryPairingServer(clock: clock)
        let hostIdentity = try DeviceIdentity.ephemeral()
        let joinerIdentity = try DeviceIdentity.ephemeral()
        let hostID = hostIdentity.id
        let host = try makeCoordinator(identity: hostIdentity, server: server, source: "host", clock: clock)
        let baseTransport = MemoryPairingTransport(server: server, observedSource: "joiner")
        let joinerRepository = try TrustRepository(
            ownerIdentity: joinerIdentity,
            trustStore: TrustStore(owner: joinerIdentity.id),
            persistedGeneration: 0
        )
        let joiner = try PairingCoordinator(
            identity: joinerIdentity,
            trustRepository: joinerRepository,
            transport: MutatingPairingTransport(base: baseTransport, mutation: .authorizationTag),
            clock: clock
        )
        let result = try await joiner.join(code: try await host.createCode())

        _ = try await host.confirmFingerprint(result.fingerprint)
        await XCTAssertThrowsErrorAsync(try await joiner.confirmFingerprint(result.fingerprint)) { error in
            XCTAssertEqual(error as? PairingError, .invalidHandshake)
        }
        let joinerTrustsHost = await joiner.isTrusted(hostID)
        XCTAssertFalse(joinerTrustsHost)
        let state = await joiner.currentState()
        XCTAssertEqual(state, .failed(.pairingHandshakeFailed))
    }

    func testRestoredTrustStoreUsesPersistedIssuerSequenceAndRetainsPeers() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let server = MemoryPairingServer(clock: clock)
        let hostIdentity = try DeviceIdentity.ephemeral()
        let existingPeer = try DeviceIdentity.ephemeral()
        let joinerIdentity = try DeviceIdentity.ephemeral()
        var originalStore = TrustStore(owner: hostIdentity.id)
        try originalStore.authorize(SignedTrustRecord.authorizing(existingPeer, signedBy: hostIdentity, sequence: 1))
        let snapshot = try originalStore.snapshot(signedBy: hostIdentity)
        let restoredStore = try TrustStore(snapshot: snapshot, expectedOwner: hostIdentity, minimumGeneration: snapshot.generation)
        let existingPeerID = existingPeer.id
        let joinerID = joinerIdentity.id
        let hostRepository = try TrustRepository(
            ownerIdentity: hostIdentity,
            trustStore: restoredStore,
            persistedGeneration: snapshot.generation
        )
        let host = try PairingCoordinator(
            identity: hostIdentity,
            displayName: "Restarted Host",
            trustRepository: hostRepository,
            transport: MemoryPairingTransport(server: server, observedSource: "host"),
            clock: clock
        )
        let joiner = try makeCoordinator(identity: joinerIdentity, server: server, source: "joiner", clock: clock)
        let result = try await joiner.join(code: try await host.createCode())

        let authorization = try await host.confirmFingerprint(result.fingerprint)
        _ = try await joiner.confirmFingerprint(result.fingerprint)

        let retainedExistingPeer = await host.isTrusted(existingPeerID)
        let trustsNewJoiner = await host.isTrusted(joinerID)
        XCTAssertEqual(authorization.issuerSequence, 2)
        XCTAssertTrue(retainedExistingPeer)
        XCTAssertTrue(trustsNewJoiner)
    }

    func testSharedRepositoryPersistsTwoPairingsAcrossRestartWithSequenceThree() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let hostIdentity = try DeviceIdentity.ephemeral()
        let firstPeer = try DeviceIdentity.ephemeral()
        let secondPeer = try DeviceIdentity.ephemeral()
        let thirdPeer = try DeviceIdentity.ephemeral()
        var seededStore = TrustStore(owner: hostIdentity.id)
        try seededStore.authorize(
            SignedTrustRecord.authorizing(firstPeer, signedBy: hostIdentity, sequence: 1)
        )
        let seedSnapshot = try seededStore.snapshot(signedBy: hostIdentity)
        let restoredSeed = try TrustStore(
            snapshot: seedSnapshot,
            expectedOwner: hostIdentity,
            minimumGeneration: seedSnapshot.generation
        )
        let firstRepository = try TrustRepository(
            ownerIdentity: hostIdentity,
            trustStore: restoredSeed,
            persistedGeneration: seedSnapshot.generation
        )

        let secondAuthorization = try await pairHost(
            hostIdentity: hostIdentity,
            hostRepository: firstRepository,
            joinerIdentity: secondPeer,
            clock: clock
        )
        XCTAssertEqual(secondAuthorization.issuerSequence, 2)
        let afterSecond = try await firstRepository.latestSignedSnapshot()

        let restoredSecond = try TrustStore(
            snapshot: afterSecond,
            expectedOwner: hostIdentity,
            minimumGeneration: afterSecond.generation
        )
        let secondRepository = try TrustRepository(
            ownerIdentity: hostIdentity,
            trustStore: restoredSecond,
            persistedGeneration: afterSecond.generation
        )
        let thirdAuthorization = try await pairHost(
            hostIdentity: hostIdentity,
            hostRepository: secondRepository,
            joinerIdentity: thirdPeer,
            clock: clock
        )
        let afterThird = try await secondRepository.latestSignedSnapshot()

        XCTAssertEqual(thirdAuthorization.issuerSequence, 3)
        XCTAssertGreaterThan(afterThird.generation, afterSecond.generation)
        let finalStore = try TrustStore(
            snapshot: afterThird,
            expectedOwner: hostIdentity,
            minimumGeneration: afterThird.generation
        )
        XCTAssertTrue(finalStore.isTrusted(firstPeer.id))
        XCTAssertTrue(finalStore.isTrusted(secondPeer.id))
        XCTAssertTrue(finalStore.isTrusted(thirdPeer.id))
    }

    func testTrustRepositoryRejectsPersistedGenerationRollback() throws {
        let owner = try DeviceIdentity.ephemeral()
        var store = TrustStore(owner: owner.id)
        let snapshot = try store.snapshot(signedBy: owner)
        let restored = try TrustStore(
            snapshot: snapshot,
            expectedOwner: owner,
            minimumGeneration: snapshot.generation
        )

        XCTAssertThrowsError(
            try TrustRepository(
                ownerIdentity: owner,
                trustStore: restored,
                persistedGeneration: snapshot.generation - 1
            )
        ) { error in
            XCTAssertEqual(error as? TrustRepositoryError, .generationMismatch)
        }
    }

    func testExactSessionExpiryRejectsBeforeHostTrustMutation() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let context = try PairingTestContext(clock: clock)
        let result = try await context.joiner.join(code: try await context.host.createCode())

        clock.advance(seconds: 300)
        await XCTAssertThrowsErrorAsync(
            try await context.host.confirmFingerprint(result.fingerprint)
        ) { error in
            XCTAssertEqual(error as? PairingError, .sessionExpired)
        }
        let hostTrustsJoiner = await context.host.isTrusted(context.joinerID)
        let deliveryCount = await context.server.deliveredAuthorizationCount
        XCTAssertFalse(hostTrustsJoiner)
        XCTAssertEqual(deliveryCount, 0)
    }

    func testServerRejectsReservationAndAuthorizationAtExactRouteBoundary() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let server = MemoryPairingServer(clock: clock)
        let hostTransport = MemoryPairingTransport(server: server, observedSource: "boundary-host")
        let joinTransport = MemoryPairingTransport(server: server, observedSource: "boundary-joiner")
        let endpoint = ImmediateEndpoint()

        let firstCode = "410000"
        try await hostTransport.publish(
            .testValue(code: firstCode, expiresAt: Date(timeIntervalSince1970: 1_300)),
            endpoint: endpoint
        )
        let first = try await joinTransport.submit(code: firstCode, request: .testValue(code: firstCode))

        let authorizationServer = MemoryPairingServer(clock: clock)
        let authorizationHost = MemoryPairingTransport(server: authorizationServer, observedSource: "auth-boundary-host")
        let authorizationJoiner = MemoryPairingTransport(server: authorizationServer, observedSource: "auth-boundary-joiner")
        let secondCode = "410001"
        try await authorizationHost.publish(
            .testValue(code: secondCode, expiresAt: Date(timeIntervalSince1970: 1_300)),
            endpoint: endpoint
        )
        let second = try await authorizationJoiner.submit(code: secondCode, request: .testValue(code: secondCode))

        clock.advance(seconds: 300)
        await XCTAssertThrowsErrorAsync(
            try await hostTransport.reserveAuthorizationDelivery(for: first.sessionID)
        ) { error in
            XCTAssertEqual(error as? PairingError, .sessionExpired)
        }
        await XCTAssertThrowsErrorAsync(
            try await authorizationJoiner.authorization(for: second.sessionID)
        ) { error in
            XCTAssertEqual(error as? PairingError, .sessionExpired)
        }
        let counts = await server.sessionStorageCounts()
        let authorizationCounts = await authorizationServer.sessionStorageCounts()
        XCTAssertEqual(counts, PairingSessionStorageCounts(routes: 0, deliveries: 0, reservations: 0))
        XCTAssertEqual(authorizationCounts, PairingSessionStorageCounts(routes: 0, deliveries: 0, reservations: 0))
    }

    func testSequentialSuccessfulSessionsHitPerSourceRouteCap() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let server = MemoryPairingServer(clock: clock)
        let hostTransport = MemoryPairingTransport(server: server, observedSource: "route-host")
        let joinTransport = MemoryPairingTransport(server: server, observedSource: "route-joiner")
        let endpoint = ImmediateEndpoint()

        for index in 0..<8 {
            let code = String(format: "%06d", 300_000 + index)
            let offer = PairingOffer.testValue(code: code, expiresAt: Date(timeIntervalSince1970: 1_300))
            try await hostTransport.publish(offer, endpoint: endpoint)
            _ = try await joinTransport.submit(code: code, request: .testValue(code: code))
        }
        let blockedCode = "300008"
        try await hostTransport.publish(
            .testValue(code: blockedCode, expiresAt: Date(timeIntervalSince1970: 1_300)),
            endpoint: endpoint
        )
        await XCTAssertThrowsErrorAsync(
            try await joinTransport.submit(code: blockedCode, request: .testValue(code: blockedCode))
        ) { error in
            XCTAssertEqual(error as? PairingError, .resourceExhausted)
        }
        let attemptCount = await endpoint.attemptCount
        XCTAssertEqual(attemptCount, 8)
        let counts = await server.sessionStorageCounts()
        XCTAssertLessThanOrEqual(counts.routes, 8)
        XCTAssertLessThanOrEqual(counts.deliveries, 8)
    }

    func testBlockedOldConfirmationCannotClearOrPublishOverNewSession() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let server = MemoryPairingServer(clock: clock)
        let hostIdentity = try DeviceIdentity.ephemeral()
        let oldJoinerIdentity = try DeviceIdentity.ephemeral()
        let newJoinerIdentity = try DeviceIdentity.ephemeral()
        let hostBase = MemoryPairingTransport(server: server, observedSource: "host")
        let blockingHostTransport = BlockingReserveTransport(base: hostBase)
        let hostRepository = try TrustRepository(
            ownerIdentity: hostIdentity,
            trustStore: TrustStore(owner: hostIdentity.id),
            persistedGeneration: 0
        )
        let host = try PairingCoordinator(
            identity: hostIdentity,
            trustRepository: hostRepository,
            transport: blockingHostTransport,
            clock: clock
        )
        let oldJoiner = try makeCoordinator(identity: oldJoinerIdentity, server: server, source: "old", clock: clock)
        let newJoiner = try makeCoordinator(identity: newJoinerIdentity, server: server, source: "new", clock: clock)
        let oldResult = try await oldJoiner.join(code: try await host.createCode())
        let oldConfirmation = Task {
            try await host.confirmFingerprint(oldResult.fingerprint)
        }
        await blockingHostTransport.waitUntilReserveStarted()

        let newCode = try await host.createCode()
        let newResult = try await newJoiner.join(code: newCode)
        await blockingHostTransport.releaseReserve()

        await XCTAssertThrowsErrorAsync(try await oldConfirmation.value) { error in
            XCTAssertEqual(error as? PairingError, .staleOperation)
        }
        let deliveryCount = await server.deliveredAuthorizationCount
        let trustsOld = await host.isTrusted(oldJoinerIdentity.id)
        let trustsNew = await host.isTrusted(newJoinerIdentity.id)
        let currentState = await host.currentState()
        XCTAssertEqual(deliveryCount, 0)
        XCTAssertFalse(trustsOld)
        XCTAssertFalse(trustsNew)
        XCTAssertEqual(
            currentState,
            .awaitingFingerprint(local: newResult.fingerprint, remote: newResult.fingerprint)
        )
    }

    func testFailBeforeDeliveryCommitRetriesStableReservationWithoutNewSequence() async throws {
        let setup = try DeliveryFaultPairingSetup(mode: .failBeforeCommit)
        let result = try await setup.joiner.join(code: try await setup.host.createCode())

        var firstAuthorization: SignedTrustRecord?
        await XCTAssertThrowsErrorAsync(
            try await setup.host.confirmFingerprint(result.fingerprint)
        ) { error in
            XCTAssertEqual(error as? DeliveryFaultError, .transient)
        }
        firstAuthorization = await setup.fault.lastAttemptedAuthorization
        let beforeRetryCount = await setup.server.deliveredAuthorizationCount
        XCTAssertEqual(beforeRetryCount, 0)

        let retried = try await setup.host.confirmFingerprint(result.fingerprint)
        let received = try await setup.joiner.confirmFingerprint(result.fingerprint)

        XCTAssertEqual(retried.issuerSequence, 1)
        XCTAssertEqual(retried.signature, firstAuthorization?.signature)
        XCTAssertEqual(received.signature, retried.signature)
        let reservationCount = await setup.fault.uniqueReservationCount
        XCTAssertEqual(reservationCount, 1)
    }

    func testResponseLossAfterCommitRetriesIdempotentlyWithoutDuplicateMailbox() async throws {
        let setup = try DeliveryFaultPairingSetup(mode: .loseResponseAfterCommit)
        let result = try await setup.joiner.join(code: try await setup.host.createCode())

        await XCTAssertThrowsErrorAsync(
            try await setup.host.confirmFingerprint(result.fingerprint)
        ) { error in
            XCTAssertEqual(error as? DeliveryFaultError, .transient)
        }
        let committedBeforeRetry = await setup.server.deliveredAuthorizationCount
        XCTAssertEqual(committedBeforeRetry, 1)
        let attemptedReservation = await setup.fault.lastReservation
        let reservation = try XCTUnwrap(attemptedReservation)
        let committedStatus = try await setup.hostTransport.deliveryStatus(for: reservation)
        XCTAssertEqual(committedStatus, .committed)

        let received = try await setup.joiner.confirmFingerprint(result.fingerprint)
        let retried = try await setup.host.confirmFingerprint(result.fingerprint)
        let committedAfterRetry = await setup.server.deliveredAuthorizationCount
        let hostState = await setup.host.currentState()

        XCTAssertEqual(committedAfterRetry, 1)
        XCTAssertEqual(retried.signature, received.signature)
        XCTAssertEqual(
            hostState,
            .confirmed(DeviceSummary(id: received.subject, displayName: "Fault Joiner", availability: .internet))
        )
        let reservationCount = await setup.fault.uniqueReservationCount
        let authorizationCount = await setup.fault.uniqueAuthorizationCount
        XCTAssertEqual(reservationCount, 1)
        XCTAssertEqual(authorizationCount, 1)
    }

    func testExplicitCancellationReleasesUncommittedReservationButCannotAbandonIssuedTrust() async throws {
        let setup = try DeliveryFaultPairingSetup(mode: .failBeforeCommit)
        let result = try await setup.joiner.join(code: try await setup.host.createCode())

        await XCTAssertThrowsErrorAsync(
            try await setup.host.confirmFingerprint(result.fingerprint)
        ) { error in
            XCTAssertEqual(error as? DeliveryFaultError, .transient)
        }
        await XCTAssertThrowsErrorAsync(
            try await setup.host.cancelPendingPairing()
        ) { error in
            XCTAssertEqual(error as? PairingError, .operationInProgress)
        }

        _ = try await setup.host.confirmFingerprint(result.fingerprint)
        _ = try await setup.joiner.confirmFingerprint(result.fingerprint)

        let clock = TestClock(now: Date(timeIntervalSince1970: 2_000))
        let server = MemoryPairingServer(clock: clock)
        let host = MemoryPairingTransport(server: server, observedSource: "cancel-host")
        let joiner = MemoryPairingTransport(server: server, observedSource: "cancel-joiner")
        let sessionID = try await establishTestRoute(
            code: "430000",
            host: host,
            joiner: joiner,
            endpoint: ImmediateEndpoint(),
            expiresAt: Date(timeIntervalSince1970: 2_300)
        )
        let reservation = try await host.reserveAuthorizationDelivery(for: sessionID)
        await host.cancelAuthorizationDelivery(reservation)

        await XCTAssertThrowsErrorAsync(try await host.deliveryStatus(for: reservation)) { error in
            XCTAssertEqual(error as? PairingError, .invalidHandshake)
        }
        let counts = await server.sessionStorageCounts()
        XCTAssertEqual(counts.reservations, 0)
    }

    func testActiveReservationCanCommitAcrossPairingExpiryAndMailboxRemainsRetrievable() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(MemoryPairingServer.authorizationMailboxTTL, 900)
        let setup = try DeliveryFaultPairingSetup(mode: .failBeforeCommit, clock: clock)
        let result = try await setup.joiner.join(code: try await setup.host.createCode())

        await XCTAssertThrowsErrorAsync(
            try await setup.host.confirmFingerprint(result.fingerprint)
        ) { error in
            XCTAssertEqual(error as? DeliveryFaultError, .transient)
        }
        clock.advance(seconds: 300)

        let committed = try await setup.host.confirmFingerprint(result.fingerprint)
        clock.advance(seconds: 899)
        let received = try await setup.joiner.confirmFingerprint(result.fingerprint)

        XCTAssertEqual(received.signature, committed.signature)
        XCTAssertEqual(received.issuerSequence, 1)
    }

    func testDeliveredMailboxHasIndependentTTLAndBoundedPerRecipientCapacity() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let server = MemoryPairingServer(clock: clock)
        let hostTransport = MemoryPairingTransport(server: server, observedSource: "mailbox-host")
        let joinTransport = MemoryPairingTransport(server: server, observedSource: "mailbox-joiner")
        let endpoint = ImmediateEndpoint()
        let issuer = try DeviceIdentity.ephemeral()
        let subject = try DeviceIdentity.ephemeral()

        for index in 0..<8 {
            let code = String(format: "%06d", 420_000 + index)
            let sessionID = try await establishTestRoute(
                code: code,
                host: hostTransport,
                joiner: joinTransport,
                endpoint: endpoint,
                expiresAt: Date(timeIntervalSince1970: 1_300)
            )
            let reservation = try await hostTransport.reserveAuthorizationDelivery(for: sessionID)
            let record = try SignedTrustRecord.authorizing(subject, signedBy: issuer, sequence: UInt64(index + 1))
            try await hostTransport.deliverAuthorization(
                PairingAuthorizationEnvelope(sessionID: sessionID, authorization: record, channelTag: Data([UInt8(index)])),
                reservation: reservation
            )
        }

        clock.advance(seconds: 300)
        let retained = await server.sessionStorageCounts()
        XCTAssertEqual(retained.routes, 0)
        XCTAssertEqual(retained.deliveries, 8)

        let blockedSession = try await establishTestRoute(
            code: "420008",
            host: hostTransport,
            joiner: joinTransport,
            endpoint: endpoint,
            expiresAt: Date(timeIntervalSince1970: 1_600)
        )
        await XCTAssertThrowsErrorAsync(
            try await hostTransport.reserveAuthorizationDelivery(for: blockedSession)
        ) { error in
            XCTAssertEqual(error as? PairingError, .resourceExhausted)
        }

        clock.advance(seconds: 600)
        let purged = await server.sessionStorageCounts()
        XCTAssertEqual(purged.deliveries, 0)
        XCTAssertLessThanOrEqual(purged.routes, 1)
        XCTAssertEqual(purged.reservations, 0)
    }

    func testConcurrentJoinIsRejectedWhileFirstJoinIsBlocked() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let server = MemoryPairingServer(clock: clock)
        let hostIdentity = try DeviceIdentity.ephemeral()
        let joinerIdentity = try DeviceIdentity.ephemeral()
        let host = try makeCoordinator(identity: hostIdentity, server: server, source: "host", clock: clock)
        let joinBase = MemoryPairingTransport(server: server, observedSource: "joiner")
        let blockingJoinTransport = BlockingLookupTransport(base: joinBase)
        let joinRepository = try TrustRepository(
            ownerIdentity: joinerIdentity,
            trustStore: TrustStore(owner: joinerIdentity.id),
            persistedGeneration: 0
        )
        let joiner = try PairingCoordinator(
            identity: joinerIdentity,
            trustRepository: joinRepository,
            transport: blockingJoinTransport,
            clock: clock
        )
        let code = try await host.createCode()
        let firstJoin = Task { try await joiner.join(code: code) }
        await blockingJoinTransport.waitUntilLookupStarted()

        await XCTAssertThrowsErrorAsync(try await joiner.join(code: code)) { error in
            XCTAssertEqual(error as? PairingError, .operationInProgress)
        }
        await blockingJoinTransport.releaseLookup()
        _ = try await firstJoin.value
    }

    func testCoordinatorRejectsTrustStoreOwnedByAnotherIdentity() throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let server = MemoryPairingServer(clock: clock)
        let identity = try DeviceIdentity.ephemeral()
        let otherOwner = try DeviceIdentity.ephemeral()
        let mismatchedStore = TrustStore(owner: otherOwner.id)
        let mismatchedRepository = try TrustRepository(
            ownerIdentity: otherOwner,
            trustStore: mismatchedStore,
            persistedGeneration: 0
        )

        XCTAssertThrowsError(
            try PairingCoordinator(
                identity: identity,
                trustRepository: mismatchedRepository,
                transport: MemoryPairingTransport(server: server, observedSource: "local"),
                clock: clock
            )
        ) { error in
            XCTAssertEqual(error as? PairingError, .invalidTrustStore)
        }
    }

    func testCodeRotationInvalidatesOldCodeAndKeepsNewSessionUsable() async throws {
        let context = try PairingTestContext()
        let oldCode = try await context.host.createCode()
        let newCode = try await context.host.createCode()

        await XCTAssertThrowsErrorAsync(try await context.joiner.join(code: oldCode)) { error in
            XCTAssertEqual(error as? PairingError, .invalidCode)
        }
        let result = try await context.joiner.join(code: newCode)
        XCTAssertEqual(result.fingerprint.count, 12)
    }
}

private struct PairingTestContext {
    let server: MemoryPairingServer
    let joinerTransport: MemoryPairingTransport
    let host: PairingCoordinator
    let joiner: PairingCoordinator
    let hostID: DeviceID
    let joinerID: DeviceID

    init(clock: TestClock = TestClock(now: Date(timeIntervalSince1970: 1_000))) throws {
        server = MemoryPairingServer(clock: clock)
        let hostIdentity = try DeviceIdentity.ephemeral()
        let joinerIdentity = try DeviceIdentity.ephemeral()
        hostID = hostIdentity.id
        joinerID = joinerIdentity.id
        host = try makeCoordinator(identity: hostIdentity, displayName: "Host Mac", server: server, source: "host", clock: clock)
        joinerTransport = MemoryPairingTransport(server: server, observedSource: "joiner")
        let joinerStore = TrustStore(owner: joinerIdentity.id)
        let joinerRepository = try TrustRepository(
            ownerIdentity: joinerIdentity,
            trustStore: joinerStore,
            persistedGeneration: 0
        )
        joiner = try PairingCoordinator(
            identity: joinerIdentity,
            displayName: "Joining Mac",
            trustRepository: joinerRepository,
            transport: joinerTransport,
            clock: clock
        )
    }
}

private enum DeliveryFaultMode: Sendable {
    case failBeforeCommit
    case loseResponseAfterCommit
}

private enum DeliveryFaultError: Error, Equatable {
    case transient
}

private struct DeliveryFaultPairingSetup {
    let server: MemoryPairingServer
    let hostTransport: MemoryPairingTransport
    let host: PairingCoordinator
    let joiner: PairingCoordinator
    let fault: DeliveryFaultController

    init(
        mode: DeliveryFaultMode,
        clock: TestClock = TestClock(now: Date(timeIntervalSince1970: 1_000))
    ) throws {
        server = MemoryPairingServer(clock: clock)
        let hostIdentity = try DeviceIdentity.ephemeral()
        let joinerIdentity = try DeviceIdentity.ephemeral()
        hostTransport = MemoryPairingTransport(server: server, observedSource: "fault-host")
        fault = DeliveryFaultController(mode: mode, base: hostTransport)
        let hostRepository = try TrustRepository(
            ownerIdentity: hostIdentity,
            trustStore: TrustStore(owner: hostIdentity.id),
            persistedGeneration: 0
        )
        host = try PairingCoordinator(
            identity: hostIdentity,
            displayName: "Fault Host",
            trustRepository: hostRepository,
            transport: DeliveryFaultTransport(base: hostTransport, controller: fault),
            clock: clock
        )
        joiner = try makeCoordinator(
            identity: joinerIdentity,
            displayName: "Fault Joiner",
            server: server,
            source: "fault-joiner",
            clock: clock
        )
    }
}

private struct DeliveryFaultTransport: PairingTransport {
    let base: MemoryPairingTransport
    let controller: DeliveryFaultController

    func publish(_ offer: PairingOffer, endpoint: any PairingHostEndpoint) async throws {
        try await base.publish(offer, endpoint: endpoint)
    }

    func lookup(code: String) async throws -> PairingOffer {
        try await base.lookup(code: code)
    }

    func submit(code: String, request: PairingJoinRequest) async throws -> PairingJoinResponse {
        try await base.submit(code: code, request: request)
    }

    func remove(code: String) async {
        await base.remove(code: code)
    }

    func reserveAuthorizationDelivery(for sessionID: PairingSessionID) async throws -> PairingDeliveryReservation {
        try await base.reserveAuthorizationDelivery(for: sessionID)
    }

    func deliveryStatus(for reservation: PairingDeliveryReservation) async throws -> PairingDeliveryStatus {
        try await base.deliveryStatus(for: reservation)
    }

    func deliverAuthorization(
        _ envelope: PairingAuthorizationEnvelope,
        reservation: PairingDeliveryReservation
    ) async throws {
        try await controller.deliver(envelope, reservation: reservation)
    }

    func cancelAuthorizationDelivery(_ reservation: PairingDeliveryReservation) async {
        await base.cancelAuthorizationDelivery(reservation)
    }

    func authorization(for sessionID: PairingSessionID) async throws -> PairingAuthorizationEnvelope {
        try await base.authorization(for: sessionID)
    }
}

private actor DeliveryFaultController {
    let mode: DeliveryFaultMode
    let base: MemoryPairingTransport
    private var injectedFailure = false
    private var reservations: Set<PairingDeliveryReservation> = []
    private var authorizationSignatures: Set<Data> = []
    private(set) var lastAttemptedAuthorization: SignedTrustRecord?
    private(set) var lastReservation: PairingDeliveryReservation?

    init(mode: DeliveryFaultMode, base: MemoryPairingTransport) {
        self.mode = mode
        self.base = base
    }

    var uniqueReservationCount: Int { reservations.count }
    var uniqueAuthorizationCount: Int { authorizationSignatures.count }

    func deliver(
        _ envelope: PairingAuthorizationEnvelope,
        reservation: PairingDeliveryReservation
    ) async throws {
        reservations.insert(reservation)
        lastReservation = reservation
        authorizationSignatures.insert(envelope.authorization.signature)
        lastAttemptedAuthorization = envelope.authorization
        guard !injectedFailure else {
            return try await base.deliverAuthorization(envelope, reservation: reservation)
        }
        injectedFailure = true
        switch mode {
        case .failBeforeCommit:
            throw DeliveryFaultError.transient
        case .loseResponseAfterCommit:
            try await base.deliverAuthorization(envelope, reservation: reservation)
            throw DeliveryFaultError.transient
        }
    }
}

private func makeCoordinator(
    identity: DeviceIdentity,
    displayName: String = "Mac",
    server: MemoryPairingServer,
    source: String,
    clock: any PairingClock
) throws -> PairingCoordinator {
    let trustStore = TrustStore(owner: identity.id)
    let repository = try TrustRepository(
        ownerIdentity: identity,
        trustStore: trustStore,
        persistedGeneration: 0
    )
    return try PairingCoordinator(
        identity: identity,
        displayName: displayName,
        trustRepository: repository,
        transport: MemoryPairingTransport(server: server, observedSource: source),
        clock: clock
    )
}

private func pairHost(
    hostIdentity: DeviceIdentity,
    hostRepository: TrustRepository,
    joinerIdentity: DeviceIdentity,
    clock: any PairingClock
) async throws -> SignedTrustRecord {
    let server = MemoryPairingServer(clock: clock)
    let host = try PairingCoordinator(
        identity: hostIdentity,
        trustRepository: hostRepository,
        transport: MemoryPairingTransport(server: server, observedSource: UUID().uuidString),
        clock: clock
    )
    let joiner = try makeCoordinator(
        identity: joinerIdentity,
        server: server,
        source: UUID().uuidString,
        clock: clock
    )
    let result = try await joiner.join(code: try await host.createCode())
    let authorization = try await host.confirmFingerprint(result.fingerprint)
    _ = try await joiner.confirmFingerprint(result.fingerprint)
    return authorization
}

private func establishTestRoute(
    code: String,
    host: MemoryPairingTransport,
    joiner: MemoryPairingTransport,
    endpoint: ImmediateEndpoint,
    expiresAt: Date
) async throws -> PairingSessionID {
    try await host.publish(.testValue(code: code, expiresAt: expiresAt), endpoint: endpoint)
    let response = try await joiner.submit(code: code, request: .testValue(code: code))
    return response.sessionID
}

private func fingerprint(for result: PairingJoinResult) -> String {
    SHA256.hash(data: result.hostEphemeralPublicKey + result.joiningEphemeralPublicKey)
        .prefix(6)
        .map { String(format: "%02x", $0) }
        .joined()
}

private enum HandshakeMutation: CustomStringConvertible {
    case signature
    case responseTag
    case transcript
    case authorizationTag

    var description: String {
        switch self {
        case .signature: "signature"
        case .responseTag: "response-tag"
        case .transcript: "transcript"
        case .authorizationTag: "authorization-tag"
        }
    }
}

private struct MutatingPairingTransport: PairingTransport {
    let base: MemoryPairingTransport
    let mutation: HandshakeMutation

    func publish(_ offer: PairingOffer, endpoint: any PairingHostEndpoint) async throws {
        try await base.publish(offer, endpoint: endpoint)
    }

    func lookup(code: String) async throws -> PairingOffer {
        let offer = try await base.lookup(code: code)
        guard mutation == .transcript else { return offer }
        return PairingOffer(
            code: offer.code,
            expiresAt: offer.expiresAt,
            hostID: offer.hostID,
            hostIdentityPublicKey: offer.hostIdentityPublicKey,
            hostEphemeralPublicKey: offer.hostEphemeralPublicKey,
            hostDisplayName: offer.hostDisplayName + " altered"
        )
    }

    func submit(code: String, request: PairingJoinRequest) async throws -> PairingJoinResponse {
        let response = try await base.submit(code: code, request: request)
        switch mutation {
        case .signature:
            return PairingJoinResponse(
                sessionID: response.sessionID,
                hostIdentitySignature: Data(repeating: 0, count: response.hostIdentitySignature.count),
                channelTag: response.channelTag
            )
        case .responseTag:
            return PairingJoinResponse(
                sessionID: response.sessionID,
                hostIdentitySignature: response.hostIdentitySignature,
                channelTag: Data(repeating: 0, count: response.channelTag.count)
            )
        case .transcript, .authorizationTag:
            return response
        }
    }

    func remove(code: String) async {
        await base.remove(code: code)
    }

    func reserveAuthorizationDelivery(
        for sessionID: PairingSessionID
    ) async throws -> PairingDeliveryReservation {
        try await base.reserveAuthorizationDelivery(for: sessionID)
    }

    func deliveryStatus(for reservation: PairingDeliveryReservation) async throws -> PairingDeliveryStatus {
        try await base.deliveryStatus(for: reservation)
    }

    func deliverAuthorization(
        _ envelope: PairingAuthorizationEnvelope,
        reservation: PairingDeliveryReservation
    ) async throws {
        try await base.deliverAuthorization(envelope, reservation: reservation)
    }

    func cancelAuthorizationDelivery(_ reservation: PairingDeliveryReservation) async {
        await base.cancelAuthorizationDelivery(reservation)
    }

    func authorization(for sessionID: PairingSessionID) async throws -> PairingAuthorizationEnvelope {
        let envelope = try await base.authorization(for: sessionID)
        guard mutation == .authorizationTag else { return envelope }
        return PairingAuthorizationEnvelope(
            sessionID: envelope.sessionID,
            authorization: envelope.authorization,
            channelTag: Data(repeating: 0, count: envelope.channelTag.count)
        )
    }
}

private actor ImmediateEndpoint: PairingHostEndpoint {
    private(set) var attemptCount = 0

    func accept(_ request: PairingJoinRequest) -> PairingJoinResponse {
        attemptCount += 1
        return PairingJoinResponse(
            sessionID: PairingSessionID(),
            hostIdentitySignature: Data(),
            channelTag: Data()
        )
    }
}

private struct BlockingReserveTransport: PairingTransport {
    let base: MemoryPairingTransport
    private let gate = AsyncGate()

    func publish(_ offer: PairingOffer, endpoint: any PairingHostEndpoint) async throws {
        try await base.publish(offer, endpoint: endpoint)
    }

    func lookup(code: String) async throws -> PairingOffer {
        try await base.lookup(code: code)
    }

    func submit(code: String, request: PairingJoinRequest) async throws -> PairingJoinResponse {
        try await base.submit(code: code, request: request)
    }

    func remove(code: String) async {
        await base.remove(code: code)
    }

    func reserveAuthorizationDelivery(
        for sessionID: PairingSessionID
    ) async throws -> PairingDeliveryReservation {
        await gate.block()
        return try await base.reserveAuthorizationDelivery(for: sessionID)
    }

    func deliveryStatus(for reservation: PairingDeliveryReservation) async throws -> PairingDeliveryStatus {
        try await base.deliveryStatus(for: reservation)
    }

    func deliverAuthorization(
        _ envelope: PairingAuthorizationEnvelope,
        reservation: PairingDeliveryReservation
    ) async throws {
        try await base.deliverAuthorization(envelope, reservation: reservation)
    }

    func cancelAuthorizationDelivery(_ reservation: PairingDeliveryReservation) async {
        await base.cancelAuthorizationDelivery(reservation)
    }

    func authorization(for sessionID: PairingSessionID) async throws -> PairingAuthorizationEnvelope {
        try await base.authorization(for: sessionID)
    }

    func waitUntilReserveStarted() async { await gate.waitUntilBlocked() }
    func releaseReserve() async { await gate.release() }
}

private struct BlockingLookupTransport: PairingTransport {
    let base: MemoryPairingTransport
    private let gate = AsyncGate()

    func publish(_ offer: PairingOffer, endpoint: any PairingHostEndpoint) async throws {
        try await base.publish(offer, endpoint: endpoint)
    }

    func lookup(code: String) async throws -> PairingOffer {
        await gate.block()
        return try await base.lookup(code: code)
    }

    func submit(code: String, request: PairingJoinRequest) async throws -> PairingJoinResponse {
        try await base.submit(code: code, request: request)
    }

    func remove(code: String) async { await base.remove(code: code) }

    func reserveAuthorizationDelivery(
        for sessionID: PairingSessionID
    ) async throws -> PairingDeliveryReservation {
        try await base.reserveAuthorizationDelivery(for: sessionID)
    }

    func deliveryStatus(for reservation: PairingDeliveryReservation) async throws -> PairingDeliveryStatus {
        try await base.deliveryStatus(for: reservation)
    }

    func deliverAuthorization(
        _ envelope: PairingAuthorizationEnvelope,
        reservation: PairingDeliveryReservation
    ) async throws {
        try await base.deliverAuthorization(envelope, reservation: reservation)
    }

    func cancelAuthorizationDelivery(_ reservation: PairingDeliveryReservation) async {
        await base.cancelAuthorizationDelivery(reservation)
    }

    func authorization(for sessionID: PairingSessionID) async throws -> PairingAuthorizationEnvelope {
        try await base.authorization(for: sessionID)
    }

    func waitUntilLookupStarted() async { await gate.waitUntilBlocked() }
    func releaseLookup() async { await gate.release() }
}

private actor AsyncGate {
    private var blocked = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func block() async {
        blocked = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilBlocked() async {
        guard !blocked else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor BlockingRejectingEndpoint: PairingHostEndpoint {
    private(set) var attemptCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func accept(_ request: PairingJoinRequest) async throws -> PairingJoinResponse {
        attemptCount += 1
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        throw PairingError.invalidHandshake
    }

    func releaseAll() {
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }
}

private extension PairingOffer {
    static func testValue(code: String, expiresAt: Date) -> PairingOffer {
        let identityKey = P256.Signing.PrivateKey()
        let ephemeralKey = P256.KeyAgreement.PrivateKey()
        return PairingOffer(
            code: code,
            expiresAt: expiresAt,
            hostID: DeviceIdentity.deviceID(for: identityKey.publicKey.rawRepresentation),
            hostIdentityPublicKey: identityKey.publicKey.rawRepresentation,
            hostEphemeralPublicKey: ephemeralKey.publicKey.rawRepresentation,
            hostDisplayName: "Host"
        )
    }
}

private extension PairingJoinRequest {
    static func testValue(code: String) -> PairingJoinRequest {
        let identityKey = P256.Signing.PrivateKey()
        let ephemeralKey = P256.KeyAgreement.PrivateKey()
        return PairingJoinRequest(
            code: code,
            joiningID: DeviceIdentity.deviceID(for: identityKey.publicKey.rawRepresentation),
            joiningIdentityPublicKey: identityKey.publicKey.rawRepresentation,
            joiningEphemeralPublicKey: ephemeralKey.publicKey.rawRepresentation,
            joiningDisplayName: "Joiner",
            identitySignature: Data(),
            channelTag: Data()
        )
    }
}

private final class TestClock: PairingClock, @unchecked Sendable {
    private let lock = NSLock()
    private var storedNow: Date

    init(now: Date) { storedNow = now }

    var now: Date { lock.withLock { storedNow } }

    func advance(seconds: TimeInterval) {
        lock.withLock { storedNow = storedNow.addingTimeInterval(seconds) }
    }

    func rewind(seconds: TimeInterval) { advance(seconds: -seconds) }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
