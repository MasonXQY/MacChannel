import CryptoKit
import Foundation
import XCTest
@testable import MacChannelCore

final class AccountInvitationServiceTests: XCTestCase, @unchecked Sendable {
    func testMutationRejectsSubstitutedEndpointPairGrantAndLocalSigner() async throws {
        var f = try InvitationProofFixture()
        let identity = try invitationIdentity(f.sender)
        f.fields["senderPublicKey"] = identity.publicKey.rawRepresentation.base64EncodedString()
        f.fields["senderDeviceID"] = identity.id.rawValue.uuidString.lowercased()
        let pair = try AccountInvitationPair(canonicalPayload: f.payload)
        let transport = InvitationHTTPTransport(body: Data()), client = try invitationClient(identity, transport)
        var changed = f.fields; changed["targetGeneration"] = "999"
        let substituted = try invitationJSON(changed)
        await transport.setBody(try invitationRecordFixture(f, state: "selected", pairOverride: substituted))
        do { _ = try await client.selectInvitation(accessToken: nativeProducerToken(1), accountID: pair.target.accountID, requestID: pair.requestID, target: pair.target); XCTFail("substituted endpoint") } catch {}
        for body in [try invitationRecordFixture(f, state: "active", signed: true, pairOverride: substituted),
                     try invitationRecordFixture(f, state: "selected", signed: true),
                     try invitationRecordFixture(f, state: "active")] {
            await transport.setBody(body)
            do { _ = try await client.commitInvitation(accessToken: nativeProducerToken(1), accountID: pair.sender.accountID, pair: pair); XCTFail("wrong pair, state, or incomplete proof") } catch {}
        }
        let checkpoint = try AccountInvitationCheckpoint(requestID: pair.requestID, grantID: pair.grantID, revision: 2, state: .selected, proofDigest: pair.digest)
        var wrongGrant = f; wrongGrant.fields["grantID"] = UUID().uuidString.lowercased()
        for body in [try invitationRecordFixture(wrongGrant, state: "cancelled"),
                     try invitationRecordFixture(f, state: "cancelled", pairOverride: substituted)] {
            await transport.setBody(body)
            do { _ = try await client.transitionInvitation(accessToken: nativeProducerToken(1), accountID: pair.sender.accountID, checkpoint: checkpoint, action: .cancel); XCTFail("wrong grant or digest") } catch {}
        }
        let before = await transport.requests.count
        let wrongSigner = try invitationClient(.ephemeral(), transport)
        do { _ = try await wrongSigner.countersignInvitation(accessToken: nativeProducerToken(1), accountID: pair.sender.accountID, pair: pair, signature: f.sender.signature(for: pair.payload).derRepresentation); XCTFail("wrong local signer") } catch {}
        do { _ = try await client.countersignInvitation(accessToken: nativeProducerToken(1), accountID: pair.sender.accountID, pair: pair, signature: f.target.signature(for: pair.payload).derRepresentation); XCTFail("wrong signature") } catch {}
        let after = await transport.requests.count; XCTAssertEqual(before, after)
    }
    func testAllMutationsSignExactFieldsAndBindReturnedPair() async throws {
        var f = try InvitationProofFixture()
        let sender = try invitationIdentity(f.sender), target = try invitationIdentity(f.target)
        f.fields["senderPublicKey"] = sender.publicKey.rawRepresentation.base64EncodedString()
        f.fields["senderDeviceID"] = sender.id.rawValue.uuidString.lowercased()
        f.fields["targetPublicKey"] = target.publicKey.rawRepresentation.base64EncodedString()
        f.fields["targetDeviceID"] = target.id.rawValue.uuidString.lowercased()
        let pair = try AccountInvitationPair(canonicalPayload: f.payload)
        let transport = InvitationHTTPTransport(body: try invitationRecordFixture(f, state: "requested"))
        let client = try invitationClient(sender, transport), recipient = try invitationClient(target, transport, audience: pair.target.audience)
        let request = try invitationRequestFixture(f)
        _ = try await client.createInvitation(accessToken: nativeProducerToken(1), request: AccountInvitationRequestProof(payload: request.payload, signature: request.signature))
        await transport.setBody(try invitationRecordFixture(f, state: "selected"))
        _ = try await recipient.selectInvitation(accessToken: nativeProducerToken(1), accountID: pair.target.accountID, requestID: pair.requestID, target: pair.target)
        let signature = try sender.sign(pair.payload).derRepresentation
        var response = try XCTUnwrap(JSONSerialization.jsonObject(with: invitationRecordFixture(f, state: "selected", signed: true)) as? [String: Any])
        var wire = try XCTUnwrap(response["pair"] as? [String: String]); wire["senderSignature"] = signature.base64EncodedString(); response["pair"] = wire
        await transport.setBody(try JSONSerialization.data(withJSONObject: response))
        _ = try await client.countersignInvitation(accessToken: nativeProducerToken(1), accountID: pair.sender.accountID, pair: pair, signature: signature)
        await transport.setBody(try invitationRecordFixture(f, state: "active", signed: true))
        _ = try await client.commitInvitation(accessToken: nativeProducerToken(1), accountID: pair.sender.accountID, pair: pair)
        for action in [AccountInvitationTransition.cancel, .reject, .revoke] {
            let terminal = action == .cancel ? "cancelled" : (action == .reject ? "rejected" : "revoked")
            await transport.setBody(try invitationRecordFixture(f, state: terminal, signed: true))
            let checkpoint = try AccountInvitationCheckpoint(requestID: pair.requestID, grantID: pair.grantID, revision: 2,
                state: action == .revoke ? .active : .selected, proofDigest: pair.digest)
            _ = try await client.transitionInvitation(accessToken: nativeProducerToken(1), accountID: pair.sender.accountID, checkpoint: checkpoint, action: action)
        }
        await transport.setBody(Data("{\"blocked\":true}".utf8))
        try await client.blockInvitations(accessToken: nativeProducerToken(1), targetAccountID: pair.target.accountID, disconnectExisting: false)
        let link = try AccountInvitationLink(token: nativeProducerToken(7))
        await transport.setBody(try invitationJSON(["version": "2", "hash": link.tokenHash.base64EncodedString()]))
        _ = try await client.rotateInvitationLink(accessToken: nativeProducerToken(1), link: link)
        let requests = await transport.requests
        let extra: [Set<String>] = [["requestPayload", "requestSignature"], ["requestID", "targetDeviceID", "targetGroupID", "targetGeneration", "targetPublicKey", "targetAudience"],
            ["requestID", "signature"], ["requestID", "proofDigest"], ["requestID", "expectedRevision", "proofDigest"], ["requestID", "expectedRevision", "proofDigest"],
            ["requestID", "expectedRevision", "proofDigest"], ["targetAccountID", "disconnectExisting"], ["linkToken"]]
        XCTAssertEqual(requests.count, extra.count)
        for (index, request) in requests.enumerated() {
            let envelope = try JSONDecoder().decode(RendezvousSignedEnvelope.self, from: XCTUnwrap(request.httpBody))
            let fields = try JSONDecoder().decode([String: String].self, from: envelope.payload)
            let op = request.url!.path.replacingOccurrences(of: "/v1/account/invitation/", with: "").replacingOccurrences(of: "/", with: ".")
            XCTAssertEqual(fields["purpose"], "dropmesh.account.invitation." + op + ".v1")
            XCTAssertEqual(Set(fields.keys), extra[index].union(["purpose", "audience", "accessToken"]))
            let key = try P256.Signing.PublicKey(rawRepresentation: envelope.publicKey)
            XCTAssertTrue(key.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: envelope.signature), for: try envelope.canonicalPayload()))
            if fields["proofDigest"] != nil { XCTAssertEqual(fields["proofDigest"], pair.digest.base64EncodedString()) }
            if op == "block" { XCTAssertEqual(fields["disconnectExisting"], "false") }
        }
    }
    func testTransitionCannotChangeStateAtSameRevision() async throws {
        let f = try InvitationProofFixture(), pair = try AccountInvitationPair(canonicalPayload: f.payload)
        let client = try invitationClient(.ephemeral(), InvitationHTTPTransport(body: invitationRecordFixture(f, state: "cancelled")))
        let checkpoint = try AccountInvitationCheckpoint(requestID: pair.requestID, grantID: pair.grantID, revision: 3, state: .selected, proofDigest: pair.digest)
        do { _ = try await client.transitionInvitation(accessToken: nativeProducerToken(1), accountID: pair.sender.accountID, checkpoint: checkpoint, action: .cancel); XCTFail("same revision changed state") } catch {}
    }
    func testMalformedMetadataErrorsAndCancelledResponseFailClosed() async throws {
        let hash = Data(repeating: 7, count: 32).base64EncodedString()
        for body in ["{\"version\":\"0\",\"hash\":\"\(hash)\"}", "{\"version\":\"1\",\"version\":\"1\",\"hash\":\"\(hash)\"}",
            "{\"version\":\"1\",\"hash\":\"bad\"}", "{\"version\":1,\"hash\":\"\(hash)\"}"] {
            do { _ = try await invitationClient(.ephemeral(), InvitationHTTPTransport(body: Data(body.utf8))).invitationLink(accessToken: nativeProducerToken(1)); XCTFail("malformed") }
            catch { XCTAssertEqual(error as? AccountServiceError, .invalidResponse) }
        }
        for (status, expected) in [(401, AccountServiceError.authenticationRejected), (404, .unavailable), (429, .rateLimited), (503, .unavailable)] {
            do { _ = try await invitationClient(.ephemeral(), InvitationHTTPTransport(body: Data(), status: status)).invitationLink(accessToken: nativeProducerToken(1)); XCTFail("HTTP error") }
            catch { XCTAssertEqual(error as? AccountServiceError, expected) }
        }
        do { _ = try await invitationClient(.ephemeral(), InvitationHTTPTransport(body: Data(), status: 409)).invitationLink(accessToken: nativeProducerToken(1)); XCTFail("conflict") }
        catch { XCTAssertEqual(error as? AccountInvitationError, .conflict) }
        let gate = NativeProducerGate(), transport = InvitationHTTPTransport(body: try invitationJSON(["version": "1", "hash": hash]))
        await transport.setGate(gate)
        let client = try invitationClient(.ephemeral(), transport)
        let work = Task { try await client.invitationLink(accessToken: nativeProducerToken(1)) }
        await gate.entered(); work.cancel(); await gate.release()
        do { _ = try await work.value; XCTFail("cancelled completion") } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testGetBindsRequestedIdentityAndConfiguredOriginWithoutGrantingAuthority() async throws {
        let f = try InvitationProofFixture(), transport = InvitationHTTPTransport(body: try invitationRecordFixture(f, state: "selected"))
        let client = try invitationClient(.ephemeral(), transport)
        let result = try await client.invitation(accessToken: nativeProducerToken(1), accountID: f.fields["senderAccountID"]!, requestID: f.fields["requestID"]!)
        XCTAssertEqual(result.checkpoint.state, .selected)
        XCTAssertTrue(result.targetSignature.isEmpty)
        do { _ = try await client.invitation(accessToken: nativeProducerToken(1), accountID: f.fields["senderAccountID"]!, requestID: UUID().uuidString.lowercased()); XCTFail("substituted request") } catch {}
        var wrong = f.fields; wrong["origin"] = "https://other.example.com"
        await transport.setBody(try invitationRecordFixture(f, state: "selected", pairOverride: invitationJSON(wrong)))
        do { _ = try await client.invitation(accessToken: nativeProducerToken(1), accountID: f.fields["senderAccountID"]!, requestID: f.fields["requestID"]!); XCTFail("wrong origin") } catch {}
    }
    func testBoundedPageValidatesCursorAndDuplicateRecords() async throws {
        let f = try InvitationProofFixture(), record = try invitationRecordFixture(f, state: "requested")
        let body = Data("{\"records\":[".utf8) + record + Data("]}".utf8)
        let transport = InvitationHTTPTransport(body: body), client = try invitationClient(.ephemeral(), transport)
        let result = try await client.invitations(accessToken: nativeProducerToken(1), accountID: f.fields["senderAccountID"]!, inbox: false, afterRequestID: nil, limit: 5)
        XCTAssertEqual(result.count, 1)
        await transport.setBody(Data("{\"records\":[".utf8) + record + Data(",".utf8) + record + Data("]}".utf8))
        do { _ = try await client.invitations(accessToken: nativeProducerToken(1), accountID: f.fields["senderAccountID"]!, inbox: false, afterRequestID: nil, limit: 5); XCTFail("duplicate") } catch {}
        let count = await transport.requests.count
        do { _ = try await client.invitations(accessToken: nativeProducerToken(1), accountID: f.fields["senderAccountID"]!, inbox: false, afterRequestID: nil, limit: 6); XCTFail("over bound") } catch {}
        let after = await transport.requests.count; XCTAssertEqual(count, after)
    }
    func testSignedLinkReadUsesExactPurposeAndParsesOnlyVersionHash() async throws {
        let identity = try DeviceIdentity.ephemeral(), hash = Data(repeating: 7, count: 32)
        let transport = InvitationHTTPTransport(body: try invitationJSON(["version": "1", "hash": hash.base64EncodedString()]))
        let client = try invitationClient(identity, transport)
        let result = try await client.invitationLink(accessToken: nativeProducerToken(1))
        XCTAssertEqual(result.version, 1); XCTAssertEqual(result.hash, hash)
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first), body = try XCTUnwrap(request.httpBody)
        let envelope = try JSONDecoder().decode(RendezvousSignedEnvelope.self, from: body)
        XCTAssertEqual(request.url?.path, "/v1/account/invitation/link/get")
        let fields = try JSONDecoder().decode([String: String].self, from: envelope.payload)
        XCTAssertEqual(fields, ["purpose": "dropmesh.account.invitation.link.get.v1", "audience": "com.example.app", "accessToken": nativeProducerToken(1)])
        XCTAssertTrue(identity.publicKey.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: envelope.signature), for: try envelope.canonicalPayload()))
    }
}

func invitationClient(_ identity: DeviceIdentity, _ transport: InvitationHTTPTransport, audience: String = "com.example.app") throws -> AccountServiceClient {
    try AccountServiceClient(identity: identity, origin: URL(string: "https://accounts.example.com")!, audience: audience,
        transport: transport, now: { NativeProducerFixture.start }, nonce: { Data(repeating: 8, count: 32) })
}
actor InvitationHTTPTransport: AccountServiceTransport {
    var requests: [URLRequest] = []
    var body: Data
    let status: Int
    private var gate: NativeProducerGate?
    init(body: Data, status: Int = 200) { self.body = body; self.status = status }
    func setBody(_ data: Data) { body = data }
    func setGate(_ gate: NativeProducerGate) { self.gate = gate }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        await gate?.block()
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
    }
}

private func invitationIdentity(_ key: P256.Signing.PrivateKey) throws -> DeviceIdentity {
    let secret = CheckpointSecretStore()
    try secret.store(key.rawRepresentation, for: "p256-signing-private-key", policy: KeychainStore.identityPolicy)
    return try DeviceIdentity.loadOrCreate(keychain: secret, policy: KeychainStore.identityPolicy)
}
