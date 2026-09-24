import CryptoKit
import Foundation
import XCTest
@testable import MacChannelCore

final class WebRTCLoopbackTests: XCTestCase {
    func testAuthorizedWithdrawalDeniesExporterAndSend() async throws {
        let pair = try await makeAuthorizedPair()
        let key = try await pair.left.exportKey(label: "test", context: Data(), length: 32)
        XCTAssertEqual(key.count, 32)
        try pair.owner.replaceManual([:])
        do {
            _ = try await pair.left.exportKey(label: "test", context: Data(), length: 32)
            XCTFail("Withdrawn channel exported a key")
        } catch { XCTAssertEqual(error as? WebRTCSecureChannelError, .transportClosed) }
        do {
            try await pair.left.send(Data([1]))
            XCTFail("Withdrawn channel sent application data")
        } catch { XCTAssertEqual(error as? WebRTCSecureChannelError, .transportClosed) }
        await pair.left.close()
        await pair.right.close()
    }

    func testAuthorizedPreWithdrawalAdmissionCompletesButNextOperationIsDenied() async throws {
        let pair = try await makeAuthorizedPair()
        // Already admitted/delivered bytes are not retroactively retracted.
        var iterator = pair.left.frames().makeAsyncIterator()
        try await pair.right.send(Data([7]))
        let admitted = try await iterator.next()
        XCTAssertEqual(admitted, Data([7]))
        try pair.owner.replaceManual([:])
        do {
            _ = try await pair.left.exportKey(label: "next", context: Data(), length: 32)
            XCTFail("Next operation after withdrawal must be denied")
        } catch { XCTAssertEqual(error as? WebRTCSecureChannelError, .transportClosed) }
        await pair.left.close()
        await pair.right.close()
    }

    func testAuthorizedBackpressureWithdrawalFinishesWaiter() async throws {
        let pair = try await makeAuthorizedPair()
        await pair.left._testOnlyForceBackpressure(true)
        let finished = expectation(description: "withdrawal resumes backpressure waiter")
        let send = Task { () -> WebRTCSecureChannelError? in
            defer { finished.fulfill() }
            do { try await pair.left.send(Data([9])); return nil }
            catch { return error as? WebRTCSecureChannelError }
        }
        let suspended = await waitForBackpressureWaiters(1, on: pair.left)
        XCTAssertTrue(suspended)
        try pair.owner.replaceManual([:])
        await fulfillment(of: [finished], timeout: 2)
        let failure = await send.value
        XCTAssertEqual(failure, .transportClosed)
        await pair.left.close()
        do {
            _ = try await pair.left.exportKey(label: "closed", context: Data(), length: 32)
            XCTFail("Terminated channel exported")
        } catch { XCTAssertEqual(error as? WebRTCSecureChannelError, .transportClosed) }
        await pair.right.close()
    }

    func testAuthorizedBufferedFrameIsDeniedWhenIteratorStartsAfterWithdrawal() async throws {
        let pair = try await makeAuthorizedPair()
        let enqueued = expectation(description: "frame admitted to bounded buffer")
        pair.left._testOnlyQueueReceive(Data([42])) { admitted in
            XCTAssertTrue(admitted)
            enqueued.fulfill()
        }
        await fulfillment(of: [enqueued], timeout: 2)
        try pair.owner.replaceManual([:])
        var iterator = pair.left.frames().makeAsyncIterator()
        do { _ = try await iterator.next(); XCTFail("Buffered frame escaped withdrawal") }
        catch { XCTAssertEqual(error as? WebRTCSecureChannelError, .transportClosed) }
        await pair.left.close(); await pair.right.close()
    }

    func testAuthorizedQueuedCallbackCannotAdmitAfterWithdrawal() async throws {
        let pair = try await makeAuthorizedPair()
        let barrier = ChannelAuthorizationBarrier()
        defer { barrier.release() }
        pair.left._testOnlyQueueOperation { await barrier.pause() }
        await fulfillment(of: [barrier.entered], timeout: 2)
        let received = expectation(description: "queued callback drained")
        pair.left._testOnlyQueueReceive(Data([42])) { admitted in
            XCTAssertFalse(admitted)
            received.fulfill()
        }
        try pair.owner.replaceManual([:])
        barrier.release()
        await fulfillment(of: [received], timeout: 2)
        await pair.left.close(); await pair.right.close()
    }

    func testAuthorizedPendingAuthenticationWithdrawalFinishesWithoutExplicitClose() async throws {
        let local = try DeviceIdentity.ephemeral(), remote = try DeviceIdentity.ephemeral()
        let owner = PeerAuthorizationOwner.live(identity: local)
        try owner.replaceManual([remote.id: remote.publicKey.rawRepresentation])
        let lease = try owner.acquire(for: remote.id)
        let signaling = AuthorizationPendingSignaling()
        let done = expectation(description: "factory waiter failed")
        let task = Task {
            defer { done.fulfill() }
            do {
                _ = try await WebRTCFactory(connectionTimeout: .seconds(5)).connect(
                    localIdentity: local, remoteDevice: remote.id,
                    remotePublicKey: lease.publicKey, connectionID: UUID(), role: .offerer,
                    route: .lan, ice: ICEConfiguration(stunURLs: [], turnServers: []),
                    signaling: signaling, authorizationProvider: owner, authorizationLease: lease)
                XCTFail("Pending authentication returned after withdrawal")
            } catch { XCTAssertEqual(error as? WebRTCSecureChannelError, .authenticationFailed) }
        }
        defer { task.cancel() }
        await fulfillment(of: [signaling.offerSent], timeout: 2)
        try owner.replaceManual([:])
        await fulfillment(of: [done], timeout: 2)
        await task.value
    }

