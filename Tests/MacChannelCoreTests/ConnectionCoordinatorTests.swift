import Foundation
import XCTest
@testable import MacChannelCore

final class ConnectionCoordinatorTests: XCTestCase {
    func testSharedBudgetHoldsCancelledAcceptanceUntilLateFactoryCloses() async throws {
        let f = try AttemptAuthorizationFixture()
        let pair = try await f.loopback()
        let barrier = AttemptBarrier()
        defer { barrier.release() }
        let budget = WebRTCAcceptanceBudget()
        let occupied = try XCTUnwrap(budget.acquire(for: f.remote.id))
        let factory = AuthorizedAttemptFactory { _, _ in await barrier.wait(); return pair.left }
        let listener = WebRTCConnectionListener(directory: f.directory, identity: f.local,
            authorizationProvider: f.owner, signaling: f.signaling,
            ice: ICEConfiguration(stunURLs: [], turnServers: []), factory: factory,
            acceptanceBudget: budget)
        _ = await listener.channels()
        try await f.offer()
        await fulfillment(of: [barrier.entered], timeout: 2)
        await listener.stop()
        XCTAssertNil(budget.acquire(for: f.remote.id), "Cancelled but noncooperative acceptance remains charged")
        barrier.release()
        await listener.stopAndWait()
        let replacement = try XCTUnwrap(budget.acquire(for: f.remote.id))
        budget.release(replacement)
        budget.release(occupied)
        do { _ = try await pair.left.exportKey(label: "closed", context: Data(), length: 32); XCTFail("Late channel not closed") }
        catch { XCTAssertEqual(error as? WebRTCSecureChannelError, .transportClosed) }
        await pair.right.close()
    }
    func testSharedInboundAcceptanceBudgetAcrossTwoListeners() async throws {
        let identity = try DeviceIdentity.ephemeral()
        let peers = try (0..<6).map { _ in try DeviceIdentity.ephemeral() }
        let repository = try TrustRepository(ownerIdentity: identity,
            trustStore: TrustStore(owner: identity.id), persistedGeneration: 0)
        for peer in peers {
            _ = try await repository.issueAuthorization(subject: peer.id,
                subjectPublicKey: peer.publicKey.rawRepresentation, timestamp: Date())
        }
        let budget = WebRTCAcceptanceBudget()
        let factory = BlockingInboundWebRTCFactory()
        var listeners: [WebRTCConnectionListener] = []
        for _ in 0..<2 {
            let session = MemoryRendezvousSignalSession()
            let signaling = RendezvousWebRTCSignaling(session: session)
            let listener = WebRTCConnectionListener(directory: DeviceDirectory(trust: .allowing(identity.id)),
                identity: identity, trustRepository: repository, signaling: signaling,
                ice: ICEConfiguration(stunURLs: [], turnServers: []), factory: factory,
                acceptanceBudget: budget)
            listeners.append(listener)
            _ = await listener.channels()
            for peer in peers {
                for _ in 0..<3 {
                    try await signaling.send(.offer(sdp: "v=0\r\n", route: .directInternet),
                        to: peer.id, connectionID: UUID())
                    let payload = await session.lastSentPayload()
                    await session.deliver(RendezvousSignalFrame(from: peer.id, payload: try XCTUnwrap(payload)))
                }
            }
            await waitForSignalingToProcess(18, signaling: signaling)
        }
        try await Task.sleep(for: .milliseconds(100))
        let counts = await factory.snapshot()
        XCTAssertEqual(counts.maximumTotal, 8)
        XCTAssertEqual(counts.maximumPerDevice, 2)
        for listener in listeners { await listener.stopAndWait() }
    }

