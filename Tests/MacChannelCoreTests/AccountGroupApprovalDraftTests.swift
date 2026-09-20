import CryptoKit
import Foundation
import XCTest
@testable import MacChannelCore

final class AccountGroupApprovalDraftTests: XCTestCase {
    func testActorOnlyDraftFinalizesExactPayloadAndRejectsInvalidProof() throws {
        for raw65 in [false, true] {
            let a = P256.Signing.PrivateKey(), b = P256.Signing.PrivateKey()
            let full = try groupEvent(actor: a, subject: b, action: "approve", sequence: 2,
                previous: Data(repeating: 42, count: 32), raw65: raw65)
            let partial = try replacingSignatures(full, subject: Data())
            let draft = try AccountGroupApprovalDraft(event: partial)
            XCTAssertThrowsError(try draft.event.validate())
            let wire = try draft.wireDraft()
            let decoded = try AccountGroupApprovalDraft(wire: wire)
            let final = try decoded.finalize(subjectSignature: full.subjectSignature)
            XCTAssertEqual(final, full)
            XCTAssertEqual(try final.canonicalPayload(), try partial.canonicalPayload())
            XCTAssertEqual(final.signature, partial.signature)
            XCTAssertEqual(final.actorPublicKey.count, raw65 ? 65 : 64)
            XCTAssertEqual(final.subjectPublicKey.count, raw65 ? 65 : 64)
            XCTAssertEqual(try AccountGroupWireApprovalDraft.decodeJSON(JSONEncoder().encode(wire)), wire)
            for signature in [Data(), Data([1]), full.signature] {
                XCTAssertThrowsError(try draft.finalize(subjectSignature: signature))
            }
            XCTAssertThrowsError(try AccountGroupApprovalDraft(event: full))
            XCTAssertThrowsError(try AccountGroupApprovalDraft(event: replacingSignatures(partial, actor: Data())))
            XCTAssertThrowsError(try AccountGroupApprovalDraft(event: replacingSignatures(partial, actor: Data([1]))))
            let bootstrap = try groupEvent(actor: a, subject: a)
            XCTAssertThrowsError(try AccountGroupApprovalDraft(event: bootstrap))
            let remove = try groupEvent(actor: a, subject: b, action: "remove", sequence: 2, previous: Data(repeating: 42, count: 32))
            XCTAssertThrowsError(try AccountGroupApprovalDraft(event: remove))
        }
    }

