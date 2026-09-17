import CryptoKit
import Foundation
import XCTest

@testable import MacChannelCore

final class AccountServiceClientTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let audience = "com.zensystech.dropmesh"

    func testEveryOperationUsesExactRoutePurposeAndValidSignature() async throws {
        let fixture = try Fixture(now: now, audience: audience)
        _ = try await fixture.client.challenge()
        _ = try await fixture.client.complete(
            challengeID: fixture.challengeID,
            code: "apple-code",
            identityToken: "apple-identity-token"
        )
        _ = try await fixture.client.status(accessToken: fixture.accessToken)
        _ = try await fixture.client.refresh(refreshToken: fixture.refreshToken)
        try await fixture.client.logout(accessToken: fixture.accessToken)

        let requests = await fixture.transport.requests
        XCTAssertEqual(requests.map(\.url?.path), [
            "/v1/account/login/challenge",
            "/v1/account/login/complete",
            "/v1/account/session/status",
            "/v1/account/session/refresh",
            "/v1/account/session/logout",
        ])
        XCTAssertEqual(requests.map(\.httpMethod), Array(repeating: "POST", count: 5))
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })

        let expectedPurposes = [
            "dropmesh.account.login.challenge.v1",
            "dropmesh.account.login.complete.v1",
            "dropmesh.account.session.status.v1",
            "dropmesh.account.session.refresh.v1",
            "dropmesh.account.session.logout.v1",
        ]
        var nonces = Set<Data>()
        for (index, request) in requests.enumerated() {
            let envelope = try JSONDecoder().decode(
                RendezvousSignedEnvelope.self,
                from: try XCTUnwrap(request.httpBody)
            )
            XCTAssertEqual(envelope.deviceID, fixture.identity.id.rawValue.uuidString.lowercased())
            XCTAssertEqual(envelope.publicKey, fixture.identity.publicKey.rawRepresentation)
            XCTAssertEqual(envelope.publicKey.count, 64)
            XCTAssertEqual(envelope.epochMilliseconds, 1_800_000_000_000)
            XCTAssertTrue(nonces.insert(envelope.nonce).inserted)
            let signature = try P256.Signing.ECDSASignature(derRepresentation: envelope.signature)
            XCTAssertTrue(fixture.identity.publicKey.isValidSignature(
                signature,
                for: try envelope.canonicalPayload()
            ))
            var tampered = try envelope.canonicalPayload()
            tampered.append(0)
            XCTAssertFalse(fixture.identity.publicKey.isValidSignature(signature, for: tampered))
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: envelope.payload) as? [String: String]
            )
            XCTAssertEqual(payload["purpose"], expectedPurposes[index])
            XCTAssertEqual(payload["audience"], audience)
        }

        let complete = try payload(requests[1])
        XCTAssertEqual(complete["challengeID"], fixture.challengeID)
        XCTAssertEqual(complete["code"], "apple-code")
        XCTAssertEqual(complete["identityToken"], "apple-identity-token")
        let refresh = try payload(requests[3])
        XCTAssertEqual(refresh["refreshToken"], fixture.refreshToken)
        XCTAssertNil(refresh["accessToken"])
    }

    func testDecodesBoundResponsesAndRedactsSensitiveModels() async throws {
        let fixture = try Fixture(now: now, audience: audience)
        let challenge = try await fixture.client.challenge()
        let tokens = try await fixture.client.complete(
            challengeID: fixture.challengeID,
            code: "code",
            identityToken: "identity"
        )
        let status = try await fixture.client.status(accessToken: fixture.accessToken)

        XCTAssertEqual(challenge.challengeID, fixture.challengeID)
        XCTAssertEqual(tokens.identity, fixture.sessionIdentity)
        XCTAssertEqual(status, fixture.sessionIdentity)
        XCTAssertFalse(String(describing: tokens).contains(fixture.accessToken))
        XCTAssertFalse(String(reflecting: tokens).contains(fixture.refreshToken))
        XCTAssertFalse(String(describing: challenge).contains(fixture.challengeID))
    }

    func testRejectsInvalidConfigurationAndInputsBeforeTransport() async throws {
        let identity = try DeviceIdentity.ephemeral()
        let invalidOrigins = [
            "http://accounts.example.test", "https://localhost", "https://127.0.0.1",
            "https://127.1",
            "https://localhost.", "https://service.localhost.",
            "https://[::1]", "https://[0:0:0:0:0:0:0:1]",
            "https://[0:0:0:0:0:0::1]", "https://[::ffff:127.0.0.1]",
            "https://user@example.test", "https://example.test:8443",
            "https://example.test/path", "https://example.test?query=1",
        ]
        for value in invalidOrigins {
            XCTAssertThrowsError(try AccountServiceClient(
                identity: identity,
                origin: XCTUnwrap(URL(string: value)),
                audience: audience
            ), "Expected invalid origin: \(value)") {
                XCTAssertEqual($0 as? AccountServiceError, .invalidConfiguration)
            }
        }
        XCTAssertThrowsError(try AccountServiceClient(
            identity: identity,
            origin: URL(string: "https://accounts.example.test")!,
            audience: "bad audience"
        )) { XCTAssertEqual($0 as? AccountServiceError, .invalidConfiguration) }

        let fixture = try Fixture(now: now, audience: audience)
        let invalidCredentials = ["", "contains space", String(repeating: "a", count: 44)]
        for token in invalidCredentials {
            do {
                _ = try await fixture.client.refresh(refreshToken: token)
                XCTFail("Expected invalid credential")
            } catch {
                XCTAssertEqual(error as? AccountServiceError, .invalidRequest)
            }
        }
        let invalidRequestCount = await fixture.transport.requests.count
        XCTAssertEqual(invalidRequestCount, 0)
    }

    func testMapsStatusesAndTransportWithoutRetrying() async throws {
        let expected: [(Int, AccountServiceError)] = [
            (400, .invalidRequest), (401, .authenticationRejected),
            (403, .authenticationRejected), (429, .rateLimited),
            (503, .unavailable), (500, .invalidResponse),
        ]
        for (status, expectedError) in expected {
            let fixture = try Fixture(now: now, audience: audience, forcedStatus: status)
            do {
                _ = try await fixture.client.refresh(refreshToken: fixture.refreshToken)
                XCTFail("Expected status mapping")
            } catch {
                XCTAssertEqual(error as? AccountServiceError, expectedError)
            }
            let requestCount = await fixture.transport.requests.count
            XCTAssertEqual(requestCount, 1)
        }

        let transport = CapturingAccountTransport(responses: [], failure: URLError(.notConnectedToInternet))
        let client = try testClient(identity: identity(), transport: transport)
        do {
            _ = try await client.challenge()
            XCTFail("Expected transport error")
        } catch {
            XCTAssertEqual(error as? AccountServiceError, .transport)
        }
        let transportRequestCount = await transport.requests.count
        XCTAssertEqual(transportRequestCount, 1)
    }

    func testRejectsMalformedSuccessfulResponsesAndInvalidClockEntropy() async throws {
        let malformed = [
            Data("null".utf8),
            Data("{}".utf8),
            Data("{\"signedOut\":true} trailing".utf8),
            Data(repeating: 0x20, count: 65_537),
        ]
        for body in malformed {
            let transport = CapturingAccountTransport(responses: [(body, response(status: 200))])
            let client = try testClient(identity: identity(), transport: transport)
            do {
                _ = try await client.challenge()
                XCTFail("Expected malformed response")
            } catch {
                XCTAssertEqual(error as? AccountServiceError, .invalidResponse)
            }
        }

        let transport = CapturingAccountTransport(responses: [])
        let fixedNow = now
        let badClock = try AccountServiceClient(
            identity: identity(), origin: URL(string: "https://accounts.example.test")!,
            audience: audience, transport: transport,
            now: { Date(timeIntervalSince1970: .infinity) },
            nonce: { Data(repeating: 1, count: 32) }
        )
        do { _ = try await badClock.challenge(); XCTFail("Expected bad clock") }
        catch { XCTAssertEqual(error as? AccountServiceError, .invalidRequest) }

        let badEntropy = try AccountServiceClient(
            identity: identity(), origin: URL(string: "https://accounts.example.test")!,
            audience: audience, transport: transport, now: { fixedNow },
            nonce: { throw AccountServiceError.transport }
        )
        do { _ = try await badEntropy.challenge(); XCTFail("Expected entropy failure") }
        catch { XCTAssertEqual(error as? AccountServiceError, .transport) }
    }

    func testRejectsSubMillisecondAndUnrepresentableRequestDates() async throws {
        let transport = CapturingAccountTransport(responses: [])
        let identity = try identity()
        let invalidDates = [
            Date(timeIntervalSince1970: 0.000_1),
            Date(timeIntervalSince1970: Double(Int64.max) / 1_000),
        ]
        for invalidDate in invalidDates {
            let client = try AccountServiceClient(
                identity: identity, origin: URL(string: "https://accounts.example.test")!,
                audience: audience, transport: transport, now: { invalidDate },
                nonce: { Data(repeating: 1, count: 32) })
            do { _ = try await client.challenge(); XCTFail("Expected invalid clock") }
            catch { XCTAssertEqual(error as? AccountServiceError, .invalidRequest) }
        }
        let requestCount = await transport.requests.count
        XCTAssertEqual(requestCount, 0)
    }

    func testRejectsMalformedOrUnboundSessionResponses() async throws {
        let identity = try identity()
        let account = "aaaaaaaa-1111-1111-1111-111111111111"
        let session = "22222222-2222-2222-2222-222222222222"
        let device = identity.id.rawValue.uuidString.lowercased()
        let access = rawToken(31)
        let refresh = rawToken(32)
        let valid = "\"accountID\":\"\(account)\",\"sessionID\":\"\(session)\",\"deviceID\":\"\(device)\",\"audience\":\"\(audience)\""
        let malformed = [
            "{\"accountID\":\"00000000-0000-0000-0000-000000000000\",\"sessionID\":\"\(session)\",\"deviceID\":\"\(device)\",\"audience\":\"\(audience)\"}",
            "{\"accountID\":\"\(account.uppercased())\",\"sessionID\":\"\(session)\",\"deviceID\":\"\(device)\",\"audience\":\"\(audience)\"}",
            "{\"accountID\":\"\(account)\",\"sessionID\":\"\(session)\",\"deviceID\":\"33333333-3333-3333-3333-333333333333\",\"audience\":\"\(audience)\"}",
            "{\"accountID\":\"\(account)\",\"sessionID\":\"\(session)\",\"deviceID\":\"\(device)\",\"audience\":\"other\"}",
            "{\"accountID\":1,\"sessionID\":\"\(session)\",\"deviceID\":\"\(device)\",\"audience\":\"\(audience)\"}",
        ]
        for body in malformed {
            let transport = CapturingAccountTransport(responses: [(Data(body.utf8), response(status: 200))])
            let client = try accountClient(identity: identity, transport: transport)
            do { _ = try await client.status(accessToken: access); XCTFail("Expected invalid status") }
            catch { XCTAssertEqual(error as? AccountServiceError, .invalidResponse) }
        }

        let invalidTokens = [
            "{\(valid),\"accessToken\":\"\(access)\",\"refreshToken\":\"\(access)\",\"accessExpiresAt\":1800000060000,\"refreshExpiresAt\":1800000120000}",
            "{\(valid),\"accessToken\":\"!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\",\"refreshToken\":\"\(refresh)\",\"accessExpiresAt\":1800000060000,\"refreshExpiresAt\":1800000120000}",
            "{\(valid),\"accessToken\":\"\(access)\",\"refreshToken\":\"\(refresh)\",\"accessExpiresAt\":1800000120000,\"refreshExpiresAt\":1800000060000}",
            "{\(valid),\"accessToken\":\"\(access)\",\"refreshToken\":\"\(refresh)\",\"accessExpiresAt\":1799999999999,\"refreshExpiresAt\":1800000120000}",
            "{\(valid),\"accessToken\":\"\(access)\",\"refreshToken\":\"\(refresh)\",\"accessExpiresAt\":9223372036854776000,\"refreshExpiresAt\":9223372036854776000}",
        ]
        for body in invalidTokens {
            let transport = CapturingAccountTransport(responses: [(Data(body.utf8), response(status: 200))])
            let client = try accountClient(identity: identity, transport: transport)
            do { _ = try await client.refresh(refreshToken: refresh); XCTFail("Expected invalid tokens") }
            catch { XCTAssertEqual(error as? AccountServiceError, .invalidResponse) }
        }
    }

    func testRejectsMissingOrUnsupportedJSONContentType() async throws {
        let body = Data("{\"signedOut\":true}".utf8)
        for contentType in [nil, "text/json", "application/json; charset=latin1"] as [String?] {
            let transport = CapturingAccountTransport(responses: [(
                body, response(status: 200, contentType: contentType))])
            let client = try accountClient(identity: identity(), transport: transport)
            do { try await client.logout(accessToken: rawToken(44)); XCTFail("Expected invalid type") }
            catch { XCTAssertEqual(error as? AccountServiceError, .invalidResponse) }
        }
    }

    private func identity() throws -> DeviceIdentity { try DeviceIdentity.ephemeral() }

    private func testClient(
        identity: DeviceIdentity,
        transport: CapturingAccountTransport
    ) throws -> AccountServiceClient {
        let fixedNow = now
        return try AccountServiceClient(
            identity: identity, origin: URL(string: "https://accounts.example.test")!,
            audience: audience, transport: transport, now: { fixedNow },
            nonce: { Data(repeating: 7, count: 32) }
        )
    }

    private func accountClient(
        identity: DeviceIdentity,
        transport: CapturingAccountTransport
    ) throws -> AccountServiceClient {
        let fixedNow = now
        return try AccountServiceClient(
            identity: identity, origin: URL(string: "https://accounts.example.test")!,
            audience: audience, transport: transport, now: { fixedNow },
            nonce: { Data(repeating: 8, count: 32) })
    }

    private func payload(_ request: URLRequest) throws -> [String: String] {
        let envelope = try JSONDecoder().decode(
            RendezvousSignedEnvelope.self, from: try XCTUnwrap(request.httpBody))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: envelope.payload) as? [String: String])
    }
}