    func testProviderOnlyOutboundUsesExactAuthorizedFactoryOverload() async throws {
        let fixture = try AttemptAuthorizationFixture()
        let factory = AuthorizedAttemptFactory { _, provider in
            XCTAssertTrue((provider as? PeerAuthorizationOwner) === fixture.owner)
            throw WebRTCFactoryError.timeout
        }
        let attempts = fixture.attempts(factory: factory)
        let transfer = TransferID(rawValue: UUID())
        do {
            _ = try await attempts.connect(to: fixture.remote.id, route: .relay, transferID: transfer)
            XCTFail("Recording factory must fail")
        } catch { XCTAssertEqual(error as? WebRTCFactoryError, .timeout) }
        let calls = await factory.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.peer, fixture.remote.id)
        XCTAssertEqual(calls.first?.key, fixture.remote.publicKey.rawRepresentation)
        XCTAssertEqual(calls.first?.connectionID, transfer.rawValue)
        XCTAssertEqual(calls.first?.role, .offerer)
        XCTAssertEqual(calls.first?.route, .relay)
        XCTAssertEqual(calls.first?.lease.owner, try fixture.owner.acquire(for: fixture.remote.id).owner)
        let legacy = await factory.legacyCalls
        XCTAssertEqual(legacy, 0)
    }

    func testProviderOnlyInboundUsesAuthorizedFactoryWithoutRepositoryMembership() async throws {
        let fixture = try AttemptAuthorizationFixture()
        let factory = AuthorizedAttemptFactory()
        let listener = fixture.listener(factory: factory)
        _ = await listener.connections()
        let id = UUID()
        try await fixture.offer(connectionID: id)
        await fulfillment(of: [factory.entered], timeout: 2)
        await listener.stopAndWait()
        let calls = await factory.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.connectionID, id)
        XCTAssertEqual(calls.first?.role, .answerer)
        let legacy = await factory.legacyCalls
        XCTAssertEqual(legacy, 0)
    }

    func testProviderWithdrawalDuringICESuccessAndErrorNeverStartsFactoryOrFallback() async throws {
        for fail in [false, true] {
            let fixture = try AttemptAuthorizationFixture()
            let barrier = AttemptBarrier()
            defer { barrier.release() }
            let factory = AuthorizedAttemptFactory()
            let connector = ConnectionCoordinator(attempts: fixture.attempts(factory: factory,
                ice: BarrierICEProvider(barrier: barrier, fail: fail)))
            let task = Task { try await connector.connect(to: fixture.remote.id) }
            defer { task.cancel() }
            await fulfillment(of: [barrier.entered], timeout: 2)
            try fixture.owner.replaceManual([:])
            barrier.release()
            do { _ = try await task.value; XCTFail("Withdrawn ICE attempt succeeded") }
            catch { XCTAssertEqual(error as? ConnectionAttemptError, .authenticationFailed) }
            let calls = await factory.calls
            XCTAssertTrue(calls.isEmpty)
        }
    }

    func testProviderWithdrawalDuringFactoryErrorStopsRouteFallback() async throws {
        let fixture = try AttemptAuthorizationFixture()
        let barrier = AttemptBarrier()
        defer { barrier.release() }
        let factory = AuthorizedAttemptFactory { _, _ in
            await barrier.wait()
            throw WebRTCFactoryError.timeout
        }
        let connector = ConnectionCoordinator(attempts: fixture.attempts(factory: factory))
        let task = Task { try await connector.connect(to: fixture.remote.id) }
        defer { task.cancel() }
        await fulfillment(of: [barrier.entered], timeout: 2)
        try fixture.owner.replaceManual([:])
        barrier.release()
        do { _ = try await task.value; XCTFail("Withdrawn factory error retried") }
        catch { XCTAssertEqual(error as? ConnectionAttemptError, .authenticationFailed) }
        let count = await factory.calls.count
        XCTAssertEqual(count, 1)
    }

    func testProviderRemoveAndRegrantSameKeyCannotReplaceSuspendedLease() async throws {
        let fixture = try AttemptAuthorizationFixture()
        let barrier = AttemptBarrier()
        defer { barrier.release() }
        let factory = AuthorizedAttemptFactory()
        let attempts = fixture.attempts(factory: factory, ice: BarrierICEProvider(barrier: barrier))
        let task = Task { try await attempts.connect(to: fixture.remote.id, route: .relay) }
        defer { task.cancel() }
        await fulfillment(of: [barrier.entered], timeout: 2)
        try fixture.owner.replaceManual([:])
        try fixture.owner.replaceManual([fixture.remote.id: fixture.remote.publicKey.rawRepresentation])
        barrier.release()
        do { _ = try await task.value; XCTFail("New continuity replaced original attempt lease") }
        catch { XCTAssertEqual(error as? ConnectionAttemptError, .authenticationFailed) }
        let count = await factory.calls.count
        XCTAssertEqual(count, 0)
    }

    func testProviderCancellationDuringICEPreservesCancellation() async throws {
        let fixture = try AttemptAuthorizationFixture()
        let barrier = AttemptBarrier()
        defer { barrier.release() }
        let factory = AuthorizedAttemptFactory()
        let attempts = fixture.attempts(factory: factory, ice: BarrierICEProvider(barrier: barrier, fail: true))
        let task = Task { try await attempts.connect(to: fixture.remote.id, route: .relay) }
        await fulfillment(of: [barrier.entered], timeout: 2)
        task.cancel()
        barrier.release()
        do { _ = try await task.value; XCTFail("Cancelled attempt returned") }
        catch { XCTAssertTrue(error is CancellationError) }
        let count = await factory.calls.count
        XCTAssertEqual(count, 0)
    }

    func testProviderLateOutboundResultIsClosedOnCancellationOrWithdrawal() async throws {
        for cancel in [false, true] {
            let fixture = try AttemptAuthorizationFixture()
            let pair = try await fixture.loopback()
            let barrier = AttemptBarrier()
            defer { barrier.release() }
            let factory = AuthorizedAttemptFactory { _, _ in await barrier.wait(); return pair.left }
            let attempts = fixture.attempts(factory: factory)
            let task = Task { try await attempts.connect(to: fixture.remote.id, route: .relay) }
            await fulfillment(of: [barrier.entered], timeout: 2)
            if cancel { task.cancel() } else { try fixture.owner.replaceManual([:]) }
            barrier.release()
            do { _ = try await task.value; XCTFail("Late result escaped") }
            catch {
                if cancel { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? ConnectionAttemptError, .authenticationFailed) }
            }
            await assertClosed(pair.left)
            await pair.right.close()
        }
    }

    func testProviderDeniedAndWrongPeerLeaseNeverReachFactory() async throws {
        let fixture = try AttemptAuthorizationFixture()
        let original = try fixture.owner.acquire(for: fixture.remote.id)
        let forged = PeerAuthorizationLease(peer: fixture.local.id, publicKey: original.publicKey,
            owner: original.owner, continuity: original.continuity)
        let factory = AuthorizedAttemptFactory()
        let wrong = WebRTCConnectionAttempts(directory: fixture.directory, identity: fixture.local,
            authorizationProvider: SubstitutingAttemptProvider(owner: fixture.owner, lease: forged),
            signaling: fixture.signaling, ice: ICEConfiguration(stunURLs: [], turnServers: []), factory: factory)
        do { _ = try await wrong.connect(to: fixture.remote.id, route: .relay); XCTFail("Wrong peer admitted") }
        catch { XCTAssertEqual(error as? ConnectionAttemptError, .authenticationFailed) }
        try fixture.owner.replaceManual([:])
        do { _ = try await fixture.attempts(factory: factory).connect(to: fixture.remote.id, route: .relay); XCTFail("Denied peer admitted") }
        catch { XCTAssertEqual(error as? ConnectionAttemptError, .authenticationFailed) }
        let count = await factory.calls.count
        XCTAssertEqual(count, 0)
    }

    func testProviderInboundWithdrawalDuringICEIsCheckedBeforeFactory() async throws {
        let fixture = try AttemptAuthorizationFixture()
        let barrier = AttemptBarrier()
        defer { barrier.release() }
        let rejected = expectation(description: "inbound validates withdrawn lease")
        let probe = AttemptProviderProbe(owner: fixture.owner) { valid in if !valid { rejected.fulfill() } }
        let factory = AuthorizedAttemptFactory()
        let listener = fixture.listener(factory: factory, ice: BarrierICEProvider(barrier: barrier), provider: probe)
        _ = await listener.connections()
        try await fixture.offer()
        await fulfillment(of: [barrier.entered], timeout: 2)
        try fixture.owner.replaceManual([:])
        barrier.release()
        await fulfillment(of: [rejected], timeout: 2)
        await listener.stopAndWait()
        let calls = await factory.calls.count
        XCTAssertEqual(calls, 0)
    }

    func testProviderInboundLateWithdrawalRejectsBothConsumerModes() async throws {
        for legacy in [false, true] {
            let fixture = try AttemptAuthorizationFixture()
            let pair = try await fixture.loopback()
            let barrier = AttemptBarrier()
            defer { barrier.release() }
            let rejected = expectation(description: "late inbound lease rejected")
            let probe = AttemptProviderProbe(owner: fixture.owner) { valid in if !valid { rejected.fulfill() } }
            let factory = AuthorizedAttemptFactory { _, _ in await barrier.wait(); return pair.left }
            let listener = fixture.listener(factory: factory, provider: probe)
            if legacy { _ = await listener.channels() } else { _ = await listener.connections() }
            try await fixture.offer()
            await fulfillment(of: [barrier.entered], timeout: 2)
            try fixture.owner.replaceManual([:])
            barrier.release()
            await fulfillment(of: [rejected], timeout: 2)
            await listener.stopAndWait()
            await assertClosed(pair.left)
            await pair.right.close()
        }
    }

    func testProviderStopAndWaitOwnsCancellationIgnoringLateFactoryAndClose() async throws {
        let fixture = try AttemptAuthorizationFixture()
        let pair = try await fixture.loopback()
        let barrier = AttemptBarrier()
        defer { barrier.release() }
        let returned = PeerTestBox(false)
        let factory = AuthorizedAttemptFactory { _, _ in
            await barrier.wait()
            returned.update { $0 = true }
            return pair.left
        }
        let listener = fixture.listener(factory: factory)
        _ = await listener.channels()
        try await fixture.offer()
        await fulfillment(of: [barrier.entered], timeout: 2)
        await listener.stop()
        let joinStarted = expectation(description: "join requested")
        let join = Task {
            joinStarted.fulfill()
            await listener.stopAndWait()
            XCTAssertTrue(returned.value, "Drain returned before owned factory completed")
            do { _ = try await pair.left.exportKey(label: "closed", context: Data(), length: 32); XCTFail("Drain returned before channel close") }
            catch { XCTAssertEqual(error as? WebRTCSecureChannelError, .transportClosed) }
        }
        await fulfillment(of: [joinStarted], timeout: 2)
        // stop remains idempotent while the exact old task is still retired.
        await listener.stop()
        barrier.release()
        await join.value
        await listener.stopAndWait()
        let calls = await factory.calls.count
        XCTAssertEqual(calls, 1)
        await pair.right.close()
    }

    func testProviderStopDuringICESuccessAndErrorNeverStartsFactory() async throws {
        for fail in [false, true] {
            let fixture = try AttemptAuthorizationFixture()
            let barrier = AttemptBarrier()
            defer { barrier.release() }
            let factory = AuthorizedAttemptFactory()
            let listener = fixture.listener(factory: factory, ice: BarrierICEProvider(barrier: barrier, fail: fail))
            _ = await listener.connections()
            try await fixture.offer()
            await fulfillment(of: [barrier.entered], timeout: 2)
            await listener.stop()
            barrier.release()
            await listener.stopAndWait()
            let calls = await factory.calls.count
            XCTAssertEqual(calls, 0)
        }
    }

    func testProviderInboundTransferConsumerRealChannelDeliverySmoke() async throws {
        let fixture = try AttemptAuthorizationFixture()
        let pair = try await fixture.loopback()
        let barrier = AttemptBarrier()
        defer { barrier.release() }
        let factory = AuthorizedAttemptFactory { _, _ in await barrier.wait(); return pair.left }
        let listener = fixture.listener(factory: factory)
        let stream = await listener.connections()
        // This starts the reader but is not proof of a registered zero-buffer
        // waiter. Actual delivery is a bounded smoke; rejection tests above use
        // deterministic admission barriers instead.
        let waiting = expectation(description: "receiver task starts")
        let delivered = expectation(description: "receiver finishes")
        let receiver = Task {
            defer { delivered.fulfill() }
            var iterator = stream.makeAsyncIterator()
            waiting.fulfill()
            return try await iterator.next()
        }
        defer { receiver.cancel() }
        do {
            let id = UUID()
            try await fixture.offer(connectionID: id)
            await fulfillment(of: [barrier.entered, waiting], timeout: 2)
            barrier.release()
            await fulfillment(of: [delivered], timeout: 2)
            // Finish the stream even if delivery was dropped; never hang on
            // receiver.value after the bounded smoke reports a failure.
            await listener.stopAndWait()
            let value = try await receiver.value
            let accepted = try XCTUnwrap(value)
            XCTAssertEqual(accepted.source, fixture.remote.id)
            XCTAssertEqual(accepted.transferID.rawValue, id)
            let key = try await accepted.channel.exportKey(label: "usable", context: Data(), length: 32)
            XCTAssertEqual(key.count, 32)
            await accepted.channel.close()
        } catch {
            barrier.release()
            receiver.cancel()
            await listener.stopAndWait()
            _ = try? await receiver.value
            await pair.left.close(); await pair.right.close()
            throw error
        }
        receiver.cancel()
        _ = try? await receiver.value
        await pair.left.close(); await pair.right.close()
    }

    func testProviderInboundNoWaitingOrTerminatedTransferConsumerClosesResult() async throws {
        for terminate in [false, true] {
            let fixture = try AttemptAuthorizationFixture()
            let pair = try await fixture.loopback()
            let delivered = expectation(description: "final publication check")
            let validations = PeerTestBox(0)
            let probe = AttemptProviderProbe(owner: fixture.owner) { _ in
                validations.update { $0 += 1 }
                if validations.value == 3 { delivered.fulfill() }
            }
            let factory = AuthorizedAttemptFactory { _, _ in return pair.left }
            let listener = fixture.listener(factory: factory, provider: probe)
            let stream = await listener.connections()
            if terminate {
                let reader = Task { var iterator = stream.makeAsyncIterator(); return try await iterator.next() }
                reader.cancel()
                _ = try? await reader.value
            }
            try await fixture.offer()
            await fulfillment(of: [delivered], timeout: 2)
            await listener.stopAndWait()
            await assertClosed(pair.left)
            await pair.right.close()
        }
    }

    func testProviderSameKeyAccountOverlapPreservesSuspendedAttemptThenFinalRemovalCloses() async throws {
        let fixture = try AttemptAuthorizationFixture()
        let pair = try await fixture.loopback()
        let barrier = AttemptBarrier()
        defer { barrier.release() }
        let factory = AuthorizedAttemptFactory { _, _ in return pair.left }
        let attempts = fixture.attempts(factory: factory, ice: BarrierICEProvider(barrier: barrier))
        let task = Task { try await attempts.connect(to: fixture.remote.id, route: .relay) }
        defer { task.cancel() }
        await fulfillment(of: [barrier.entered], timeout: 2)
        let epoch = try fixture.installAccount()
        try fixture.owner.replaceManual([:])
        barrier.release()
        let result = try await task.value
        let key = try await result.exportKey(label: "overlap", context: Data(), length: 32)
        XCTAssertEqual(key.count, 32)
        fixture.owner.invalidateAccount(epoch)
        await assertClosed(pair.left)
        await pair.right.close()
    }

    func testProviderAccountExpiryDuringICESuccessAndErrorIsTerminal() async throws {
        for fail in [false, true] {
            let clock = PeerTestBox(Date(timeIntervalSince1970: 1_800_000_000))
            let fixture = try AttemptAuthorizationFixture(clock: clock)
            _ = try fixture.installAccount()
            try fixture.owner.replaceManual([:])
            let barrier = AttemptBarrier()
            defer { barrier.release() }
            let factory = AuthorizedAttemptFactory()
            let attempts = fixture.attempts(factory: factory, ice: BarrierICEProvider(barrier: barrier, fail: fail))
            let task = Task { try await attempts.connect(to: fixture.remote.id, route: .relay) }
            defer { task.cancel() }
            await fulfillment(of: [barrier.entered], timeout: 2)
            clock.update { $0 = $0.addingTimeInterval(31) }
            barrier.release()
            do { _ = try await task.value; XCTFail("Expired account admitted") }
            catch { XCTAssertEqual(error as? ConnectionAttemptError, .authenticationFailed) }
            let calls = await factory.calls.count
            XCTAssertEqual(calls, 0)
        }
    }

    func testProviderStopDuringOfferReaderStartupJoinsAndNeverRestarts() async throws {
        let fixture = try AttemptAuthorizationFixture()
        let barrier = AttemptBarrier()
        defer { barrier.release() }
        let session = StartupBarrierSignalSession(barrier: barrier)
        let factory = AuthorizedAttemptFactory()
        let listener = WebRTCConnectionListener(directory: fixture.directory, identity: fixture.local,
            authorizationProvider: fixture.owner, signaling: RendezvousWebRTCSignaling(session: session),
            ice: ICEConfiguration(stunURLs: [], turnServers: []), factory: factory)
        _ = await listener.connections()
        await fulfillment(of: [barrier.entered], timeout: 2)
        await listener.stop()
        barrier.release()
        await listener.stopAndWait()
        _ = await listener.connections()
        _ = await listener.channels()
        let requests = await session.requests
        let calls = await factory.calls.count
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(calls, 0)
    }

    func testProviderLegacyChannelBufferOverflowClosesOnlyDroppedResult() async throws {
        let fixture = try AttemptAuthorizationFixture()
        var pairs: [(left: WebRTCSecureChannel, right: WebRTCSecureChannel)] = []
        for _ in 0..<33 { pairs.append(try await fixture.loopback()) }
        let ids = (0..<33).map { _ in UUID() }
        let channels = Dictionary(uniqueKeysWithValues: zip(ids, pairs.map(\.left)))
        let publications = (0..<33).map { expectation(description: "publication \($0)") }
        let validations = PeerTestBox(0)
        let probe = AttemptProviderProbe(owner: fixture.owner) { valid in
            XCTAssertTrue(valid)
            validations.update { $0 += 1 }
            let count = validations.value
            if count % 3 == 0 { publications[count / 3 - 1].fulfill() }
        }
        let factory = AuthorizedAttemptFactory { call, _ in try XCTUnwrap(channels[call.connectionID]) }
        let listener = fixture.listener(factory: factory, provider: probe)
        let stream = await listener.channels()
        for index in 0..<33 {
            try await fixture.offer(connectionID: ids[index])
            await fulfillment(of: [publications[index]], timeout: 2)
        }
        await listener.stopAndWait()
        await assertClosed(pairs[32].left)
        let stillAdmitted = try await pairs[0].left.exportKey(label: "buffered", context: Data(), length: 32)
        XCTAssertEqual(stillAdmitted.count, 32, "stop does not retract prior handoff objects")
        var iterator = stream.makeAsyncIterator()
        var count = 0
        while let channel = try await iterator.next() {
            XCTAssertFalse(channel === pairs[32].left)
            count += 1
            await channel.close()
        }
        XCTAssertEqual(count, 32)
        for pair in pairs { await pair.left.close(); await pair.right.close() }
    }

    func testProviderAcceptanceCapsRemainEightGlobalAndTwoPerPeer() async throws {
        let fixture = try AttemptAuthorizationFixture()
        let peers = try (0..<5).map { _ in try DeviceIdentity.ephemeral() }
        try fixture.owner.replaceManual(Dictionary(uniqueKeysWithValues: peers.map { ($0.id, $0.publicKey.rawRepresentation) }))
        let barrier = AttemptBarrier()
        barrier.entered.expectedFulfillmentCount = 8
        defer { barrier.release() }
        let factory = AuthorizedAttemptFactory { _, _ in await barrier.wait(); throw WebRTCFactoryError.timeout }
        let listener = fixture.listener(factory: factory)
        _ = await listener.channels()
        for peer in peers {
            for _ in 0..<3 { try await fixture.offer(peer: peer.id) }
        }
        await fulfillment(of: [barrier.entered], timeout: 2)
        await waitForSignalingToProcess(15, signaling: fixture.signaling)
        let calls = await factory.calls
        XCTAssertEqual(calls.count, 8)
        let counts = Dictionary(grouping: calls, by: \.peer).mapValues(\.count)
        XCTAssertTrue(counts.values.allSatisfy { $0 <= 2 })
        barrier.release()
        // A positive subsequent entry demonstrates recovery after the held
        // acceptances throw. Bound probes; no sleep is nondelivery evidence.
        for _ in 0..<32 {
            if await factory.calls.count > 8 { break }
            try await fixture.offer(peer: peers[0].id)
            await Task.yield()
        }
        let recovered = await factory.calls.count
        XCTAssertGreaterThan(recovered, 8)
        await listener.stop()
        await listener.stopAndWait()
    }

    private func assertClosed(_ channel: WebRTCSecureChannel, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await channel.exportKey(label: "closed", context: Data(), length: 32); XCTFail("Channel was not closed", file: file, line: line) }
        catch { XCTAssertEqual(error as? WebRTCSecureChannelError, .transportClosed, file: file, line: line) }
        await channel.close()
    }

    func testProductionAttemptsResolveFreshICEForEveryFallbackRoute() async throws {
        let local = try DeviceIdentity.ephemeral()
        let remote = try DeviceIdentity.ephemeral()
        let repository = try TrustRepository(
            ownerIdentity: local,
            trustStore: TrustStore(owner: local.id),
            persistedGeneration: 0
        )
        _ = try await repository.issueAuthorization(
            subject: remote.id,
            subjectPublicKey: remote.publicKey.rawRepresentation,
            timestamp: Date()
        )
        let directory = DeviceDirectory(trust: await repository.currentTrustStore())
        await directory.apply(.lan(remote.id, host: "127.0.0.1", port: 9_001))
        let provider = RecordingICEConfigurationProvider()
        let factory = RecordingFailingWebRTCFactory()
        let attempts = WebRTCConnectionAttempts(
            directory: directory,
            identity: local,
            trustRepository: repository,
            signaling: RendezvousWebRTCSignaling(session: MemoryRendezvousSignalSession()),
            iceProvider: provider,
            factory: factory
        )
        let connector = ConnectionCoordinator(attempts: attempts)

        do {
            _ = try await connector.connect(to: remote.id)
            XCTFail("Expected all recorded attempts to fail")
        } catch {}

        let providerRoutes = await provider.requestedRoutes()
        let factoryRoutes = await factory.requestedRoutes()
        let turnCounts = await factory.requestedICE().map(\.turnServers.count)
        XCTAssertEqual(providerRoutes, [.lan, .directInternet, .relay])
        XCTAssertEqual(factoryRoutes, [.lan, .directInternet, .relay])
        XCTAssertEqual(turnCounts, [0, 0, 1])
    }

    func testInboundListenerResolvesCurrentICEForOfferRoute() async throws {
        let local = try DeviceIdentity.ephemeral()
        let remote = try DeviceIdentity.ephemeral()
        let repository = try TrustRepository(
            ownerIdentity: local,
            trustStore: TrustStore(owner: local.id),
            persistedGeneration: 0
        )
        _ = try await repository.issueAuthorization(
            subject: remote.id,
            subjectPublicKey: remote.publicKey.rawRepresentation,
            timestamp: Date()
        )
        let session = MemoryRendezvousSignalSession()
        let signaling = RendezvousWebRTCSignaling(session: session)
        let provider = RecordingICEConfigurationProvider()
        let factory = RecordingFailingWebRTCFactory()
        let listener = WebRTCConnectionListener(
            directory: DeviceDirectory(trust: await repository.currentTrustStore()),
            identity: local,
            trustRepository: repository,
            signaling: signaling,
            iceProvider: provider,
            factory: factory
        )
        _ = await listener.connections()
        try await signaling.send(
            .offer(sdp: "v=0\r\n", route: .relay),
            to: remote.id,
            connectionID: UUID()
        )
        let sentPayload = await session.lastSentPayload()
        let payload = try XCTUnwrap(sentPayload)
        await session.deliver(RendezvousSignalFrame(
            from: remote.id,
            payload: payload
        ))

        for _ in 0..<1_000 {
            if await factory.requestedRoutes() == [.relay] { break }
            try await Task.sleep(for: .milliseconds(1))
        }

        let providerRoutes = await provider.requestedRoutes()
        let turnCount = await factory.requestedICE().first?.turnServers.count
        XCTAssertEqual(providerRoutes, [.relay])
        XCTAssertEqual(turnCount, 1)
        await listener.stop()
    }

    func testFallsBackFromLANToInternetToRelay() async throws {
        let attempts = AttemptRecorder(results: [
            .failure(.timeout),
            .failure(.iceFailed),
            .success(.relay),
        ])
        let connector = ConnectionCoordinator(attempts: attempts)

        let channel = try await connector.connect(to: DeviceID(rawValue: UUID()))
        let routes = await attempts.routes

        XCTAssertEqual(channel.route, .relay)
        XCTAssertEqual(routes, [.lan, .directInternet, .relay])
    }

    func testTransferReconnectContinuesAfterTheFailedDataRoute() async throws {
        let attempts = AttemptRecorder(results: [.success(.relay)])
        let connector = ConnectionCoordinator(attempts: attempts)

        let channel = try await connector.connect(
            to: DeviceID(rawValue: UUID()),
            transferID: TransferID(rawValue: UUID()),
            after: .directInternet
        )
        let routes = await attempts.routes

        XCTAssertEqual(channel.route, .relay)
        XCTAssertEqual(routes, [.relay])
    }

    func testStopsAfterFirstSuccessfulRoute() async throws {
        let attempts = AttemptRecorder(results: [.success(.lan), .success(.directInternet)])
        let connector = ConnectionCoordinator(attempts: attempts)

        let channel = try await connector.connect(to: DeviceID(rawValue: UUID()))
        let routes = await attempts.routes

        XCTAssertEqual(channel.route, .lan)
        XCTAssertEqual(routes, [.lan])
    }

    func testReportsAllRoutesFailedOnlyAfterExactFallbackOrder() async {
        let attempts = AttemptRecorder(results: [
            .failure(.timeout),
            .failure(.iceFailed),
            .failure(.iceFailed),
        ])
        let connector = ConnectionCoordinator(attempts: attempts)

        do {
            _ = try await connector.connect(to: DeviceID(rawValue: UUID()))
            XCTFail("Expected every route to fail")
        } catch {
            XCTAssertEqual(error as? ConnectionCoordinatorError, .allRoutesFailed)
        }
        let routes = await attempts.routes
        XCTAssertEqual(routes, [.lan, .directInternet, .relay])
    }

    func testAuthenticationFailureDoesNotRetryOnAnotherRoute() async {
        let attempts = AttemptRecorder(results: [
            .failure(.authenticationFailed),
            .success(.directInternet),
        ])
        let connector = ConnectionCoordinator(attempts: attempts)

        do {
            _ = try await connector.connect(to: DeviceID(rawValue: UUID()))
            XCTFail("Expected authentication to fail closed")
        } catch {
            XCTAssertEqual(error as? ConnectionAttemptError, .authenticationFailed)
        }
        let routes = await attempts.routes
        XCTAssertEqual(routes, [.lan])
    }

    func testServerUnavailableDoesNotRetryThreeRoutes() async {
        let attempts = UnavailableAttemptRecorder()
        let connector = ConnectionCoordinator(attempts: attempts)

        do {
            _ = try await connector.connect(to: DeviceID(rawValue: UUID()))
            XCTFail("An offline peer must fail immediately")
        } catch {
            XCTAssertEqual(error as? ConnectionCoordinatorError, .peerUnavailable)
        }
        let routes = await attempts.routes
        XCTAssertEqual(routes, [.lan])
    }

    func testRendezvousWebRTCSignalingUsesOneSharedSessionStream() async throws {
        let peer = DeviceID(rawValue: UUID())
        let connectionID = UUID()
        let session = MemoryRendezvousSignalSession()
        let signaling = RendezvousWebRTCSignaling(session: session)
        let first = await signaling.messages(from: peer, connectionID: connectionID)
        _ = await signaling.messages(from: DeviceID(rawValue: UUID()), connectionID: UUID())
        var iterator = first.makeAsyncIterator()
        let message = WebRTCSignalMessage.candidate(
            sdp: "candidate:1 1 udp 1 127.0.0.1 7000 typ host",
            sdpMLineIndex: 0,
            sdpMid: "0"
        )

        try await signaling.send(message, to: peer, connectionID: connectionID)
        let sentPayload = await session.lastSentPayload()
        let payload = try XCTUnwrap(sentPayload)
        await session.deliver(RendezvousSignalFrame(from: peer, payload: payload))

        let received = try await iterator.next()
        let streamRequests = await session.streamRequests
        let sentDevice = await session.lastSentDevice()
        XCTAssertEqual(received, message)
        XCTAssertEqual(streamRequests, 1)
        XCTAssertEqual(sentDevice, peer)
    }

    func testServerUnavailableFailsOnlyMatchingSignalSubscriberImmediately() async throws {
        let peer = DeviceID(rawValue: UUID())
        let otherPeer = DeviceID(rawValue: UUID())
        let session = MemoryRendezvousSignalSession()
        let signaling = RendezvousWebRTCSignaling(session: session)
        var failed = await signaling.messages(from: peer, connectionID: UUID()).makeAsyncIterator()
        let otherConnectionID = UUID()
        var unaffected = await signaling.messages(
            from: otherPeer,
            connectionID: otherConnectionID
        ).makeAsyncIterator()

        await session.deliver(
            RendezvousProtocolError(code: "unavailable", device: peer)
        )

        do {
            _ = try await failed.next()
            XCTFail("Unavailable peer must fail without waiting for ICE timeout")
        } catch {
            XCTAssertEqual(error as? WebRTCFactoryError, .peerUnavailable)
        }
        let answer = WebRTCSignalMessage.answer(sdp: "still-connected")
        try await signaling.send(answer, to: otherPeer, connectionID: otherConnectionID)
        let sentPayload = await session.lastSentPayload()
        await session.deliver(RendezvousSignalFrame(
            from: otherPeer,
            payload: try XCTUnwrap(sentPayload)
        ))
        let received = try await unaffected.next()
        XCTAssertEqual(received, answer)
    }

    func testEachFallbackRouteUsesOnlyItsAllowedICECandidates() {
        let ice = ICEConfiguration(
            stunURLs: ["stun:stun.example:3478"],
            turnServers: [TURNServer(
                urls: ["turns:turn.example:5349"],
                username: "short-lived-user",
                credential: "short-lived-password"
            )]
        )

        XCTAssertEqual(
            WebRTCFactory.routePlan(for: .lan, ice: ice),
            WebRTCRoutePlan(servers: [], relayOnly: false, allowedCandidateKinds: [.host])
        )
        XCTAssertEqual(
            WebRTCFactory.routePlan(for: .directInternet, ice: ice),
            WebRTCRoutePlan(
                servers: [.init(urls: ["stun:stun.example:3478"], username: nil, credential: nil)],
                relayOnly: false,
                allowedCandidateKinds: [.serverReflexive]
            )
        )
        XCTAssertEqual(
            WebRTCFactory.routePlan(for: .relay, ice: ice),
            WebRTCRoutePlan(
                servers: [.init(
                    urls: ["turns:turn.example:5349"],
                    username: "short-lived-user",
                    credential: "short-lived-password"
                )],
                relayOnly: true,
                allowedCandidateKinds: [.relay]
            )
        )

        let host = "candidate:1 1 udp 1 192.168.1.20 7000 typ host"
        let serverReflexive = "candidate:2 1 udp 1 203.0.113.20 7001 typ srflx raddr 192.168.1.20 rport 7000"
        let relay = "candidate:3 1 udp 1 198.51.100.40 7002 typ relay raddr 203.0.113.20 rport 7001"
        XCTAssertTrue(WebRTCFactory.routePlan(for: .lan, ice: ice).allows(candidateSDP: host))
        XCTAssertFalse(WebRTCFactory.routePlan(for: .lan, ice: ice).allows(candidateSDP: serverReflexive))
        XCTAssertFalse(WebRTCFactory.routePlan(for: .directInternet, ice: ice).allows(candidateSDP: host))
        XCTAssertTrue(WebRTCFactory.routePlan(for: .directInternet, ice: ice).allows(candidateSDP: serverReflexive))
        XCTAssertFalse(WebRTCFactory.routePlan(for: .directInternet, ice: ice).allows(candidateSDP: relay))
        XCTAssertTrue(WebRTCFactory.routePlan(for: .relay, ice: ice).allows(candidateSDP: relay))
        XCTAssertFalse(WebRTCFactory.routePlan(for: .directInternet, ice: ice).allowsRemoteDescription(
            "v=0\r\na=candidate:1 1 udp 1 192.168.1.20 7000 typ host\r\n"
        ))
        XCTAssertTrue(WebRTCFactory.routePlan(for: .directInternet, ice: ice).allowsRemoteDescription(
            "v=0\r\na=candidate:2 1 udp 1 203.0.113.20 7001 typ srflx\r\n"
        ))
    }

    func testAnswererAcceptsOnlyTheExpectedOrderedReliableDataChannel() {
        let expected = WebRTCDataChannelProperties(
            label: "macchannel",
            protocolName: "macchannel.secure.v1",
            isOrdered: true,
            maxPacketLifeTime: UInt16.max,
            maxRetransmits: UInt16.max,
            isNegotiated: false
        )

        XCTAssertTrue(WebRTCFactory.acceptsDataChannel(expected))
        XCTAssertFalse(WebRTCFactory.acceptsDataChannel(.init(
            label: "macchannel",
            protocolName: "macchannel.secure.v1",
            isOrdered: false,
            maxPacketLifeTime: UInt16.max,
            maxRetransmits: UInt16.max,
            isNegotiated: false
        )))
        XCTAssertFalse(WebRTCFactory.acceptsDataChannel(.init(
            label: "attacker",
            protocolName: "wrong",
            isOrdered: true,
            maxPacketLifeTime: 1,
            maxRetransmits: 1,
            isNegotiated: true
        )))
    }

    func testReplacingSignalSubscriberCannotRemoveItsReplacement() async throws {
        let peer = DeviceID(rawValue: UUID())
        let connectionID = UUID()
        let session = MemoryRendezvousSignalSession()
        let signaling = RendezvousWebRTCSignaling(session: session)
        _ = await signaling.messages(from: peer, connectionID: connectionID)
        let replacement = await signaling.messages(from: peer, connectionID: connectionID)
        var iterator = replacement.makeAsyncIterator()
        await Task.yield()
        await Task.yield()
        let message = WebRTCSignalMessage.answer(sdp: "replacement-answer")
        try await signaling.send(message, to: peer, connectionID: connectionID)
        let sentPayload = await session.lastSentPayload()
        await session.deliver(RendezvousSignalFrame(from: peer, payload: try XCTUnwrap(sentPayload)))

        let delivered = expectation(description: "replacement received signal")
        Task {
            do {
                let received = try await iterator.next()
                XCTAssertEqual(received, message)
            }
            catch { XCTFail("Unexpected stream error: \(error)") }
            delivered.fulfill()
        }

        await fulfillment(of: [delivered], timeout: 1)
    }

    func testUnmatchedOfferIsPublishedAndBufferedForProductionAnswerer() async throws {
        let peer = DeviceID(rawValue: UUID())
        let connectionID = UUID()
        let session = MemoryRendezvousSignalSession()
        let signaling = RendezvousWebRTCSignaling(session: session)
        let incoming = await signaling.incomingOffers()
        var incomingIterator = incoming.makeAsyncIterator()
        let offer = WebRTCSignalMessage.offer(sdp: "incoming-sdp", route: .relay)
        try await signaling.send(offer, to: peer, connectionID: connectionID)
        let sentPayload = await session.lastSentPayload()
        await session.deliver(RendezvousSignalFrame(from: peer, payload: try XCTUnwrap(sentPayload)))

        let incomingOffer = await incomingIterator.next()
        XCTAssertEqual(incomingOffer, IncomingWebRTCOffer(
            remoteDevice: peer,
            connectionID: connectionID,
            route: .relay
        ))
        let messages = await signaling.messages(from: peer, connectionID: connectionID)
        var messageIterator = messages.makeAsyncIterator()
        let bufferedOffer = try await messageIterator.next()
        XCTAssertEqual(bufferedOffer, offer)
    }

    func testFallbackOfferForSameTransferReplacesUnacceptedRouteAttempt() async throws {
        let peer = DeviceID(rawValue: UUID())
        let connectionID = UUID()
        let session = MemoryRendezvousSignalSession()
        let signaling = RendezvousWebRTCSignaling(session: session)
        let incoming = await signaling.incomingOffers()
        var incomingIterator = incoming.makeAsyncIterator()

        let lanOffer = WebRTCSignalMessage.offer(sdp: "lan-offer", route: .lan)
        try await signaling.send(lanOffer, to: peer, connectionID: connectionID)
        let lastLANPayload = await session.lastSentPayload()
        let lanPayload = try XCTUnwrap(lastLANPayload)
        await session.deliver(RendezvousSignalFrame(
            from: peer,
            payload: lanPayload
        ))
        let publishedLANOffer = await incomingIterator.next()
        XCTAssertEqual(
            publishedLANOffer,
            IncomingWebRTCOffer(remoteDevice: peer, connectionID: connectionID, route: .lan)
        )

        // The production listener can reject an asymmetric Bonjour route before
        // subscribing to its messages. A later relay attempt for the same
        // transfer must still be surfaced and must not inherit the stale offer.
        let relayOffer = WebRTCSignalMessage.offer(sdp: "relay-offer", route: .relay)
        try await signaling.send(relayOffer, to: peer, connectionID: connectionID)
        let lastRelayPayload = await session.lastSentPayload()
        let relayPayload = try XCTUnwrap(lastRelayPayload)
        await session.deliver(RendezvousSignalFrame(
            from: peer,
            payload: relayPayload
        ))

        let republished = expectation(description: "fallback offer republished")
        var fallbackOffer: IncomingWebRTCOffer?
        Task {
            fallbackOffer = await incomingIterator.next()
            republished.fulfill()
        }
        await fulfillment(of: [republished], timeout: 1)
        XCTAssertEqual(
            fallbackOffer,
            IncomingWebRTCOffer(remoteDevice: peer, connectionID: connectionID, route: .relay)
        )

        var messages = await signaling.messages(
            from: peer,
            connectionID: connectionID
        ).makeAsyncIterator()
        let bufferedFallbackOffer = try await messages.next()
        XCTAssertEqual(bufferedFallbackOffer, relayOffer)
    }

    func testExactly128SignalsBufferedBeforeSubscribePreserveOrder() async throws {
        let peer = DeviceID(rawValue: UUID())
        let connectionID = UUID()
        let session = MemoryRendezvousSignalSession()
        let signaling = RendezvousWebRTCSignaling(session: session)
        _ = await signaling.incomingOffers()
        let expected = (0..<128).map { WebRTCSignalMessage.answer(sdp: "answer-\($0)") }

        for message in expected {
            try await signaling.send(message, to: peer, connectionID: connectionID)
            let sentPayload = await session.lastSentPayload()
            let payload = try XCTUnwrap(sentPayload)
            await session.deliver(RendezvousSignalFrame(
                from: peer,
                payload: payload
            ))
        }
        await waitForSignalingToProcess(128, signaling: signaling)

        var iterator = await signaling.messages(from: peer, connectionID: connectionID).makeAsyncIterator()
        var received: [WebRTCSignalMessage] = []
        for _ in expected.indices {
            let next = try await iterator.next()
            received.append(try XCTUnwrap(next))
        }
        XCTAssertEqual(received, expected)
    }

    func test129thSignalBufferedBeforeSubscribeFailsClosed() async throws {
        let peer = DeviceID(rawValue: UUID())
        let connectionID = UUID()
        let session = MemoryRendezvousSignalSession()
        let signaling = RendezvousWebRTCSignaling(session: session)
        _ = await signaling.incomingOffers()

        for index in 0..<129 {
            try await signaling.send(.answer(sdp: "answer-\(index)"), to: peer, connectionID: connectionID)
            let sentPayload = await session.lastSentPayload()
            let payload = try XCTUnwrap(sentPayload)
            await session.deliver(RendezvousSignalFrame(
                from: peer,
                payload: payload
            ))
        }
        await waitForSignalingToProcess(129, signaling: signaling)

        var iterator = await signaling.messages(from: peer, connectionID: connectionID).makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("An incomplete signaling stream must not continue after pending overflow")
        } catch {
            XCTAssertEqual(error as? WebRTCFactoryError, .signalingOverflow)
        }
    }

    func testLiveSignalSubscriberByteOverflowFailsBeforeDeliveringIncompleteSequence() async throws {
        let peer = DeviceID(rawValue: UUID())
        let connectionID = UUID()
        let session = MemoryRendezvousSignalSession()
        let signaling = RendezvousWebRTCSignaling(session: session)
        let stream = await signaling.messages(from: peer, connectionID: connectionID)
        let padding = String(repeating: "x", count: 60 * 1024)

        for index in 0..<9 {
            try await signaling.send(
                .candidate(
                    sdp: "candidate:\(index) 1 udp 1 192.168.1.20 \(7_000 + index) typ host \(padding)",
                    sdpMLineIndex: 0,
                    sdpMid: "0"
                ),
                to: peer,
                connectionID: connectionID
            )
            let sentPayload = await session.lastSentPayload()
            await session.deliver(RendezvousSignalFrame(
                from: peer,
                payload: try XCTUnwrap(sentPayload)
            ))
        }
        await waitForSignalingToProcess(9, signaling: signaling)

        var iterator = stream.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("A byte-overflowed live signaling sequence must fail before partial delivery")
        } catch {
            XCTAssertEqual(error as? WebRTCFactoryError, .signalingOverflow)
        }
    }

    func testStoppedConnectionListenerCannotRestartItsOfferReader() async throws {
        let identity = try DeviceIdentity.ephemeral()
        let session = MemoryRendezvousSignalSession()
        let signaling = RendezvousWebRTCSignaling(session: session)
        let repository = try TrustRepository(
            ownerIdentity: identity,
            trustStore: TrustStore(owner: identity.id),
            persistedGeneration: 0
        )
        let listener = WebRTCConnectionListener(
            directory: DeviceDirectory(trust: .allowing(identity.id)),
            identity: identity,
            trustRepository: repository,
            signaling: signaling,
            ice: ICEConfiguration(stunURLs: [], turnServers: [])
        )

        await listener.stop()
        let channels = await listener.channels()
        var iterator = channels.makeAsyncIterator()

        let next = try await iterator.next()
        let streamRequests = await session.streamRequests
        XCTAssertNil(next)
        XCTAssertEqual(streamRequests, 0)
    }

    func testConnectionListenerProvidesFreshTransferStreamAfterConsumerRestart() async throws {
        let identity = try DeviceIdentity.ephemeral()
        let session = MemoryRendezvousSignalSession()
        let signaling = RendezvousWebRTCSignaling(session: session)
        let repository = try TrustRepository(
            ownerIdentity: identity,
            trustStore: TrustStore(owner: identity.id),
            persistedGeneration: 0
        )
        let listener = WebRTCConnectionListener(
            directory: DeviceDirectory(trust: .allowing(identity.id)),
            identity: identity,
            trustRepository: repository,
            signaling: signaling,
            ice: ICEConfiguration(stunURLs: [], turnServers: [])
        )
        defer { Task { await listener.stop() } }

        let firstStream = await listener.connections()
        let firstWaiter = Task {
            var iterator = firstStream.makeAsyncIterator()
            _ = try await iterator.next()
        }
        try await Task.sleep(for: .milliseconds(20))
        firstWaiter.cancel()
        _ = await firstWaiter.result

        let secondStream = await listener.connections()
        let didFinish = await streamTerminatesWithin(
            secondStream,
            timeout: .milliseconds(50)
        )
        XCTAssertFalse(
            didFinish,
            "Restarting the receive consumer must not inherit a terminated transfer stream"
        )
    }

    func testStoppedConnectionListenerCannotRestartItsTransferStream() async throws {
        let identity = try DeviceIdentity.ephemeral()
        let session = MemoryRendezvousSignalSession()
        let signaling = RendezvousWebRTCSignaling(session: session)
        let repository = try TrustRepository(
            ownerIdentity: identity,
            trustStore: TrustStore(owner: identity.id),
            persistedGeneration: 0
        )
        let listener = WebRTCConnectionListener(
            directory: DeviceDirectory(trust: .allowing(identity.id)),
            identity: identity,
            trustRepository: repository,
            signaling: signaling,
            ice: ICEConfiguration(stunURLs: [], turnServers: [])
        )

        await listener.stop()
        let stream = await listener.connections()
        let didFinish = await streamTerminatesWithin(stream, timeout: .seconds(1))
        XCTAssertTrue(didFinish, "A stopped listener must return a terminated transfer stream")
        let streamRequests = await session.streamRequests
        XCTAssertEqual(streamRequests, 0)
    }

    func testConnectionListenerCapsConcurrentOfferAcceptanceGloballyAndPerDevice() async throws {
        let identity = try DeviceIdentity.ephemeral()
        let peers = try (0..<5).map { _ in try DeviceIdentity.ephemeral() }
        let repository = try TrustRepository(
            ownerIdentity: identity,
            trustStore: TrustStore(owner: identity.id),
            persistedGeneration: 0
        )
        for peer in peers {
            _ = try await repository.issueAuthorization(
                subject: peer.id,
                subjectPublicKey: peer.publicKey.rawRepresentation,
                timestamp: Date()
            )
        }
        let session = MemoryRendezvousSignalSession()
        let signaling = RendezvousWebRTCSignaling(session: session)
        let factory = BlockingInboundWebRTCFactory()
        let listener = WebRTCConnectionListener(
            directory: DeviceDirectory(trust: .allowing(identity.id)),
            identity: identity,
            trustRepository: repository,
            signaling: signaling,
            ice: ICEConfiguration(stunURLs: ["stun:example.test"], turnServers: []),
            factory: factory
        )
        _ = await listener.channels()

        for peer in peers {
            for _ in 0..<3 {
                let connectionID = UUID()
                try await signaling.send(
                    .offer(sdp: "v=0\r\n", route: .directInternet),
                    to: peer.id,
                    connectionID: connectionID
                )
                let sentPayload = await session.lastSentPayload()
                await session.deliver(RendezvousSignalFrame(
                    from: peer.id,
                    payload: try XCTUnwrap(sentPayload)
                ))
            }
        }
        try await Task.sleep(for: .milliseconds(100))

        let snapshot = await factory.snapshot()
        XCTAssertEqual(snapshot.maximumTotal, 8)
        XCTAssertLessThanOrEqual(snapshot.maximumPerDevice, 2)
        await listener.stop()
    }

    private func waitForSignalingToProcess(
        _ count: Int,
        signaling: RendezvousWebRTCSignaling
    ) async {
        for _ in 0..<1_000 {
            if await signaling._testOnlyReceivedFrameCount() == count { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Signaling reader did not process \(count) frames")
    }
}

private func streamTerminatesWithin<Element: Sendable>(
    _ stream: AsyncThrowingStream<Element, Error>,
    timeout: Duration
) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            do {
                _ = try await iterator.next()
            } catch {}
            return true
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return false
        }
        let result = await group.next() ?? false
        group.cancelAll()
        return result
    }
}

