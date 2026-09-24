import CryptoKit
import Foundation
import XCTest
@testable import MacChannelCore

final class AccountInvitationProofTests: XCTestCase, @unchecked Sendable {
    func testFrozenGoFixtureVerifiesExactCanonicalBytesAndBothSignatures() throws {
        struct Fixture: Decodable { let wire: [String: String]; let canonicalJSON: String; let sha256: String }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in ["pair-v1.json", "pair-v1-raw64.json"] {
        let data = try Data(contentsOf: root.appendingPathComponent("Services/rendezvous/internal/accountinvite/testdata/" + file))
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        let proof = try AccountInvitationPairProof(wireJSON: invitationJSON(fixture.wire))
        XCTAssertEqual(proof.payload, Data(fixture.canonicalJSON.utf8))
        XCTAssertEqual(proof.pair.digest.map { String(format: "%02x", $0) }.joined(), fixture.sha256)
        XCTAssertNotEqual(proof.pair.sender.audience, proof.pair.target.audience)
        XCTAssertEqual(try AccountInvitationPairProof(wireJSON: proof.wireJSON()), proof)
        }
    }
    func testActualNativeIdentityKeepsRaw64BytesAndItsExistingDeviceID() throws {
        let native = try DeviceIdentity.ephemeral(), f = try InvitationProofFixture()
        var fields = f.fields
        fields["senderPublicKey"] = native.publicKey.rawRepresentation.base64EncodedString()
        fields["senderDeviceID"] = native.id.rawValue.uuidString.lowercased()
        let payload = try invitationJSON(fields)
        let proof = try AccountInvitationPairProof(payload: payload,
            senderSignature: native.sign(payload).derRepresentation, targetSignature: f.target.signature(for: payload).derRepresentation)
        XCTAssertEqual(proof.pair.sender.publicKey.count, 64)
        XCTAssertEqual(proof.pair.sender.deviceID, native.id.rawValue.uuidString.lowercased())
        fields["senderPublicKey"] = native.publicKey.x963Representation.base64EncodedString()
        XCTAssertThrowsError(try AccountInvitationPair(canonicalPayload: invitationJSON(fields)), "representation conversion cannot change identity")
    }
    func testStrictCanonicalFieldsAndEndpointBindingRejectTampering() throws {
        let f = try InvitationProofFixture()
        for (key, value) in ["purpose": "dropmesh.account.group.event.v1", "senderGeneration": "01",
            "targetGeneration": "9223372036854775808", "expiresAtMilliseconds": "1800086400001",
            "senderAccountID": "00000000-0000-0000-0000-000000000000", "targetAccountID": f.fields["senderAccountID"]!, "grantID": f.fields["requestID"]!,
            "origin": "https://accounts.example.com/", "targetAudience": "bad audience", "audience": "other",
            "targetDeviceID": f.fields["senderDeviceID"]!, "targetLinkHash": Data(repeating: 1, count: 31).base64EncodedString(),
            "targetPublicKey": f.sender.publicKey.x963Representation.base64EncodedString()] {
            var fields = f.fields; fields[key] = value
            XCTAssertThrowsError(try AccountInvitationPair(canonicalPayload: invitationJSON(fields)), key)
        }
        let bytes = try f.payload
        let json = String(decoding: bytes, as: UTF8.self)
        for altered in [bytes + Data(" ".utf8), Data(json.replacingOccurrences(of: "\"linkVersion\":\"1\"", with: "\"linkVersion\":\"1\",\"linkVersion\":\"1\"").utf8),
            Data(json.replacingOccurrences(of: "\"linkVersion\":\"1\"", with: "\"linkVersion\":1").utf8),
            Data(json.replacingOccurrences(of: "\"audience\"", with: "\"extra\":\"x\",\"audience\"").utf8)] {
            XCTAssertThrowsError(try AccountInvitationPair(canonicalPayload: altered))
        }
    }
    func testCommitExpiryAndRoleSpecificAudienceDoNotConfuseProofWithLiveAuthority() throws {
        let f = try InvitationProofFixture(), pair = try AccountInvitationPair(canonicalPayload: f.payload)
        let targetBinding = try AccountSessionBinding(deviceID: UUID(uuidString: pair.target.deviceID)!,
            audience: pair.target.audience, origin: URL(string: pair.origin)!)
        try pair.validateForCommit(binding: targetBinding, local: pair.target, role: .target, atMilliseconds: pair.issuedAtMilliseconds)
        XCTAssertThrowsError(try pair.validateForCommit(binding: targetBinding, local: pair.target, role: .sender, atMilliseconds: pair.issuedAtMilliseconds))
        XCTAssertThrowsError(try pair.validateForCommit(binding: targetBinding, local: pair.target, role: .target, atMilliseconds: pair.expiresAtMilliseconds))
        let wrongGeneration = try AccountInvitationEndpoint(audience: pair.target.audience, accountID: pair.target.accountID,
            groupID: pair.target.groupID, generation: 3, deviceID: pair.target.deviceID, publicKey: pair.target.publicKey)
        XCTAssertThrowsError(try pair.validateForCommit(binding: targetBinding, local: wrongGeneration, role: .target, atMilliseconds: pair.issuedAtMilliseconds))
        let proof = try AccountInvitationPairProof(payload: pair.payload, senderSignature: f.sender.signature(for: pair.payload).derRepresentation,
            targetSignature: f.target.signature(for: pair.payload).derRepresentation)
        XCTAssertEqual(try AccountInvitationPairProof(wireJSON: proof.wireJSON()), proof)
    }
    func testBothExactEndpointsMustSignSameFinalizedPair() throws {
        let f = try InvitationProofFixture()
        let proof = try AccountInvitationPairProof(payload: f.payload,
            senderSignature: f.sender.signature(for: f.payload).derRepresentation,
            targetSignature: f.target.signature(for: f.payload).derRepresentation)
        XCTAssertEqual(proof.payload, try f.payload)
        XCTAssertThrowsError(try AccountInvitationPairProof(payload: f.payload,
            senderSignature: proof.senderSignature, targetSignature: Data()))
        XCTAssertThrowsError(try AccountInvitationPairProof(payload: f.payload,
            senderSignature: proof.targetSignature, targetSignature: proof.senderSignature))
        var fields = f.fields; fields["targetAccountID"] = UUID().uuidString.lowercased()
        XCTAssertThrowsError(try AccountInvitationPairProof(payload: invitationJSON(fields),
            senderSignature: proof.senderSignature, targetSignature: proof.targetSignature))
    }
}

