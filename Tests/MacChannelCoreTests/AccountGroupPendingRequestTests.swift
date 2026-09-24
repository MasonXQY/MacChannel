import CryptoKit
import Foundation
import XCTest
@testable import MacChannelCore

let pendingID = "99999999-9999-9999-9999-999999999999"

final class AccountGroupPendingRequestTests: XCTestCase {
    func testCrossLanguageLiteralRecordsProofsAndAllRetainedTerminalStates() throws {
        for fixture in try pendingFixtures() {
            XCTAssertEqual(fixture.records.count, 8)
            for entry in fixture.records {
                let record = try AccountGroupPendingRequest(data: Data(entry.json.utf8))
                XCTAssertEqual(record.summary.status.rawValue, entry.status)
                if let draft = record.draft {
                    XCTAssertEqual(try draft.event.canonicalPayload().base64EncodedString(), fixture.canonicalPayload)
                    XCTAssertEqual(Data(SHA256.hash(data: try draft.event.canonicalPayload())).hex, fixture.draftDigest)
                }
                if let event = record.event { XCTAssertEqual(try event.digest().hex, fixture.finalizedDigest) }
                if let hash = record.eventHash { XCTAssertEqual(hash.hex, fixture.finalizedDigest) }
                if [.rejected, .cancelled, .expired, .invalidated].contains(record.summary.status) {
                    XCTAssertNoThrow(try AccountGroupPendingRequest(summary: record.summary, draft: nil, event: nil, eventHash: nil))
                    XCTAssertNoThrow(try AccountGroupPendingRequest(summary: record.summary, draft: record.draft, event: nil, eventHash: nil))
                    XCTAssertThrowsError(try AccountGroupPendingRequest(summary: record.summary, draft: nil, event: record.event, eventHash: nil))
                    XCTAssertThrowsError(try AccountGroupPendingRequest(summary: record.summary, draft: record.draft, event: record.event, eventHash: Data(repeating: 0, count: 32)))
                }
            }
            let summaries = try AccountGroupPendingSummary.decodeList(Data(fixture.listJSON.utf8))
            XCTAssertEqual(summaries.map(\.status), [.requested, .proposed, .countersigned])
            print("ACCEPTED pending fixture \(fixture.name): \(fixture.finalizedDigest)")
        }
    }

