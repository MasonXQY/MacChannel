import CryptoKit
import Foundation
import XCTest
@testable import MacChannelCore

final class AccountGroupServiceTests: XCTestCase {
    func testSinglePageAndWhitespaceMemberOrder() async throws {
        let history = [try CheckpointHistory().events[0]]
        let source = try groupPage(history)
        let object = try JSONSerialization.jsonObject(with: source)
        let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        let result = try await groupClient(GroupTransport([(200, pretty)])).groupHistory(accessToken: groupToken, groupID: groupID)
        XCTAssertEqual(result, history)
    }

    func testHeadChangeDiscardsPartialCollectionAndRestartsWithEmptyCursor() async throws {
        let history = try CheckpointHistory().events
        let transport = GroupTransport([(200, try groupPage(history, count: 1)), (409, Data("private server detail".utf8)), (200, try groupPage(history))])
        let result = try await groupClient(transport).groupHistory(accessToken: groupToken, groupID: groupID)
        XCTAssertEqual(result, history)
        let requests = await transport.requests
        let fields = try requests.map { try JSONDecoder().decode([String: String].self, from: JSONDecoder().decode(RendezvousSignedEnvelope.self, from: $0.httpBody!).payload) }
        XCTAssertEqual(fields.map { $0["afterSequence"]! }, ["0", "1", "0"])
        XCTAssertEqual(fields.map { $0["expectedHeadHash"]! }, ["", try history.last!.digest().base64EncodedString(), ""])
        let nonces = try requests.map { try JSONDecoder().decode(RendezvousSignedEnvelope.self, from: $0.httpBody!).nonce }
        XCTAssertEqual(Set(nonces).count, 3)
    }

    func testTwoRestartsAllowedAndPersistentConflictStopsAfterThreeAttempts() async throws {
        let history = try CheckpointHistory().events
        let success = GroupTransport([(409, Data()), (409, Data()), (200, try groupPage(history))])
        let result = try await groupClient(success).groupHistory(accessToken: groupToken, groupID: groupID)
        XCTAssertEqual(result, history)
        let failure = GroupTransport(Array(repeating: (409, Data()), count: 4))
        do { _ = try await groupClient(failure).groupHistory(accessToken: groupToken, groupID: groupID); XCTFail("Expected changed head") }
        catch { XCTAssertEqual(error as? AccountGroupServiceError, .changedHead) }
        let count = await failure.requests.count
        XCTAssertEqual(count, 3)
    }

    func testGroupSpecificStatusMappingDoesNotChangeLogin() async throws {
        for (status, expected) in [(404, AccountServiceError.unavailable), (400, .invalidRequest), (401, .authenticationRejected), (403, .authenticationRejected), (429, .rateLimited), (503, .unavailable), (500, .invalidResponse)] {
            await groupServiceFailure(expected) { try await groupClient(GroupTransport([(status, Data("secret error details".utf8))])).groupHistory(accessToken: groupToken, groupID: groupID) }
        }
        for status in [404, 409] {
            await groupServiceFailure(.invalidResponse) { try await groupClient(GroupTransport([(status, Data())])).challenge() }
        }
    }

    func testInputValidationBeforeTransportAndTransportFailure() async throws {
        let transport = GroupTransport([])
        let client = try groupClient(transport)
        for (token, group) in [("invalid", groupID), (groupToken, "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"), (groupToken, "not-uuid")] {
            await groupServiceFailure(.invalidRequest) { try await client.groupHistory(accessToken: token, groupID: group) }
        }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
        await groupServiceFailure(.transport) { try await client.groupHistory(accessToken: groupToken, groupID: groupID) }
    }