private struct AttemptAuthorizationFixture {
    let local: DeviceIdentity
    let remote: DeviceIdentity
    let owner: PeerAuthorizationOwner
    let directory: DeviceDirectory
    let session: MemoryRendezvousSignalSession
    let signaling: RendezvousWebRTCSignaling
    let clock: PeerTestBox<Date>?

    init(clock: PeerTestBox<Date>? = nil) throws {
        self.clock = clock
        local = try DeviceIdentity.ephemeral()
        remote = try DeviceIdentity.ephemeral()
        if let clock {
            owner = PeerAuthorizationOwner(local: local.id, now: { clock.value }, schedule: { _, _ in {} })
        } else { owner = PeerAuthorizationOwner.live(identity: local) }
        try owner.replaceManual([remote.id: remote.publicKey.rawRepresentation])
        directory = DeviceDirectory(trust: .allowing(local.id))
        session = MemoryRendezvousSignalSession()
        signaling = RendezvousWebRTCSignaling(session: session)
    }

    func attempts(factory: any AuthorizedWebRTCChannelFactory,
                  ice: any ICEConfigurationProviding = StaticICEConfigurationProvider(ICEConfiguration(stunURLs: [], turnServers: []))) -> WebRTCConnectionAttempts {
        WebRTCConnectionAttempts(directory: directory, identity: local, authorizationProvider: owner,
            signaling: signaling, iceProvider: ice, factory: factory)
    }

