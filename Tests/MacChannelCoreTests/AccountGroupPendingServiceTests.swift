import CryptoKit
import Foundation
import XCTest
@testable import MacChannelCore

final class AccountGroupPendingServiceTests: XCTestCase {
    func testAllEightSignedRoutesFieldsFreshNoncesAndProofDigests() async throws {
        let actor = try DeviceIdentity.ephemeral(), subject = try DeviceIdentity.ephemeral()
        let event = try pendingEvent(actor, subject)
        let draft = try pendingDraft(event), hash = try event.digest()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let draftEncoded = try encoder.encode(draft.wireDraft()).base64EncodedString()
        let nonce = GroupNonce()
        var seen = Set<Data>(), signatures = Set<Data>()
        for op in pendingOperations {
            let identity = ["propose", "commit", "reject"].contains(op) ? actor : subject
            let status = ["propose": "proposed", "countersign": "countersigned", "commit": "committed", "cancel": "cancelled", "reject": "rejected"][op] ?? "requested"
            let response = op == "list" ? try pendingJSON(["requests": [pendingSummaryObject(subject)]]) : try pendingResponse(subject, event: event, status: status)
            let transport = GroupTransport([(200, response)])
            let client = try groupClient(transport, identity: identity, nonce: nonce)
            try await performPending(client, op, draft: draft, event: event)
            let requests = await transport.requests
            let request = try XCTUnwrap(requests.first)
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/account/group/join/" + op)
            let proof = try JSONDecoder().decode(RendezvousSignedEnvelope.self, from: XCTUnwrap(request.httpBody))
            XCTAssertEqual(proof.publicKey, identity.publicKey.rawRepresentation)
            XCTAssertEqual(proof.deviceID, identity.id.rawValue.uuidString.lowercased())
            XCTAssertEqual(proof.epochMilliseconds, 2_000_000_000_000)
            XCTAssertTrue(seen.insert(proof.nonce).inserted)
            XCTAssertTrue(signatures.insert(proof.signature).inserted)
            XCTAssertTrue(identity.publicKey.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: proof.signature), for: try proof.canonicalPayload()))
            var expected = ["purpose": "dropmesh.account.group.join.\(op).v1", "audience": "test.app", "accessToken": groupToken]
            if op != "list" { expected["requestID"] = pendingID }
            if op == "create" { expected["groupID"] = groupID; expected["generation"] = "1"; expected["publicKey"] = subject.publicKey.rawRepresentation.base64EncodedString() }
            if op == "propose" { expected["draft"] = draftEncoded }
            if op == "commit" || op == "countersign" { expected["draftHash"] = hash.base64EncodedString() }
            if op == "countersign" { expected["subjectSignature"] = event.subjectSignature.base64EncodedString() }
            XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: proof.payload), expected)
        }
    }

    func testInvalidInputsNeverReachTransport() async throws {
        let actor = try DeviceIdentity.ephemeral(), subject = try DeviceIdentity.ephemeral()
        let event = try pendingEvent(actor, subject), draft = try pendingDraft(event)
        let transport = GroupTransport([]), client = try groupClient(transport, identity: actor)
        for op in pendingOperations {
            for (token, account, request) in [("bad", groupAccount, pendingID), (groupToken, "bad", pendingID), (groupToken, "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", pendingID)] {
                await groupServiceFailure(.invalidRequest) { try await performPending(client, op, draft: draft, event: event, token: token, account: account, request: request) }
            }
            if op != "list" {
                await groupServiceFailure(.invalidRequest) { try await performPending(client, op, draft: draft, event: event, request: "BAD") }
            }
        }
        for generation in [UInt64(0), UInt64(Int64.max) + 1] {
            await groupServiceFailure(.invalidRequest) { try await client.createGroupJoin(accessToken: groupToken, accountID: groupAccount, requestID: pendingID, groupID: groupID, generation: generation) }
        }
        await groupServiceFailure(.invalidRequest) { try await client.createGroupJoin(accessToken: groupToken, accountID: groupAccount, requestID: pendingID, groupID: "bad", generation: 1) }
        for hash in [Data(), Data(repeating: 0, count: 31), Data(repeating: 0, count: 33)] {
            await groupServiceFailure(.invalidRequest) { try await client.commitGroupJoin(accessToken: groupToken, accountID: groupAccount, requestID: pendingID, draftHash: hash) }
            await groupServiceFailure(.invalidRequest) { try await client.countersignGroupJoin(accessToken: groupToken, accountID: groupAccount, requestID: pendingID, draftHash: hash, subjectSignature: event.subjectSignature) }
        }
        for signature in [Data(), Data([1]), Data(repeating: 0, count: 64), Data(repeating: 0, count: 81)] {
            await groupServiceFailure(.invalidRequest) { try await client.countersignGroupJoin(accessToken: groupToken, accountID: groupAccount, requestID: pendingID, draftHash: event.digest(), subjectSignature: signature) }
        }
        let foreign = try pendingDraft(pendingEvent(subject, actor))
        await groupServiceFailure(.invalidRequest) { try await client.proposeGroupJoin(accessToken: groupToken, accountID: groupAccount, requestID: pendingID, draft: foreign) }
        let count = await transport.requests.count; XCTAssertEqual(count, 0)
    }

    func testResponseBindingsDigestsAndCompetingCommittedCancellation() async throws {
        let actor = try DeviceIdentity.ephemeral(), subject = try DeviceIdentity.ephemeral()
        let event = try pendingEvent(actor, subject), draft = try pendingDraft(event)
        for op in pendingOperations {
            let identity = ["propose", "commit", "reject"].contains(op) ? actor : subject
            for field in ["accountID", "requestID"] {
                if op == "list" && field == "requestID" { continue }
                var object = pendingObject(subject); object[field] = "88888888-8888-8888-8888-888888888888"
                let response = op == "list" ? try pendingJSON(["requests": [object.filter { !["draft", "event", "eventHash"].contains($0.key) }]]) : try pendingJSON(["request": object])
                await groupServiceFailure(.invalidResponse) { try await performPending(groupClient(GroupTransport([(200, response)]), identity: identity), op, draft: draft, event: event) }
            }
        }
        for op in ["create", "countersign", "cancel"] {
            let status = op == "create" ? "requested" : "committed"
            let response = try pendingResponse(subject, event: event, status: status)
            await groupServiceFailure(.invalidResponse) { try await performPending(groupClient(GroupTransport([(200, response)]), identity: actor), op, draft: draft, event: event) }
        }
        let otherEvent = try pendingEvent(actor, subject, milliseconds: 1_800_000_000_001)
        for op in ["propose", "countersign", "commit"] {
            let response = try pendingResponse(subject, event: otherEvent, status: "committed")
            let identity = op == "countersign" ? subject : actor
            await groupServiceFailure(.invalidResponse) { try await performPending(groupClient(GroupTransport([(200, response)]), identity: identity), op, draft: draft, event: event) }
        }
        for field in ["groupID", "generation"] {
            var object = pendingObject(subject); object[field] = field == "generation" ? 2 : groupAccount
            await groupServiceFailure(.invalidResponse) { try await performPending(groupClient(GroupTransport([(200, pendingJSON(["request": object]))]), identity: subject), "create", draft: draft, event: event) }
        }
        for op in ["get", "cancel"] {
            let response = try pendingResponse(subject, event: event, status: "committed")
            let client = try groupClient(GroupTransport([(200, response)]), identity: subject)
            let result = op == "get" ? try await client.groupJoin(accessToken: groupToken, accountID: groupAccount, requestID: pendingID) : try await client.cancelGroupJoin(accessToken: groupToken, accountID: groupAccount, requestID: pendingID)
            XCTAssertEqual(result.summary.status, .committed)
        }
    }

    func testEveryHTTPMappingAndNoRetry() async throws {
        let actor = try DeviceIdentity.ephemeral(), subject = try DeviceIdentity.ephemeral()
        let event = try pendingEvent(actor, subject), draft = try pendingDraft(event)
        for op in pendingOperations {
            for (status, expected) in [(400, AccountServiceError.invalidRequest), (401, .authenticationRejected), (403, .authenticationRejected), (404, .unavailable), (429, .rateLimited), (500, .invalidResponse), (503, .unavailable)] {
                let transport = GroupTransport([(status, Data())])
                await groupServiceFailure(expected) { try await performPending(groupClient(transport, identity: actor), op, draft: draft, event: event) }
                let count = await transport.requests.count; XCTAssertEqual(count, 1)
            }
            let transport = GroupTransport([(409, Data())])
            do { try await performPending(groupClient(transport, identity: actor), op, draft: draft, event: event); XCTFail("Expected conflict") }
            catch { XCTAssertEqual(error as? AccountGroupEnrollmentError, .conflict) }
            let count = await transport.requests.count; XCTAssertEqual(count, 1)
        }
    }

    func testCancellationBeforeTransportDuringPreparationAndAfterLateSuccessOrError() async throws {
        let actor = try DeviceIdentity.ephemeral(), subject = try DeviceIdentity.ephemeral()
        let event = try pendingEvent(actor, subject), draft = try pendingDraft(event)
        for op in pendingOperations {
            for stage in 0..<2 {
                let transport = GroupTransport([]), gate = PendingGate()
                let client = try AccountServiceClient(identity: actor, origin: URL(string: "https://example.com")!, audience: "test.app", transport: transport, now: { Date(timeIntervalSince1970: 2_000_000_000) }, nonce: {
                    if stage == 1 { withUnsafeCurrentTask { $0?.cancel() } }
                    return Data(repeating: 1, count: 32)
                })
                let task = Task { @Sendable in
                    if stage == 0 { await gate.block() }
                    try await performPending(client, op, draft: draft, event: event)
                }
                if stage == 0 { await gate.wait(); task.cancel(); await gate.release() }
                do { try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
                let count = await transport.requests.count; XCTAssertEqual(count, 0)
            }
            for response: [(Int, Data)] in [[(200, try pendingResponse(subject, event: event, status: "committed"))], [(409, Data())], []] {
                let gate = PendingGate(), transport = PendingBlockingTransport(response, gate)
                let client = try AccountServiceClient(identity: actor, origin: URL(string: "https://example.com")!, audience: "test.app", transport: transport, now: { Date(timeIntervalSince1970: 2_000_000_000) }, nonce: { Data(repeating: 1, count: 32) })
                let task = Task { @Sendable in try await performPending(client, op, draft: draft, event: event) }
                await gate.wait(); task.cancel(); await gate.release()
                do { try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
            }
        }
    }
    func testCreateSignsExactLocalIdentity() async throws {
        let identity = try DeviceIdentity.ephemeral()
        let transport = GroupTransport([(200, try pendingJSON(["request": pendingObject(identity)]))])
        let client = try groupClient(transport, identity: identity)
        _ = try await client.createGroupJoin(accessToken: groupToken, accountID: groupAccount,
            requestID: pendingID, groupID: groupID, generation: 1)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/v1/account/group/join/create")
        let proof = try JSONDecoder().decode(RendezvousSignedEnvelope.self, from: XCTUnwrap(request.httpBody))
        XCTAssertEqual(proof.publicKey, identity.publicKey.rawRepresentation)
        XCTAssertEqual(proof.deviceID, identity.id.rawValue.uuidString.lowercased())
        XCTAssertTrue(identity.publicKey.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: proof.signature), for: try proof.canonicalPayload()))
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: proof.payload), [
            "purpose": "dropmesh.account.group.join.create.v1", "audience": "test.app", "accessToken": groupToken,
            "requestID": pendingID, "groupID": groupID, "generation": "1", "publicKey": identity.publicKey.rawRepresentation.base64EncodedString()])
    }
}

