import XCTest
@testable import MacChannelCore

final class AccountRouteControllerTests: XCTestCase, @unchecked Sendable {
    func testControllerReleaseClosesAttachedSocketAndFinishesObservers() async throws {
        let f = try NativeProducerFixture()
        let owner = PeerAuthorizationOwner(local: f.local.id, now: { f.clock.value }, schedule: f.timer.schedule)
        let configuration = try AccountPeerAuthorization(owner: owner, identity: f.local, binding: f.binding, freshness: 20)
        var controller: AccountSessionController? = try AccountSessionController(service: f.service, storage: f.storage,
            binding: f.binding, groupVerifier: f.verifier, peerAuthorization: configuration, now: { f.clock.value })
        try await f.pin()
        await controller?.restore()
        _ = try await controller?.syncGroup(groupID: groupID)
        let stream = await controller!.runtimeChanges()
        let finished = PeerTestBox(false)
        let observer = Task { for await _ in stream {}; finished.update { $0 = true } }
        let s = try await RouteControllerSocket.start(f.local)
        _ = try await controller?.attachAccountRoute(to: s.session)
        controller = nil
        for _ in 0..<100 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(20))
        let closed = await s.socket.closed
        XCTAssertTrue(closed)
        XCTAssertTrue(finished.value)
        observer.cancel()
        await s.session.stop()
    }

    func testCancellationAtFirstOwnerInstallationCannotPublishUsableRoute() async throws {
        let f = try NativeProducerFixture()
        let syncTask = PeerTestBox<Task<AccountGroupSnapshot, Error>?>(nil)
        let owner = PeerAuthorizationOwner(local: f.local.id, now: { f.clock.value }, schedule: { _, _ in
            syncTask.value?.cancel()
            return {}
        })
        let configuration = try AccountPeerAuthorization(owner: owner, identity: f.local, binding: f.binding, freshness: 20)
        let controller = try AccountSessionController(service: f.service, storage: f.storage, binding: f.binding,
            groupVerifier: f.verifier, peerAuthorization: configuration, now: { f.clock.value })
        try await f.pin()
        await controller.restore()
        let gate = NativeProducerGate()
        await f.service.setGate(gate, operation: "history")
        let task = Task { try await controller.syncGroup(groupID: groupID) }
        syncTask.update { $0 = task }
        await gate.entered()
        await gate.release()
        _ = try? await task.value
        let s = try await RouteControllerSocket.start(f.local)
        do { _ = try await controller.attachAccountRoute(to: s.session); XCTFail("cancelled installation published route") } catch {}
        await s.session.stop()
    }

    func testGenerationMismatchLocalRemovalAndExpiredFreshnessForbidAttachment() async throws {
        for variant in ["generation", "localRemoval", "freshness"] {
            let f = try NativeProducerFixture()
            try await f.grant()
            if variant == "freshness" {
                f.clock.update { $0 = $0.addingTimeInterval(20) }
            } else {
                let history: [AccountGroupEvent]
                if variant == "generation" {
                    history = [try nativeProducerEvent(actor: f.local, subject: f.local, generation: 2)]
                } else {
                    history = f.events + [try nativeProducerEvent(actor: f.local, subject: f.local,
                        action: "remove", sequence: 3, previous: f.events[1].digest())]
                }
                await f.service.setHistory(history)
                do { _ = try await f.controller.syncGroup(groupID: groupID); XCTFail("invalid local history") } catch {}
            }
            let s = try await RouteControllerSocket.start(f.local)
            do { _ = try await f.controller.attachAccountRoute(to: s.session); XCTFail("invalid context: \(variant)") } catch {}
            let count = await s.socket.controlCount
            XCTAssertEqual(count, 0)
            await s.session.stop()
        }
    }

    func testWrongSocketAndRefreshedCredentialsRequireNewVerifiedAttachment() async throws {
        let f = try NativeProducerFixture()
        try await f.grant()
        let first = try await RouteControllerSocket.start(f.local)
        let second = try await RouteControllerSocket.start(f.local)
        let attachment = try await f.controller.attachAccountRoute(to: first.session)
        do { try await f.controller.bindAccountRoute(attachment, on: second.session); XCTFail("socket substitution") } catch {}
        try await f.controller.refresh()
        do { _ = try await f.controller.attachAccountRoute(to: second.session); XCTFail("refresh retained old history") } catch {}
        _ = try await f.controller.syncGroup(groupID: groupID)
        let replacement = try await f.controller.attachAccountRoute(to: second.session)
        try await f.controller.bindAccountRoute(replacement, on: second.session)
        let data = try await second.socket.payload()
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
        XCTAssertEqual(payload["accessToken"] as? String, nativeProducerToken(5))
        await f.controller.detachAccountRoute(attachment)
        let closed = await second.socket.closed
        XCTAssertFalse(closed)
        await f.controller.detachAccountRoute(replacement)
        await first.session.stop()
        await second.session.stop()
    }

    func testCancelledNoncooperativeHistoryImmediatelyCancelsExistingBind() async throws {
        let f = try NativeProducerFixture()
        try await f.grant()
        let s = try await RouteControllerSocket.start(f.local)
        await s.socket.configure(blockSend: false, blockAck: true)
        let attachment = try await f.controller.attachAccountRoute(to: s.session)
        let bind = Task { try await f.controller.bindAccountRoute(attachment, on: s.session) }
        await s.socket.control.entered()
        let gate = NativeProducerGate()
        await f.service.setGate(gate, operation: "history")
        let sync = Task { try await f.controller.syncGroup(groupID: groupID) }
        await gate.entered()
        sync.cancel()
        for _ in 0..<100 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(20))
        let closed = await s.socket.closed
        XCTAssertTrue(closed, "cancellation must retire the bound socket before noncooperative history returns")
        await gate.release()
        _ = try? await sync.value
        await s.socket.ack()
        _ = try? await bind.value
        await s.session.stop()
    }

    func testMissingContextDoesNotGenerateWakeLoopAndSameContextBindIsIdempotent() async throws {
        let f = try NativeProducerFixture()
        try await f.prepare()
        let s = try await RouteControllerSocket.start(f.local)
        let changes = await f.controller.runtimeChanges()
        let wakes = PeerTestBox(0)
        let subscriber = Task { for await _ in changes { wakes.update { $0 += 1 } } }
        for _ in 0..<100 { await Task.yield() }
        for _ in 0..<4 { do { _ = try await f.controller.attachAccountRoute(to: s.session) } catch {} }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(wakes.value, 1, "missing history is passive; wakeups must not self-trigger a retry loop")
        subscriber.cancel()
        _ = try await f.controller.syncGroup(groupID: groupID)
        let attachment = try await f.controller.attachAccountRoute(to: s.session)
        try await f.controller.bindAccountRoute(attachment, on: s.session)
        _ = try await f.controller.syncGroup(groupID: groupID)
        let same = try await f.controller.attachAccountRoute(to: s.session)
        XCTAssertEqual(attachment, same)
        try await f.controller.bindAccountRoute(same, on: s.session)
        let count = await s.socket.controlCount
        XCTAssertEqual(count, 1)
        await f.controller.detachAccountRoute(same)
        await s.session.stop()
    }

    func testNoHistoryCannotAttachAndVerifiedBindUsesPrivateCurrentCredentials() async throws {
        let f = try NativeProducerFixture()
        try await f.prepare()
        let s = try await RouteControllerSocket.start(f.local)
        do { _ = try await f.controller.attachAccountRoute(to: s.session); XCTFail("unverified route") } catch {}
        _ = try await f.controller.syncGroup(groupID: groupID)
        let attachment = try await f.controller.attachAccountRoute(to: s.session)
        try await f.controller.bindAccountRoute(attachment, on: s.session)
        let wirePayload = try await s.socket.payload()
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(wirePayload)) as? [String: Any])
        XCTAssertEqual(payload["accessToken"] as? String, nativeProducerToken(1))
        XCTAssertEqual(payload["generation"] as? Int, 1)
        XCTAssertEqual(payload["groupID"] as? String, groupID)
        await f.controller.detachAccountRoute(attachment)
        await s.session.stop()
    }

    func testBlockedSendAndAckAreInvalidatedBeforeRefreshOrLogoutCompletes() async throws {
        for blockedSend in [false, true] {
            for logout in [false, true] {
                let f = try NativeProducerFixture()
                try await f.grant()
                let s = try await RouteControllerSocket.start(f.local)
                await s.socket.configure(blockSend: blockedSend, blockAck: !blockedSend)
                let attachment = try await f.controller.attachAccountRoute(to: s.session)
                let bind = Task { try await f.controller.bindAccountRoute(attachment, on: s.session) }
                await s.socket.control.entered()
                let gate = NativeProducerGate()
                await f.service.setGate(gate, operation: logout ? "logout" : "refresh")
                let change = Task { if logout { try await f.controller.logout() } else { try await f.controller.refresh() } }
                await gate.entered()
                do { try await f.controller.bindAccountRoute(attachment, on: s.session); XCTFail("stale attachment") } catch {}
                XCTAssertTrue(f.owner.snapshot().peers.isEmpty)
                await s.socket.sendGate.release()
                do { try await bind.value; XCTFail("invalidated bind accepted") } catch {}
                await gate.release()
                try await change.value
                await s.session.stop()
            }
        }
    }

    func testReplacementWaitsForCancellationInsensitiveOldSendAndOldCleanupCannotStopNewSocket() async throws {
        let f = try NativeProducerFixture()
        try await f.grant()
        let old = try await RouteControllerSocket.start(f.local)
        await old.socket.configure(blockSend: true, blockAck: false)
        let attachment = try await f.controller.attachAccountRoute(to: old.session)
        let bind = Task { try await f.controller.bindAccountRoute(attachment, on: old.session) }
        await old.socket.control.entered()
        await f.controller.suspendAccountRuntime()
        _ = try await f.controller.syncGroup(groupID: groupID)
        let new = try await RouteControllerSocket.start(f.local)
        let finished = PeerTestBox(false)
        let replacement = Task {
            let next = try await f.controller.attachAccountRoute(to: new.session)
            try await f.controller.bindAccountRoute(next, on: new.session)
            finished.update { $0 = true }
            return next
        }
        await old.socket.closedGate.entered()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertFalse(finished.value)
        let before = await new.socket.controlCount
        XCTAssertEqual(before, 0)
        await old.socket.sendGate.release()
        _ = try? await bind.value
        let next = try await replacement.value
        await f.controller.detachAccountRoute(attachment)
        let closed = await new.socket.closed
        XCTAssertFalse(closed)
        await f.controller.detachAccountRoute(next)
        await new.session.stop()
    }

    func testInvalidatedQueuedAttachmentCannotBindAfterDrain() async throws {
        let f = try NativeProducerFixture()
        try await f.grant()
        let old = try await RouteControllerSocket.start(f.local)
        await old.socket.configure(blockSend: true, blockAck: false)
        let oldAttachment = try await f.controller.attachAccountRoute(to: old.session)
        let bind = Task { try await f.controller.bindAccountRoute(oldAttachment, on: old.session) }
        await old.socket.control.entered()
        let new = try await RouteControllerSocket.start(f.local)
        let queued = Task { try await f.controller.attachAccountRoute(to: new.session) }
        await old.socket.closedGate.entered()
        await f.controller.suspendAccountRuntime()
        await old.socket.sendGate.release()
        do { _ = try await queued.value; XCTFail("queued attachment survived invalidation") } catch {}
        _ = try? await bind.value
        let count = await new.socket.controlCount
        XCTAssertEqual(count, 0)
        await new.session.stop()
    }

    func testExpiredDuringBindAndStaleHistoryCannotRetainRoute() async throws {
        let f = try NativeProducerFixture(freshness: 10, access: 10)
        try await f.grant()
        let s = try await RouteControllerSocket.start(f.local)
        await s.socket.configure(blockSend: false, blockAck: true)
        let attachment = try await f.controller.attachAccountRoute(to: s.session)
        let bind = Task { try await f.controller.bindAccountRoute(attachment, on: s.session) }
        await s.socket.control.entered()
        f.clock.update { $0 = $0.addingTimeInterval(10) }
        await s.socket.ack()
        do { try await bind.value; XCTFail("expired bind accepted") } catch {}
        await s.session.stop()

        let fresh = try NativeProducerFixture()
        try await fresh.grant()
        await fresh.service.setHistory([fresh.events[0]])
        do { _ = try await fresh.controller.syncGroup(groupID: groupID); XCTFail("rollback accepted") } catch {}
        let other = try await RouteControllerSocket.start(fresh.local)
        do { _ = try await fresh.controller.attachAccountRoute(to: other.session); XCTFail("failed history retained context") } catch {}
        await other.session.stop()
    }

    func testSuspendWithdrawsOnlyAccountAuthorityAndWakesRuntime() async throws {
        let f = try NativeProducerFixture()
        try await f.grant()
        let repository = try TrustRepository(ownerIdentity: f.local, trustStore: TrustStore(owner: f.local.id), persistedGeneration: 0, authorizationOwner: f.owner)
        _ = try await repository.issueAuthorization(subject: f.peer.id, subjectPublicKey: f.peer.publicKey.rawRepresentation, timestamp: NativeProducerFixture.start)
        let lease = try f.owner.acquire(for: f.peer.id)
        let changes = await f.controller.runtimeChanges()
        var iterator = changes.makeAsyncIterator()
        _ = await iterator.next()
        await f.controller.suspendAccountRuntime()
        let wake: Void? = await iterator.next()
        XCTAssertNotNil(wake)
        XCTAssertNoThrow(try f.owner.validate(lease))
    }
}