    func testAuthorizedMismatchedAndStaleLeaseRejectBeforeSignaling() async throws {
        let local = try DeviceIdentity.ephemeral(), remote = try DeviceIdentity.ephemeral()
        let owner = PeerAuthorizationOwner.live(identity: local)
        try owner.replaceManual([remote.id: remote.publicKey.rawRepresentation])
        let lease = try owner.acquire(for: remote.id)
        let signal = AuthorizationPendingSignaling()
        for (peer, key, stale) in [(local.id, lease.publicKey, false),
                                   (remote.id, local.publicKey.rawRepresentation, false),
                                   (remote.id, lease.publicKey, true)] {
            if stale { try owner.replaceManual([:]) }
            do {
                _ = try await WebRTCFactory(connectionTimeout: .milliseconds(100)).connect(
                    localIdentity: local, remoteDevice: peer, remotePublicKey: key,
                    connectionID: UUID(), role: .offerer, route: .lan,
                    ice: ICEConfiguration(stunURLs: [], turnServers: []), signaling: signal,
                    authorizationProvider: owner, authorizationLease: lease)
                XCTFail("Invalid authorization returned a channel")
            } catch { XCTAssertEqual(error as? WebRTCSecureChannelError, .authenticationFailed) }
        }
        let calls = await signal.messageCalls
        XCTAssertEqual(calls, 0)
    }

    func testAuthorizedLateFactoryResultRechecksBeforeReturning() async throws {
        try await assertLateFactoryResult(revoke: true)
    }

    func testAuthorizedLateFactoryCancellationNeverReturnsChannel() async throws {
        try await assertLateFactoryResult(revoke: false)
    }

    private func assertLateFactoryResult(revoke: Bool) async throws {
        let barrier = ChannelAuthorizationBarrier()
        defer { barrier.release() }
        let local = try DeviceIdentity.ephemeral(), remote = try DeviceIdentity.ephemeral()
        let owner = PeerAuthorizationOwner.live(identity: local)
        try owner.replaceManual([remote.id: remote.publicKey.rawRepresentation])
        let lease = try owner.acquire(for: remote.id)
        let bus = InMemoryWebRTCSignalBus(), id = UUID()
        let factory = WebRTCFactory(connectionTimeout: .seconds(5), beforeAuthorizedReturn: { await barrier.pause() })
        let left = Task {
            try await factory.connect(localIdentity: local, remoteDevice: remote.id,
                remotePublicKey: lease.publicKey, connectionID: id, role: .offerer, route: .lan,
                ice: ICEConfiguration(stunURLs: [], turnServers: []), signaling: bus.endpoint(for: local.id),
                authorizationProvider: owner, authorizationLease: lease)
        }
        let right = Task {
            try await factory.connect(localIdentity: remote, remoteDevice: local.id,
                remotePublicKey: local.publicKey.rawRepresentation, connectionID: id, role: .answerer,
                route: .lan, ice: ICEConfiguration(stunURLs: [], turnServers: []), signaling: bus.endpoint(for: remote.id))
        }
        defer { left.cancel(); right.cancel() }
        await fulfillment(of: [barrier.entered], timeout: 2)
        if revoke { try owner.replaceManual([:]) } else { left.cancel() }
        barrier.release()
        do { let channel = try await left.value; await channel.close(); XCTFail("Late result escaped") }
        catch {
            if revoke { XCTAssertEqual(error as? WebRTCSecureChannelError, .authenticationFailed) }
            else { XCTAssertTrue(error is CancellationError) }
        }
        if let channel = try? await right.value { await channel.close() }
    }

    func testAuthorizedGateExactSourceOverlapAndFinalRemoval() throws {
        let fixture = try PeerOwnerFixture()
        try fixture.owner.replaceManual([fixture.peer: fixture.peerKey])
        let lease = try fixture.owner.acquire(for: fixture.peer)
        let gate = try WebRTCPeerAuthorizationGate(provider: fixture.owner, lease: lease,
            peer: fixture.peer, publicKey: fixture.peerKey)
        let invalidations = PeerTestBox(0)
        gate.onInvalidation { invalidations.update { $0 += 1 } }
        let epoch = try fixture.begin()
        try fixture.install(epoch)
        try fixture.owner.replaceManual([:])
        XCTAssertNoThrow(try gate.requireCurrent())
        XCTAssertEqual(invalidations.value, 0)
        fixture.owner.invalidateAccount(epoch)
        XCTAssertThrowsError(try gate.requireCurrent())
        XCTAssertEqual(invalidations.value, 1)
        try fixture.owner.replaceManual([fixture.peer: fixture.peerKey])
        XCTAssertThrowsError(try gate.requireCurrent(), "A withdrawn continuity never revives")
    }

    func testAuthorizedGateExpiryAndConflictingEvidenceFailClosed() throws {
        let fixture = try PeerOwnerFixture()
        let epoch = try fixture.begin()
        try fixture.install(epoch)
        let gate = try WebRTCPeerAuthorizationGate(provider: fixture.owner,
            lease: fixture.owner.acquire(for: fixture.peer), peer: fixture.peer, publicKey: fixture.peerKey)
        fixture.clock.update { $0 = fixture.start.addingTimeInterval(21) }
        XCTAssertThrowsError(try gate.requireCurrent(), "Delayed timer cannot extend authorization")
        // Different-key evidence for a hash-derived peer is rejected at producer
        // validation, not silently substituted into this exact-key lease.
        XCTAssertThrowsError(try fixture.owner.replaceManual([fixture.peer: fixture.localKey]))
        XCTAssertThrowsError(try gate.requireCurrent())
    }