    func listener(factory: any AuthorizedWebRTCChannelFactory,
                  ice: any ICEConfigurationProviding = StaticICEConfigurationProvider(ICEConfiguration(stunURLs: [], turnServers: [])),
                  provider: (any PeerAuthorizationProviding)? = nil) -> WebRTCConnectionListener {
        WebRTCConnectionListener(directory: directory, identity: local, authorizationProvider: provider ?? owner,
            signaling: signaling, iceProvider: ice, factory: factory)
    }

    func offer(connectionID: UUID = UUID(), peer: DeviceID? = nil) async throws {
        let sender = peer ?? remote.id
        try await signaling.send(.offer(sdp: "v=0\r\n", route: .relay), to: sender, connectionID: connectionID)
        let data = await session.lastSentPayload()
        await session.deliver(RendezvousSignalFrame(from: sender, payload: try XCTUnwrap(data)))
    }

    func loopback() async throws -> (left: WebRTCSecureChannel, right: WebRTCSecureChannel) {
        let bus = InMemoryWebRTCSignalBus(), id = UUID()
        let factory = WebRTCFactory(connectionTimeout: .seconds(5))
        let ice = ICEConfiguration(stunURLs: [], turnServers: [])
        async let left = factory.connect(localIdentity: local, remoteDevice: remote.id,
            remotePublicKey: remote.publicKey.rawRepresentation, connectionID: id, role: .offerer,
            route: .lan, ice: ice, signaling: bus.endpoint(for: local.id),
            authorizationProvider: owner, authorizationLease: owner.acquire(for: remote.id))
        async let right = factory.connect(localIdentity: remote, remoteDevice: local.id,
            remotePublicKey: local.publicKey.rawRepresentation, connectionID: id, role: .answerer,
            route: .lan, ice: ice, signaling: bus.endpoint(for: remote.id))
        return try await (left, right)
    }

