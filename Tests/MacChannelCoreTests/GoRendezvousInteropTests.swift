import CryptoKit
import Foundation
import XCTest
@testable import MacChannelCore

final class GoRendezvousInteropTests: XCTestCase {
    func testLiveSwiftPairingHTTPAndWebSocketAuthenticationAgainstGoRouter() async throws {
        guard let rawURL = ProcessInfo.processInfo.environment["MACCHANNEL_GO_TEST_SERVER_URL"],
              let httpOrigin = URL(string: rawURL)
        else {
            throw XCTSkip("The Go httptest wrapper supplies the live server URL")
        }
        let identity = try DeviceIdentity.ephemeral()
        let transport = try RendezvousPairingTransport(
            identity: identity,
            origin: httpOrigin,
            session: URLSession(configuration: .ephemeral),
            allowInsecureForTesting: true
        )
        let _: any BilateralPairingTransport = transport
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let offer = PairingOffer(
            code: "426135",
            expiresAt: Date().addingTimeInterval(60),
            hostID: identity.id,
            hostIdentityPublicKey: identity.publicKey.rawRepresentation,
            hostEphemeralPublicKey: ephemeral.publicKey.rawRepresentation,
            hostDisplayName: "Swift 集成测试"
        )
        let hostEndpoint = IntegrationPairingEndpoint()
        try await transport.publish(offer, endpoint: hostEndpoint)
        let joinerIdentity = try DeviceIdentity.ephemeral()
        let joinerTransport = try RendezvousPairingTransport(
            identity: joinerIdentity,
            origin: httpOrigin,
            session: URLSession(configuration: .ephemeral),
            allowInsecureForTesting: true
        )
        let lookedUp = try await joinerTransport.lookup(code: offer.code)
        XCTAssertEqual(lookedUp.hostID, identity.id)
        let joinResponse = try await joinerTransport.submit(
            code: offer.code,
            request: PairingJoinRequest(
                code: offer.code,
                joiningID: joinerIdentity.id,
                joiningIdentityPublicKey: joinerIdentity.publicKey.rawRepresentation,
                joiningEphemeralPublicKey: P256.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                joiningDisplayName: "Swift 加入端",
                identitySignature: Data([1, 2, 3]),
                channelTag: Data([4, 5, 6])
            )
        )
        XCTAssertEqual(joinResponse.hostIdentitySignature, Data([7, 8, 9]))
        XCTAssertEqual(joinResponse.channelTag, Data([10, 11, 12]))
        let acceptedJoiningID = await hostEndpoint.acceptedJoiningID()
        XCTAssertEqual(acceptedJoiningID, joinerIdentity.id)

        let hostAuthorization = try SignedTrustRecord.authorizing(
            joinerIdentity,
            signedBy: identity
        )
        let reservation = try await transport.reserveAuthorizationDelivery(
            for: joinResponse.sessionID
        )
        try await transport.deliverAuthorization(
            PairingAuthorizationEnvelope(
                sessionID: joinResponse.sessionID,
                authorization: hostAuthorization,
                channelTag: Data([13, 14, 15])
            ),
            reservation: reservation
        )
        let receivedHostAuthorization = try await joinerTransport.authorization(
            for: joinResponse.sessionID
        )
        XCTAssertEqual(receivedHostAuthorization.authorization.signature, hostAuthorization.signature)

        let joinerAuthorization = try SignedTrustRecord.authorizing(
            identity,
            signedBy: joinerIdentity
        )
        let joinerDelivery = Task {
            try await joinerTransport.deliverPeerAuthorization(
                PairingAuthorizationEnvelope(
                    sessionID: joinResponse.sessionID,
                    authorization: joinerAuthorization,
                    channelTag: Data([16, 17, 18])
                )
            )
        }
        let receivedJoinerAuthorization = try await transport.peerAuthorization(
            for: joinResponse.sessionID
        )
        XCTAssertEqual(
            receivedJoinerAuthorization.authorization.signature,
            joinerAuthorization.signature
        )
        try await transport.resolvePeerAuthorization(for: joinResponse.sessionID, accepted: true)
        try await joinerDelivery.value
        await joinerTransport.stop()

        var components = try XCTUnwrap(URLComponents(url: httpOrigin, resolvingAgainstBaseURL: false))
        components.scheme = "ws"
        components.path = "/v1/ws"
        let webSocketURL = try XCTUnwrap(components.url)
        let socket = IntegrationPresenceWebSocket(url: webSocketURL)
        let session = try AuthenticatedPresenceSession(
            identity: identity,
            origin: webSocketURL,
            socket: socket,
            client: PresenceClient(directory: DeviceDirectory(trust: .allowing(identity.id))),
            allowInsecureForTesting: true
        )
        try await session.connect()
        try await socket.ping()
        await session.stop()
        await transport.stop()

        let hostIdentity = try DeviceIdentity.ephemeral()
        let joiningIdentity = try DeviceIdentity.ephemeral()
        let hostRepository = try TrustRepository(
            ownerIdentity: hostIdentity,
            trustStore: TrustStore(owner: hostIdentity.id),
            persistedGeneration: 0
        )
        let joiningRepository = try TrustRepository(
            ownerIdentity: joiningIdentity,
            trustStore: TrustStore(owner: joiningIdentity.id),
            persistedGeneration: 0
        )
        _ = try await joiningRepository.issueAuthorization(
            subject: hostIdentity.id,
            subjectPublicKey: hostIdentity.publicKey.rawRepresentation,
            timestamp: Date().addingTimeInterval(-2)
        )
        _ = try await joiningRepository.revoke(hostIdentity.id)

        let hostPairingTransport = try RendezvousPairingTransport(
            identity: hostIdentity,
            origin: httpOrigin,
            session: URLSession(configuration: .ephemeral),
            allowInsecureForTesting: true
        )
        let joiningPairingTransport = try RendezvousPairingTransport(
            identity: joiningIdentity,
            origin: httpOrigin,
            session: URLSession(configuration: .ephemeral),
            allowInsecureForTesting: true
        )
        let hostCoordinator = try PairingCoordinator(
            identity: hostIdentity,
            displayName: "Host after revocation",
            trustRepository: hostRepository,
            transport: hostPairingTransport
        )
        let joiningCoordinator = try PairingCoordinator(
            identity: joiningIdentity,
            displayName: "Joiner after revocation",
            trustRepository: joiningRepository,
            transport: joiningPairingTransport
        )
        let pairingCode = try await hostCoordinator.createCode()
        _ = try await joiningCoordinator.join(code: pairingCode)
        let joiningCompletion = Task {
            try await joiningCoordinator.awaitHostApproval()
        }
        _ = try await hostCoordinator.approvePendingPairing()
        _ = try await joiningCompletion.value

        let hostTrustsJoiner = await hostCoordinator.isTrusted(joiningIdentity.id)
        let joinerTrustsHost = await joiningCoordinator.isTrusted(hostIdentity.id)
        XCTAssertTrue(hostTrustsJoiner)
        XCTAssertTrue(joinerTrustsHost)
        let joiningRecords = await joiningRepository.authenticationRecords()
        XCTAssertTrue(joiningRecords.contains {
            $0.action == .authorize && $0.issuer == joiningIdentity.id
                && $0.subject == hostIdentity.id && $0.issuerSequence == 3
        })
        await joiningPairingTransport.stop()
        await hostPairingTransport.stop()

        let rejectingHostIdentity = try DeviceIdentity.ephemeral()
        let rejectedJoinerIdentity = try DeviceIdentity.ephemeral()
        let rejectingHostTransport = try RendezvousPairingTransport(
            identity: rejectingHostIdentity,
            origin: httpOrigin,
            session: URLSession(configuration: .ephemeral),
            allowInsecureForTesting: true
        )
        let rejectedJoinerTransport = try RendezvousPairingTransport(
            identity: rejectedJoinerIdentity,
            origin: httpOrigin,
            session: URLSession(configuration: .ephemeral),
            allowInsecureForTesting: true
        )
        let rejectingHost = try PairingCoordinator(
            identity: rejectingHostIdentity,
            trustRepository: TrustRepository(
                ownerIdentity: rejectingHostIdentity,
                trustStore: TrustStore(owner: rejectingHostIdentity.id),
                persistedGeneration: 0
            ),
            transport: rejectingHostTransport
        )
        let rejectedJoiner = try PairingCoordinator(
            identity: rejectedJoinerIdentity,
            trustRepository: TrustRepository(
                ownerIdentity: rejectedJoinerIdentity,
                trustStore: TrustStore(owner: rejectedJoinerIdentity.id),
                persistedGeneration: 0
            ),
            transport: rejectedJoinerTransport
        )
        let rejectedCode = try await rejectingHost.createCode()
        let rejectedJoin = try await rejectedJoiner.join(code: rejectedCode)
        try await rejectingHost.rejectPendingPairing()
        do {
            _ = try await rejectedJoiner.confirmFingerprint(rejectedJoin.fingerprint)
            XCTFail("Rejected public pairing must fail immediately")
        } catch {
            XCTAssertEqual(error as? PairingError, .authorizationRejected)
        }
        await rejectedJoinerTransport.stop()
        await rejectingHostTransport.stop()

        try await verifySharedOwners(webSocketURL: webSocketURL)
    }

