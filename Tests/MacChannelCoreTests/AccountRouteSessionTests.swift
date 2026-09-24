import XCTest
@testable import MacChannelCore

final class AccountRouteSessionTests: XCTestCase, @unchecked Sendable {
    func testBindSignsExactPayloadAndUnbindUsesSoleReader() async throws {
        let identity = try DeviceIdentity.ephemeral()
        let socket2 = AccountSocket(identity: identity)
        let session2 = try AuthenticatedPresenceSession(identity: identity,
            origin: URL(string: "wss://example.test/v1/ws")!, socket: socket2,
            client: PresenceClient(directory: DeviceDirectory(trust: .allowing(identity.id))))
        try await session2.connect()
        let ready = RouteReady()
        let reader2 = Task { try await session2.run(onStarted: { await ready.mark() }, onTrustResult: nil) }
        await ready.wait()
        try await session2.bindAccountRoute(accessToken: "synthetic-token", audience: "ios",
            groupID: "12345678-1234-1234-1234-123456789abc", generation: 7)
        let frames = await socket2.frames
        let wire = try XCTUnwrap(frames.first { (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["type"] as? String == "account-route-bind" })
        struct Bind: Decodable { let envelope: RendezvousSignedEnvelope }
        let envelope = try JSONDecoder().decode(Bind.self, from: wire).envelope
        XCTAssertEqual(envelope.deviceID, identity.id.rawValue.uuidString.lowercased())
        XCTAssertEqual(envelope.nonce, Data(repeating: 8, count: 32))
        XCTAssertEqual(envelope.publicKey, identity.publicKey.rawRepresentation)
        XCTAssertTrue(try identity.publicKey.isValidSignature(.init(derRepresentation: envelope.signature), for: envelope.canonicalPayload()))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: envelope.payload) as? [String: Any])
        XCTAssertEqual(Set(payload.keys), ["type", "accessToken", "audience", "groupID", "generation"])
        XCTAssertEqual(payload["type"] as? String, "account-route-bind-v1")
        XCTAssertEqual(payload["accessToken"] as? String, "synthetic-token")
        XCTAssertEqual(payload["audience"] as? String, "ios")
        XCTAssertEqual(payload["groupID"] as? String, "12345678-1234-1234-1234-123456789abc")
        XCTAssertEqual(payload["generation"] as? Int, 7)
        try await unbindWhenSendsDrained(session2)
        await session2.stop()
        _ = try? await reader2.value
    }

    func testMalformedChallengeRejectionAndWrongAckRetireSession() async throws {
        for mode in [AccountSocket.Mode.expired, .badNonce, .extraField, .rejected, .wrongAck, .earlyAck, .sendFailure, .unsupported, .receiveFailure] {
            try await withSession(mode: mode) { session, socket in
                do { try await self.bind(session); XCTFail("accepted \(mode)") }
                catch { XCTAssertFalse(String(describing: error).contains("synthetic-token")) }
                do { try await session.unbindAccountRoute(); XCTFail("reused retired session") } catch {}
            }
        }
    }

    func testBlockedSendIsBoundedAndUnbindTimeoutRetires() async throws {
        try await withSession(mode: .blockedSend) { session, _ in
            do { try await self.bind(session, timeout: .milliseconds(30)); XCTFail("send did not time out") } catch {}
            do { try await session.unbindAccountRoute(); XCTFail("retired session reused") } catch {}
        }
        try await withSession(mode: .silent) { session, _ in
            do { try await session.unbindAccountRoute(timeout: .milliseconds(30)); XCTFail("unbind did not time out") } catch {}
            do { try await self.bind(session); XCTFail("retired session reused") } catch {}
        }
    }

    func testStopJoinsEverySendAfterAcknowledgementBeforeSendReturns() async throws {
        try await withSession(mode: .delayedSend) { session, socket in
            try await self.bind(session)
            let finished = RouteReady()
            let stop = Task { await session.stop(); await finished.mark() }
            for _ in 0..<100 { await Task.yield() }
            try await Task.sleep(for: .milliseconds(20))
            let stoppedEarly = await finished.ready
            XCTAssertFalse(stoppedEarly, "stop must join both suspended sends after socket close")
            await socket.releaseOneSend()
            try await Task.sleep(for: .milliseconds(20))
            let stoppedAfterOne = await finished.ready
            XCTAssertFalse(stoppedAfterOne, "the previous challenge send must not be lost when the bind send starts")
            await socket.releaseOneSend()
            await stop.value
        }
    }

    func testAcknowledgedButUndrainedSendsBlockNewOperations() async throws {
        try await withSession(mode: .delayedSend) { session, socket in
            try await self.bind(session)
            do { try await self.bind(session); XCTFail("undrained sends allowed another operation") }
            catch { XCTAssertEqual(error as? AuthenticatedPresenceError, .transport("account_route_busy")) }
            let frames = await socket.frames
            XCTAssertEqual(frames.count, 3, "only authentication and original challenge/bind are allowed")
            await socket.setMode(.normal)
            await socket.releaseAllSends()
            try await self.unbindWhenSendsDrained(session)
        }
    }

    func testTimeoutCancellationStopAndLateAckFenceNewOperation() async throws {
        for action in 0..<3 {
            try await withSession(mode: .silent) { session, socket in
                let operation = Task { try await self.bind(session, timeout: .milliseconds(30)) }
                await socket.waitForControl()
                if action == 1 { operation.cancel() }
                if action == 2 { await session.stop() }
                do { try await operation.value; XCTFail("accepted interrupted operation") } catch {}
                await socket.push(AccountSocket.json(["type": "account-route-bind-ok"]))
                do { try await self.bind(session); XCTFail("late ack permitted retry") } catch {}
            }
        }
    }

    func testOverlappingOperationRejectedWithoutDisturbingFirst() async throws {
        try await withSession(mode: .silent) { session, socket in
            let first = Task { try await self.bind(session) }
            await socket.waitForControl()
            do { try await session.unbindAccountRoute(); XCTFail("overlap accepted") } catch {}
            await socket.setMode(.normal)
            await socket.push(AccountSocket.challenge())
            try await first.value
        }
    }

    func testInvalidInputsEmitNoControlFrames() async throws {
        try await withSession(mode: .normal) { session, socket in
            for (token, audience, group, generation) in [
                ("", "ios", self.group, UInt64(1)),
                (String(repeating: "é", count: 2049), "ios", self.group, 1),
                ("token", "", self.group, 1), ("token", "ios", "BAD", 1),
                ("token", "ios", self.group.uppercased(), 1),
                ("token", "ios", self.group, 0), ("token", "ios", self.group, UInt64.max)
            ] {
                do { try await session.bindAccountRoute(accessToken: token, audience: audience,
                    groupID: group, generation: generation); XCTFail("invalid input accepted") } catch {}
            }
            let frames = await socket.frames
            XCTAssertEqual(frames.count, 1)
        }
    }

    private let group = "12345678-1234-1234-1234-123456789abc"
    private func unbindWhenSendsDrained(_ session: AuthenticatedPresenceSession) async throws {
        // Actor completion callbacks, not a fixed sleep, determine readiness.
        for _ in 0..<1000 {
            do { try await session.unbindAccountRoute(); return }
            catch AuthenticatedPresenceError.transport("account_route_busy") { await Task.yield() }
        }
        XCTFail("send callbacks never drained")
    }
    private func bind(_ session: AuthenticatedPresenceSession, timeout: Duration = .seconds(1)) async throws {
        try await session.bindAccountRoute(accessToken: "synthetic-token", audience: "ios",
            groupID: group, generation: 7, timeout: timeout)
    }
    private func withSession(mode: AccountSocket.Mode,
        body: (AuthenticatedPresenceSession, AccountSocket) async throws -> Void) async throws {
        let identity = try DeviceIdentity.ephemeral()
        let socket = AccountSocket(identity: identity)
        await socket.setMode(mode)
        let session = try AuthenticatedPresenceSession(identity: identity,
            origin: URL(string: "wss://example.test/v1/ws")!, socket: socket,
            client: PresenceClient(directory: DeviceDirectory(trust: .allowing(identity.id))))
        try await session.connect()
        let ready = RouteReady()
        let reader = Task { try await session.run(onStarted: { await ready.mark() }, onTrustResult: nil) }
        await ready.wait()
        do { try await body(session, socket) }
        catch { await session.stop(); _ = try? await reader.value; throw error }
        await session.stop()
        _ = try? await reader.value
    }
}

