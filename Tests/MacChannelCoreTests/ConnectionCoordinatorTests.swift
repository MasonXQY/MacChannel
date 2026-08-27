import Foundation
import XCTest
@testable import MacChannelCore

final class ConnectionCoordinatorTests: XCTestCase {
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
    private(set) var streamRequests = 0
    private var sent: [(Data, DeviceID)] = []

    init() {
        var continuation: AsyncStream<RendezvousSignalFrame>.Continuation!
        stream = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func signalFrames() -> AsyncStream<RendezvousSignalFrame> {
        streamRequests += 1
        return stream
    }

    func sendSignal(_ payload: Data, to device: DeviceID) async throws {
        sent.append((payload, device))
    }

    func deliver(_ frame: RendezvousSignalFrame) { continuation.yield(frame) }
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