    private func verifySharedOwners(webSocketURL: URL) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstIdentity = try DeviceIdentity.ephemeral()
        let secondIdentity = try DeviceIdentity.ephemeral()
        let a = try SignedTrustRecord.authorizing(secondIdentity, signedBy: firstIdentity)
        let b = try SignedTrustRecord.authorizing(firstIdentity, signedBy: secondIdentity)
        let first = try await IntegrationOwner(identity: firstIdentity, local: a, peer: b,
            root: root.appendingPathComponent("first.json"), socketURL: webSocketURL)
        let second = try await IntegrationOwner(identity: secondIdentity, local: b, peer: a,
            root: root.appendingPathComponent("second.json"), socketURL: webSocketURL)
        XCTAssertNotEqual(first.identity.id, second.identity.id)
        let firstSignals = await first.owner.bridge.signalFrames()
        let secondSignals = await second.owner.bridge.signalFrames()
        let firstErrors = await first.owner.bridge.protocolErrors()
        let secondErrors = await second.owner.bridge.protocolErrors()
        let firstDevices = await first.directory.devices()
        let secondDevices = await second.directory.devices()
        let observations = IntegrationObservations()
        let observers = [
            Task { for await value in firstSignals { await observations.signal(value, side: 0) } },
            Task { for await value in secondSignals { await observations.signal(value, side: 1) } },
            Task { for await value in firstErrors { await observations.error(value, side: 0) } },
            Task { for await value in secondErrors { await observations.error(value, side: 1) } },
            Task { for await value in firstDevices { await observations.devices(value, side: 0) } },
            Task { for await value in secondDevices { await observations.devices(value, side: 1) } }
        ]
        // Streams and bounded recorders exist before start, publication, or sends.
        var stage = "identity-only authentication"
        do {
            await first.owner.start()
            await second.owner.start()
            try await integrationEventually("identity-only connections") {
                let a = await first.owner.state
                let b = await second.owner.state
                return a == .online && b == .online
            }
            await first.owner.refreshTrust()
            await second.owner.refreshTrust()
            try await integrationEventually("unsaved proofs withheld") {
                let a = await first.owner.trustSyncState
                let b = await second.owner.trustSyncState
                return a == .pendingPersistence && b == .pendingPersistence
            }
            XCTAssertEqual(first.factory.sentRecords, [])
            XCTAssertEqual(second.factory.sentRecords, [])
            try await first.store.persistLatest(from: first.repository)
            try await second.store.persistLatest(from: second.repository)
            await first.owner.refreshTrust()
            await second.owner.refreshTrust()
            try await integrationEventually("real bilateral trust acknowledgments and fresh presence") {
                let a = await first.owner.trustSyncState
                let b = await second.owner.trustSyncState
                let visible = await observations.visible(first: first.identity.id, second: second.identity.id)
                return a == .synchronized && b == .synchronized && visible
            }
            XCTAssertEqual(Set(first.factory.sentRecords), Set([a, b]))
            XCTAssertEqual(Set(second.factory.sentRecords), Set([a, b]))
            XCTAssertEqual(first.factory.acceptedCount, 2)
            XCTAssertEqual(second.factory.acceptedCount, 2)
            stage = "bilateral signal delivery"
            let outbound = Data("synthetic shared-owner first → second\u{0}payload".utf8)
            let inbound = Data("synthetic shared-owner second → first\u{0}payload".utf8)
            try await first.owner.bridge.sendSignal(outbound, to: second.identity.id)
            try await second.owner.bridge.sendSignal(inbound, to: first.identity.id)
            try await integrationEventually("both exact bridge payloads") {
                await observations.hasSignals(first: RendezvousSignalFrame(from: second.identity.id, payload: inbound),
                    second: RendezvousSignalFrame(from: first.identity.id, payload: outbound))
            }
            stage = "revocation persistence and acknowledgment"
            let revocation = try await first.repository.revoke(second.identity.id)
            await first.owner.refreshTrust()
            try await integrationEventually("revocation requires a durable receipt") {
                await first.owner.trustSyncState == .pendingPersistence
            }
            XCTAssertFalse(first.factory.sentRecords.contains(revocation))
            try await first.store.persistLatest(from: first.repository)
            let publication = await first.repository.publicationSnapshot(persisted: first.store.persistedState())
            XCTAssertEqual(publication.records, [revocation])
            XCTAssertFalse(publication.pendingPersistence)
            await first.owner.refreshTrust()
            try await integrationEventually("real revocation acknowledgment") {
                let state = await first.owner.trustSyncState
                return state == .synchronized && first.factory.acceptedCount == 3
            }
            XCTAssertEqual(Set(first.factory.sentRecords), Set([a, b, revocation]))
            stage = "received peer withdrawal durable catch-up"
            try await integrationEventually("peer withdrawal ingested without retiring identity") {
                let trust = await second.repository.currentTrustStore()
                return trust.isTrusted(second.identity.id) && !trust.isTrusted(first.identity.id)
            }
            let secondState = await second.owner.state
            XCTAssertEqual(secondState, .online)
            let pendingWithdrawal = await second.repository.publicationSnapshot(persisted: second.store.persistedState())
            XCTAssertTrue(pendingWithdrawal.records.isEmpty)
            XCTAssertTrue(pendingWithdrawal.pendingPersistence)
            // This fixture has no app persistence observer. Exercise its real
            // checkpoint explicitly, retaining the received signature verbatim.
            try await second.store.persistLatest(from: second.repository)
            await second.owner.refreshTrust()
            try await integrationEventually("received withdrawal saved without unauthorized publication") {
                let state = await second.owner.trustSyncState
                return state == .synchronized
            }
            let restoredSecond = try await second.store.load(identity: second.identity)
            let restoredTrust = await restoredSecond.currentTrustStore()
            let restoredProofs = await restoredSecond.authenticationRecords()
            XCTAssertEqual(restoredTrust.trustedDeviceIDs, [second.identity.id])
            XCTAssertTrue(restoredProofs.isEmpty)
            let retainedSecond = await second.store.persistedState()
            XCTAssertEqual(retainedSecond?.authenticationRecords, [revocation])
            XCTAssertEqual(Set(second.factory.sentRecords), Set([a, b]))
            XCTAssertEqual(second.factory.acceptedCount, 2, "A subject must not publish a peer-issued revoke")
            // AuthenticatedPresenceSession sends through Go; no raw protocol or
            // local trust filter substitutes for the server's routing decision.
            stage = "first post-revocation bridge send"
            try await first.owner.bridge.sendSignal(Data("post-revocation first".utf8), to: second.identity.id)
            stage = "first Go forbidden response"
            try await integrationEventually("first Go forbidden response") {
                await observations.firstForbidden(device: second.identity.id)
            }
            stage = "second post-revocation bridge send"
            try await second.owner.bridge.sendSignal(Data("post-revocation second".utf8), to: first.identity.id)
            stage = "post-revocation rejection observation"
            try await integrationEventually("Go rejects both former routes") {
                await observations.hasForbidden(first: second.identity.id, second: first.identity.id)
            }
            XCTAssertEqual(first.factory.count, 1)
            XCTAssertEqual(second.factory.count, 1)
        } catch {
            let states = await [first.owner.state, second.owner.state]
            XCTFail("Live integration failed during \(stage); states=\(states); first=\(first.factory.frameTypes); second=\(second.factory.frameTypes)")
            await stopIntegration(first, second, observers: observers)
            throw error
        }
        await stopIntegration(first, second, observers: observers)
        let receivedCounts = await observations.signalCounts
        XCTAssertEqual(receivedCounts, [1, 1], "No post-revocation payload reached either bridge")
        XCTAssertEqual(first.factory.receivedSignalCount, 1, "No post-revocation frame reached the first socket")
        XCTAssertEqual(second.factory.receivedSignalCount, 1, "No post-revocation frame reached the second socket")
        for fixture in [first, second] {
            XCTAssertEqual(fixture.factory.authenticationRecordCounts, [0])
            XCTAssertEqual(fixture.factory.count, 1, "Acknowledgments must not replace the socket owner")
            XCTAssertTrue(fixture.factory.closed)
            XCTAssertFalse(fixture.factory.overflow)
            let state = await fixture.owner.state
            XCTAssertEqual(state, .stopped)
        }
        let overflow = await observations.overflow
        XCTAssertFalse(overflow)
    }

    private func stopIntegration(_ first: IntegrationOwner, _ second: IntegrationOwner,
                                 observers: [Task<Void, Never>]) async {
        async let a: Void = first.owner.stop()
        async let b: Void = second.owner.stop()
        _ = await (a, b)
        for observer in observers { observer.cancel() }
        for observer in observers { await observer.value }
        for fixture in [first, second] {
            let state = await fixture.owner.state
            XCTAssertEqual(state, .stopped, "Failure cleanup must also join both owners")
            XCTAssertTrue(fixture.factory.closed)
        }
    }

    private func integrationEventually(_ description: String,
        _ condition: @escaping @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for \(description)")
        throw CancellationError()
    }
}