private let pendingOperations = ["create", "get", "list", "propose", "countersign", "commit", "cancel", "reject"]
private func performPending(_ client: AccountServiceClient, _ op: String, draft: AccountGroupApprovalDraft, event: AccountGroupEvent,
                            token: String = groupToken, account: String = groupAccount, request: String = pendingID) async throws {
    switch op {
    case "create": _ = try await client.createGroupJoin(accessToken: token, accountID: account, requestID: request, groupID: groupID, generation: 1)
    case "get": _ = try await client.groupJoin(accessToken: token, accountID: account, requestID: request)
    case "list": _ = try await client.groupJoins(accessToken: token, accountID: account)
    case "propose": _ = try await client.proposeGroupJoin(accessToken: token, accountID: account, requestID: request, draft: draft)
    case "countersign": _ = try await client.countersignGroupJoin(accessToken: token, accountID: account, requestID: request, draftHash: event.digest(), subjectSignature: event.subjectSignature)
    case "commit": _ = try await client.commitGroupJoin(accessToken: token, accountID: account, requestID: request, draftHash: event.digest())
    case "cancel": _ = try await client.cancelGroupJoin(accessToken: token, accountID: account, requestID: request)
    default: _ = try await client.rejectGroupJoin(accessToken: token, accountID: account, requestID: request)
    }
}
private func pendingSummaryObject(_ identity: DeviceIdentity) -> [String: Any] { pendingObject(identity).filter { !["draft", "event", "eventHash"].contains($0.key) } }
private func pendingEvent(_ actor: DeviceIdentity, _ subject: DeviceIdentity, milliseconds: Int64 = 1_800_000_000_000) throws -> AccountGroupEvent {
    func make(_ signature: Data = Data(), _ subjectSignature: Data = Data()) throws -> AccountGroupEvent {
        try .init(accountID: groupAccount, groupID: groupID, generation: 1, sequence: 2,
            previousHash: Data(repeating: 42, count: 32), action: "approve",
            actorDeviceID: actor.id.rawValue.uuidString.lowercased(), actorPublicKey: actor.publicKey.rawRepresentation,
            subjectDeviceID: subject.id.rawValue.uuidString.lowercased(), subjectPublicKey: subject.publicKey.rawRepresentation,
            epochMilliseconds: milliseconds, signature: signature, subjectSignature: subjectSignature)
    }
    let payload = try make().canonicalPayload()
    return try make(actor.sign(payload).derRepresentation, subject.sign(payload).derRepresentation)
}
private func pendingDraft(_ event: AccountGroupEvent) throws -> AccountGroupApprovalDraft {
    try .init(event: AccountGroupEvent(canonicalPayload: event.canonicalPayload(), signature: event.signature, subjectSignature: Data()))
}
private func pendingResponse(_ identity: DeviceIdentity, event: AccountGroupEvent, status: String) throws -> Data {
    var object = pendingObject(identity); object["status"] = status
    if status != "requested" {
        object["draft"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(pendingDraft(event).wireDraft()))
    }
    if ["countersigned", "committed"].contains(status) { object["event"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event.wireEvent())) }
    if status == "committed" { object["eventHash"] = try event.digest().base64EncodedString() }
    return try pendingJSON(["request": object])
}
private actor PendingGate {
    let entered = XCTestExpectation(description: "pending entered")
    var continuation: CheckedContinuation<Void, Never>?
    func block() async { entered.fulfill(); await withCheckedContinuation { continuation = $0 } }
    func wait() async { let result = await XCTWaiter().fulfillment(of: [entered], timeout: 5); XCTAssertEqual(result, .completed) }
    func release() { continuation?.resume(); continuation = nil }
}
private actor PendingBlockingTransport: AccountServiceTransport {
    let responses: [(Int, Data)], gate: PendingGate
    init(_ responses: [(Int, Data)], _ gate: PendingGate) { self.responses = responses; self.gate = gate }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await gate.block()
        guard let response = responses.first else { throw AccountServiceError.transport }
        return (response.1, HTTPURLResponse(url: request.url!, statusCode: response.0, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
    }
}