    func installAccount() throws -> PeerAccountEpoch {
        let date = clock?.value ?? Date()
        let binding = try AccountSessionBinding(deviceID: local.id.rawValue, audience: "test",
            origin: URL(string: "https://example.com")!)
        let account = UUID().uuidString.lowercased()
        let epoch = try owner.beginAccountSession(binding: binding, accountID: account,
            sessionID: UUID().uuidString.lowercased(), localPublicKey: local.publicKey.rawRepresentation,
            accessExpiresAt: date.addingTimeInterval(100))
        try owner.install(VerifiedPeerAccountEvidence(epoch: epoch, binding: binding,
            snapshot: AccountGroupSnapshot(accountID: account, groupID: UUID().uuidString.lowercased(),
                generation: 1, sequence: 1, headHash: Data(repeating: 1, count: 32),
                members: [local, remote].map { AccountGroupMember(deviceID: $0.id.rawValue.uuidString.lowercased(),
                    publicKey: $0.publicKey.rawRepresentation) }), freshUntil: date.addingTimeInterval(30)))
        return epoch
    }
}

private actor StartupBarrierSignalSession: RendezvousSignalSession {
    let barrier: AttemptBarrier
    private(set) var requests = 0
    init(barrier: AttemptBarrier) { self.barrier = barrier }
    func signalFrames() async -> AsyncStream<RendezvousSignalFrame> {
        requests += 1
        await barrier.wait()
        return AsyncStream { $0.finish() }
    }
    func protocolErrors() async -> AsyncStream<RendezvousProtocolError> { AsyncStream { $0.finish() } }
    func sendSignal(_ payload: Data, to device: DeviceID) async throws {}
}