    func testAuthorizedGateClaimReleasedWithoutRetainCycle() throws {
        let fixture = try PeerOwnerFixture()
        try fixture.owner.replaceManual([fixture.peer: fixture.peerKey])
        let provider = RecordingAuthorizationProvider(fixture.owner)
        var gate: WebRTCPeerAuthorizationGate? = try WebRTCPeerAuthorizationGate(provider: provider,
            lease: fixture.owner.acquire(for: fixture.peer), peer: fixture.peer, publicKey: fixture.peerKey)
        weak var weakGate = gate
        XCTAssertTrue(provider.hasRegistration)
        gate = nil
        XCTAssertNil(weakGate)
        XCTAssertFalse(provider.hasRegistration)
        XCTAssertEqual(provider.claims, 1)
    }

    func testAuthorizedCloseRacingWithdrawalDisposesRegistrationAndChannel() async throws {
        var pair: AuthorizedLoopbackPair? = try await makeAuthorizedPair()
        let provider = pair!.provider
        weak var weakChannel: WebRTCSecureChannel?
        var channel: WebRTCSecureChannel? = pair!.left
        weakChannel = channel
        XCTAssertTrue(provider.hasRegistration)
        var closeTask: Task<Void, Never>? = Task { [channel] in await channel?.close() }
        try pair!.owner.replaceManual([:])
        await closeTask?.value
        closeTask = nil
        channel = nil
        XCTAssertFalse(provider.hasRegistration)
        await pair!.right.close()
        pair = nil
        XCTAssertNil(weakChannel)
    }

    func testAuthorizedChannelSurvivesSameKeyAccountOverlapThenDeniesFinalRemoval() async throws {
        let pair = try await makeAuthorizedPair()
        let binding = try AccountSessionBinding(deviceID: pair.local.id.rawValue,
            audience: "test", origin: URL(string: "https://example.com")!)
        let account = UUID().uuidString.lowercased()
        let epoch = try pair.owner.beginAccountSession(binding: binding, accountID: account,
            sessionID: UUID().uuidString.lowercased(), localPublicKey: pair.local.publicKey.rawRepresentation,
            accessExpiresAt: Date().addingTimeInterval(100))
        try pair.owner.install(VerifiedPeerAccountEvidence(epoch: epoch, binding: binding,
            snapshot: AccountGroupSnapshot(accountID: account, groupID: UUID().uuidString.lowercased(),
                generation: 1, sequence: 1, headHash: Data(repeating: 1, count: 32),
                members: [pair.local, pair.remote].map { AccountGroupMember(
                    deviceID: $0.id.rawValue.uuidString.lowercased(), publicKey: $0.publicKey.rawRepresentation) }),
            freshUntil: Date().addingTimeInterval(30)))
        try pair.owner.replaceManual([:])
        var iterator = pair.right.frames().makeAsyncIterator()
        try await pair.left.send(Data([12]))
        let frame = try await iterator.next()
        XCTAssertEqual(frame, Data([12]))
        pair.owner.invalidateAccount(epoch)
        do { try await pair.left.send(Data([13])); XCTFail("Final source removed") }
        catch { XCTAssertEqual(error as? WebRTCSecureChannelError, .transportClosed) }
        await pair.left.close(); await pair.right.close()
    }

    func testLegacyTerminalReceiveErrorIsPreservedForLateIterator() async throws {
        let pair = try await makeLoopbackPair()
        let rejected = expectation(description: "oversized receive rejected")
        pair.left._testOnlyQueueReceive(Data(repeating: 1, count: WebRTCSecureChannel.maximumMessageBytes + 1)) { admitted in
            XCTAssertFalse(admitted); rejected.fulfill()
        }
        await fulfillment(of: [rejected], timeout: 2)
        var iterator = pair.left.frames().makeAsyncIterator()
        do { _ = try await iterator.next(); XCTFail("Expected original receive error") }
        catch { XCTAssertEqual(error as? WebRTCSecureChannelError, .messageTooLarge) }
        await pair.left.close(); await pair.right.close()
    }

    func testLegacyTerminationRejectsExportSendAndBufferedIteration() async throws {
        let pair = try await makeLoopbackPair()
        let enqueued = expectation(description: "legacy buffer populated")
        pair.left._testOnlyQueueReceive(Data([42])) { admitted in
            XCTAssertTrue(admitted); enqueued.fulfill()
        }
        await fulfillment(of: [enqueued], timeout: 2)
        await pair.left.close()
        do { _ = try await pair.left.exportKey(label: "closed", context: Data(), length: 32); XCTFail("closed export") }
        catch { XCTAssertEqual(error as? WebRTCSecureChannelError, .transportClosed) }
        do { try await pair.left.send(Data([1])); XCTFail("closed send") }
        catch { XCTAssertEqual(error as? WebRTCSecureChannelError, .transportClosed) }
        var iterator = pair.left.frames().makeAsyncIterator()
        do { _ = try await iterator.next(); XCTFail("closed buffered iteration") }
        catch { XCTAssertEqual(error as? WebRTCSecureChannelError, .transportClosed) }
        await pair.right.close()
    }

    func testAuthorizedSuspendedIteratorRechecksBeforeReturningBufferedElement() async throws {
        let pair = try await makeAuthorizedPair()
        let barrier = ChannelAuthorizationBarrier()
        defer { barrier.release() }
        let consumer = Task {
            var iterator = pair.left._testOnlyFrames(beforeDelivery: { await barrier.pause() }).makeAsyncIterator()
            do { _ = try await iterator.next(); XCTFail("Post-suspension delivery escaped withdrawal") }
            catch { XCTAssertEqual(error as? WebRTCSecureChannelError, .transportClosed) }
        }
        defer { consumer.cancel() }
        try await pair.right.send(Data([17]))
        await fulfillment(of: [barrier.entered], timeout: 2)
        try pair.owner.replaceManual([:])
        barrier.release()
        await consumer.value
        await pair.left.close(); await pair.right.close()
    }