private actor RouteControllerSocket: PresenceWebSocket {
    nonisolated let control = NativeProducerGate()
    nonisolated let sendGate = NativeProducerGate()
    nonisolated let closedGate = NativeProducerGate()
    var controlCount = 0
    var closed = false
    private var blockSend = false, blockAck = false
    private var frames: [Data] = []
    private var incoming: [Data]
    private var receiver: CheckedContinuation<Data, Error>?
    init(_ identity: DeviceIdentity) {
        incoming = [Self.json(["type": "challenge", "nonce": Data(repeating: 1, count: 32).base64EncodedString(), "expiresAt": 9999999999999]), Self.json(["type": "auth-ok", "deviceID": identity.id.rawValue.uuidString.lowercased()])]
    }
    static func start(_ identity: DeviceIdentity) async throws -> (session: AuthenticatedPresenceSession, socket: RouteControllerSocket) {
        let socket = RouteControllerSocket(identity)
        let session = try AuthenticatedPresenceSession(identity: identity, origin: URL(string: "wss://account.example.test/v1/ws")!, socket: socket, client: PresenceClient(directory: DeviceDirectory(trust: .allowing(identity.id))))
        try await session.connect()
        let ready = NativeProducerGate()
        Task { try? await session.run(onStarted: { await ready.release(); await ready.block() }, onTrustResult: nil) }
        await ready.entered()
        return (session, socket)
    }
    func configure(blockSend: Bool, blockAck: Bool) { self.blockSend = blockSend; self.blockAck = blockAck }
    static func json(_ value: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: value) }
    func payload() throws -> Data? {
        struct Bind: Decodable { let envelope: RendezvousSignedEnvelope }
        for frame in frames {
            guard (try? JSONSerialization.jsonObject(with: frame) as? [String: Any])?["type"] as? String == "account-route-bind" else { continue }
            if let bind = try? JSONDecoder().decode(Bind.self, from: frame) { return bind.envelope.payload }
        }
        return nil
    }
    func send(_ data: Data) async throws {
        frames.append(data)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        switch object["type"] as? String {
        case "account-route-bind-challenge":
            controlCount += 1
            if blockSend { await control.release(); await control.block(); await sendGate.block() }
            push(Self.json(["type": "account-route-bind-challenge", "nonce": Data(repeating: 8, count: 32).base64EncodedString(), "expiresAt": Int64(Date().timeIntervalSince1970 * 1000) + 10000]))
        case "account-route-bind":
            await control.release(); await control.block()
            if !blockAck { ack() }
        default: break
        }
    }
    func ack() { push(Self.json(["type": "account-route-bind-ok"])) }
    func push(_ data: Data) { if let receiver { self.receiver = nil; receiver.resume(returning: data) } else { incoming.append(data) } }
    func receive() async throws -> Data {
        if closed { throw AuthenticatedPresenceError.transport("closed") }
        if !incoming.isEmpty { return incoming.removeFirst() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func ping() async throws {}
    func close() async {
        closed = true
        receiver?.resume(throwing: AuthenticatedPresenceError.transport("closed")); receiver = nil
        await closedGate.release(); await closedGate.block()
    }
}
