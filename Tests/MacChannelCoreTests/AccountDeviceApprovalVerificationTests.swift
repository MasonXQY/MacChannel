import CryptoKit
import Foundation
import XCTest
@testable import MacChannelCore

final class AccountDeviceApprovalVerificationTests: XCTestCase {
    func testIndependentLiteralVectorsAndStrictFullComparison() throws {
        let requests = ["EBC60E82B5EBE5C713FA212344D0B989AB7BB62932EC58A071A29A8E920751F6", "5F91553E4949B5C8424A57F346EAB5FE96C8F6CAA4A89037B151F9164F5F09FD"]
        let full = ["ACF7CA24FE19B66132F89A372D831CD8613367C98EB4F275579B60D5808AF5DF", "23A77325DA721E881BDA99E08868090DC1542436953A56684AE4165A49C27659"]
        for (index, fixture) in try approvalFixtures().enumerated() {
            let context = try approvalContext(fixture.draft)
            XCTAssertTrue(context.matchesRequestCode("DMJR1-" + requests[index]))
            XCTAssertTrue(context.matchesRequestCode("DMJR1-" + requests[index].lowercased().map(String.init).joined(separator: " -")))
            for bad in [String(context.requestCode.dropLast()), context.requestCode + "0", context.requestCode + "\n", context.requestCode.replacingOccurrences(of: "DMJR1", with: "dmjr1"), "DMJR1-" + String(repeating: "０", count: 64)] {
                XCTAssertFalse(context.matchesRequestCode(bad))
            }
            let capsule = try AccountDeviceApprovalCapsule(origin: context.origin, requestID: context.requestID,
                draft: fixture.draft, expectedAnchorHash: Data(repeating: 65, count: 32))
            XCTAssertEqual(capsule.fingerprint.replacingOccurrences(of: "-", with: ""), full[index])
            let parsed = try AccountDeviceApprovalCapsule.parse(capsule.code, expectedRequest: context, expectedDraft: fixture.draft)
            XCTAssertTrue(parsed == capsule)
            XCTAssertEqual(parsed.canonicalPayload, try fixture.draft.event.canonicalPayload())
            XCTAssertFalse(String(reflecting: capsule).contains(capsule.code))
        }
    }

    func testCapsuleStrictRawBoundaryAndExpectedContext() throws {
        let f = try approvalFixtures()[0], request = try approvalContext(f.draft)
        let capsule = try AccountDeviceApprovalCapsule(origin: request.origin, requestID: request.requestID,
            draft: f.draft, expectedAnchorHash: Data(repeating: 65, count: 32))
        let data = try XCTUnwrap(Data(base64Encoded: String(capsule.code.dropFirst(6))))
        let json = String(decoding: data, as: UTF8.self)
        let invalid = [json + "{}", "null", "[]", "{}", String(repeating: " ", count: 8193),
            json.replacingOccurrences(of: "{", with: "{\"origin\":\"https://example.com\","),
            json.replacingOccurrences(of: "{", with: "{\"ori\\u0067in\":\"https://example.com\","),
            json.replacingOccurrences(of: "{", with: "{\"extra\":\"x\","),
            json.replacingOccurrences(of: "\"purpose\":\"dropmesh.account.group.join.member-verify.v1\"", with: "\"purpose\":null"),
            json.replacingOccurrences(of: "member-verify.v1", with: "request-compare.v1"),
            json.replacingOccurrences(of: "https://example.com", with: "https://other.example.com"),
            json.replacingOccurrences(of: request.requestID, with: "44444444-4444-4444-4444-444444444444")]
        for bad in invalid {
            XCTAssertThrowsError(try AccountDeviceApprovalCapsule.parse("DMJA1:" + Data(bad.utf8).base64EncodedString(), expectedRequest: request, expectedDraft: f.draft))
        }
        for bad in [capsule.code + "\n", capsule.code + "=", "DMJA1:Zh==", "DMJA1:Zg", "dmja1:" + String(capsule.code.dropFirst(6))] {
            XCTAssertThrowsError(try AccountDeviceApprovalCapsule.parse(bad, expectedRequest: request, expectedDraft: f.draft))
        }
        XCTAssertThrowsError(try AccountDeviceApprovalCapsule.parse(capsule.code, expectedRequest: approvalContext(approvalFixtures()[1].draft), expectedDraft: approvalFixtures()[1].draft))
    }