private struct SubstitutingAttemptProvider: PeerAuthorizationProviding {
    let owner: PeerAuthorizationOwner
    let lease: PeerAuthorizationLease
    func acquire(for peer: DeviceID) throws -> PeerAuthorizationLease { lease }
    func validate(_ lease: PeerAuthorizationLease) throws { try owner.validate(lease) }
    func claim(_ lease: PeerAuthorizationLease, onInvalidation: @escaping @Sendable () -> Void) throws -> PeerAuthorizationRegistration {
        try owner.claim(lease, onInvalidation: onInvalidation)
    }
    func snapshot() -> PeerAuthorizationSnapshot { owner.snapshot() }
    func updates() -> AsyncStream<PeerAuthorizationSnapshot> { owner.updates() }
}

private struct AttemptProviderProbe: PeerAuthorizationProviding {
    let owner: PeerAuthorizationOwner
    let observed: @Sendable (Bool) -> Void
    func acquire(for peer: DeviceID) throws -> PeerAuthorizationLease { try owner.acquire(for: peer) }
    func validate(_ lease: PeerAuthorizationLease) throws {
        do { try owner.validate(lease) }
        catch { observed(false); throw error }
        observed(true)
    }
    func claim(_ lease: PeerAuthorizationLease, onInvalidation: @escaping @Sendable () -> Void) throws -> PeerAuthorizationRegistration {
        try owner.claim(lease, onInvalidation: onInvalidation)
    }
    func snapshot() -> PeerAuthorizationSnapshot { owner.snapshot() }
    func updates() -> AsyncStream<PeerAuthorizationSnapshot> { owner.updates() }
}