    private func makeAuthorizedPair() async throws -> AuthorizedLoopbackPair {
        let local = try DeviceIdentity.ephemeral()
        let remote = try DeviceIdentity.ephemeral()
        let owner = PeerAuthorizationOwner.live(identity: local)
        try owner.replaceManual([remote.id: remote.publicKey.rawRepresentation])
        let lease = try owner.acquire(for: remote.id)
        let provider = RecordingAuthorizationProvider(owner)
        let bus = InMemoryWebRTCSignalBus()
        let id = UUID()
        let factory = WebRTCFactory(connectionTimeout: .seconds(5))
        async let left = factory.connect(localIdentity: local, remoteDevice: remote.id,
            remotePublicKey: remote.publicKey.rawRepresentation, connectionID: id,
            role: .offerer, route: .lan, ice: ICEConfiguration(stunURLs: [], turnServers: []),
            signaling: bus.endpoint(for: local.id), authorizationProvider: provider, authorizationLease: lease)
        async let right = factory.connect(localIdentity: remote, remoteDevice: local.id,
            remotePublicKey: local.publicKey.rawRepresentation, connectionID: id,
            role: .answerer, route: .lan, ice: ICEConfiguration(stunURLs: [], turnServers: []),
            signaling: bus.endpoint(for: remote.id))
        return try await AuthorizedLoopbackPair(left: left, right: right, owner: owner,
            provider: provider, local: local, remote: remote)
    }

    func testThroughputFlowControlRemainsExplicitlyBounded() {
        XCTAssertEqual(WebRTCSecureChannel.bufferedAmountLowThreshold, 1024 * 1024)
    }

    func testCallbackQueueCanStageEntireInboundFrameBuffer() {
        XCTAssertEqual(WebRTCSecureChannel.inboundApplicationFrameCapacity, 256)
        XCTAssertEqual(
            WebRTCSecureChannel.orderedCallbackCapacity,
            WebRTCSecureChannel.inboundApplicationFrameCapacity
        )
    }

    func testOrderedReliableLoopbackTransfersOneMiBIn64KiBFrames() async throws {
        let leftIdentity = try DeviceIdentity.ephemeral()
        let rightIdentity = try DeviceIdentity.ephemeral()
        let bus = InMemoryWebRTCSignalBus()
        let connectionID = UUID()
        let factory = WebRTCFactory(connectionTimeout: .seconds(15))
        let ice = ICEConfiguration(stunURLs: [], turnServers: [])

        async let left = factory.connect(
            localIdentity: leftIdentity,
            remoteDevice: rightIdentity.id,
            remotePublicKey: rightIdentity.publicKey.rawRepresentation,
            connectionID: connectionID,
            role: .offerer,
            route: .lan,
            ice: ice,
            signaling: bus.endpoint(for: leftIdentity.id)
        )
        async let right = factory.connect(
            localIdentity: rightIdentity,
            remoteDevice: leftIdentity.id,
            remotePublicKey: leftIdentity.publicKey.rawRepresentation,
            connectionID: connectionID,
            role: .answerer,
            route: .lan,
            ice: ice,
            signaling: bus.endpoint(for: rightIdentity.id)
        )
        let (leftChannel, rightChannel) = try await (left, right)

        let expected = Data((0..<(1024 * 1024)).map { UInt8($0 % 251) })
        let receiver = Task { () throws -> Data in
            var received = Data()
            for try await frame in rightChannel.frames() {
                received.append(frame)
                if received.count == expected.count { return received }
            }
            return received
        }
        for offset in stride(from: 0, to: expected.count, by: WebRTCSecureChannel.maximumMessageBytes) {
            let end = min(offset + WebRTCSecureChannel.maximumMessageBytes, expected.count)
            try await leftChannel.send(expected.subdata(in: offset..<end))
        }

        let received = try await receiver.value
        XCTAssertEqual(received, expected)
        XCTAssertEqual(leftChannel.route, .lan)
        XCTAssertEqual(rightChannel.route, .lan)
        XCTAssertTrue(leftChannel.isOrderedReliable)
        XCTAssertTrue(rightChannel.isOrderedReliable)

        let context = Data("transfer-42".utf8)
        let leftKey = try await leftChannel.exportKey(label: "file-content", context: context, length: 32)
        let rightKey = try await rightChannel.exportKey(label: "file-content", context: context, length: 32)
        let manifestKey = try await leftChannel.exportKey(label: "manifest", context: context, length: 32)
        XCTAssertEqual(leftKey, rightKey)
        XCTAssertNotEqual(leftKey, manifestKey)
        do {
            _ = try await leftChannel.exportKey(label: "file\0content", context: context, length: 32)
            XCTFail("Expected an ambiguous exporter label to be rejected")
        } catch {
            XCTAssertEqual(error as? WebRTCSecureChannelError, .invalidKeyRequest)
        }

        await leftChannel.close()
        await leftChannel.close()
        await rightChannel.close()
    }

    func testRejectsApplicationMessageLargerThan64KiB() async throws {
        let channels = try await makeLoopbackPair()

        do {
            try await channels.left.send(Data(repeating: 1, count: WebRTCSecureChannel.maximumMessageBytes + 1))
            XCTFail("Expected an oversized message to be rejected")
        } catch {
            XCTAssertEqual(error as? WebRTCSecureChannelError, .messageTooLarge)
        }

        await channels.left.close()
        await channels.right.close()
    }