    func testMalformedSchemaAndCounterFormsAreRejectedWithoutRetry() async throws {
        let data = try groupPage(CheckpointHistory().events)
        var mutations: [[String: Any]] = []
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in original.keys {
            var missing = original; missing.removeValue(forKey: key); mutations.append(missing)
            var null = original; null[key] = NSNull(); mutations.append(null)
            var wrong = original; wrong[key] = ["wrong"]; mutations.append(wrong)
        }
        var unknown = original; unknown["extra"] = true; mutations.append(unknown)
        for field in ["generation", "headSequence", "afterSequence", "nextSequence"] {
            for value: Any in [true, -1, 1.5, "1"] {
                var mutation = original; mutation[field] = value; mutations.append(mutation)
            }
        }
        for fields in mutations {
            try await rejectPage(JSONSerialization.data(withJSONObject: fields))
        }
        let raw = String(decoding: data, as: UTF8.self)
        for replacement in ["1e0", "1.0", "-0", "01", "9223372036854775808", "18446744073709551616", "0", "true"] {
            try await rejectPage(Data(raw.replacingOccurrences(of: "\"generation\":1", with: "\"generation\":\(replacement)").utf8))
        }
        for suffix in ["{}", "null", "x"] { try await rejectPage(data + Data(suffix.utf8)) }
    }

    func testDuplicateKeysAndEscapedAliasesAtBothBoundaries() async throws {
        let raw = String(decoding: try groupPage(CheckpointHistory().events), as: UTF8.self)
        for injected in ["\"groupID\":\"\(groupID)\",", "\"group\\u0049D\":\"\(groupID)\","] {
            try await rejectPage(Data(("{" + injected + raw.dropFirst()).utf8))
        }
        for name in ["payload", "payl\\u006fad"] {
            let value = raw.replacingOccurrences(of: "\"subjectSignature\":\"\"", with: "\"\(name)\":\"\"")
            try await rejectPage(Data(value.utf8))
        }
    }

    func testCanonicalHashUUIDAndExactNumericBounds() async throws {
        let data = try groupPage(CheckpointHistory().events)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for (key, value): (String, Any) in [("groupID", "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"), ("groupID", "bad"), ("headHash", ""), ("headHash", Data(repeating: 1, count: 31).base64EncodedString()), ("headHash", String((original["headHash"] as! String).dropLast())), ("headSequence", 0), ("headSequence", 8193), ("afterSequence", 8193), ("nextSequence", 8193)] {
            var fields = original; fields[key] = value
            try await rejectPage(JSONSerialization.data(withJSONObject: fields))
        }
        var boundary = original
        boundary["generation"] = Int64.max; boundary["headSequence"] = 8192
        boundary["afterSequence"] = 8192; boundary["nextSequence"] = 8192
        let decoded = try AccountGroupPage(data: JSONSerialization.data(withJSONObject: boundary))
        XCTAssertEqual(decoded.generation, UInt64(Int64.max))
        XCTAssertEqual(decoded.headSequence, 8192)
    }

    func testPageByteAndEventLimits() async throws {
        let history = try makeGroupHistory(17)
        let sixteen = try groupPage(history, count: 16)
        XCTAssertEqual(try AccountGroupPage(data: sixteen).events.count, 16)
        let atLimit = sixteen + Data(repeating: 32, count: 65_536 - sixteen.count)
        XCTAssertEqual(try AccountGroupPage(data: atLimit).events.count, 16)
        try await rejectPage(atLimit + Data([32]))
        try await rejectPage(groupPage(history, count: 17))
    }