struct InvitationProofFixture {
    let sender = P256.Signing.PrivateKey(), target = P256.Signing.PrivateKey()
    var fields: [String: String]
    var payload: Data { get throws { try invitationJSON(fields) } }
    init() throws {
        fields = ["purpose": "dropmesh.account.invitation.pair.v1", "audience": "com.example.app",
            "origin": "https://accounts.example.com", "requestID": "11111111-1111-1111-1111-111111111111",
            "grantID": "22222222-2222-2222-2222-222222222222", "linkVersion": "1",
            "senderAudience": "com.example.app", "targetAudience": "com.example.mac", "targetLinkHash": Data(repeating: 7, count: 32).base64EncodedString(),
            "issuedAtMilliseconds": "1800000000000", "expiresAtMilliseconds": "1800086400000",
            "senderAccountID": "33333333-3333-3333-3333-333333333333", "senderGroupID": "44444444-4444-4444-4444-444444444444",
            "senderGeneration": "1", "senderDeviceID": try AccountGroupEvent.deviceID(publicKey: sender.publicKey.x963Representation),
            "senderPublicKey": sender.publicKey.x963Representation.base64EncodedString(),
            "targetAccountID": "55555555-5555-5555-5555-555555555555", "targetGroupID": "66666666-6666-6666-6666-666666666666",
            "targetGeneration": "2", "targetDeviceID": try AccountGroupEvent.deviceID(publicKey: target.publicKey.x963Representation),
            "targetPublicKey": target.publicKey.x963Representation.base64EncodedString()]
    }
}

func invitationJSON(_ fields: [String: String]) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(fields)
}