private actor AuthorizedAttemptFactory: AuthorizedWebRTCChannelFactory {
    struct Call: Sendable {
        let peer: DeviceID
        let key: Data
        let connectionID: UUID
        let role: WebRTCRole
        let route: ConnectionRoute
        let lease: PeerAuthorizationLease
    }
    nonisolated let entered = XCTestExpectation(description: "authorized factory entered")
    private(set) var calls: [Call] = []
    private(set) var legacyCalls = 0
    private let operation: @Sendable (Call, any PeerAuthorizationProviding) async throws -> WebRTCSecureChannel

    init(operation: @escaping @Sendable (Call, any PeerAuthorizationProviding) async throws -> WebRTCSecureChannel = { _, _ in throw WebRTCFactoryError.timeout }) {
        self.operation = operation
    }

    func connect(localIdentity: DeviceIdentity, remoteDevice: DeviceID, remotePublicKey: Data,
                 connectionID: UUID, role: WebRTCRole, route: ConnectionRoute,
                 ice: ICEConfiguration, signaling: any WebRTCSignalTransport) async throws -> WebRTCSecureChannel {
        legacyCalls += 1
        XCTFail("Provider path called legacy factory")
        throw WebRTCFactoryError.timeout
    }

    func connect(localIdentity: DeviceIdentity, remoteDevice: DeviceID, remotePublicKey: Data,
                 connectionID: UUID, role: WebRTCRole, route: ConnectionRoute,
                 ice: ICEConfiguration, signaling: any WebRTCSignalTransport,
                 authorizationProvider: any PeerAuthorizationProviding,
                 authorizationLease: PeerAuthorizationLease) async throws -> WebRTCSecureChannel {
        let call = Call(peer: remoteDevice, key: remotePublicKey, connectionID: connectionID,
                        role: role, route: route, lease: authorizationLease)
        calls.append(call)
        entered.fulfill()
        return try await operation(call, authorizationProvider)
    }
}

