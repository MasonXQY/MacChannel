import CryptoKit
import Foundation
import XCTest
@testable import MacChannelCore

final class AccountGroupEnrollmentServiceTests: XCTestCase {
    func testSignedDiscoveryAbsentPresentAndBootstrapUseExactPayloadAndFreshNonce() async throws {
        let identity = try DeviceIdentity.ephemeral()
        let anchor = try enrollmentEvent(identity)
        let transport = GroupTransport([(200, Data(#"{"status":"absent"}"#.utf8)),
            (200, try discoveryData(anchor)), (200, try recordedData(anchor))])
        let client = try groupClient(transport, identity: identity)
        let absent = try await client.discoverGroup(accessToken: groupToken, accountID: groupAccount)
        XCTAssertEqual(absent, .absent)
        let present = try await client.discoverGroup(accessToken: groupToken, accountID: groupAccount)
        XCTAssertEqual(present, .present(.init(groupID: groupID, generation: 1, anchor: anchor,
            anchorHash: try anchor.digest(), headSequence: 1, headHash: try anchor.digest())))
        try await client.recordGroupBootstrap(accessToken: groupToken, event: anchor)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
        var nonces = Set<Data>()
        for (i, request) in requests.enumerated() {
            let bootstrap = i == 2
            XCTAssertEqual(request.url?.path, "/v1/account/group/" + (bootstrap ? "bootstrap" : "discover"))
            XCTAssertEqual(request.httpMethod, "POST")
            let proof = try JSONDecoder().decode(RendezvousSignedEnvelope.self, from: XCTUnwrap(request.httpBody))
            XCTAssertTrue(nonces.insert(proof.nonce).inserted)
            XCTAssertEqual(proof.deviceID, identity.id.rawValue.uuidString.lowercased())
            XCTAssertEqual(proof.publicKey, identity.publicKey.rawRepresentation)
            XCTAssertEqual(proof.epochMilliseconds, 2_000_000_000_000)
            XCTAssertTrue(identity.publicKey.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: proof.signature), for: try proof.canonicalPayload()))
            var expected = ["purpose": "dropmesh.account.group.\(bootstrap ? "bootstrap" : "discover").v1",
                            "audience": "test.app", "accessToken": groupToken]
            if bootstrap {
                expected["confirmation"] = "join_this_device"
                expected["event"] = try enrollmentWire(anchor).base64EncodedString()
            }
            XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: proof.payload), expected)
        }
    }

    func testDiscoveryAllowsInformationalLaterHeadAndExactBounds() async throws {
        let anchor = try enrollmentEvent(DeviceIdentity.ephemeral(), generation: UInt64(Int64.max))
        var object = try discoveryObject(anchor)
        object["headSequence"] = 8192
        object["headHash"] = Data(repeating: 8, count: 32).base64EncodedString()
        let data = try enrollmentJSON(object)
        let bounded = data + Data(repeating: 32, count: 65_536 - data.count)
        let result = try await groupClient(GroupTransport([(200, bounded)])).discoverGroup(accessToken: groupToken, accountID: groupAccount)
        XCTAssertEqual(result, .present(.init(groupID: groupID, generation: UInt64(Int64.max), anchor: anchor,
            anchorHash: try anchor.digest(), headSequence: 8192, headHash: Data(repeating: 8, count: 32))))
        try await rejectDiscovery(bounded + Data([32]))
    }

    func testDiscoveryRejectsEveryMissingNullWrongTypeUnknownAndDuplicateField() async throws {
        let object = try discoveryObject(enrollmentEvent(DeviceIdentity.ephemeral()))
        for key in object.keys {
            var missing = object; missing.removeValue(forKey: key)
            try await rejectDiscovery(enrollmentJSON(missing))
            for invalid: Any in [NSNull(), true, ["wrong"], 1.5] {
                var bad = object; bad[key] = invalid
                try await rejectDiscovery(enrollmentJSON(bad))
            }
            let raw = String(decoding: try enrollmentJSON(object), as: UTF8.self)
            try await rejectDiscovery(Data(("{\"\(key)\":null," + raw.dropFirst()).utf8))
        }
        var unknown = object; unknown["extra"] = "x"
        try await rejectDiscovery(enrollmentJSON(unknown))
        let raw = String(decoding: try enrollmentJSON(object), as: UTF8.self)
        try await rejectDiscovery(Data((#"{"st\u0061tus":"present","# + raw.dropFirst()).utf8))
        for invalid in [#"{}"#, #"[]"#, #"null"#, #"{"status":"absent","extra":0}"#,
                        #"{"status":"absent","status":"absent"}"#, #"{"status":null}"#,
                        #"{"status":"other"}"#, #"{"status":"absent",}"#] {
            try await rejectDiscovery(Data(invalid.utf8))
        }
        for suffix in ["{}", "null", "x"] { try await rejectDiscovery(Data((raw + suffix).utf8)) }
    }

    func testDiscoveryRejectsCounterLexicalFormsUUIDHashesAndAnchorBindings() async throws {
        let identity = try DeviceIdentity.ephemeral()
        let anchor = try enrollmentEvent(identity)
        let original = try discoveryObject(anchor)
        let raw = String(decoding: try enrollmentJSON(original), as: UTF8.self)
        for key in ["generation", "headSequence"] {
            for value in ["1e0", "1.0", "-0", "-1", "01", "0", "true", "\"1\"", "9223372036854775808", "18446744073709551616"] {
                try await rejectDiscovery(Data(raw.replacingOccurrences(of: "\"\(key)\":1", with: "\"\(key)\":\(value)").utf8))
            }
        }
        for (key, value): (String, Any) in [("headSequence", 8193), ("groupID", "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"),
            ("groupID", "bad"), ("groupID", groupAccount), ("generation", 2), ("status", "absent")] {
            var bad = original; bad[key] = value; try await rejectDiscovery(enrollmentJSON(bad))
        }
        for key in ["anchorHash", "headHash"] {
            for value in ["", Data(repeating: 0, count: 31).base64EncodedString(), Data(repeating: 0, count: 33).base64EncodedString(),
                          Data(repeating: 0, count: 32).base64EncodedString(), String((original[key] as! String).dropLast())] {
                var bad = original; bad[key] = value; try await rejectDiscovery(enrollmentJSON(bad))
            }
        }
        let otherAccount = try enrollmentEvent(identity, account: "33333333-3333-3333-3333-333333333333")
        try await rejectDiscovery(discoveryData(otherAccount))
        let removal = try enrollmentEvent(identity, action: "remove")
        try await rejectDiscovery(discoveryData(removal))
        var wire = try XCTUnwrap(original["anchor"] as? [String: Any])
        for key in wire.keys {
            var badWire = wire; badWire.removeValue(forKey: key)
            var bad = original; bad["anchor"] = badWire; try await rejectDiscovery(enrollmentJSON(bad))
            badWire = wire; badWire[key] = NSNull(); bad["anchor"] = badWire
            try await rejectDiscovery(enrollmentJSON(bad))
        }
        wire["signature"] = Data(repeating: 0, count: 64).base64EncodedString()
        var bad = original; bad["anchor"] = wire; try await rejectDiscovery(enrollmentJSON(bad))
        for alias in ["payload", "payl\\u006fad"] {
            try await rejectDiscovery(Data(raw.replacingOccurrences(of: #""subjectSignature":"""#, with: "\"\(alias)\":\"\"").utf8))
        }
    }

    func testBootstrapAcknowledgmentRejectsSchemaCountersIdentityAndHashMismatch() async throws {
        let identity = try DeviceIdentity.ephemeral()
        let event = try enrollmentEvent(identity)
        let original = try recordedObject(event)
        for key in original.keys {
            var missing = original; missing.removeValue(forKey: key)
            try await rejectAck(enrollmentJSON(missing), identity: identity, event: event)
            for invalid: Any in [NSNull(), true, [], 1.5] {
                var bad = original; bad[key] = invalid
                try await rejectAck(enrollmentJSON(bad), identity: identity, event: event)
            }
            let raw = String(decoding: try enrollmentJSON(original), as: UTF8.self)
            try await rejectAck(Data(("{\"\(key)\":null," + raw.dropFirst()).utf8), identity: identity, event: event)
        }
        for (key, value): (String, Any) in [("status", "present"), ("groupID", groupAccount),
            ("groupID", "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"), ("groupID", "bad"), ("generation", 2),
            ("eventHash", Data(repeating: 0, count: 32).base64EncodedString()), ("eventHash", ""),
            ("eventHash", Data(repeating: 0, count: 31).base64EncodedString()),
            ("eventHash", String((original["eventHash"] as! String).dropLast())), ("extra", "x")] {
            var bad = original; bad[key] = value
            try await rejectAck(enrollmentJSON(bad), identity: identity, event: event)
        }
        let raw = String(decoding: try enrollmentJSON(original), as: UTF8.self)
        for value in ["0", "-1", "1.0", "1e0", "01", "\"1\"", "9223372036854775808"] {
            try await rejectAck(Data(raw.replacingOccurrences(of: #""generation":1"#, with: "\"generation\":\(value)").utf8), identity: identity, event: event)
        }
        try await rejectAck(Data((#"{"group\u0049D":"" ,"# + raw.dropFirst()).utf8), identity: identity, event: event)
        try await rejectAck(Data((raw + "{}").utf8), identity: identity, event: event)
        try await rejectAck(Data(raw.utf8) + Data(repeating: 32, count: 65_536), identity: identity, event: event)
    }

    func testInputsRejectBeforeAnyRequestIncludingWrongActorEncodingActionSignature() async throws {
        let identity = try DeviceIdentity.ephemeral()
        let event = try enrollmentEvent(identity)
        let transport = GroupTransport([])
        let client = try groupClient(transport, identity: identity)
        for (token, account) in [("bad", groupAccount), (groupToken, "bad"),
            (groupToken, "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")] {
            await groupServiceFailure(.invalidRequest) { try await client.discoverGroup(accessToken: token, accountID: account) }
        }
        await groupServiceFailure(.invalidRequest) { try await client.recordGroupBootstrap(accessToken: "bad", event: event) }
        for bad in [try enrollmentEvent(DeviceIdentity.ephemeral()), try enrollmentEvent(identity, raw65: true),
                    try enrollmentEvent(identity, action: "remove"), try enrollmentEvent(identity, signed: false)] {
            await groupServiceFailure(.invalidRequest) { try await client.recordGroupBootstrap(accessToken: groupToken, event: bad) }
        }
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)
    }

    func testCancellationDuringEnvelopePreparationPreventsTransport() async throws {
        let identity = try DeviceIdentity.ephemeral()
        let event = try enrollmentEvent(identity)
        for bootstrap in [false, true] {
            let transport = GroupTransport([(200, bootstrap ? try recordedData(event) : try discoveryData(event))])
            let client = try AccountServiceClient(identity: identity, origin: URL(string: "https://example.com")!,
                audience: "test.app", transport: transport, now: { Date(timeIntervalSince1970: 2_000_000_000) }, nonce: {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return Data(repeating: 1, count: 32)
                })
            let task = Task { @Sendable in try await AccountGroupEnrollmentServiceTests.perform(client, event, bootstrap: bootstrap) }
            await assertCancelled(task)
            let count = await transport.requests.count
            XCTAssertEqual(count, 0)
        }
    }

    func testStatusMappingNoAutomaticRetryOrLoginRegressionAndTransportFailure() async throws {
        let identity = try DeviceIdentity.ephemeral()
        let event = try enrollmentEvent(identity)
        for bootstrap in [false, true] {
            for (status, expected) in [(404, AccountServiceError.unavailable), (400, .invalidRequest),
                (401, .authenticationRejected), (403, .authenticationRejected), (429, .rateLimited),
                (503, .unavailable), (500, .invalidResponse)] {
                let transport = GroupTransport([(status, Data("private error".utf8))])
                let client = try groupClient(transport, identity: identity)
                await groupServiceFailure(expected) { try await Self.perform(client, event, bootstrap: bootstrap) }
                let count = await transport.requests.count; XCTAssertEqual(count, 1)
            }
            let conflict = GroupTransport([(409, Data())])
            do { try await Self.perform(groupClient(conflict, identity: identity), event, bootstrap: bootstrap); XCTFail("Expected conflict") }
            catch { XCTAssertEqual(error as? AccountGroupEnrollmentError, .conflict) }
            let count = await conflict.requests.count; XCTAssertEqual(count, 1)
            let failure = GroupTransport([])
            await groupServiceFailure(.transport) { try await Self.perform(groupClient(failure, identity: identity), event, bootstrap: bootstrap) }
            let failures = await failure.requests.count; XCTAssertEqual(failures, 1)
        }
        for status in [404, 409] {
            await groupServiceFailure(.invalidResponse) { try await groupClient(GroupTransport([(status, Data())])).challenge() }
        }
    }

    func testCancellationBeforeRequestAndAfterNoncooperativeSuccessOrError() async throws {
        let identity = try DeviceIdentity.ephemeral()
        let event = try enrollmentEvent(identity)
        for bootstrap in [false, true] {
            let empty = GroupTransport([])
            let client = try groupClient(empty, identity: identity)
            let before = EnrollmentGate()
            let task = Task { @Sendable in await before.block(); try await AccountGroupEnrollmentServiceTests.perform(client, event, bootstrap: bootstrap) }
            await before.waitUntilEntered(); task.cancel(); await before.release()
            await assertCancelled(task)
            let requests = await empty.requests.count; XCTAssertEqual(requests, 0)
            for response: [(Int, Data)] in [[(200, bootstrap ? try recordedData(event) : try discoveryData(event))], [(409, Data())], []] {
                let gate = EnrollmentGate()
                let transport = EnrollmentBlockingTransport(responses: response, gate: gate)
                let client = try AccountServiceClient(identity: identity, origin: URL(string: "https://example.com")!, audience: "test.app", transport: transport, now: { Date(timeIntervalSince1970: 2_000_000_000) }, nonce: { Data(repeating: 1, count: 32) })
                let task = Task { @Sendable in try await AccountGroupEnrollmentServiceTests.perform(client, event, bootstrap: bootstrap) }
                await gate.waitUntilEntered(); task.cancel(); await gate.release()
                await assertCancelled(task)
            }
        }
    }

    private static func perform(_ client: AccountServiceClient, _ event: AccountGroupEvent, bootstrap: Bool) async throws {
        if bootstrap { try await client.recordGroupBootstrap(accessToken: groupToken, event: event) }
        else { _ = try await client.discoverGroup(accessToken: groupToken, accountID: groupAccount) }
    }
    private func assertCancelled(_ task: Task<Void, Error>) async {
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    private func rejectDiscovery(_ data: Data) async throws {
        let transport = GroupTransport([(200, data)])
        await groupServiceFailure(.invalidResponse) { try await groupClient(transport).discoverGroup(accessToken: groupToken, accountID: groupAccount) }
        let count = await transport.requests.count; XCTAssertEqual(count, 1)
    }
    private func rejectAck(_ data: Data, identity: DeviceIdentity, event: AccountGroupEvent) async throws {
        let transport = GroupTransport([(200, data)])
        await groupServiceFailure(.invalidResponse) { try await groupClient(transport, identity: identity).recordGroupBootstrap(accessToken: groupToken, event: event) }
        let count = await transport.requests.count; XCTAssertEqual(count, 1)
    }
}

private func enrollmentEvent(_ identity: DeviceIdentity, account: String = groupAccount, generation: UInt64 = 1,
                             action: String = "bootstrap", raw65: Bool = false, signed: Bool = true) throws -> AccountGroupEvent {
    let key = raw65 ? identity.publicKey.x963Representation : identity.publicKey.rawRepresentation
    let device = try AccountGroupEvent.deviceID(publicKey: key)
    func make(_ signature: Data = Data()) throws -> AccountGroupEvent {
        try AccountGroupEvent(accountID: account, groupID: groupID, generation: generation, sequence: action == "bootstrap" ? 1 : 2,
            previousHash: action == "bootstrap" ? Data() : Data(repeating: 1, count: 32), action: action,
            actorDeviceID: device, actorPublicKey: key, subjectDeviceID: device, subjectPublicKey: key,
            epochMilliseconds: 1_800_000_000_000, signature: signature)
    }
    let unsigned = try make()
    return signed ? try make(identity.sign(unsigned.canonicalPayload()).derRepresentation) : unsigned
}
private func enrollmentJSON(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
}
private func enrollmentWire(_ event: AccountGroupEvent) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(event.wireEvent())
}
private func discoveryObject(_ event: AccountGroupEvent) throws -> [String: Any] {
    ["status": "present", "groupID": event.groupID, "generation": event.generation,
     "anchor": try JSONSerialization.jsonObject(with: enrollmentWire(event)),
     "anchorHash": try event.digest().base64EncodedString(), "headSequence": 1,
     "headHash": try event.digest().base64EncodedString()]
}
private func discoveryData(_ event: AccountGroupEvent) throws -> Data { try enrollmentJSON(discoveryObject(event)) }
private func recordedObject(_ event: AccountGroupEvent) throws -> [String: Any] {
    ["status": "recorded", "groupID": event.groupID, "generation": event.generation, "eventHash": try event.digest().base64EncodedString()]
}
private func recordedData(_ event: AccountGroupEvent) throws -> Data { try enrollmentJSON(recordedObject(event)) }

/// Noncooperative await controlled entirely by the test. XCTest bounds the entry
/// wait so a client regression cannot leave the suite hung before cancellation.
private actor EnrollmentGate {
    private let entered = XCTestExpectation(description: "transport entered")
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func block() async {
        entered.fulfill()
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilEntered() async {
        let result = await XCTWaiter().fulfillment(of: [entered], timeout: 5)
        XCTAssertEqual(result, .completed)
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
private actor EnrollmentBlockingTransport: AccountServiceTransport {
    let responses: [(Int, Data)]
    let gate: EnrollmentGate
    init(responses: [(Int, Data)], gate: EnrollmentGate) { self.responses = responses; self.gate = gate }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await gate.block()
        guard let response = responses.first else { throw AccountServiceError.transport }
        return (response.1, HTTPURLResponse(url: request.url!, statusCode: response.0, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
    }
}
