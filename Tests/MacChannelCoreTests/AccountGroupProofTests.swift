import CryptoKit
import Foundation
import XCTest
@testable import MacChannelCore

final class AccountGroupProofTests: XCTestCase {
    func testSignedBootstrapRoundTrip() throws {
        let key = P256.Signing.PrivateKey()
        let event = try groupEvent(actor: key, subject: key)
        XCTAssertEqual(try AccountGroupEvent(wire: event.wireEvent()), event)
    }
    func testUnsignedAnchorRejectedEvenWithExactPins() throws {
        let key = P256.Signing.PrivateKey()
        let event = try groupEvent(actor: key, subject: key, signed: false)
        let hash = Data(SHA256.hash(data: try event.canonicalPayload()))
        XCTAssertThrowsError(try AccountGroupState(anchor: event, expectedAccountID: groupAccount,
            expectedGroupID: groupID, expectedGeneration: 1, expectedAnchorHash: hash))
    }
    func testMembershipRemovalReplayFreshRejoinAndTerminalEmpty() throws {
        let a = P256.Signing.PrivateKey(), b = P256.Signing.PrivateKey()
        let anchor = try groupEvent(actor: a, subject: a)
        var state = try groupState(anchor)
        let initial = state.snapshot
        let approval = try groupEvent(actor: a, subject: b, action: "approve", sequence: 2, previous: anchor.digest())
        try state.apply(approval)
        XCTAssertEqual(state.snapshot.members.count, 2)
        let copy = state
        try state.apply(groupEvent(actor: b, subject: b, action: "remove", sequence: 3, previous: approval.digest()))
        XCTAssertEqual(copy.snapshot.members.count, 2)
        let removed = state.snapshot
        XCTAssertThrowsError(try state.apply(approval))
        XCTAssertEqual(state.snapshot, removed)
        try state.apply(groupEvent(actor: a, subject: b, action: "approve", sequence: 4, previous: removed.headHash))
        try state.apply(groupEvent(actor: a, subject: b, action: "remove", sequence: 5, previous: state.snapshot.headHash))
        try state.apply(groupEvent(actor: a, subject: a, action: "remove", sequence: 6, previous: state.snapshot.headHash))
        XCTAssertEqual(state.snapshot.members.count, 0)
        let terminal = state.snapshot
        XCTAssertThrowsError(try state.apply(groupEvent(actor: a, subject: b, action: "approve", sequence: 7, previous: terminal.headHash)))
        XCTAssertEqual(state.snapshot, terminal)
        XCTAssertEqual(initial.members.count, 1)
    }

