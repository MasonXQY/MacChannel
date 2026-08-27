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
        await session.stop()
        await transport.stop()
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