private actor RouteReady {
    var ready = false
    var waiter: CheckedContinuation<Void, Never>?
    func mark() { ready = true; waiter?.resume(); waiter = nil }
    func wait() async { if !ready { await withCheckedContinuation { waiter = $0 } } }
}

private actor AccountSocket: PresenceWebSocket {
    enum Mode { case normal, silent, expired, badNonce, extraField, rejected, wrongAck, earlyAck, sendFailure, unsupported, receiveFailure, blockedSend, delayedSend }
    var mode = Mode.normal
    var controlSent = false
    var controlWaiter: CheckedContinuation<Void, Never>?
    func setMode(_ mode: Mode) { self.mode = mode }
    func waitForControl() async { if !controlSent { await withCheckedContinuation { controlWaiter = $0 } } }
    static func challenge() -> Data { json(["type": "account-route-bind-challenge", "nonce": Data(repeating: 8, count: 32).base64EncodedString(), "expiresAt": Int64(Date().timeIntervalSince1970 * 1000) + 10000]) }
    var frames: [Data] = []
    var incoming: [Data]
    var receiver: CheckedContinuation<Data, Error>?
    var sender: CheckedContinuation<Void, Error>?
    var delayedSends: [CheckedContinuation<Void, Never>] = []
    func releaseOneSend() { if !delayedSends.isEmpty { delayedSends.removeFirst().resume() } }
    func releaseAllSends() { while !delayedSends.isEmpty { delayedSends.removeFirst().resume() } }
    var closed = false
    init(identity: DeviceIdentity) {
        incoming = [Self.json(["type": "challenge", "nonce": Data(repeating: 1, count: 32).base64EncodedString(), "expiresAt": 9999999999999]),
                    Self.json(["type": "auth-ok", "deviceID": identity.id.rawValue.uuidString.lowercased()])]
    }
    static func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
    func send(_ data: Data) async throws {
        frames.append(data)
        let frame = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        switch frame["type"] as? String {
        case "account-route-bind-challenge":
            controlSent = true; controlWaiter?.resume(); controlWaiter = nil
            switch mode {
            case .silent: break
            case .blockedSend: try await withCheckedThrowingContinuation { sender = $0 }
            case .receiveFailure: await close()
            case .unsupported: push(Self.json(["type": "protocol-error", "code": "unknown_frame"]))
            case .earlyAck: push(Self.json(["type": "account-route-bind-ok"]))
            case .sendFailure: throw AuthenticatedPresenceError.transport("synthetic-token")
            case .rejected: push(Self.json(["type": "account-route-bind-error", "code": "synthetic-token"]))
            case .expired: push(Self.json(["type": "account-route-bind-challenge", "nonce": Data(repeating: 8, count: 32).base64EncodedString(), "expiresAt": 1]))
            case .badNonce: push(Self.json(["type": "account-route-bind-challenge", "nonce": "AA==", "expiresAt": Int64(Date().timeIntervalSince1970 * 1000) + 10000]))
            case .extraField: push(Self.json(["type": "account-route-bind-challenge", "nonce": Data(repeating: 8, count: 32).base64EncodedString(), "expiresAt": Int64(Date().timeIntervalSince1970 * 1000) + 10000, "extra": true]))
            default: push(Self.challenge())
            }
        case "account-route-bind": push(Self.json(["type": mode == .wrongAck ? "account-route-unbind-ok" : "account-route-bind-ok"]))
        case "account-route-unbind": if mode != .silent { push(Self.json(["type": "account-route-unbind-ok"])) }
        default: break
        }
        if mode == .delayedSend, (frame["type"] as? String)?.hasPrefix("account-route-") == true {
            await withCheckedContinuation { delayedSends.append($0) }
        }
    }
    func push(_ data: Data) { if let receiver { self.receiver = nil; receiver.resume(returning: data) } else { incoming.append(data) } }
    func receive() async throws -> Data {
        if closed { throw AuthenticatedPresenceError.transport("closed") }
        if !incoming.isEmpty { return incoming.removeFirst() }
        XCTAssertNil(receiver, "a second socket reader is forbidden")
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func ping() async throws {}
    func close() async {
        closed = true
        receiver?.resume(throwing: AuthenticatedPresenceError.transport("closed")); receiver = nil
        sender?.resume(throwing: AuthenticatedPresenceError.transport("closed")); sender = nil
    }
}