    func testImportedCapsuleRetainsExactValidIndependentBytes() throws {
        let f = try approvalFixtures()[0], request = try approvalContext(f.draft)
        let canonical = try AccountDeviceApprovalCapsule(origin: request.origin, requestID: request.requestID, draft: f.draft, expectedAnchorHash: Data(repeating: 65, count: 32))
        let data = try XCTUnwrap(Data(base64Encoded: String(canonical.code.dropFirst(6))))
        let incoming = "DMJA1:" + (Data(" \n".utf8) + data + Data("\t".utf8)).base64EncodedString()
        let imported = try AccountDeviceApprovalCapsule.parse(incoming, expectedRequest: request, expectedDraft: f.draft)
        XCTAssertTrue(imported.code == incoming)
        XCTAssertEqual(imported.comparisonDigest, canonical.comparisonDigest)
    }

    func testEveryPayloadFieldSubstitutionAndKeyRepresentationBindsComparison() throws {
        let f = try approvalFixtures()[0], request = try approvalContext(f.draft)
        let capsule = try AccountDeviceApprovalCapsule(origin: request.origin, requestID: request.requestID, draft: f.draft, expectedAnchorHash: Data(repeating: 65, count: 32))
        let raw = try XCTUnwrap(Data(base64Encoded: String(capsule.code.dropFirst(6))))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: String])
        let payload = try f.draft.event.canonicalPayload()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        for (name, value) in [("accountID", groupAccount as Any), ("groupID", groupID), ("generation", 8),
            ("actorDeviceID", groupAccount), ("subjectDeviceID", groupID), ("actorPublicKey", Data([1]).base64EncodedString()),
            ("subjectPublicKey", Data([4]).base64EncodedString()), ("previousHash", Data(repeating: 67, count: 32).base64EncodedString()),
            ("sequence", 3), ("epochMilliseconds", 1_700_000_000_124 as Int64), ("purpose", "wrong"), ("action", "remove")] {
            var modified = object; modified[name] = value
            var envelope = fields
            envelope["context"] = (Data(repeating: 65, count: 32) + (try JSONSerialization.data(withJSONObject: modified, options: [.sortedKeys, .withoutEscapingSlashes]))).base64EncodedString()
            let code = "DMJA1:" + (try JSONSerialization.data(withJSONObject: envelope)).base64EncodedString()
            XCTAssertThrowsError(try AccountDeviceApprovalCapsule.parse(code, expectedRequest: request, expectedDraft: f.draft), name)
        }
        let changedAnchor = try AccountDeviceApprovalCapsule(origin: request.origin, requestID: request.requestID, draft: f.draft, expectedAnchorHash: Data(repeating: 66, count: 32))
        XCTAssertNotEqual(changedAnchor.comparisonDigest, capsule.comparisonDigest)
        let e = f.draft.event
        for context in [
            try AccountDeviceApprovalRequestContext(origin: URL(string: "https://other.example.com")!, requestID: request.requestID, accountID: e.accountID, groupID: e.groupID, generation: e.generation, subjectDeviceID: e.subjectDeviceID, subjectPublicKey: e.subjectPublicKey),
            try AccountDeviceApprovalRequestContext(origin: request.origin, requestID: groupID, accountID: e.accountID, groupID: e.groupID, generation: e.generation, subjectDeviceID: e.subjectDeviceID, subjectPublicKey: e.subjectPublicKey),
            try AccountDeviceApprovalRequestContext(origin: request.origin, requestID: request.requestID, accountID: groupAccount, groupID: e.groupID, generation: e.generation, subjectDeviceID: e.subjectDeviceID, subjectPublicKey: e.subjectPublicKey),
            try AccountDeviceApprovalRequestContext(origin: request.origin, requestID: request.requestID, accountID: e.accountID, groupID: groupID, generation: e.generation, subjectDeviceID: e.subjectDeviceID, subjectPublicKey: e.subjectPublicKey),
            try AccountDeviceApprovalRequestContext(origin: request.origin, requestID: request.requestID, accountID: e.accountID, groupID: e.groupID, generation: 8, subjectDeviceID: e.subjectDeviceID, subjectPublicKey: e.subjectPublicKey),
            try AccountDeviceApprovalRequestContext(origin: request.origin, requestID: request.requestID, accountID: e.accountID, groupID: e.groupID, generation: e.generation, subjectDeviceID: AccountGroupEvent.deviceID(publicKey: Data(e.subjectPublicKey.dropFirst())), subjectPublicKey: Data(e.subjectPublicKey.dropFirst()))] {
            XCTAssertFalse(context.matchesRequestCode(request.requestCode))
            XCTAssertThrowsError(try AccountDeviceApprovalCapsule.parse(capsule.code, expectedRequest: context, expectedDraft: f.draft))
        }
        for context in [Data(repeating: 0, count: 4097), Data(repeating: 0, count: 31), Data([65]) + payload] {
            var envelope = fields; envelope["context"] = context.base64EncodedString()
            XCTAssertThrowsError(try AccountDeviceApprovalCapsule.parse("DMJA1:" + JSONSerialization.data(withJSONObject: envelope).base64EncodedString(), expectedRequest: request, expectedDraft: f.draft))
        }
        for name in fields.keys {
            var missing = fields; missing.removeValue(forKey: name)
            XCTAssertThrowsError(try AccountDeviceApprovalCapsule.parse("DMJA1:" + JSONSerialization.data(withJSONObject: missing).base64EncodedString(), expectedRequest: request, expectedDraft: f.draft))
            for value in [NSNull(), 1, [], [:]] as [Any] {
                var wrong: [String: Any] = fields; wrong[name] = value
                XCTAssertThrowsError(try AccountDeviceApprovalCapsule.parse("DMJA1:" + JSONSerialization.data(withJSONObject: wrong).base64EncodedString(), expectedRequest: request, expectedDraft: f.draft))
            }
        }
    }
}