    func testCollectorRejectsNoProgressFalseMoreAndWrongMetadata() async throws {
        let history = try CheckpointHistory().events
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: groupPage(history)) as? [String: Any])
        for (key, value): (String, Any) in [("groupID", groupAccount), ("generation", 2), ("afterSequence", 1), ("nextSequence", 2), ("hasMore", true), ("headSequence", 4), ("headHash", Data(repeating: 0, count: 32).base64EncodedString())] {
            var fields = original; fields[key] = value
            try await rejectPage(JSONSerialization.data(withJSONObject: fields))
        }
        var empty = original; empty["events"] = []; empty["nextSequence"] = 0; empty["hasMore"] = true
        try await rejectPage(JSONSerialization.data(withJSONObject: empty))
        var falseMore = try XCTUnwrap(JSONSerialization.jsonObject(with: groupPage(history, count: 1)) as? [String: Any]); falseMore["hasMore"] = false
        try await rejectPage(JSONSerialization.data(withJSONObject: falseMore))
        let last = try XCTUnwrap(JSONSerialization.jsonObject(with: groupPage(history, after: 1)) as? [String: Any])
        for (key, value): (String, Any) in [("generation", 2), ("headSequence", 4), ("headHash", Data(repeating: 1, count: 32).base64EncodedString())] {
            var fields = last; fields[key] = value
            let transport = GroupTransport([(200, try groupPage(history, count: 1)), (200, try JSONSerialization.data(withJSONObject: fields))])
            await groupServiceFailure(.invalidResponse) { try await groupClient(transport).groupHistory(accessToken: groupToken, groupID: groupID) }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 2)
        }
    }

    func testWrongEventSequenceChainAndTamperedSignatures() async throws {
        let fixture = try CheckpointHistory()
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: groupPage(fixture.events)) as? [String: Any])
        var reversed = original; reversed["events"] = (original["events"] as! [Any]).reversed().map { $0 }
        try await rejectPage(JSONSerialization.data(withJSONObject: reversed))
        var events = original["events"] as! [[String: Any]]
        events[1]["signature"] = Data(repeating: 0, count: 64).base64EncodedString()
        var tampered = original; tampered["events"] = events
        try await rejectPage(JSONSerialization.data(withJSONObject: tampered))
        let fork = try groupEvent(actor: fixture.a, subject: fixture.b, action: "approve", sequence: 2, previous: Data(repeating: 9, count: 32))
        try await rejectPage(groupPage([fixture.events[0], fork]))
        let generation = try groupEvent(actor: fixture.a, subject: fixture.a, generation: 2)
        try await rejectPage(groupPage([generation]))
    }

    func testCollectorStopsAt512PagesWithoutReturningPrefix() async throws {
        let history = try makeGroupHistory(513)
        let transport = GroupTransport(try (0..<513).map { (200, try groupPage(history, after: $0, count: 1)) })
        await groupServiceFailure(.invalidResponse) { try await groupClient(transport).groupHistory(accessToken: groupToken, groupID: groupID) }
        let count = await transport.requests.count
        XCTAssertEqual(count, 512)
    }

    func testMaximum8192EventHistoryFits512Pages() async throws {
        let history = try makeGroupHistory(8192)
        let transport = GroupTransport(try stride(from: 0, to: 8192, by: 16).map { (200, try groupPage(history, after: $0, count: 16)) })
        let result = try await groupClient(transport).groupHistory(accessToken: groupToken, groupID: groupID)
        XCTAssertEqual(result.count, 8192)
        XCTAssertEqual(result.last, history.last)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 512)
    }

    func testCancelledBlockedResponseReturnsNoPartialHistory() async throws {
        let transport = GroupTransport([(200, try groupPage(CheckpointHistory().events))])
        let gate = GroupGate(); await transport.setGate(gate)
        let client = try groupClient(transport)
        let task = Task { try await client.groupHistory(accessToken: groupToken, groupID: groupID) }
        await gate.wait(); task.cancel(); await gate.resume()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    private func rejectPage(_ data: Data, file: StaticString = #filePath, line: UInt = #line) async throws {
        let transport = GroupTransport([(200, data)])
        await groupServiceFailure(.invalidResponse, file: file, line: line) { try await groupClient(transport).groupHistory(accessToken: groupToken, groupID: groupID) }
        let count = await transport.requests.count
        XCTAssertEqual(count, 1, file: file, line: line)
    }

    func testSignedMultiPageCollectionUsesExactPayloadAndFreshProof() async throws {
        let history = try CheckpointHistory().events
        let transport = GroupTransport([(200, try groupPage(history, after: 0, count: 2)), (200, try groupPage(history, after: 2, count: 1))])
        let identity = try DeviceIdentity.ephemeral()
        let nonce = GroupNonce()
        let client = try groupClient(transport, identity: identity, nonce: nonce)
        let received = try await client.groupHistory(accessToken: groupToken, groupID: groupID)
        XCTAssertEqual(received, history)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        var nonces = Set<Data>()
        for (index, request) in requests.enumerated() {
            XCTAssertEqual(request.url?.path, "/v1/account/group/events")
            XCTAssertEqual(request.httpMethod, "POST")
            let proof = try JSONDecoder().decode(RendezvousSignedEnvelope.self, from: XCTUnwrap(request.httpBody))
            XCTAssertTrue(nonces.insert(proof.nonce).inserted)
            XCTAssertEqual(proof.epochMilliseconds, 2_000_000_000_000)
            XCTAssertTrue(identity.publicKey.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: proof.signature), for: try proof.canonicalPayload()))
            let fields = try JSONDecoder().decode([String: String].self, from: proof.payload)
            XCTAssertEqual(fields, ["purpose": "dropmesh.account.group.events.v1", "audience": "test.app", "accessToken": groupToken, "groupID": groupID, "afterSequence": index == 0 ? "0" : "2", "expectedHeadHash": index == 0 ? "" : try history.last!.digest().base64EncodedString()])
        }
    }
}