    func testCanonicalGoldenBothKeyFormsAndSignatureIndependentDigest() throws {
        // P256 generator (private scalar 1), known independently of codec.
        let raw = Data(hex: "6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2964fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5")
        let key = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0, count: 31) + Data([1]))
        XCTAssertEqual(key.publicKey.rawRepresentation, raw)
        for form65 in [false, true] {
            let e = try groupEvent(actor: key, subject: key, raw65: form65)
            let bytes = form65 ? Data([4]) + raw : raw
            // Independently computed with xxd | shasum -a 256, no UUID bit rewriting.
            let id = form65 ? "698bea63-dc44-a344-663f-f1429aea1084" : "d875db7d-ef23-2236-aec7-38c6b0bb3e80"
            XCTAssertEqual(groupIdentity(bytes), id)
            XCTAssertEqual(try AccountGroupEvent.deviceID(publicKey: bytes), id)
            XCTAssertEqual(e.actorPublicKey, bytes)
            let golden = "{\"accountID\":\"11111111-1111-1111-1111-111111111111\",\"action\":\"bootstrap\",\"actorDeviceID\":\"\(id)\",\"actorPublicKey\":\"\(bytes.base64EncodedString())\",\"epochMilliseconds\":1800000000000,\"generation\":1,\"groupID\":\"22222222-2222-2222-2222-222222222222\",\"previousHash\":\"\",\"purpose\":\"dropmesh.account.group.event.v1\",\"sequence\":1,\"subjectDeviceID\":\"\(id)\",\"subjectPublicKey\":\"\(bytes.base64EncodedString())\"}"
            XCTAssertEqual(try e.canonicalPayload(), Data(golden.utf8))
            XCTAssertEqual(try AccountGroupEvent(wire: e.wireEvent()), e)
            let second = try groupEvent(actor: key, subject: key, raw65: form65)
            XCTAssertNotEqual(e.signature, second.signature)
            XCTAssertEqual(try e.digest(), try second.digest())
        }
        XCTAssertNotEqual(groupIdentity(raw), groupIdentity(Data([4]) + raw))
    }

    func testEveryBoundPayloadFieldTamperingRejected() throws {
        let a = P256.Signing.PrivateKey(), b = P256.Signing.PrivateKey()
        let anchor = try groupEvent(actor: a, subject: a)
        let e = try groupEvent(actor: a, subject: b, action: "approve", sequence: 2, previous: anchor.digest())
        let wire = try e.wireEvent()
        let source = String(decoding: try e.canonicalPayload(), as: UTF8.self)
        let pairs: [(String, String)] = [
            (groupAccount, "33333333-3333-3333-3333-333333333333"),
            (groupID, "44444444-4444-4444-4444-444444444444"),
            ("\"generation\":1", "\"generation\":2"), ("\"sequence\":2", "\"sequence\":3"),
            ("1800000000000", "1800000000001"), ("\"approve\"", "\"remove\""),
            (e.actorDeviceID, groupIdentity(b.publicKey.rawRepresentation)),
            (e.actorPublicKey.base64EncodedString(), b.publicKey.rawRepresentation.base64EncodedString()),
            (e.subjectDeviceID, groupIdentity(a.publicKey.rawRepresentation)),
            (e.subjectPublicKey.base64EncodedString(), a.publicKey.rawRepresentation.base64EncodedString()),
            (e.previousHash.base64EncodedString(), Data(repeating: 0, count: 32).base64EncodedString())
        ]
        for (before, after) in pairs {
            XCTAssertThrowsError(try AccountGroupEvent(wire: AccountGroupWireEvent(
                payload: Data(source.replacingOccurrences(of: before, with: after).utf8).base64EncodedString(),
                signature: wire.signature, subjectSignature: wire.subjectSignature)), before)
        }
        for invalid in ["", Data(repeating: 0, count: 81).base64EncodedString(), try b.signature(for: Data([1])).derRepresentation.base64EncodedString()] {
            XCTAssertThrowsError(try AccountGroupEvent(wire: AccountGroupWireEvent(payload: wire.payload, signature: invalid, subjectSignature: wire.subjectSignature)))
            XCTAssertThrowsError(try AccountGroupEvent(wire: AccountGroupWireEvent(payload: wire.payload, signature: wire.signature, subjectSignature: invalid)))
        }
        let bootstrap = try anchor.wireEvent()
        XCTAssertThrowsError(try AccountGroupEvent(wire: AccountGroupWireEvent(payload: bootstrap.payload, signature: bootstrap.signature, subjectSignature: bootstrap.signature)))
        let unsigned = try groupEvent(actor: a, subject: a, signed: false)
        XCTAssertThrowsError(try unsigned.digest())
        XCTAssertThrowsError(try unsigned.wireEvent())
    }

    func testNoncanonicalPayloadAndStrictBase64Rejected() throws {
        let a = P256.Signing.PrivateKey()
        let e = try groupEvent(actor: a, subject: a)
        let w = try e.wireEvent()
        let source = String(decoding: try e.canonicalPayload(), as: UTF8.self)
        let malformed = [
            source + " ", source + "{}", " " + source,
            source.replacingOccurrences(of: "{", with: "{\"extra\":0,"),
            source.replacingOccurrences(of: "{", with: "{\"accountID\":\"\(groupAccount)\","),
            source.replacingOccurrences(of: "\"sequence\":1", with: "\"sequence\":1.0"),
            source.replacingOccurrences(of: "\"sequence\":1", with: "\"sequence\":1e0"),
            source.replacingOccurrences(of: "\"sequence\":1,", with: ""),
            source.replacingOccurrences(of: "\"sequence\":1", with: "\"sequence\":null"),
            source.replacingOccurrences(of: "dropmesh.account.group.event.v1", with: "wrong"),
            source.replacingOccurrences(of: "\"generation\":1,\"groupID\":\"\(groupID)\"", with: "\"groupID\":\"\(groupID)\",\"generation\":1"),
            source.replacingOccurrences(of: "accountID", with: "AccountID"),
            source.replacingOccurrences(of: "\"sequence\":1", with: "\"sequence\":\"1\"")
        ]
        for payload in malformed {
            // Re-sign malformed bytes: rejection must be canonical/schema based.
            XCTAssertThrowsError(try AccountGroupEvent(wire: AccountGroupWireEvent(
                payload: Data(payload.utf8).base64EncodedString(),
                signature: a.signature(for: Data(payload.utf8)).derRepresentation.base64EncodedString(), subjectSignature: "")))
        }
        for payload in [String(repeating: "A", count: 4097), w.payload + "\n", w.payload + "=", "-___", "Zh==", "Zg"] {
            XCTAssertThrowsError(try AccountGroupEvent(wire: AccountGroupWireEvent(payload: payload, signature: w.signature, subjectSignature: "")))
        }
        for signature in [String(repeating: "A", count: 109), w.signature + "\n", "Zh=="] {
            XCTAssertThrowsError(try AccountGroupEvent(wire: AccountGroupWireEvent(payload: w.payload, signature: signature, subjectSignature: "")))
        }
    }

    func testOuterJSONStrictHelperAndCodableLimits() throws {
        let valid = "{\"payload\":\"\",\"signature\":\"\",\"subjectSignature\":\"\"}"
        XCTAssertEqual(try AccountGroupWireEvent.decodeJSON(Data(valid.utf8)), AccountGroupWireEvent(payload: "", signature: "", subjectSignature: ""))
        let invalid = [valid + "{}", valid.replacingOccurrences(of: "{", with: "{\"payload\":\"\","),
            valid.replacingOccurrences(of: "{", with: "{\"pay\\u006coad\":\"\","),
            valid.replacingOccurrences(of: "\"payload\":\"\",", with: ""),
            valid.replacingOccurrences(of: "\"payload\":\"\"", with: "\"payload\":null"),
            valid.replacingOccurrences(of: "\"payload\":\"\"", with: "\"payload\":1"),
            valid.replacingOccurrences(of: "{", with: "{\"extra\":\"\","),
            String(repeating: " ", count: 8193), "[]", "{\"payload\":\"unterminated\\"]
        for json in invalid { XCTAssertThrowsError(try AccountGroupWireEvent.decodeJSON(Data(json.utf8)), json.prefix(100).description) }
        // Document Foundation's duplicate-key limitation explicitly; raw helper closes it.
        let duplicate = Data(valid.replacingOccurrences(of: "{", with: "{\"payload\":\"\",").utf8)
        XCTAssertNoThrow(try JSONDecoder().decode(AccountGroupWireEvent.self, from: duplicate))
        for json in invalid.dropFirst(3).dropLast(3) {
            XCTAssertThrowsError(try JSONDecoder().decode(AccountGroupWireEvent.self, from: Data(json.utf8)))
        }
        let long = AccountGroupWireEvent(payload: String(repeating: "A", count: 4097), signature: "", subjectSignature: "")
        XCTAssertThrowsError(try JSONDecoder().decode(AccountGroupWireEvent.self, from: JSONEncoder().encode(long)))
    }
    func testRawWireErrorsAreGeneric() {
        for json in ["{\"payload\":\"\\q\",\"signature\":\"\",\"subjectSignature\":\"\"}",
                     "{\"payload\":null,\"signature\":\"\",\"subjectSignature\":\"\"}",
                     "{\"payload\":3,\"signature\":\"\",\"subjectSignature\":\"\"}"] {
            XCTAssertThrowsError(try AccountGroupWireEvent.decodeJSON(Data(json.utf8))) { error in
                XCTAssertEqual(error as? AccountGroupProofError, .invalidEvent)
            }
        }
    }

    func testPinsAndInvalidTransitionsLeaveStateUnchanged() throws {
        let a = P256.Signing.PrivateKey(), b = P256.Signing.PrivateKey(), c = P256.Signing.PrivateKey()
        let anchor = try groupEvent(actor: a, subject: a, generation: 2)
        let hash = try anchor.digest()
        for (account, group, generation, digest) in [(groupID, groupID, UInt64(2), hash),
            (groupAccount, groupAccount, 2, hash), (groupAccount, groupID, 1, hash),
            (groupAccount, groupID, 2, Data(repeating: 0, count: 32))] {
            XCTAssertThrowsError(try AccountGroupState(anchor: anchor, expectedAccountID: account,
                expectedGroupID: group, expectedGeneration: generation, expectedAnchorHash: digest))
        }
        var state = try groupState(anchor)
        for event in [
            try groupEvent(actor: a, subject: b, action: "approve", sequence: 2, previous: hash, generation: 1),
            try groupEvent(actor: a, subject: b, action: "approve", sequence: 3, previous: hash, generation: 2),
            try groupEvent(actor: a, subject: b, action: "approve", sequence: 2, previous: Data(repeating: 0, count: 32), generation: 2),
            try groupEvent(actor: c, subject: b, action: "approve", sequence: 2, previous: hash, generation: 2),
            try groupEvent(actor: a, subject: b, action: "remove", sequence: 2, previous: hash, generation: 2)
        ] {
            let before = state.snapshot
            XCTAssertThrowsError(try state.apply(event))
            XCTAssertEqual(state.snapshot, before)
        }
        try state.apply(groupEvent(actor: a, subject: b, action: "approve", sequence: 2, previous: hash, generation: 2))
        let before = state.snapshot
        XCTAssertThrowsError(try state.apply(groupEvent(actor: a, subject: b, action: "approve", sequence: 3, previous: before.headHash, generation: 2)))
        XCTAssertEqual(state.snapshot, before)
    }

    func testMemberCapAndSortedOwnedSnapshots() throws {
        let a = P256.Signing.PrivateKey()
        var state = try groupState(groupEvent(actor: a, subject: a))
        for sequence in 2...64 {
            try state.apply(groupEvent(actor: a, subject: P256.Signing.PrivateKey(), action: "approve",
                sequence: UInt64(sequence), previous: state.snapshot.headHash))
        }
        let full = state.snapshot
        XCTAssertEqual(full.members.count, 64)
        XCTAssertEqual(full.members.map(\.deviceID), full.members.map(\.deviceID).sorted())
        XCTAssertThrowsError(try state.apply(groupEvent(actor: a, subject: P256.Signing.PrivateKey(), action: "approve", sequence: 65, previous: full.headHash)))
        XCTAssertEqual(state.snapshot, full)
        var hash = full.headHash; hash[0] ^= 1
        var key = full.members[0].publicKey; key[key.startIndex] ^= 1
        XCTAssertEqual(state.snapshot, full)
    }

    func testIntegerBoundsAndIdentityRejections() throws {
        let a = P256.Signing.PrivateKey(), b = P256.Signing.PrivateKey()
        for generation in [UInt64(0), UInt64(Int64.max) + 1, UInt64.max] {
            XCTAssertThrowsError(try groupEvent(actor: a, subject: a, generation: generation))
        }
        for sequence in [UInt64(0), UInt64(Int64.max) + 1, UInt64.max] {
            XCTAssertThrowsError(try groupEvent(actor: a, subject: b, action: "approve", sequence: sequence, previous: Data(repeating: 1, count: 32)))
        }
        let max = try groupEvent(actor: a, subject: b, action: "approve", sequence: UInt64(Int64.max), previous: Data(repeating: 1, count: 32), generation: UInt64(Int64.max))
        XCTAssertEqual(try AccountGroupEvent(wire: max.wireEvent()), max)
        XCTAssertTrue(String(decoding: try max.canonicalPayload(), as: UTF8.self).contains("9223372036854775807"))
        var state = try groupState(groupEvent(actor: a, subject: a, generation: UInt64(Int64.max)))
        let before = state.snapshot
        XCTAssertThrowsError(try state.apply(max))
        XCTAssertEqual(state.snapshot, before)
        for key in [Data(), Data(repeating: 0, count: 64), Data(repeating: 0, count: 65), Data(repeating: 4, count: 66)] {
            XCTAssertThrowsError(try AccountGroupEvent.deviceID(publicKey: key))
        }
        let e = try groupEvent(actor: a, subject: a)
        for (account, timestamp, actorID, subjectKey) in [("AAAAAAAA-1111-1111-1111-111111111111", Int64(1), e.actorDeviceID, e.subjectPublicKey),
            (groupAccount, 0, e.actorDeviceID, e.subjectPublicKey), (groupAccount, -1, e.actorDeviceID, e.subjectPublicKey),
            (groupAccount, 1, e.actorDeviceID.uppercased(), e.subjectPublicKey), (groupAccount, 1, e.actorDeviceID, b.publicKey.rawRepresentation)] {
            XCTAssertThrowsError(try AccountGroupEvent(accountID: account, groupID: groupID, generation: 1, sequence: 1,
                previousHash: Data(), action: "bootstrap", actorDeviceID: actorID, actorPublicKey: e.actorPublicKey,
                subjectDeviceID: e.subjectDeviceID, subjectPublicKey: subjectKey, epochMilliseconds: timestamp))
        }
    }
}