private struct IntegrationOwner: Sendable {
    let identity: DeviceIdentity
    let repository: TrustRepository
    let directory: DeviceDirectory
    let store: AuthenticatedTrustSnapshotStore<IntegrationSecrets>
    let factory: IntegrationSocketRecorder
    let owner: AuthenticatedPresenceSupervisor

    init(identity: DeviceIdentity, local: SignedTrustRecord, peer: SignedTrustRecord,
         root: URL, socketURL: URL) async throws {
        self.identity = identity
        let repository = try TrustRepository(ownerIdentity: identity,
            trustStore: TrustStore(owner: identity.id), persistedGeneration: 0)
        self.repository = repository
        try await repository.commitBilateralPairing(localAuthorization: local, peerAuthorization: peer)
        let store = AuthenticatedTrustSnapshotStore(url: root, secrets: IntegrationSecrets())
        self.store = store
        // A fresh directory from verified local trust, with no online sightings.
        // Proofs remain unsaved and cannot enter the identity-only handshake.
        directory = DeviceDirectory(trust: await repository.currentTrustStore())
        let factory = IntegrationSocketRecorder(url: socketURL)
        self.factory = factory
        owner = AuthenticatedPresenceSupervisor(identity: identity, repository: repository,
            directory: directory, origin: URL(string: "wss://fixture.invalid/v1/ws")!,
            makeSocket: { try factory.make() }, sleep: { try await Task.sleep(for: $0) },
            publication: { await repository.publicationSnapshot(persisted: store.persistedState()) },
            persistedUpdates: { await store.persistedUpdates() })
    }
}

