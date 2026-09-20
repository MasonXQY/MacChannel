import CryptoKit
import Foundation
import XCTest
@testable import MacChannelCore

final class AccountTURNServiceClientTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let group = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    private var token: String { Data(repeating: 7, count: 32).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }

    func testSignedExactRequestAndUsableResponse() async throws {
        let identity = try DeviceIdentity.ephemeral()
        let transport = TURNAccountTransport(body: response())
        let client = try makeClient(identity, transport)
        let service: any AccountTURNCredentialService = client
        let value = try await service.turnCredentials(accessToken: token, groupID: group, generation: 3)
        XCTAssertTrue(value.isUsable(at: now))
        XCTAssertEqual(value.expiresAt, now.addingTimeInterval(300))
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.url?.path, "/v1/account/turn-credentials")
        XCTAssertNil(request.url?.query)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.httpMethod, "POST")
        let envelope = try JSONDecoder().decode(RendezvousSignedEnvelope.self, from: XCTUnwrap(request.httpBody))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: envelope.payload) as? [String: String])
        XCTAssertEqual(fields, ["purpose": "dropmesh.account.turn.credentials.v1", "audience": "com.example.app", "accessToken": token, "groupID": group, "generation": "3"])
        let signature = try P256.Signing.ECDSASignature(derRepresentation: envelope.signature)
        XCTAssertTrue(identity.publicKey.isValidSignature(signature, for: try envelope.canonicalPayload()))
        XCTAssertEqual(envelope.publicKey, identity.publicKey.rawRepresentation)
    }

    func testInvalidArgumentsNeverSend() async throws {
        let transport = TURNAccountTransport(body: response())
        let client = try makeClient(DeviceIdentity.ephemeral(), transport)
        for (access, groupID, generation) in [("bad", group, UInt64(1)), (token, "bad", 1), (token, group, 0), (token, group, UInt64.max)] {
            do { _ = try await client.turnCredentials(accessToken: access, groupID: groupID, generation: generation); XCTFail("accepted invalid input") }
            catch { XCTAssertEqual(error as? AccountServiceError, .invalidRequest) }
        }
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)
    }

    func testRejectsMalformedAndExpiredResponses() async throws {
        let valid = String(decoding: response(), as: UTF8.self)
        let bodies = [
            valid.replacingOccurrences(of: "1800000300:", with: "1800000301:"),
            valid.replacingOccurrences(of: "1800000300:", with: "01800000300:"),
            valid.replacingOccurrences(of: "Z\"", with: ".500Z\""),
            valid.replacingOccurrences(of: "turn:relay.example.test:3478?transport=udp", with: "https://relay.example.test"),
            valid.replacingOccurrences(of: "turn:relay.example.test:3478?transport=udp", with: "turn:user@relay.example.test:3478"),
            valid.replacingOccurrences(of: "\"urls\":[", with: "\"extra\":true,\"urls\":["),
            valid.replacingOccurrences(of: "\"username\":", with: "\"username\":\"duplicate\",\"username\":"),
            valid.replacingOccurrences(of: "\"credential\":", with: "\"credentia\\u006c\":\"duplicate\",\"credential\":"),
            String(decoding: response(expiry: now), as: UTF8.self),
            String(decoding: response(expiry: now.addingTimeInterval(301)), as: UTF8.self),
            valid + "{}",
        ]
        for body in bodies {
            let client = try makeClient(DeviceIdentity.ephemeral(), TURNAccountTransport(body: Data(body.utf8)))
            do { _ = try await client.turnCredentials(accessToken: token, groupID: group, generation: 1); XCTFail("accepted invalid response") }
            catch { XCTAssertEqual(error as? AccountServiceError, .invalidResponse) }
        }
    }

    func testUnavailableAuthenticationAndCancellation() async throws {
        for (status, expected) in [(404, AccountServiceError.unavailable), (401, .authenticationRejected), (429, .rateLimited), (503, .unavailable)] {
            let client = try makeClient(DeviceIdentity.ephemeral(), TURNAccountTransport(body: response(), status: status))
            do { _ = try await client.turnCredentials(accessToken: token, groupID: group, generation: 1); XCTFail("accepted HTTP error") }
            catch { XCTAssertEqual(error as? AccountServiceError, expected) }
        }
        let transport = TURNAccountTransport(body: response())
        let client = try makeClient(DeviceIdentity.ephemeral(), transport)
        let accessToken = token
        let groupID = group
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await client.turnCredentials(accessToken: accessToken, groupID: groupID, generation: 1) }
        do { _ = try await task.value; XCTFail("ignored cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)
    }

    func testRejectsCredentialExpiredWhileAwaitingResponse() async throws {
        let clock = TURNClientClock(first: now, subsequent: now.addingTimeInterval(301))
        let client = try AccountServiceClient(identity: DeviceIdentity.ephemeral(), origin: URL(string: "https://accounts.example.test")!, audience: "com.example.app", transport: TURNAccountTransport(body: response()), now: { clock.read() }, nonce: { Data(repeating: 2, count: 32) })
        do { _ = try await client.turnCredentials(accessToken: token, groupID: group, generation: 1); XCTFail("accepted expired in-flight credentials") }
        catch { XCTAssertEqual(error as? AccountServiceError, .invalidResponse) }
    }

    private func makeClient(_ identity: DeviceIdentity, _ transport: TURNAccountTransport) throws -> AccountServiceClient {
        let date = now
        return try AccountServiceClient(identity: identity, origin: URL(string: "https://accounts.example.test")!, audience: "com.example.app", transport: transport, now: { date }, nonce: { Data(repeating: 2, count: 32) })
    }

    private func response(expiry: Date? = nil) -> Data {
        let expiry = expiry ?? now.addingTimeInterval(300)
        return try! JSONSerialization.data(withJSONObject: ["urls": ["turn:relay.example.test:3478?transport=udp"], "username": "\(Int64(expiry.timeIntervalSince1970)):opaque", "credential": "credential", "expiresAt": ISO8601DateFormatter().string(from: expiry)], options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

private final class TURNClientClock: @unchecked Sendable {
    private let lock = NSLock()
    private let first: Date
    private let subsequent: Date
    private var used = false
    init(first: Date, subsequent: Date) { self.first = first; self.subsequent = subsequent }
    func read() -> Date { lock.lock(); defer { lock.unlock() }; if used { return subsequent }; used = true; return first }
}

private actor TURNAccountTransport: AccountServiceTransport {
    private let body: Data
    private let status: Int
    private(set) var requests: [URLRequest] = []
    init(body: Data, status: Int = 200) { self.body = body; self.status = status }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
    }
}