struct ApprovalFixture {
    let draft: AccountGroupApprovalDraft
    let final: AccountGroupEvent
}
func approvalFixtures() throws -> [ApprovalFixture] {
    struct File: Decodable {
        struct Entry: Decodable { let draftJSON: String; let subjectSignature: String }
        let fixtures: [Entry]
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try JSONDecoder().decode(File.self, from: Data(contentsOf: root.appendingPathComponent("Fixtures/account-group-approval-v1.json"))).fixtures.map {
        let draft = try AccountGroupApprovalDraft(wire: AccountGroupWireApprovalDraft.decodeJSON(Data($0.draftJSON.utf8)))
        return try ApprovalFixture(draft: draft, final: draft.finalize(subjectSignature: XCTUnwrap(Data(base64Encoded: $0.subjectSignature))))
    }
}
func approvalContext(_ draft: AccountGroupApprovalDraft, requestID: String = "33333333-3333-3333-3333-333333333333") throws -> AccountDeviceApprovalRequestContext {
    let e = draft.event
    return try AccountDeviceApprovalRequestContext(origin: URL(string: "https://example.com")!, requestID: requestID,
        accountID: e.accountID, groupID: e.groupID, generation: e.generation, subjectDeviceID: e.subjectDeviceID, subjectPublicKey: e.subjectPublicKey)
}