private final class IntegrationSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func data(for account: String, policy: KeychainPolicy) throws -> Data? {
        lock.withLock { values[account] }
    }
    func store(_ data: Data, for account: String, policy: KeychainPolicy) throws {
        lock.withLock { values[account] = data }
    }
}

/// Records bounded real wire traffic without altering it or introducing a reader.
private final class IntegrationSocketRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var attempts = 0
    private var sent: [Data] = []
    private var received: [Data] = []
    private var didClose = false
    private var didOverflow = false
    init(url: URL) { self.url = url }
    var count: Int { lock.withLock { attempts } }
    var closed: Bool { lock.withLock { didClose } }
    var overflow: Bool { lock.withLock { didOverflow } }
    var frameTypes: [String] { lock.withLock { received.map { Self.object($0)?["type"] as? String ?? "invalid" } } }
    var authenticationRecordCounts: [Int] {
        lock.withLock { sent.compactMap { data in
            guard let frame = Self.object(data), frame["envelope"] != nil else { return nil }
            return (frame["trustRecords"] as? [Any])?.count ?? -1
        } }
    }
    var sentRecords: [SignedTrustRecord] {
        struct Update: Decodable { let trustRecords: [SignedTrustRecord] }
        return lock.withLock { sent.filter { Self.object($0)?["type"] as? String == "trust-update" }
            .flatMap { (try? JSONDecoder().decode(Update.self, from: $0).trustRecords) ?? [] } }
    }
    var acceptedCount: Int { lock.withLock { received.filter { Self.object($0)?["type"] as? String == "trust-ok" }.count } }
    var receivedSignalCount: Int { lock.withLock { received.filter { Self.object($0)?["type"] as? String == "signal" }.count } }
    func make() throws -> any PresenceWebSocket {
        try lock.withLock {
            attempts += 1
            guard attempts == 1 else { throw CancellationError() }
            return IntegrationPresenceWebSocket(url: url, recorder: self)
        }
    }
    func record(_ data: Data, incoming: Bool) {
        lock.withLock {
            if incoming {
                if received.count < 64 { received.append(data) } else { didOverflow = true }
            } else {
                if sent.count < 64 { sent.append(data) } else { didOverflow = true }
            }
        }
    }
    func recordClose() { lock.withLock { didClose = true } }
    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