private struct Fixture {
    let identity: DeviceIdentity
    let transport: CapturingAccountTransport
    let client: AccountServiceClient
    let challengeID = rawToken(1)
    let challengeNonce = rawToken(2)
    let accessToken = rawToken(3)
    let refreshToken = rawToken(4)
    let sessionIdentity: AccountSessionIdentity

    init(now: Date, audience: String, forcedStatus: Int? = nil) throws {
        identity = try DeviceIdentity.ephemeral()
        sessionIdentity = AccountSessionIdentity(
            accountID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            sessionID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            deviceID: identity.id.rawValue,
            audience: audience
        )
        let status = forcedStatus ?? 200
        let identityJSON = "\"accountID\":\"\(sessionIdentity.accountID.uuidString.lowercased())\",\"sessionID\":\"\(sessionIdentity.sessionID.uuidString.lowercased())\",\"deviceID\":\"\(sessionIdentity.deviceID.uuidString.lowercased())\",\"audience\":\"\(audience)\""
        let responses: [(Data, HTTPURLResponse)] = [
            (Data("{\"challengeID\":\"\(challengeID)\",\"nonce\":\"\(challengeNonce)\",\"expiresAt\":1800000060000}".utf8), response(status: status)),
            (Data("{\(identityJSON),\"accessToken\":\"\(accessToken)\",\"refreshToken\":\"\(refreshToken)\",\"accessExpiresAt\":1800000060000,\"refreshExpiresAt\":1800000120000}".utf8), response(status: status)),
            (Data("{\(identityJSON)}".utf8), response(status: status)),
            (Data("{\(identityJSON),\"accessToken\":\"\(accessToken)\",\"refreshToken\":\"\(refreshToken)\",\"accessExpiresAt\":1800000060000,\"refreshExpiresAt\":1800000120000}".utf8), response(status: status)),
            (Data("{\"signedOut\":true}".utf8), response(status: status)),
        ]
        transport = CapturingAccountTransport(responses: responses)
        let nonces = NonceSequence()
        client = try AccountServiceClient(
            identity: identity,
            origin: URL(string: "https://accounts.example.test")!,
            audience: audience,
            transport: transport,
            now: { now },
            nonce: { nonces.next() }
        )
    }
}

private final class NonceSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt8 = 10

    func next() -> Data {
        lock.lock()
        defer { value &+= 1; lock.unlock() }
        return Data(repeating: value, count: 32)
    }
}

private actor CapturingAccountTransport: AccountServiceTransport {
    private(set) var requests: [URLRequest] = []
    private var responses: [(Data, HTTPURLResponse)]
    private let failure: Error?

    init(responses: [(Data, HTTPURLResponse)], failure: Error? = nil) {
        self.responses = responses
        self.failure = failure
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let failure { throw failure }
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return responses.removeFirst()
    }
}

private func rawToken(_ byte: UInt8) -> String {
    Data(repeating: byte, count: 32).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func response(status: Int, contentType: String? = "application/json; charset=utf-8") -> HTTPURLResponse {
    var headers: [String: String] = [:]
    if let contentType { headers["Content-Type"] = contentType }
    return HTTPURLResponse(
        url: URL(string: "https://accounts.example.test")!,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: headers
    )!
}
