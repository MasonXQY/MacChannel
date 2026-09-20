import CryptoKit
import Foundation
import XCTest
@testable import MacChannelCore

final class AccountDeletionServiceTests: XCTestCase, @unchecked Sendable {
    func testExactSignedBeginBooleanAndReceiptOnlyStatus() async throws {
        let identity = try DeviceIdentity.ephemeral(), transport = DeletionTransport()
        let client = try deletionClient(identity, transport)
        let receipt = nativeProducerToken(7)
        let status = try await client.beginDeletion(receipt: receipt, accessToken: nativeProducerToken(1),
            challengeID: nativeProducerToken(3), code: "code", identityToken: "identity", confirmation: true)
        XCTAssertEqual(status, .pending)
        _ = try await client.deletionStatus(receipt: receipt)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        for (index, request) in requests.enumerated() {
            let envelope = try JSONDecoder().decode(RendezvousSignedEnvelope.self, from: XCTUnwrap(request.httpBody))
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: envelope.payload) as? [String: Any])
            let op = index == 0 ? "begin" : "status"
            XCTAssertEqual(request.url?.path, "/v1/account/deletion/" + op)
            XCTAssertEqual(fields["purpose"] as? String, "dropmesh.account.deletion.\(op).v1")
            XCTAssertEqual(fields["receipt"] as? String, receipt)
            XCTAssertEqual(fields["audience"] as? String, "app")
            XCTAssertEqual(Set(fields.keys), index == 0 ? ["purpose", "audience", "receipt", "accessToken", "challengeID", "code", "identityToken", "confirmation"] : ["purpose", "audience", "receipt"])
            if index == 0 {
                XCTAssertTrue(fields["confirmation"] is NSNumber)
                XCTAssertEqual(String(decoding: envelope.payload, as: UTF8.self).contains("\"confirmation\":true"), true)
            }
            XCTAssertTrue(identity.publicKey.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: envelope.signature), for: try envelope.canonicalPayload()))
        }
    }
    func testAllStatusesAndStrictResponseParsing() async throws {
        for state in ["pending", "retrying", "completed", "completed_manual_revocation_required"] {
            let transport = DeletionTransport(body: "{\"status\":\"\(state)\"}")
            let result = try await deletionClient(.ephemeral(), transport).deletionStatus(receipt: nativeProducerToken(7))
            XCTAssertEqual(result.rawValue, state)
        }
        for body in ["{\"status\":\"submitting\"}", "{\"status\":\"completed\",\"status\":\"pending\"}",
                     "{\"status\":\"completed\",\"extra\":1}", "{\"status\":true}", "{\"status\":\"pending\"}{}"] {
            do { _ = try await deletionClient(.ephemeral(), DeletionTransport(body: body)).deletionStatus(receipt: nativeProducerToken(7)); XCTFail("malformed response") }
            catch { XCTAssertEqual(error as? AccountServiceError, .invalidResponse) }
        }
    }
    func testErrorsAndMissingConfirmationNeverSend() async throws {
        let transport = DeletionTransport(), client = try deletionClient(.ephemeral(), transport)
        do { _ = try await client.beginDeletion(receipt: nativeProducerToken(7), accessToken: nativeProducerToken(1),
            challengeID: nativeProducerToken(3), code: "code", identityToken: "identity", confirmation: false); XCTFail("no confirmation") } catch {}
        do { _ = try await client.deletionStatus(receipt: "invalid"); XCTFail("invalid receipt") } catch {}
        let count = await transport.requests.count; XCTAssertEqual(count, 0)
        for (status, expected) in [(401, AccountServiceError.authenticationRejected), (404, .unavailable), (503, .unavailable)] {
            do { _ = try await deletionClient(.ephemeral(), DeletionTransport(status: status)).deletionStatus(receipt: nativeProducerToken(7)); XCTFail("HTTP error") }
            catch { XCTAssertEqual(error as? AccountServiceError, expected) }
        }
    }
}

private func deletionClient(_ identity: DeviceIdentity, _ transport: DeletionTransport) throws -> AccountServiceClient {
    try AccountServiceClient(identity: identity, origin: URL(string: "https://accounts.example.com")!, audience: "app",
        transport: transport, now: { NativeProducerFixture.start }, nonce: { Data(repeating: 8, count: 32) })
}
private actor DeletionTransport: AccountServiceTransport {
    var requests: [URLRequest] = []
    let body: String, status: Int
    init(body: String = "{\"status\":\"pending\"}", status: Int = 200) { self.body = body; self.status = status }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!)
    }
}