private actor IntegrationObservations {
    private var signals: [[RendezvousSignalFrame]] = [[], []]
    private var errors: [[RendezvousProtocolError]] = [[], []]
    private var latestDevices: [[DeviceSummary]] = [[], []]
    var overflow = false
    var signalCounts: [Int] { signals.map(\.count) }
    func signal(_ value: RendezvousSignalFrame, side: Int) {
        guard signals[side].count < 8 else { overflow = true; return }
        signals[side].append(value)
    }
    func error(_ value: RendezvousProtocolError, side: Int) {
        guard errors[side].count < 8 else { overflow = true; return }
        errors[side].append(value)
    }
    func devices(_ value: [DeviceSummary], side: Int) { latestDevices[side] = value }
    func visible(first: DeviceID, second: DeviceID) -> Bool {
        latestDevices[0].contains { $0.id == second && $0.availability == .internet }
            && latestDevices[1].contains { $0.id == first && $0.availability == .internet }
    }
    func hasSignals(first: RendezvousSignalFrame, second: RendezvousSignalFrame) -> Bool {
        signals == [[first], [second]]
    }
    func hasForbidden(first: DeviceID, second: DeviceID) -> Bool {
        errors == [[RendezvousProtocolError(code: "forbidden", device: first)],
                   [RendezvousProtocolError(code: "forbidden", device: second)]]
    }
    func firstForbidden(device: DeviceID) -> Bool {
        errors[0] == [RendezvousProtocolError(code: "forbidden", device: device)]
    }
}

