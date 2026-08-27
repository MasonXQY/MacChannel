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
        XCTAssertEqual(request.httpMethod, "POST")
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
            [
                TURNServer(
                    urls: [
                        "turn:localhost:3478?transport=udp",
                        "turns:localhost:5349?transport=tcp",
                    ],
                    username: "1800000600:opaque-handle",
                    credential: "secret"
                )
            ]
        )
        XCTAssertTrue(credentials.isUsable(at: now))
    }

    func testRejectsCredentialExpiryBeyondTenMinuteContract() async throws {
        let identity = try DeviceIdentity.ephemeral()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        TURNClientURLProtocol.reset()
        TURNClientURLProtocol.response = """
            {"credential":"secret","expiresAt":"2027-01-15T08:11:01Z","urls":["turn:localhost:3478?transport=udp"],"username":"1800000661:opaque"}
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

    func testMapsAuthenticationAvailabilityAndNonHTTPResponses() async throws {
        let statuses: [(Int, RendezvousTURNClientError)] = [
            (401, .authenticationRejected),
            (403, .authenticationRejected),
            (503, .unavailable),
        ]
        for (status, expected) in statuses {
            let client = try makeClient(statusCode: status, response: Data())
            do {
                _ = try await client.fetch()
                XCTFail("Expected HTTP \(status) to fail")
            } catch {
                XCTAssertEqual(error as? RendezvousTURNClientError, expected)
            }
        }

        TURNClientURLProtocol.transportError = URLError(.notConnectedToInternet)
        let transport = try makeClient(statusCode: 200, response: Data())
        TURNClientURLProtocol.transportError = URLError(.notConnectedToInternet)
        do {
            _ = try await transport.fetch()
            XCTFail("Expected transport failure")
        } catch {
            XCTAssertEqual(error as? RendezvousTURNClientError, .transport)
        }

        let nonHTTP = try makeClient(statusCode: nil, response: Data())
        do {
            _ = try await nonHTTP.fetch()
            XCTFail("Expected a non-HTTP response to fail")
        } catch {
            XCTAssertEqual(error as? RendezvousTURNClientError, .invalidResponse)
        }
    }

    func testRejectsOversizedBodiesFieldsAndTooManyURLs() async throws {
        let valid = validResponse()
        let malformed: [Data] = [
            Data(repeating: 0x20, count: 65_537),
            response(
                urls: (0..<9).map { "turn:turn\($0).test:3478?transport=udp" },
                username: "1800000600:opaque",
                credential: "secret"
            ),
            response(
                urls: ["turn:turn.test:3478?transport=udp"],
                username: "1800000600:" + String(repeating: "a", count: 257),
                credential: "secret"
            ),
            response(
                urls: ["turn:turn.test:3478?transport=udp"],
                username: "1800000600:opaque",
                credential: String(repeating: "s", count: 513)
            ),
        ]
        XCTAssertFalse(valid.isEmpty)
        for body in malformed {
            let client = try makeClient(statusCode: 200, response: body)
            do {
                _ = try await client.fetch()
                XCTFail("Expected oversized response to fail")
            } catch {
                XCTAssertEqual(error as? RendezvousTURNClientError, .invalidResponse)
            }
        }
    }

    func testStrictlyParsesTURNHostPortAndTransport() async throws {
        let malformedURLs = [
            "turn::3478?transport=udp",
            "turn:turn.test?transport=udp",
            "turn:turn.test:0?transport=udp",
            "turn:turn.test:70000?transport=udp",
            "turn:turn.test:3478",
            "turn:turn.test:3478?transport=tls",
            "turn:turn.test:3478?transport=udp&token=secret",
            "turns:turn.test:5349?transport=udp",
            "turn://user:secret@turn.test:3478?transport=udp",
            "turn:turn test:3478?transport=udp",
            "turn:-turn.test:3478?transport=udp",
            "turn:turn-.test:3478?transport=udp",
            "turn:turn..test:3478?transport=udp",
            "turn:[:::]:3478?transport=udp",
            "turn:[1:2:3]:3478?transport=udp",
            "turn:[::ffff::1]:3478?transport=udp",
        ]
        for url in malformedURLs {
            let client = try makeClient(
                statusCode: 200,
                response: response(
                    urls: [url],
                    username: "1800000600:opaque",
                    credential: "secret"
                )
            )
            do {
                _ = try await client.fetch()
                XCTFail("Expected malformed TURN URL to fail: \(url)")
            } catch {
                XCTAssertEqual(error as? RendezvousTURNClientError, .invalidResponse)
            }
        }
    }

    func testAcceptsOnlySyntacticallyValidIPv6Literals() async throws {
        let client = try makeClient(
            statusCode: 200,
            response: response(
                urls: [
                    "turn:[::1]:3478?transport=udp",
                    "turns:[2001:db8::1]:5349?transport=tcp",
                ],
                username: "1800000600:opaque",
                credential: "secret"
            )
        )

        let credentials = try await client.fetch()

        XCTAssertEqual(credentials.urls.count, 2)
    }

    private func makeClient(
        statusCode: Int?,
        response: Data
    ) throws -> RendezvousTURNCredentialClient {
        TURNClientURLProtocol.reset()
        TURNClientURLProtocol.statusCode = statusCode
        TURNClientURLProtocol.response = response
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TURNClientURLProtocol.self]
        return try RendezvousTURNCredentialClient(
            identity: DeviceIdentity.ephemeral(),
            origin: URL(string: "http://rendezvous.test")!,
            session: URLSession(configuration: configuration),
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            allowInsecureForTesting: true
        )
    }

    private func validResponse() -> Data {
        response(
            urls: ["turn:turn.test:3478?transport=udp"],
            username: "1800000600:opaque",
            credential: "secret"
        )
    }

    private func response(urls: [String], username: String, credential: String) -> Data {
        try! JSONSerialization.data(
            withJSONObject: [
                "urls": urls,
                "username": username,
                "credential": credential,
                "expiresAt": "2027-01-15T08:10:00Z",
            ], options: [.sortedKeys])
    }
}

private final class TURNClientURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var response = Data()
    nonisolated(unsafe) static var statusCode: Int? = 200
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?
    nonisolated(unsafe) static var transportError: Error?

    static func reset() {
        response = Data()
        statusCode = 200
        lastRequest = nil
        lastBody = nil
        transportError = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let transportError = Self.transportError {
            client?.urlProtocol(self, didFailWithError: transportError)
            return
        }
        Self.lastRequest = request
        Self.lastBody =
            request.httpBody
            ?? request.httpBodyStream.flatMap { stream in
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
        let response: URLResponse
        if let statusCode = Self.statusCode {
            response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
        } else {
            response = URLResponse(
                url: request.url!,
                mimeType: "application/json",
                expectedContentLength: Self.response.count,
                textEncodingName: nil
            )
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.response)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
