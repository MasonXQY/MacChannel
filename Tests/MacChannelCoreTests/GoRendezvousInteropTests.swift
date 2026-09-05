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
            allowInsecureForTesting: true
        )
        let joiningPairingTransport = try RendezvousPairingTransport(
            identity: joiningIdentity,
            origin: httpOrigin,
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
            allowInsecureForTesting: true
        )
        let rejectedJoinerTransport = try RendezvousPairingTransport(
            identity: rejectedJoinerIdentity,
            origin: httpOrigin,
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

    init(url: URL) {
        session = URLSession(configuration: .ephemeral)
        task = session.webSocketTask(with: url, protocols: [AuthenticatedPresenceSession.subprotocol])
        task.resume()
    }

    func send(_ data: Data) async throws { try await task.send(.data(data)) }
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
        switch try await task.receive() {
        case let .data(data): data
        case let .string(text): Data(text.utf8)
        @unknown default: throw AuthenticatedPresenceError.invalidFrame
        }
    }
    func close() async {
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }
}