private actor IntegrationPairingEndpoint: RendezvousPairingHostEndpoint {
    private var joiningID: DeviceID?

    func accept(_ request: PairingJoinRequest) async throws -> PairingJoinResponse {
        throw PairingError.invalidHandshake
    }

    func accept(
        _ request: PairingJoinRequest,
        sessionID: PairingSessionID
    ) async throws -> PairingJoinResponse {
        joiningID = request.joiningID
        return PairingJoinResponse(
            sessionID: sessionID,
            hostIdentitySignature: Data([7, 8, 9]),
            channelTag: Data([10, 11, 12])
        )
    }

    func acceptedJoiningID() -> DeviceID? { joiningID }
}

private final class IntegrationPresenceWebSocket: PresenceWebSocket, @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private let recorder: IntegrationSocketRecorder?

    init(url: URL, recorder: IntegrationSocketRecorder? = nil) {
        self.recorder = recorder
        session = URLSession(configuration: .ephemeral)
        task = session.webSocketTask(with: url, protocols: [AuthenticatedPresenceSession.subprotocol])
        task.resume()
    }

    func send(_ data: Data) async throws {
        recorder?.record(data, incoming: false)
        try await task.send(.data(data))
    }
    func ping() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            task.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
    func receive() async throws -> Data {
        let data: Data = switch try await task.receive() {
        case let .data(data): data
        case let .string(text): Data(text.utf8)
        @unknown default: throw AuthenticatedPresenceError.invalidFrame
        }
        recorder?.record(data, incoming: true)
        return data
    }
    func close() async {
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
        recorder?.recordClose()
    }
}