private extension Data {
    init(hex: String) {
        self.init(stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        })
    }
}

let groupAccount = "11111111-1111-1111-1111-111111111111"
let groupID = "22222222-2222-2222-2222-222222222222"
func groupState(_ anchor: AccountGroupEvent) throws -> AccountGroupState {
    try AccountGroupState(anchor: anchor, expectedAccountID: groupAccount, expectedGroupID: groupID,
        expectedGeneration: anchor.generation, expectedAnchorHash: anchor.digest())
}
func groupIdentity(_ key: Data) -> String {
    let hex = SHA256.hash(data: key).prefix(16).map { String(format: "%02x", $0) }.joined()
    return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(Array(hex)[$0]) }.joined(separator: "-")
}
func groupEvent(actor: P256.Signing.PrivateKey, subject: P256.Signing.PrivateKey,
                action: String = "bootstrap", sequence: UInt64 = 1, previous: Data = Data(),
                generation: UInt64 = 1, raw65: Bool = false, signed: Bool = true) throws -> AccountGroupEvent {
    let a = raw65 ? actor.publicKey.x963Representation : actor.publicKey.rawRepresentation
    let s = raw65 ? subject.publicKey.x963Representation : subject.publicKey.rawRepresentation
    func make(_ signature: Data = Data(), _ subjectSignature: Data = Data()) throws -> AccountGroupEvent {
        try AccountGroupEvent(accountID: groupAccount, groupID: groupID, generation: generation,
            sequence: sequence, previousHash: previous, action: action, actorDeviceID: groupIdentity(a), actorPublicKey: a,
            subjectDeviceID: groupIdentity(s), subjectPublicKey: s, epochMilliseconds: 1_800_000_000_000,
            signature: signature, subjectSignature: subjectSignature)
    }
    let unsigned = try make()
    guard signed else { return unsigned }
    let payload = try unsigned.canonicalPayload()
    return try make(actor.signature(for: payload).derRepresentation,
                    action == "approve" ? subject.signature(for: payload).derRepresentation : Data())
}