func makeGroupHistory(_ count: Int) throws -> [AccountGroupEvent] {
    let fixture = try CheckpointHistory()
    var history = [fixture.events[0]]
    for sequence in 2...count {
        history.append(try groupEvent(actor: fixture.a, subject: fixture.b, action: sequence.isMultiple(of: 2) ? "approve" : "remove", sequence: UInt64(sequence), previous: history.last!.digest()))
    }
    return history
}
func groupServiceFailure<T>(_ expected: AccountServiceError, file: StaticString = #filePath, line: UInt = #line, _ operation: () async throws -> T) async {
    do { _ = try await operation(); XCTFail("Expected rejection", file: file, line: line) }
    catch { XCTAssertEqual(error as? AccountServiceError, expected, file: file, line: line) }
}

let groupToken = Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
func groupPage(_ history: [AccountGroupEvent], after: Int = 0, count: Int? = nil) throws -> Data {
    let end = min(history.count, after + (count ?? history.count))
    let events = try history[after..<end].map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0.wireEvent())) }
    return try JSONSerialization.data(withJSONObject: ["groupID": groupID, "generation": 1, "headSequence": history.count, "headHash": try history.last!.digest().base64EncodedString(), "afterSequence": after, "nextSequence": end, "hasMore": end < history.count, "events": events], options: [.sortedKeys, .withoutEscapingSlashes])
}
func groupClient(_ transport: GroupTransport, identity: DeviceIdentity? = nil, nonce: GroupNonce = GroupNonce()) throws -> AccountServiceClient {
    try AccountServiceClient(identity: identity ?? DeviceIdentity.ephemeral(), origin: URL(string: "https://example.com")!, audience: "test.app", transport: transport, now: { Date(timeIntervalSince1970: 2_000_000_000) }, nonce: { nonce.next() })
}
final class GroupNonce: @unchecked Sendable {
    let lock = NSLock()
    var counter: UInt8 = 0
    func next() -> Data { lock.withLock { counter &+= 1; return Data(repeating: counter, count: 32) } }
}
actor GroupTransport: AccountServiceTransport {
    var responses: [(Int, Data)]
    var requests: [URLRequest] = []
    var gate: GroupGate?
    init(_ responses: [(Int, Data)]) { self.responses = responses }
    func setGate(_ gate: GroupGate) { self.gate = gate }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let gate { await gate.block() }
        guard !responses.isEmpty else { throw AccountServiceError.transport }
        let value = responses.removeFirst()
        return (value.1, HTTPURLResponse(url: request.url!, statusCode: value.0, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
    }
}
actor GroupGate {
    var held: CheckedContinuation<Void, Never>?
    var observer: CheckedContinuation<Void, Never>?
    func block() async { await withCheckedContinuation { held = $0; observer?.resume(); observer = nil } }
    func wait() async { if held != nil { return }; await withCheckedContinuation { observer = $0 } }
    func resume() { held?.resume(); held = nil }
}