    func testSyntheticCrossLanguageFixture() throws {
        struct Fixture: Decodable {
            struct Entry: Decodable { let name, canonicalPayload, draftJSON, subjectSignature, finalizedDigest: String }
            let fixtures: [Entry]
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("Fixtures/account-group-approval-v1.json")))
        XCTAssertEqual(fixture.fixtures.count, 2)
        for f in fixture.fixtures {
            let wire = try AccountGroupWireApprovalDraft.decodeJSON(Data(f.draftJSON.utf8))
            let draft = try AccountGroupApprovalDraft(wire: wire)
            XCTAssertEqual(try draft.event.canonicalPayload().base64EncodedString(), f.canonicalPayload)
            XCTAssertEqual(try draft.wireDraft(), wire)
            // Explicit wire field order is shared fixture data, not JSONEncoder order.
            XCTAssertEqual("{\"payload\":\"\(wire.payload)\",\"signature\":\"\(wire.signature)\"}", f.draftJSON)
            let final = try draft.finalize(subjectSignature: XCTUnwrap(Data(base64Encoded: f.subjectSignature)))
            XCTAssertEqual(try final.digest().map { String(format: "%02x", $0) }.joined(), f.finalizedDigest)
            print("ACCEPTED approval fixture \(f.name): \(f.finalizedDigest)")
        }
    }

    func testStrictRawJSONAndBase64() throws {
        let a = P256.Signing.PrivateKey(), b = P256.Signing.PrivateKey()
        let e = try groupEvent(actor: a, subject: b, action: "approve", sequence: 2, previous: Data(repeating: 42, count: 32))
        let wire = try AccountGroupApprovalDraft(event: replacingSignatures(e, subject: Data())).wireDraft()
        let raw = "{\"payload\":\"\(wire.payload)\",\"signature\":\"\(wire.signature)\"}"
        let invalid = [raw + "{}", raw + "x", "null", "[]", "{}", String(repeating: " ", count: 8193),
            raw.replacingOccurrences(of: "{", with: "{\"payload\":\"\","),
            raw.replacingOccurrences(of: "{", with: "{\"pay\\u006coad\":\"\","),
            raw.replacingOccurrences(of: "{", with: "{\"extra\":\"\","),
            raw.replacingOccurrences(of: "{", with: "{\"subjectSignature\":\"\","),
            "{\"payload\":null,\"signature\":\"\"}", "{\"payload\":1,\"signature\":\"\"}",
            "{\"payload\":[],\"signature\":\"\"}", "{\"payload\":\"\"}",
            "{\"Payload\":\"\",\"signature\":\"\"}", "{\"payload\":\"\\q\",\"signature\":\"\"}",
            "{\"payload\":\"Zh==\",\"signature\":\"\"}", "{\"payload\":\"\",\"signature\":\"Zg\"}",
            "{\"payload\":\"\(String(repeating: "A", count: 4097))\",\"signature\":\"\"}",
            "{\"payload\":\"\",\"signature\":\"\(String(repeating: "A", count: 109))\"}"]
        for bad in invalid {
            XCTAssertThrowsError(try AccountGroupWireApprovalDraft.decodeJSON(Data(bad.utf8))) {
                XCTAssertEqual($0 as? AccountGroupProofError, .invalidEvent)
            }
        }
        XCTAssertThrowsError(try AccountGroupEvent(wire: AccountGroupWireEvent(payload: wire.payload, signature: wire.signature, subjectSignature: "")))
        for signature in ["", wire.signature + "\n", "Zh==", String(repeating: "A", count: 109)] {
            XCTAssertThrowsError(try AccountGroupApprovalDraft(wire: AccountGroupWireApprovalDraft(payload: wire.payload, signature: signature)))
        }
        for payload in [wire.payload + "\n", "Zh==", String(repeating: "A", count: 4097)] {
            XCTAssertThrowsError(try AccountGroupApprovalDraft(wire: AccountGroupWireApprovalDraft(payload: payload, signature: wire.signature)))
        }
    }

    func testMalformedCanonicalBytesRemainRejectedEvenWhenActorResigns() throws {
        let a = P256.Signing.PrivateKey(), b = P256.Signing.PrivateKey()
        let e = try groupEvent(actor: a, subject: b, action: "approve", sequence: 2, previous: Data(repeating: 42, count: 32))
        let source = String(decoding: try e.canonicalPayload(), as: UTF8.self)
        let bad = [source + " ", " " + source, source + "{}",
            source.replacingOccurrences(of: "{", with: "{\"extra\":null,"),
            source.replacingOccurrences(of: "\"sequence\":2", with: "\"sequence\":2,\"sequence\":2"),
            source.replacingOccurrences(of: "\"sequence\":2", with: "\"sequence\":2e0"),
            source.replacingOccurrences(of: "\"sequence\":2", with: "\"sequence\":2.0"),
            source.replacingOccurrences(of: "\"sequence\":2,", with: ""),
            source.replacingOccurrences(of: "\"sequence\":2", with: "\"sequence\":null"),
            source.replacingOccurrences(of: "\"accountID\":", with: "\"AccountID\":"),
            source.replacingOccurrences(of: "\"generation\":1,\"groupID\":\"\(groupID)\"", with: "\"groupID\":\"\(groupID)\",\"generation\":1")]
        for json in bad {
            let data = Data(json.utf8)
            XCTAssertThrowsError(try AccountGroupApprovalDraft(wire: AccountGroupWireApprovalDraft(
                payload: data.base64EncodedString(), signature: a.signature(for: data).derRepresentation.base64EncodedString())))
        }
    }

    func testStructureRepresentationAndHistoryCannotBeBypassed() throws {
        let a = P256.Signing.PrivateKey(), b = P256.Signing.PrivateKey()
        let anchor = try groupEvent(actor: a, subject: a)
        let full = try groupEvent(actor: a, subject: b, action: "approve", sequence: 2, previous: anchor.digest())
        let draft = try AccountGroupApprovalDraft(event: replacingSignatures(full, subject: Data()))
        var state = try groupState(anchor); let before = state.snapshot
        XCTAssertThrowsError(try state.apply(draft.event))
        XCTAssertEqual(state.snapshot, before)
        let source = String(decoding: try full.canonicalPayload(), as: UTF8.self)
        var mutated = [source.replacingOccurrences(of: "\"sequence\":2", with: "\"sequence\":1"),
            source.replacingOccurrences(of: "\"generation\":1", with: "\"generation\":0"),
            source.replacingOccurrences(of: full.previousHash.base64EncodedString(), with: ""),
            source.replacingOccurrences(of: full.actorDeviceID, with: full.subjectDeviceID),
            source.replacingOccurrences(of: full.subjectDeviceID, with: full.actorDeviceID)]
        for (key, id) in [(full.actorPublicKey, full.actorDeviceID), (full.subjectPublicKey, full.subjectDeviceID)] {
            let form65 = Data([4]) + key
            mutated.append(source.replacingOccurrences(of: key.base64EncodedString(), with: form65.base64EncodedString())
                .replacingOccurrences(of: id, with: try AccountGroupEvent.deviceID(publicKey: form65)))
            for invalid in [Data(repeating: 0, count: 64), Data(repeating: 0, count: 65), Data([4])] {
                mutated.append(source.replacingOccurrences(of: key.base64EncodedString(), with: invalid.base64EncodedString())
                    .replacingOccurrences(of: id, with: groupIdentity(invalid)))
            }
        }
        for json in mutated {
            XCTAssertThrowsError(try AccountGroupApprovalDraft(wire: AccountGroupWireApprovalDraft(
                payload: Data(json.utf8).base64EncodedString(), signature: full.signature.base64EncodedString())))
        }
        let wrongBytes = try b.signature(for: Data([1])).derRepresentation
        XCTAssertThrowsError(try draft.finalize(subjectSignature: wrongBytes))
        var copy = draft.event.actorPublicKey; copy[copy.startIndex] ^= 1
        var subject = full.subjectSignature
        let final = try draft.finalize(subjectSignature: subject); subject[subject.startIndex] ^= 1
        XCTAssertEqual(try final.digest(), try full.digest())
        XCTAssertEqual(draft.event.actorPublicKey, full.actorPublicKey)
    }

    private func replacingSignatures(_ e: AccountGroupEvent, actor: Data? = nil, subject: Data? = nil) throws -> AccountGroupEvent {
        try AccountGroupEvent(accountID: e.accountID, groupID: e.groupID, generation: e.generation,
            sequence: e.sequence, previousHash: e.previousHash, action: e.action,
            actorDeviceID: e.actorDeviceID, actorPublicKey: e.actorPublicKey,
            subjectDeviceID: e.subjectDeviceID, subjectPublicKey: e.subjectPublicKey,
            epochMilliseconds: e.epochMilliseconds, signature: actor ?? e.signature,
            subjectSignature: subject ?? e.subjectSignature)
    }
}