/// Deliberately ignores task cancellation until the test releases ownership.
private final class AttemptBarrier: @unchecked Sendable {
    let entered = XCTestExpectation(description: "dependency entered")
    private let lock = NSLock()
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { continuation in
            let resume = lock.withLock {
                guard !released else { return true }
                waiters.append(continuation)
                return false
            }
            entered.fulfill()
            if resume { continuation.resume() }
        }
    }
    func release() {
        let pending = lock.withLock {
            released = true
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        pending.forEach { $0.resume() }
    }
}

private struct BarrierICEProvider: ICEConfigurationProviding {
    let barrier: AttemptBarrier
    var fail = false
    func configuration(for route: ConnectionRoute) async throws -> ICEConfiguration {
        await barrier.wait()
        if fail { throw WebRTCFactoryError.timeout }
        return ICEConfiguration(stunURLs: [], turnServers: [])
    }
}

private actor RecordingICEConfigurationProvider: ICEConfigurationProviding {
    private var routes: [ConnectionRoute] = []

    func configuration(for route: ConnectionRoute) async throws -> ICEConfiguration {
        routes.append(route)
        return ICEConfiguration(
            stunURLs: route == .directInternet ? ["stun:stun.test:3478"] : [],
            turnServers: route == .relay
                ? [TURNServer(
                    urls: ["turn:turn.test:3478?transport=udp"],
                    username: "1800000600:opaque",
                    credential: "secret"
                )]
                : []
        )
    }

    func requestedRoutes() -> [ConnectionRoute] { routes }
}

private actor RecordingFailingWebRTCFactory: WebRTCChannelFactory {
    private var routes: [ConnectionRoute] = []
    private var configurations: [ICEConfiguration] = []

    func connect(
        localIdentity: DeviceIdentity,
        remoteDevice: DeviceID,
        remotePublicKey: Data,
        connectionID: UUID,
        role: WebRTCRole,
        route: ConnectionRoute,
        ice: ICEConfiguration,
        signaling: any WebRTCSignalTransport
    ) async throws -> WebRTCSecureChannel {
        _ = localIdentity
        _ = remoteDevice
        _ = remotePublicKey
        _ = connectionID
        _ = role
        _ = signaling
        routes.append(route)
        configurations.append(ice)
        throw WebRTCFactoryError.timeout
    }

    func requestedRoutes() -> [ConnectionRoute] { routes }
    func requestedICE() -> [ICEConfiguration] { configurations }
}

private actor AttemptRecorder: ConnectionAttempting {
    private var results: [Result<ConnectionRoute, ConnectionAttemptError>]
    private(set) var routes: [ConnectionRoute] = []

    init(results: [Result<ConnectionRoute, ConnectionAttemptError>]) {
        self.results = results
    }

    func connect(to device: DeviceID, route: ConnectionRoute) async throws -> any SecureChannel {
        _ = device
        routes.append(route)
        guard !results.isEmpty else { throw ConnectionAttemptError.iceFailed }
        return TestSecureChannel(route: try results.removeFirst().get())
    }
}

private actor UnavailableAttemptRecorder: ConnectionAttempting {
    private(set) var routes: [ConnectionRoute] = []

    func connect(to device: DeviceID, route: ConnectionRoute) async throws -> any SecureChannel {
        _ = device
        routes.append(route)
        throw WebRTCFactoryError.peerUnavailable
    }
}

private final class TestSecureChannel: SecureChannel, @unchecked Sendable {
    let route: ConnectionRoute

    init(route: ConnectionRoute) { self.route = route }

    func send(_ frame: Data) async throws { _ = frame }
    func frames() -> AsyncThrowingStream<Data, Error> { AsyncThrowingStream { $0.finish() } }
    func exportKey(label: String, context: Data, length: Int) async throws -> Data {
        _ = label
        _ = context
        return Data(repeating: 0, count: length)
    }
    func close() async {}
}

private actor MemoryRendezvousSignalSession: RendezvousSignalSession {
    private let stream: AsyncStream<RendezvousSignalFrame>
    private let continuation: AsyncStream<RendezvousSignalFrame>.Continuation
    private let errorStream: AsyncStream<RendezvousProtocolError>
    private let errorContinuation: AsyncStream<RendezvousProtocolError>.Continuation
    private(set) var streamRequests = 0
    private var sent: [(Data, DeviceID)] = []

    init() {
        var continuation: AsyncStream<RendezvousSignalFrame>.Continuation!
        stream = AsyncStream { continuation = $0 }
        self.continuation = continuation
        var errorContinuation: AsyncStream<RendezvousProtocolError>.Continuation!
        errorStream = AsyncStream { errorContinuation = $0 }
        self.errorContinuation = errorContinuation
    }

    func signalFrames() -> AsyncStream<RendezvousSignalFrame> {
        streamRequests += 1
        return stream
    }

    func protocolErrors() -> AsyncStream<RendezvousProtocolError> { errorStream }

    func sendSignal(_ payload: Data, to device: DeviceID) async throws {
        sent.append((payload, device))
    }

    func deliver(_ frame: RendezvousSignalFrame) { continuation.yield(frame) }
    func deliver(_ error: RendezvousProtocolError) { errorContinuation.yield(error) }
    func lastSentPayload() -> Data? { sent.last?.0 }
    func lastSentDevice() -> DeviceID? { sent.last?.1 }
}

private actor BlockingInboundWebRTCFactory: WebRTCChannelFactory {
    private var activeTotal = 0
    private var activeByDevice: [DeviceID: Int] = [:]
    private var maximumTotal = 0
    private var maximumPerDevice = 0

    func connect(
        localIdentity: DeviceIdentity,
        remoteDevice: DeviceID,
        remotePublicKey: Data,
        connectionID: UUID,
        role: WebRTCRole,
        route: ConnectionRoute,
        ice: ICEConfiguration,
        signaling: any WebRTCSignalTransport
    ) async throws -> WebRTCSecureChannel {
        _ = localIdentity
        _ = remotePublicKey
        _ = connectionID
        _ = role
        _ = route
        _ = ice
        _ = signaling
        activeTotal += 1
        activeByDevice[remoteDevice, default: 0] += 1
        maximumTotal = max(maximumTotal, activeTotal)
        maximumPerDevice = max(maximumPerDevice, activeByDevice[remoteDevice, default: 0])
        defer {
            activeTotal -= 1
            activeByDevice[remoteDevice, default: 0] -= 1
        }
        try await Task.sleep(for: .seconds(30))
        throw WebRTCFactoryError.timeout
    }

    func snapshot() -> (maximumTotal: Int, maximumPerDevice: Int) {
        (maximumTotal, maximumPerDevice)
    }
}
