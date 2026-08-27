import CryptoKit
import Foundation
import XCTest
@testable import MacChannelCore

final class RendezvousTURNCredentialClientTests: XCTestCase {
    func testFetchSignsCanonicalAuthenticatedRequestAndBuildsICEConfiguration() async throws {
        let identity = try DeviceIdentity.ephemeral()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let protocolType = TURNClientURLProtocol.self
        protocolType.reset()
        protocolType.response = """
        {"credential":"secret","expiresAt":"2027-01-15T08:10:00Z","urls":["stun:localhost:3478","turn:localhost:3478?transport=udp","turns:localhost:5349?transport=tcp"],"username":"1800000600:opaque-handle"}
        """.data(using: .utf8)!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolType]
        let session = URLSession(configuration: configuration)
        let client = try RendezvousTURNCredentialClient(
            identity: identity,
            origin: URL(string: "http://rendezvous.test")!,
            session: session,
            now: { now },
            allowInsecureForTesting: true
        )

        let credentials = try await client.fetch()

        let request = try XCTUnwrap(protocolType.lastRequest)
        XCTAssertEqual(request.url?.path, "/v1/turn-credentials")
        XCTAssertEqual(request.httpMethod, "GET")
        let envelope = try JSONDecoder().decode(
            RendezvousSignedEnvelope.self,
            from: try XCTUnwrap(protocolType.lastBody)
        )
        XCTAssertEqual(envelope.deviceID, identity.id.rawValue.uuidString.lowercased())
        XCTAssertEqual(envelope.payload, Data("{\"type\":\"turn-credentials-v1\"}".utf8))
        let signature = try P256.Signing.ECDSASignature(derRepresentation: envelope.signature)
        XCTAssertTrue(
            identity.publicKey.isValidSignature(
                signature,
                for: try envelope.canonicalPayload()
            )
        )
        XCTAssertEqual(credentials.iceConfiguration.stunURLs, ["stun:localhost:3478"])
        XCTAssertEqual(
            credentials.iceConfiguration.turnServers,
            [TURNServer(
                urls: [
                    "turn:localhost:3478?transport=udp",
                    "turns:localhost:5349?transport=tcp",
                ],
                username: "1800000600:opaque-handle",
                credential: "secret"
            )]
        )
        XCTAssertTrue(credentials.isUsable(at: now))
    }

    func testRejectsCredentialExpiryBeyondTenMinuteContract() async throws {
        let identity = try DeviceIdentity.ephemeral()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        TURNClientURLProtocol.reset()
        TURNClientURLProtocol.response = """
        {"credential":"secret","expiresAt":"2027-01-15T08:11:01Z","urls":["turn:localhost:3478"],"username":"1800000661:opaque"}
        """.data(using: .utf8)!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TURNClientURLProtocol.self]
        let client = try RendezvousTURNCredentialClient(
            identity: identity,
            origin: URL(string: "http://rendezvous.test")!,
            session: URLSession(configuration: configuration),
            now: { now },
            allowInsecureForTesting: true
        )

        do {
            _ = try await client.fetch()
            XCTFail("Expected an overlong credential to be rejected")
        } catch {
            XCTAssertEqual(error as? RendezvousTURNClientError, .invalidResponse)
        }
    }
}

private final class TURNClientURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var response = Data()
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    static func reset() {
        response = Data()
        lastRequest = nil
        lastBody = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? request.httpBodyStream.flatMap { stream in
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            return body
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.response)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