    func testRejectsReceivedMessageLargerThan64KiB() async throws {
        let channels = try await makeLoopbackPair()
        var iterator = channels.right.frames().makeAsyncIterator()

        XCTAssertTrue(channels.left._testOnlySendRawFrame(Data(
            repeating: 1,
            count: WebRTCSecureChannel.maximumMessageBytes + 1
        )))

        do {
            _ = try await iterator.next()
            XCTFail("Expected an oversized inbound message to close the channel")
        } catch {
            XCTAssertEqual(error as? WebRTCSecureChannelError, .messageTooLarge)
        }
        await channels.left.close()
        await channels.right.close()
    }

    func testTwoLegSignalingMITMCannotDeriveTheEndToEndExporter() async throws {
        let channels = try await makeLoopbackPair()
        let label = "file-content"
        let context = Data("mitm-regression".utf8)
        let actual = try await channels.left.exportKey(label: label, context: context, length: 32)
        let material = try await channels.left._testOnlyHandshakePublicMaterial()
        let leftPublicKey = try P256.KeyAgreement.PublicKey(
            rawRepresentation: material.localAgreementPublicKey
        )
        let rightPublicKey = try P256.KeyAgreement.PublicKey(
            rawRepresentation: material.remoteAgreementPublicKey
        )
        let proxyLeftLeg = P256.KeyAgreement.PrivateKey()
        let proxyRightLeg = P256.KeyAgreement.PrivateKey()
        let leftLegSecret = try proxyLeftLeg.sharedSecretFromKeyAgreement(with: leftPublicKey)
        let rightLegSecret = try proxyRightLeg.sharedSecretFromKeyAgreement(with: rightPublicKey)
        var salt = Data("macchannel-webrtc-export-v1".utf8)
        salt.append(material.transcriptHash)
        var info = Data(label.utf8)
        info.append(0)
        info.append(context)
        let proxyLeftKey = leftLegSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: info,
            outputByteCount: 32
        ).withUnsafeBytes { Data($0) }
        let proxyRightKey = rightLegSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: info,
            outputByteCount: 32
        ).withUnsafeBytes { Data($0) }

        XCTAssertNotEqual(proxyLeftKey, actual)
        XCTAssertNotEqual(proxyRightKey, actual)
        XCTAssertNotEqual(proxyLeftKey, proxyRightKey)
        await channels.left.close()
        await channels.right.close()
    }

    func testRemoteCloseTerminatesTheActorBackedFrameStream() async throws {
        let channels = try await makeLoopbackPair()
        let streamEnded = expectation(description: "remote frame stream ended")
        var iterator = channels.right.frames().makeAsyncIterator()
        Task {
            do {
                _ = try await iterator.next()
                XCTFail("Expected the remote frame stream to fail")
            } catch {
                XCTAssertEqual(error as? WebRTCSecureChannelError, .transportClosed)
            }
            streamEnded.fulfill()
        }

        await channels.left.close()

        await fulfillment(of: [streamEnded], timeout: 2)
        await channels.right.close()
    }

    func testActorBackedFrameStreamDoesNotDropATwoHundredFrameReceiverBurst() async throws {
        let channels = try await makeLoopbackPair()
        let expected = (0..<200).map { Data([UInt8($0)]) }
        for frame in expected { try await channels.left.send(frame) }
        try await Task.sleep(for: .milliseconds(100))
        let allReceived = expectation(description: "all buffered frames received")
        let recorder = ReceivedFrameRecorder()
        Task {
            do {
                for try await frame in channels.right.frames() {
                    await recorder.append(frame)
                    if await recorder.count == expected.count {
                        allReceived.fulfill()
                        return
                    }
                }
            } catch {}
        }

        await fulfillment(of: [allReceived], timeout: 2)
        let received = await recorder.frames
        XCTAssertEqual(received, expected)
        await channels.left.close()
        await channels.right.close()
    }

    func testCancellingConnectionDoesNotWaitForTheRouteTimeout() async throws {
        let local = try DeviceIdentity.ephemeral()
        let remote = try DeviceIdentity.ephemeral()
        let factory = WebRTCFactory(connectionTimeout: .seconds(30))
        let task = Task {
            try await factory.connect(
                localIdentity: local,
                remoteDevice: remote.id,
                remotePublicKey: remote.publicKey.rawRepresentation,
                connectionID: UUID(),
                role: .offerer,
                route: .lan,
                ice: ICEConfiguration(stunURLs: [], turnServers: []),
                signaling: NeverSignalTransport()
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let cancelled = expectation(description: "cancelled connection returned")
        Task {
            do {
                _ = try await task.value
                XCTFail("Expected cancellation")
            } catch is CancellationError {
                // Expected.
            } catch {
                XCTFail("Expected CancellationError, got \(error)")
            }
            cancelled.fulfill()
        }

        await fulfillment(of: [cancelled], timeout: 1)
    }

    func testPreDescriptionCandidateCountFloodFailsAttemptAndCleansUpReader() async throws {
        let messages = (0..<129).map { index in
            WebRTCSignalMessage.candidate(
                sdp: "candidate:\(index) 1 udp 1 192.168.1.20 \(7_000 + index) typ host",
                sdpMLineIndex: 0,
                sdpMid: "0"
            )
        }
        try await assertPreDescriptionCandidateFloodFails(messages)
    }

    func testPreDescriptionCandidateByteFloodFailsAttemptAndCleansUpReader() async throws {
        let padding = String(repeating: "x", count: 60 * 1024)
        let messages = (0..<9).map { index in
            WebRTCSignalMessage.candidate(
                sdp: "candidate:\(index) 1 udp 1 192.168.1.20 \(7_000 + index) typ host \(padding)",
                sdpMLineIndex: 0,
                sdpMid: "0"
            )
        }
        try await assertPreDescriptionCandidateFloodFails(messages)
    }

    func testCloseWaitsForBlockedCandidateSenderAndPreventsLateSignaling() async throws {
        let leftIdentity = try DeviceIdentity.ephemeral()
        let rightIdentity = try DeviceIdentity.ephemeral()
        let bus = InMemoryWebRTCSignalBus()
        let connectionID = UUID()
        let factory = WebRTCFactory(connectionTimeout: .seconds(15))
        let ice = ICEConfiguration(stunURLs: [], turnServers: [])
        async let left = factory.connect(
            localIdentity: leftIdentity,
            remoteDevice: rightIdentity.id,
            remotePublicKey: rightIdentity.publicKey.rawRepresentation,
            connectionID: connectionID,
            role: .offerer,
            route: .lan,
            ice: ice,
            signaling: bus.endpoint(for: leftIdentity.id)
        )
        async let right = factory.connect(
            localIdentity: rightIdentity,
            remoteDevice: leftIdentity.id,
            remotePublicKey: leftIdentity.publicKey.rawRepresentation,
            connectionID: connectionID,
            role: .answerer,
            route: .lan,
            ice: ice,
            signaling: bus.endpoint(for: rightIdentity.id)
        )
        let (leftChannel, rightChannel) = try await (left, right)

        await bus.blockCandidateSends()
        await leftChannel._testOnlyGenerateLocalCandidate()
        let candidateBlocked = await bus.waitUntilCandidateSendIsBlocked()
        XCTAssertTrue(candidateBlocked)
        let deliveriesBeforeClose = await bus.candidateDeliveryCount

        await leftChannel.close()

        let blockedAfterClose = await bus.blockedCandidateSendCount
        XCTAssertEqual(blockedAfterClose, 0, "close must drain cancelled candidate senders")
        await bus.releaseCandidateSends()
        try await Task.sleep(for: .milliseconds(20))
        let deliveriesAfterClose = await bus.candidateDeliveryCount
        XCTAssertEqual(deliveriesAfterClose, deliveriesBeforeClose, "signaling must not escape after close")
        await rightChannel.close()
    }

    func testLiveSignalingOverflowAfterChannelCreationClosesPeer() async throws {
        let leftIdentity = try DeviceIdentity.ephemeral()
        let rightIdentity = try DeviceIdentity.ephemeral()
        let bus = InMemoryWebRTCSignalBus()
        let connectionID = UUID()
        let factory = WebRTCFactory(connectionTimeout: .seconds(15))
        let ice = ICEConfiguration(stunURLs: [], turnServers: [])
        async let left = factory.connect(
            localIdentity: leftIdentity,
            remoteDevice: rightIdentity.id,
            remotePublicKey: rightIdentity.publicKey.rawRepresentation,
            connectionID: connectionID,
            role: .offerer,
            route: .lan,
            ice: ice,
            signaling: bus.endpoint(for: leftIdentity.id)
        )
        async let right = factory.connect(
            localIdentity: rightIdentity,
            remoteDevice: leftIdentity.id,
            remotePublicKey: leftIdentity.publicKey.rawRepresentation,
            connectionID: connectionID,
            role: .answerer,
            route: .lan,
            ice: ice,
            signaling: bus.endpoint(for: rightIdentity.id)
        )
        let (leftChannel, rightChannel) = try await (left, right)

        await bus.failSignals(
            recipient: leftIdentity.id,
            sender: rightIdentity.id,
            connectionID: connectionID,
            error: WebRTCFactoryError.signalingOverflow
        )
        try await Task.sleep(for: .milliseconds(100))

        do {
            try await leftChannel.send(Data([1]))
            XCTFail("A live signaling overflow must close an already-created peer channel")
        } catch {
            XCTAssertEqual(error as? WebRTCSecureChannelError, .transportClosed)
        }
        await leftChannel.close()
        await rightChannel.close()
    }

    func testBackpressureWaiterCountFloodFailsExcessSendAndCloseCancelsWaiters() async throws {
        let channels = try await makeLoopbackPair()
        await channels.left._testOnlyForceBackpressure(true)
        var suspended: [Task<WebRTCSecureChannelError?, Never>] = []

        for index in 0..<128 {
            suspended.append(Task {
                do {
                    try await channels.left.send(Data([UInt8(index % 251)]))
                    return nil
                } catch {
                    return error as? WebRTCSecureChannelError
                }
            })
            let reachedCount = await waitForBackpressureWaiters(index + 1, on: channels.left)
            XCTAssertTrue(reachedCount)
        }
        let excess = Task { () -> WebRTCSecureChannelError? in
            do {
                try await channels.left.send(Data([255]))
                return nil
            } catch {
                return error as? WebRTCSecureChannelError
            }
        }
        try await Task.sleep(for: .milliseconds(20))

        await channels.left.close()

        let excessError = await excess.value
        XCTAssertEqual(excessError, .overloaded)
        for task in suspended {
            let error = await task.value
            XCTAssertEqual(error, .transportClosed)
        }
        let remainingWaiters = await channels.left._testOnlyBackpressureWaiterCount()
        XCTAssertEqual(remainingWaiters, 0)
        await channels.right.close()
    }

    func testBackpressureSuspendedByteFloodFailsExcessSend() async throws {
        let channels = try await makeLoopbackPair()
        await channels.left._testOnlyForceBackpressure(true)
        var suspended: [Task<WebRTCSecureChannelError?, Never>] = []
        let frame = Data(repeating: 7, count: WebRTCSecureChannel.maximumMessageBytes)

        for index in 0..<64 {
            suspended.append(Task {
                do {
                    try await channels.left.send(frame)
                    return nil
                } catch {
                    return error as? WebRTCSecureChannelError
                }
            })
            let reachedCount = await waitForBackpressureWaiters(index + 1, on: channels.left)
            XCTAssertTrue(reachedCount)
        }
        let excess = Task { () -> WebRTCSecureChannelError? in
            do {
                try await channels.left.send(frame)
                return nil
            } catch {
                return error as? WebRTCSecureChannelError
            }
        }
        try await Task.sleep(for: .milliseconds(20))

        await channels.left.close()

        let excessError = await excess.value
        XCTAssertEqual(excessError, .overloaded)
        for task in suspended {
            let error = await task.value
            XCTAssertEqual(error, .transportClosed)
        }
        await channels.right.close()
    }

    func testAuthenticatedApplicationFrameMayStartWithHandshakeMagic() async throws {
        let channels = try await makeLoopbackPair()
        let frame = Data("MACCHANNEL-HANDSHAKE-1\nthis-is-application-data".utf8)
        var iterator = channels.right.frames().makeAsyncIterator()

        try await channels.left.send(frame)

        let received = try await iterator.next()
        XCTAssertEqual(received, frame)
        await channels.left.close()
        await channels.right.close()
    }

    private func makeLoopbackPair() async throws -> (left: WebRTCSecureChannel, right: WebRTCSecureChannel) {
        let leftIdentity = try DeviceIdentity.ephemeral()
        let rightIdentity = try DeviceIdentity.ephemeral()
        let bus = InMemoryWebRTCSignalBus()
        let connectionID = UUID()
        let factory = WebRTCFactory(connectionTimeout: .seconds(15))
        let ice = ICEConfiguration(stunURLs: [], turnServers: [])
        async let left = factory.connect(
            localIdentity: leftIdentity,
            remoteDevice: rightIdentity.id,
            remotePublicKey: rightIdentity.publicKey.rawRepresentation,
            connectionID: connectionID,
            role: .offerer,
            route: .lan,
            ice: ice,
            signaling: bus.endpoint(for: leftIdentity.id)
        )
        async let right = factory.connect(
            localIdentity: rightIdentity,
            remoteDevice: leftIdentity.id,
            remotePublicKey: leftIdentity.publicKey.rawRepresentation,
            connectionID: connectionID,
            role: .answerer,
            route: .lan,
            ice: ice,
            signaling: bus.endpoint(for: rightIdentity.id)
        )
        return try await (left, right)
    }

    private func assertPreDescriptionCandidateFloodFails(
        _ messages: [WebRTCSignalMessage]
    ) async throws {
        let local = try DeviceIdentity.ephemeral()
        let remote = try DeviceIdentity.ephemeral()
        let termination = SignalStreamTerminationRecorder()
        let signaling = CandidateFloodSignalTransport(messages: messages, termination: termination)
        let factory = WebRTCFactory(connectionTimeout: .milliseconds(250))

        do {
            _ = try await factory.connect(
                localIdentity: local,
                remoteDevice: remote.id,
                remotePublicKey: remote.publicKey.rawRepresentation,
                connectionID: UUID(),
                role: .answerer,
                route: .lan,
                ice: ICEConfiguration(stunURLs: [], turnServers: []),
                signaling: signaling
            )
            XCTFail("Expected the candidate flood to fail the attempt")
        } catch {
            XCTAssertEqual(error as? WebRTCFactoryError, .remoteCandidateOverflow)
        }
        let readerTerminated = await termination.waitUntilTerminated()
        XCTAssertTrue(readerTerminated)
    }

    private func waitForBackpressureWaiters(
        _ count: Int,
        on channel: WebRTCSecureChannel
    ) async -> Bool {
        for _ in 0..<1_000 {
            if await channel._testOnlyBackpressureWaiterCount() == count { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }
}

private struct AuthorizedLoopbackPair {
    let left: WebRTCSecureChannel
    let right: WebRTCSecureChannel
    let owner: PeerAuthorizationOwner
    let provider: RecordingAuthorizationProvider
    let local: DeviceIdentity
    let remote: DeviceIdentity
}

private final class ChannelAuthorizationBarrier: @unchecked Sendable {
    let entered = XCTestExpectation(description: "deterministic barrier entered")
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    init() { (stream, continuation) = AsyncStream.makeStream() }
    func pause() async { entered.fulfill(); for await _ in stream {} }
    func release() { continuation.finish() }
}

private final class RecordingAuthorizationProvider: PeerAuthorizationProviding, @unchecked Sendable {
    let owner: PeerAuthorizationOwner
    private let lock = NSLock()
    private weak var registration: PeerAuthorizationRegistration?
    private var claimCount = 0
    init(_ owner: PeerAuthorizationOwner) { self.owner = owner }
    var hasRegistration: Bool { lock.withLock { registration != nil } }
    var claims: Int { lock.withLock { claimCount } }
    func acquire(for peer: DeviceID) throws -> PeerAuthorizationLease { try owner.acquire(for: peer) }
    func validate(_ lease: PeerAuthorizationLease) throws { try owner.validate(lease) }
    func claim(_ lease: PeerAuthorizationLease, onInvalidation: @escaping @Sendable () -> Void) throws -> PeerAuthorizationRegistration {
        let value = try owner.claim(lease, onInvalidation: onInvalidation)
        lock.withLock { registration = value; claimCount += 1 }
        return value
    }
    func snapshot() -> PeerAuthorizationSnapshot { owner.snapshot() }
    func updates() -> AsyncStream<PeerAuthorizationSnapshot> { owner.updates() }
}

private actor AuthorizationPendingSignaling: WebRTCSignalTransport {
    nonisolated let offerSent = XCTestExpectation(description: "offer sent while authentication pending")
    private(set) var messageCalls = 0
    func messages(from remoteDevice: DeviceID, connectionID: UUID) async -> AsyncThrowingStream<WebRTCSignalMessage, Error> {
        messageCalls += 1
        return AsyncThrowingStream { _ in }
    }
    func send(_ message: WebRTCSignalMessage, to remoteDevice: DeviceID, connectionID: UUID) async throws {
        if case .offer = message { offerSent.fulfill() }
    }
}

private actor ReceivedFrameRecorder {
    private(set) var frames: [Data] = []
    var count: Int { frames.count }
    func append(_ frame: Data) { frames.append(frame) }
}

private actor NeverSignalTransport: WebRTCSignalTransport {
    private let stream: AsyncThrowingStream<WebRTCSignalMessage, Error>
    private let continuation: AsyncThrowingStream<WebRTCSignalMessage, Error>.Continuation

    init() {
        var continuation: AsyncThrowingStream<WebRTCSignalMessage, Error>.Continuation!
        stream = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
    }

    func messages(from remoteDevice: DeviceID, connectionID: UUID) async -> AsyncThrowingStream<WebRTCSignalMessage, Error> {
        _ = remoteDevice
        _ = connectionID
        return stream
    }

    func send(_ message: WebRTCSignalMessage, to remoteDevice: DeviceID, connectionID: UUID) async throws {
        _ = message
        _ = remoteDevice
        _ = connectionID
    }
}

private actor SignalStreamTerminationRecorder {
    private var terminated = false

    func markTerminated() { terminated = true }

    func waitUntilTerminated() async -> Bool {
        for _ in 0..<1_000 {
            if terminated { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }
}

private struct CandidateFloodSignalTransport: WebRTCSignalTransport {
    let messagesToDeliver: [WebRTCSignalMessage]
    let termination: SignalStreamTerminationRecorder

    init(messages: [WebRTCSignalMessage], termination: SignalStreamTerminationRecorder) {
        messagesToDeliver = messages
        self.termination = termination
    }

    func messages(
        from remoteDevice: DeviceID,
        connectionID: UUID
    ) async -> AsyncThrowingStream<WebRTCSignalMessage, Error> {
        _ = remoteDevice
        _ = connectionID
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { [termination] _ in
                Task { await termination.markTerminated() }
            }
            for message in messagesToDeliver { continuation.yield(message) }
        }
    }

    func send(
        _ message: WebRTCSignalMessage,
        to remoteDevice: DeviceID,
        connectionID: UUID
    ) async throws {
        _ = message
        _ = remoteDevice
        _ = connectionID
    }
}

actor InMemoryWebRTCSignalBus {
    struct Key: Hashable {
        let recipient: DeviceID
        let sender: DeviceID
        let connectionID: UUID
    }

    private var subscribers: [Key: AsyncThrowingStream<WebRTCSignalMessage, Error>.Continuation] = [:]
    private var pending: [Key: [WebRTCSignalMessage]] = [:]
    private let candidateGate = CancellableCandidateSendGate()
    private(set) var candidateDeliveryCount = 0

    nonisolated func endpoint(for localDevice: DeviceID) -> InMemoryWebRTCSignalEndpoint {
        InMemoryWebRTCSignalEndpoint(localDevice: localDevice, bus: self)
    }

    func stream(local: DeviceID, remote: DeviceID, connectionID: UUID) -> AsyncThrowingStream<WebRTCSignalMessage, Error> {
        let key = Key(recipient: local, sender: remote, connectionID: connectionID)
        return AsyncThrowingStream { continuation in
            subscribers[key] = continuation
            for message in pending.removeValue(forKey: key) ?? [] { continuation.yield(message) }
        }
    }

    func send(_ message: WebRTCSignalMessage, from: DeviceID, to: DeviceID, connectionID: UUID) async throws {
        if case .candidate = message {
            try await candidateGate.waitIfBlocked()
            candidateDeliveryCount += 1
        }
        let key = Key(recipient: to, sender: from, connectionID: connectionID)
        if let continuation = subscribers[key] {
            continuation.yield(message)
        } else {
            pending[key, default: []].append(message)
        }
    }

    func blockCandidateSends() async { await candidateGate.block() }
    func releaseCandidateSends() async { await candidateGate.release() }
    var blockedCandidateSendCount: Int { get async { await candidateGate.waiterCount } }

    func waitUntilCandidateSendIsBlocked() async -> Bool {
        for _ in 0..<1_000 {
            if await candidateGate.waiterCount > 0 { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    func failSignals(
        recipient: DeviceID,
        sender: DeviceID,
        connectionID: UUID,
        error: Error
    ) {
        let key = Key(recipient: recipient, sender: sender, connectionID: connectionID)
        subscribers.removeValue(forKey: key)?.finish(throwing: error)
    }
}

private actor CancellableCandidateSendGate {
    private var blocked = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    var waiterCount: Int { waiters.count }

    func block() { blocked = true }

    func release() {
        blocked = false
        let pending = waiters.values
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func waitIfBlocked() async throws {
        guard blocked else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

struct InMemoryWebRTCSignalEndpoint: WebRTCSignalTransport {
    let localDevice: DeviceID
    let bus: InMemoryWebRTCSignalBus

    func messages(from remoteDevice: DeviceID, connectionID: UUID) async -> AsyncThrowingStream<WebRTCSignalMessage, Error> {
        await bus.stream(local: localDevice, remote: remoteDevice, connectionID: connectionID)
    }

    func send(_ message: WebRTCSignalMessage, to remoteDevice: DeviceID, connectionID: UUID) async throws {
        try await bus.send(message, from: localDevice, to: remoteDevice, connectionID: connectionID)
    }
}