    func testEveryFullFieldAndProofSchemaRejectsMissingNullTypeUnknownAndDuplicate() throws {
        let raw = try XCTUnwrap(pendingFixtures().first?.records.first(where: { $0.status == "committed" })?.json)
        let wrapper = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let object = try XCTUnwrap(wrapper["request"] as? [String: Any])
        for key in object.keys {
            var missing = object; missing.removeValue(forKey: key)
            XCTAssertThrowsError(try AccountGroupPendingRequest(data: pendingJSON(["request": missing])))
            for bad: Any in [NSNull(), true, [], 1.5] {
                var wrong = object; wrong[key] = bad
                XCTAssertThrowsError(try AccountGroupPendingRequest(data: pendingJSON(["request": wrong])))
            }
            let duplicate = raw.replacingOccurrences(of: "\"request\":{", with: "\"request\":{\"\(key)\":null,")
            XCTAssertThrowsError(try AccountGroupPendingRequest(data: Data(duplicate.utf8)))
        }
        for proof in ["draft", "event"] {
            let original = try XCTUnwrap(object[proof] as? [String: Any])
            for key in original.keys {
                for value: Any in [NSNull(), true, [], "", "Zh==", "AAAA", String(repeating: "A", count: 5500)] {
                    var badProof = original; badProof[key] = value
                    var bad = object; bad[proof] = badProof
                    XCTAssertThrowsError(try AccountGroupPendingRequest(data: pendingJSON(["request": bad])))
                }
                var missing = original; missing.removeValue(forKey: key)
                var bad = object; bad[proof] = missing
                XCTAssertThrowsError(try AccountGroupPendingRequest(data: pendingJSON(["request": bad])))
            }
        }
        for alias in ["payload", "pay\\u006coad"] {
            let bad = raw.replacingOccurrences(of: "\"draft\":{", with: "\"draft\":{\"\(alias)\":\"\",")
            XCTAssertThrowsError(try AccountGroupPendingRequest(data: Data(bad.utf8)))
        }
        for field in ["requestID", "accountID", "groupID", "deviceID", "publicKey", "generation", "createdAt", "expiresAt"] {
            var bad = object
            if ["generation", "createdAt", "expiresAt"].contains(field) { bad[field] = 0 }
            else { bad[field] = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA" }
            XCTAssertThrowsError(try AccountGroupPendingRequest(data: pendingJSON(["request": bad])))
        }
        for field in ["generation", "createdAt", "expiresAt"] {
            let value = String(describing: object[field]!)
            for invalid in ["0", "-1", "01", "1.0", "1e0", "\"1\"", "18446744073709551616", "9007199254740992"] {
                // Generation permits safe signed64 range; its overflow has a separate vector.
                if field == "generation", invalid == "9007199254740992" { continue }
                let bad = raw.replacingOccurrences(of: "\"\(field)\":\(value)", with: "\"\(field)\":\(invalid)")
                XCTAssertThrowsError(try AccountGroupPendingRequest(data: Data(bad.utf8)))
            }
        }
        for field in ["publicKey", "eventHash"] {
            for value in ["", "Zh==", (object[field] as! String) + "\n", String((object[field] as! String).dropLast()), Data(repeating: 0, count: 32).base64EncodedString()] {
                var bad = object; bad[field] = value
                XCTAssertThrowsError(try AccountGroupPendingRequest(data: pendingJSON(["request": bad])))
            }
        }
    }

    func testDirectInitializerEnforcesBindingsStatesAndExactIntegerTimes() throws {
        let entries = try pendingFixtures()
        let full = try AccountGroupPendingRequest(data: Data(entries[0].records[3].json.utf8))
        let other = try AccountGroupPendingRequest(data: Data(entries[1].records[3].json.utf8))
        let s = full.summary
        func summary(account: String? = nil, group: String? = nil, generation: UInt64? = nil, key: Data? = nil,
                     device: String? = nil, status: AccountGroupPendingStatus = .committed,
                     created: UInt64 = 1, expires: UInt64 = 300001) throws -> AccountGroupPendingSummary {
            try .init(requestID: s.requestID, accountID: account ?? s.accountID, groupID: group ?? s.groupID,
                generation: generation ?? s.generation, deviceID: device ?? s.deviceID, publicKey: key ?? s.publicKey,
                status: status, createdAtMilliseconds: created, expiresAtMilliseconds: expires)
        }
        for wrong in [try summary(account: groupID), try summary(group: groupAccount), try summary(generation: 2),
                      try summary(key: other.summary.publicKey, device: other.summary.deviceID)] {
            XCTAssertThrowsError(try AccountGroupPendingRequest(summary: wrong, draft: full.draft, event: full.event, eventHash: full.eventHash))
        }
        for (created, expires): (UInt64, UInt64) in [(0,300000), (1,300000), (2,1), (UInt64.max,0), (9_007_199_254_440_992,9_007_199_254_740_992)] {
            XCTAssertThrowsError(try summary(created: created, expires: expires))
        }
        let maximum = try summary(created: 9_007_199_254_440_991, expires: 9_007_199_254_740_991)
        XCTAssertEqual(maximum.createdAtMilliseconds, 9_007_199_254_440_991)
        XCTAssertEqual(maximum.expiresAtMilliseconds, 9_007_199_254_740_991)
        XCTAssertThrowsError(try summary(generation: UInt64(Int64.max) + 1))
        XCTAssertThrowsError(try summary(key: Data(repeating: 0, count: 64)))
        // Same curve point in another encoding has a different derived identity.
        XCTAssertThrowsError(try summary(key: other.summary.publicKey))
        for status in AccountGroupPendingStatus.allCases {
            let summary = try summary(status: status)
            if status != .committed {
                XCTAssertThrowsError(try AccountGroupPendingRequest(summary: summary, draft: full.draft, event: full.event, eventHash: full.eventHash))
            }
        }
        XCTAssertThrowsError(try AccountGroupPendingRequest(summary: s, draft: full.draft, event: full.event, eventHash: Data(repeating: 0, count: 32)))
        XCTAssertThrowsError(try AccountGroupPendingRequest(summary: s, draft: full.draft, event: other.event, eventHash: full.eventHash))
    }

    func testSummaryListBoundsUniquenessAndStrictSchema() throws {
        let raw = try pendingFixtures()[0].listJSON
        let source = try XCTUnwrap((JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])?["requests"] as? [[String: Any]])
        let original = source[0]
        for key in original.keys {
            var missing = original; missing.removeValue(forKey: key)
            XCTAssertThrowsError(try AccountGroupPendingSummary.decodeList(pendingJSON(["requests": [missing]])))
            for value: Any in [NSNull(), true, [], 1.5] {
                var bad = original; bad[key] = value
                XCTAssertThrowsError(try AccountGroupPendingSummary.decodeList(pendingJSON(["requests": [bad]])))
            }
        }
        for terminal in ["committed", "cancelled", "rejected", "expired", "invalidated", "unknown"] {
            var bad = original; bad["status"] = terminal
            XCTAssertThrowsError(try AccountGroupPendingSummary.decodeList(pendingJSON(["requests": [bad]])))
        }
        var rows: [[String: Any]] = []
        for i in 0..<33 {
            var row = original; row["requestID"] = String(format: "99999999-9999-9999-9999-%012d", i)
            rows.append(row)
        }
        XCTAssertEqual(try AccountGroupPendingSummary.decodeList(pendingJSON(["requests": Array(rows.prefix(32))])).count, 32)
        XCTAssertThrowsError(try AccountGroupPendingSummary.decodeList(pendingJSON(["requests": rows])))
        XCTAssertThrowsError(try AccountGroupPendingSummary.decodeList(pendingJSON(["requests": [original, original]])))
        var proof = original; proof["draft"] = NSNull()
        XCTAssertThrowsError(try AccountGroupPendingSummary.decodeList(pendingJSON(["requests": [proof]])))
        for bad in [raw + "x", raw.replacingOccurrences(of: "\"requests\":", with: "\"requests\":[],\"requests\":"), raw.replacingOccurrences(of: "\"requestID\":", with: "\"request\\u0049D\":null,\"requestID\":")] {
            XCTAssertThrowsError(try AccountGroupPendingSummary.decodeList(Data(bad.utf8)))
        }
    }
    func testRequestedRoundTripAndStrictSchema() throws {
        let identity = try DeviceIdentity.ephemeral()
        let object = pendingObject(identity)
        let data = try pendingJSON(["request": object])
        let record = try AccountGroupPendingRequest(data: data)
        XCTAssertEqual(record.summary.createdAtMilliseconds, 1)
        XCTAssertEqual(record.summary.expiresAtMilliseconds, 300001)
        XCTAssertEqual(record.summary.publicKey, identity.publicKey.rawRepresentation)
        XCTAssertNil(record.draft)
        for key in object.keys {
            var missing = object; missing.removeValue(forKey: key)
            XCTAssertThrowsError(try AccountGroupPendingRequest(data: pendingJSON(["request": missing])))
            for bad: Any in [true, [], 1.5] {
                var wrong = object; wrong[key] = bad
                XCTAssertThrowsError(try AccountGroupPendingRequest(data: pendingJSON(["request": wrong])))
            }
            if !["draft", "event", "eventHash"].contains(key) {
                var null = object; null[key] = NSNull()
                XCTAssertThrowsError(try AccountGroupPendingRequest(data: pendingJSON(["request": null])))
            }
        }
        let raw = String(decoding: data, as: UTF8.self)
        for bad in [raw + "{}", raw + "x", raw.replacingOccurrences(of: "\"requestID\":", with: "\"request\\u0049D\":null,\"requestID\":"), raw.replacingOccurrences(of: "\"request\":", with: "\"extra\":null,\"request\":")] {
            XCTAssertThrowsError(try AccountGroupPendingRequest(data: Data(bad.utf8)))
        }
        let padded = data + Data(repeating: 32, count: 65_536 - data.count)
        XCTAssertNoThrow(try AccountGroupPendingRequest(data: padded))
        XCTAssertThrowsError(try AccountGroupPendingRequest(data: padded + Data([32])))
    }
}

struct PendingFixture: Decodable {
    struct Record: Decodable { let status, json: String }
    let name, canonicalPayload, draftDigest, finalizedDigest, listJSON: String
    let records: [Record]
}
func pendingFixtures() throws -> [PendingFixture] {
    struct Wrapper: Decodable { let fixtures: [PendingFixture] }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try JSONDecoder().decode(Wrapper.self, from: Data(contentsOf: root.appendingPathComponent("Fixtures/account-group-pending-v1.json"))).fixtures
}
private extension Data { var hex: String { map { String(format: "%02x", $0) }.joined() } }

func pendingObject(_ identity: DeviceIdentity) -> [String: Any] {
    ["requestID": pendingID, "accountID": groupAccount, "groupID": groupID,
     "generation": 1, "deviceID": identity.id.rawValue.uuidString.lowercased(),
     "publicKey": identity.publicKey.rawRepresentation.base64EncodedString(), "status": "requested",
     "createdAt": 1, "expiresAt": 300001, "draft": NSNull(), "event": NSNull(), "eventHash": NSNull()]
}
func pendingJSON(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
}
