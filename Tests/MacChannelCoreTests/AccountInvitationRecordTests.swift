import CryptoKit
import Foundation
import XCTest
@testable import MacChannelCore

final class AccountInvitationRecordTests: XCTestCase, @unchecked Sendable {
    func testRequestContainsNoRecipientDirectoryOrUnknownLinkVersion() throws {
        let f = try InvitationProofFixture(), request = try invitationRequestFixture(f)
        let proof = try AccountInvitationRequestProof(payload: request.payload, signature: request.signature)
        XCTAssertEqual(proof.payload, request.payload)
        let fields = try JSONDecoder().decode([String: String].self, from: proof.payload)
        XCTAssertNil(fields["linkVersion"]); XCTAssertNil(fields["targetAccountID"])
        XCTAssertEqual(fields["targetLinkHash"], f.fields["targetLinkHash"])
        XCTAssertThrowsError(try AccountInvitationRequestProof(payload: f.payload, signature: f.sender.signature(for: f.payload).derRepresentation))
    }
    func testSelectedOfflineTargetIsMetadataNotCompletedPairProof() throws {
        let f = try InvitationProofFixture()
        let pending = try AccountInvitationRecord(data: invitationRecordFixture(f, state: "selected"))
        XCTAssertEqual(pending.checkpoint.state, .selected)
        XCTAssertNotNil(pending.pair)
        XCTAssertTrue(pending.senderSignature.isEmpty); XCTAssertTrue(pending.targetSignature.isEmpty)
        XCTAssertThrowsError(try AccountInvitationRecord(data: invitationRecordFixture(f, state: "active")))
        let active = try AccountInvitationRecord(data: invitationRecordFixture(f, state: "active", signed: true))
        XCTAssertEqual(active.checkpoint.state, .active)
    }
    func testExactRequestPairCorrelationAndOuterDuplicateKeys() throws {
        let f = try InvitationProofFixture(), valid = try invitationRecordFixture(f, state: "active", signed: true)
        let json = String(decoding: valid, as: UTF8.self)
        for data in [Data(json.replacingOccurrences(of: "\"revision\":\"3\"", with: "\"revision\":\"3\",\"revision\":\"3\"").utf8),
            Data(json.replacingOccurrences(of: "\"revision\":\"3\"", with: "\"revision\":3").utf8), valid + Data("{}".utf8)] {
            XCTAssertThrowsError(try AccountInvitationRecord(data: data))
        }
        var altered = f.fields; altered["targetLinkHash"] = Data(repeating: 9, count: 32).base64EncodedString()
        let alteredPair = try invitationJSON(altered)
        let bytes = try invitationRecordFixture(f, state: "selected", pairOverride: alteredPair)
        XCTAssertThrowsError(try AccountInvitationRecord(data: bytes), "a separately valid pair cannot substitute the requested link")
    }
}

func invitationRequestFixture(_ f: InvitationProofFixture) throws -> (payload: Data, signature: Data) {
    var fields = f.fields
    for key in ["linkVersion", "targetAccountID", "targetAudience", "targetDeviceID", "targetGeneration", "targetGroupID", "targetPublicKey"] { fields.removeValue(forKey: key) }
    fields["purpose"] = "dropmesh.account.invitation.request.v1"
    let bytes = try invitationJSON(fields)
    return (bytes, try f.sender.signature(for: bytes).derRepresentation)
}

func invitationRecordFixture(_ f: InvitationProofFixture, state: String, signed: Bool = false, pairOverride: Data? = nil) throws -> Data {
    let request = try invitationRequestFixture(f), payload = try pairOverride ?? f.payload
    let pair: Any = state == "requested" ? NSNull() : ["payload": payload.base64EncodedString(),
        "senderSignature": signed ? try f.sender.signature(for: payload).derRepresentation.base64EncodedString() : "",
        "targetSignature": signed ? try f.target.signature(for: payload).derRepresentation.base64EncodedString() : ""]
    let fields: [String: Any] = ["requestID": f.fields["requestID"]!, "grantID": f.fields["grantID"]!, "revision": "3", "state": state,
        "proofDigest": state == "requested" ? "" : Data(SHA256.hash(data: payload)).base64EncodedString(), "verifiedAtMilliseconds": "1800000000001",
        "request": ["payload": request.payload.base64EncodedString(), "signature": request.signature.base64EncodedString()], "pair": pair]
    return try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])
}
