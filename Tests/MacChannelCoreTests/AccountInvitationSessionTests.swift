import Foundation
import XCTest
@testable import MacChannelCore

final class AccountInvitationSessionTests: XCTestCase, @unchecked Sendable {
    func testCreatingRequestPersistsSignedIntentBeforeNetworkMutation() async throws {
        let f = try InvitationSessionFixture()
        try await f.seedGroup()
        let controller = f.controller()
        await controller.restore()
        let link = try AccountInvitationLink.generate()
        let record = try await controller.createInvitationRequest(link: link)
        let retained = try await f.invitations.listRequests(binding: f.binding, accountID: f.account)
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(retained[0].phase, .signed)
        XCTAssertEqual(retained[0].request.targetLinkHash, link.tokenHash)
        XCTAssertEqual(record.checkpoint.state, .requested)
        let created = await f.service.createdRequestCount()
        XCTAssertEqual(created, 1)
    }

    func testCreatingRequestWithoutConfiguredIdentityFailsBeforeNetwork() async throws {
        let f = try InvitationSessionFixture()
        try await f.seedGroup()
        let controller = f.controller(identity: false)
        await controller.restore()
        do { _ = try await controller.createInvitationRequest(link: .generate()); XCTFail("identity required") }
        catch { XCTAssertEqual(error as? AccountSessionControllerError, .unavailable) }
        let created = await f.service.createdRequestCount()
        XCTAssertEqual(created, 0)
    }

    func testAcceptingInvitationSelectsThisDeviceSignsAndCommitsWhenSenderAlreadyConfirmed() async throws {
        let f = try InvitationSessionFixture()
        try await f.seedGroup()
        let incoming = try await f.service.installIncomingRequest(for: f, senderPreconfirmed: true)
        let controller = f.controller()
        await controller.restore()
        let result = try await controller.acceptInvitation(requestID: incoming.checkpoint.requestID)
        XCTAssertEqual(result.checkpoint.state, .active)
        let effects = await f.service.effects()
        XCTAssertEqual(effects.targets, [f.binding.deviceID.uuidString.lowercased()])
        XCTAssertEqual(effects.commits, 1)
        let intent = try await f.invitations.loadIntent(binding: f.binding, accountID: f.account,
            requestID: incoming.checkpoint.requestID)
        XCTAssertEqual(intent?.phase, .signed)
        XCTAssertEqual(intent?.role, .target)
        let checkpoint = try await f.invitations.loadCheckpoint(binding: f.binding, accountID: f.account,
            requestID: incoming.checkpoint.requestID)
        XCTAssertEqual(checkpoint?.state, .active)
    }

    func testSharingIsExplicitlyEnabledAndNeverRotatesOnRead() async throws {
        let f = try InvitationSessionFixture()
        let disabled = f.controller(enabled: false)
        let supported = await disabled.supportsInvitations()
        XCTAssertFalse(supported)
        let controller = f.controller()
        await controller.restore()
        let link = try await controller.rotateInvitationShareLink()
        let loaded = try await controller.invitationShareLink()
        XCTAssertEqual(loaded, link)
        let count = await f.service.rotations
        XCTAssertEqual(count, 1)
    }
    func testLostResponseRetainsExactCapabilityAndReadRecoversWithoutRotation() async throws {
        let f = try InvitationSessionFixture(), controller = f.controller()
        await controller.restore(); await f.service.loseNextResponse()
        do { _ = try await controller.rotateInvitationShareLink(); XCTFail("lost response") } catch {}
        let pending = try await f.links.load(binding: f.binding, accountID: f.account)
        XCTAssertNotNil(pending.pending); XCTAssertNil(pending.current)
        let restarted = f.controller(); await restarted.restore()
        let recovered = try await restarted.invitationShareLink()
        XCTAssertEqual(recovered, pending.pending)
        let count = await f.service.rotations; XCTAssertEqual(count, 1)
    }
    func testLogoutFencesLateRotationAndKeepsRecoverySecret() async throws {
        let f = try InvitationSessionFixture(), controller = f.controller(), gate = NativeProducerGate()
        await controller.restore(); await f.service.setGate(gate)
        let work = Task { try await controller.rotateInvitationShareLink() }
        await gate.entered(); try await controller.logout(); await gate.release()
        do { _ = try await work.value; XCTFail("late logged-out result") } catch {}
        let stored = try await f.links.load(binding: f.binding, accountID: f.account)
        XCTAssertNil(stored.current); XCTAssertNotNil(stored.pending)
    }
    func testRefreshFencesLateRotationAndConcurrentShareIsBusy() async throws {
        let f = try InvitationSessionFixture(), controller = f.controller(), gate = NativeProducerGate()
        await controller.restore(); await f.service.setGate(gate)
        let work = Task { try await controller.rotateInvitationShareLink() }
        await gate.entered()
        do { _ = try await controller.rotateInvitationShareLink(); XCTFail("concurrent mutation") }
        catch { XCTAssertEqual(error as? AccountSessionControllerError, .busy) }
        try await controller.refresh(); await gate.release()
        do { _ = try await work.value; XCTFail("late refreshed session") } catch {}
        let count = await f.service.rotations; XCTAssertEqual(count, 1)
    }
    func testSecureStorageFailurePreventsNetworkMutation() async throws {
        let f = try InvitationSessionFixture(), controller = f.controller()
        await controller.restore(); f.secrets.failWrites(true)
        do { _ = try await controller.rotateInvitationShareLink(); XCTFail("unpersisted token sent") } catch {}
        let count = await f.service.rotations; XCTAssertEqual(count, 0)
    }
}

private struct InvitationSessionFixture {
    let identity: DeviceIdentity
    let binding: AccountSessionBinding
    let service: InvitationSessionService
    let storage: InvitationSessionStorage
    let secrets: CheckpointSecretStore
    let links: KeychainAccountInvitationLinkStorage
    let invitationSecret: CheckpointSecretStore
    let invitations: KeychainAccountInvitationStorage
    let groupSecret: CheckpointSecretStore
    let verifier: AccountGroupHistoryVerifier
    let account: String
    let groupID: String
    let anchor: AccountGroupEvent
    init() throws {
        identity = try DeviceIdentity.ephemeral()
        secrets = CheckpointSecretStore()
        links = KeychainAccountInvitationLinkStorage(store: secrets)
        invitationSecret = CheckpointSecretStore()
        invitations = KeychainAccountInvitationStorage(store: invitationSecret)
        groupSecret = CheckpointSecretStore()
        verifier = AccountGroupHistoryVerifier(storage: KeychainAccountGroupCheckpointStorage(store: groupSecret))
        let accountID = UUID()
        binding = try AccountSessionBinding(deviceID: identity.id.rawValue, audience: "test.app", origin: URL(string: "https://account.example")!)
        account = accountID.uuidString.lowercased()
        groupID = UUID().uuidString.lowercased()
        let tokens = AccountSessionTokens(identity: .init(accountID: accountID, sessionID: UUID(), deviceID: identity.id.rawValue, audience: binding.audience),
            accessToken: nativeProducerToken(1), refreshToken: nativeProducerToken(2),
            accessExpiresAt: Date().addingTimeInterval(3600), refreshExpiresAt: Date().addingTimeInterval(7200))
        anchor = try Self.anchor(identity: identity, account: account, group: groupID)
        service = InvitationSessionService(tokens, history: [anchor])
        storage = InvitationSessionStorage(try AccountStoredSession(binding: binding, tokens: tokens, phase: .active))
    }
    func controller(enabled: Bool = true, identity includeIdentity: Bool = true) -> AccountSessionController {
        AccountSessionController(service: service, storage: storage, binding: binding,
            groupVerifier: verifier,
            invitations: enabled ? .init(identity: includeIdentity ? identity : nil, links: links, invitations: invitations) : nil)
    }
    func seedGroup() async throws {
        _ = try await verifier.confirm(anchor: anchor, expectedAccountID: account, expectedGroupID: groupID,
            expectedGeneration: 1, expectedAnchorHash: anchor.digest(), binding: binding)
    }
    private static func anchor(identity: DeviceIdentity, account: String, group: String) throws -> AccountGroupEvent {
        let key = identity.publicKey.rawRepresentation
        let device = identity.id.rawValue.uuidString.lowercased()
        let unsigned = try AccountGroupEvent(accountID: account, groupID: group, generation: 1, sequence: 1,
            previousHash: Data(), action: "bootstrap", actorDeviceID: device, actorPublicKey: key,
            subjectDeviceID: device, subjectPublicKey: key, epochMilliseconds: 1_800_000_000_000)
        return try AccountGroupEvent(accountID: account, groupID: group, generation: 1, sequence: 1,
            previousHash: Data(), action: "bootstrap", actorDeviceID: device, actorPublicKey: key,
            subjectDeviceID: device, subjectPublicKey: key, epochMilliseconds: 1_800_000_000_000,
            signature: identity.sign(unsigned.canonicalPayload()).derRepresentation)
    }
}
private actor InvitationSessionStorage: AccountSessionStorage {
    var record: AccountStoredSession?
    init(_ record: AccountStoredSession) { self.record = record }
    func load() async throws -> AccountStoredSession? { record }
    func save(_ record: AccountStoredSession) async throws { self.record = record }
    func remove() async throws { record = nil }
}
private actor InvitationSessionService: AccountSessionService, AccountInvitationService, AccountGroupEnrollmentService, AccountGroupService {
    let tokens: AccountSessionTokens
    var history: [AccountGroupEvent]
    var link: AccountInvitationLinkState?
    var rotations = 0
    var createdRequests = 0
    var selectedTargets: [String] = []
    var commits = 0
    var loseResponse = false
    var gate: NativeProducerGate?
    var records: [String: AccountInvitationRecord] = [:]
    var senderFinalKeys: [String: DeviceIdentity] = [:]
    init(_ tokens: AccountSessionTokens, history: [AccountGroupEvent]) {
        self.tokens = tokens
        self.history = history
    }
    func setGate(_ gate: NativeProducerGate) { self.gate = gate }
    func loseNextResponse() { loseResponse = true }
    func createdRequestCount() -> Int { createdRequests }
    func effects() -> (targets: [String], commits: Int) { (selectedTargets, commits) }
    func challenge() async throws -> AccountLoginChallenge { throw AccountServiceError.unavailable }
    func complete(challengeID: String, code: String, identityToken: String) async throws -> AccountSessionTokens { tokens }
    func status(accessToken: String) async throws -> AccountSessionIdentity { tokens.identity }
    func refresh(refreshToken: String) async throws -> AccountSessionTokens { tokens }
    func logout(accessToken: String) async throws {}
    func invitationLink(accessToken: String) async throws -> AccountInvitationLinkState {
        guard let link else { throw AccountInvitationError.conflict }; return link
    }
    func rotateInvitationLink(accessToken: String, link: AccountInvitationLink) async throws -> AccountInvitationLinkState {
        rotations += 1
        let state = AccountInvitationLinkState(version: UInt64(rotations), hash: link.tokenHash)
        self.link = state
        if let gate { await gate.block() }
        if loseResponse { loseResponse = false; throw AccountServiceError.transport }
        return state
    }
    func createInvitation(accessToken: String, request: AccountInvitationRequestProof) async throws -> AccountInvitationRecord {
        createdRequests += 1
        let checkpoint = try AccountInvitationCheckpoint(requestID: request.request.requestID, grantID: request.request.grantID,
            revision: 1, state: .requested, proofDigest: Data())
        let record = try AccountInvitationRecord(checkpoint: checkpoint, verifiedAtMilliseconds: request.request.issuedAtMilliseconds,
            request: request, pair: nil, senderSignature: Data(), targetSignature: Data())
        records[checkpoint.requestID] = record
        return record
    }
    func invitation(accessToken: String, accountID: String, requestID: String) async throws -> AccountInvitationRecord {
        guard let record = records[requestID] else { throw AccountServiceError.unavailable }
        return record
    }
    func invitations(accessToken: String, accountID: String, inbox: Bool, afterRequestID: String?, limit: Int) async throws -> [AccountInvitationRecord] {
        Array(records.values.sorted { $0.checkpoint.requestID < $1.checkpoint.requestID }.prefix(limit))
    }
    func selectInvitation(accessToken: String, accountID: String, requestID: String, target: AccountInvitationEndpoint) async throws -> AccountInvitationRecord {
        guard let existing = records[requestID] else { throw AccountServiceError.unavailable }
        selectedTargets.append(target.deviceID)
        let pair = try pairPayload(request: existing.request.request, target: target, linkVersion: 1)
        let checkpoint = try AccountInvitationCheckpoint(requestID: pair.requestID, grantID: pair.grantID,
            revision: existing.checkpoint.revision + 1, state: .selected, proofDigest: pair.digest)
        let senderSignature = try senderFinalKeys[requestID]?.sign(pair.payload).derRepresentation ?? Data()
        let selected = try AccountInvitationRecord(checkpoint: checkpoint, verifiedAtMilliseconds: pair.issuedAtMilliseconds,
            request: existing.request, pair: pair, senderSignature: senderSignature, targetSignature: Data())
        records[requestID] = selected
        return selected
    }
    func countersignInvitation(accessToken: String, accountID: String, pair: AccountInvitationPair, signature: Data) async throws -> AccountInvitationRecord {
        guard let existing = records[pair.requestID] else { throw AccountServiceError.unavailable }
        let senderSignature = pair.sender.accountID == accountID ? signature : existing.senderSignature
        let targetSignature = pair.target.accountID == accountID ? signature : existing.targetSignature
        let record = try AccountInvitationRecord(checkpoint: existing.checkpoint, verifiedAtMilliseconds: existing.verifiedAtMilliseconds,
            request: existing.request, pair: pair, senderSignature: senderSignature, targetSignature: targetSignature)
        records[pair.requestID] = record
        return record
    }
    func commitInvitation(accessToken: String, accountID: String, pair: AccountInvitationPair) async throws -> AccountInvitationRecord {
        guard let existing = records[pair.requestID], !existing.senderSignature.isEmpty, !existing.targetSignature.isEmpty else {
            throw AccountServiceError.unavailable
        }
        commits += 1
        let checkpoint = try AccountInvitationCheckpoint(requestID: pair.requestID, grantID: pair.grantID,
            revision: existing.checkpoint.revision + 1, state: .active, proofDigest: pair.digest)
        let record = try AccountInvitationRecord(checkpoint: checkpoint, verifiedAtMilliseconds: existing.verifiedAtMilliseconds,
            request: existing.request, pair: pair, senderSignature: existing.senderSignature, targetSignature: existing.targetSignature)
        records[pair.requestID] = record
        return record
    }
    func transitionInvitation(accessToken: String, accountID: String, checkpoint: AccountInvitationCheckpoint, action: AccountInvitationTransition) async throws -> AccountInvitationRecord { throw AccountServiceError.unavailable }
    func blockInvitations(accessToken: String, targetAccountID: String, disconnectExisting: Bool) async throws {}
    func discoverGroup(accessToken: String, accountID: String) async throws -> AccountGroupDiscovery {
        guard let anchor = history.first, let head = history.last else { return .absent }
        return .present(.init(groupID: anchor.groupID, generation: anchor.generation, anchor: anchor,
            anchorHash: try anchor.digest(), headSequence: head.sequence, headHash: try head.digest()))
    }
    func recordGroupBootstrap(accessToken: String, event: AccountGroupEvent) async throws {}
    func groupHistory(accessToken: String, groupID: String) async throws -> [AccountGroupEvent] { history }
    func installIncomingRequest(for fixture: InvitationSessionFixture, senderPreconfirmed: Bool) async throws -> AccountInvitationRecord {
        let sender = try DeviceIdentity.ephemeral()
        let senderEndpoint = try AccountInvitationEndpoint(audience: fixture.binding.audience,
            accountID: UUID().uuidString.lowercased(), groupID: UUID().uuidString.lowercased(), generation: 1,
            deviceID: sender.id.rawValue.uuidString.lowercased(), publicKey: sender.publicKey.rawRepresentation)
        let issued = UInt64(AccountServiceClient.validEpochMilliseconds(Date())!)
        let request = try AccountInvitationRequest(sender: senderEndpoint, origin: fixture.binding.origin,
            requestID: UUID().uuidString.lowercased(), grantID: UUID().uuidString.lowercased(),
            targetLinkHash: Data(repeating: 7, count: 32), issuedAtMilliseconds: issued)
        let proof = try AccountInvitationRequestProof(payload: request.payload,
            signature: sender.sign(request.payload).derRepresentation)
        let record = try await createInvitation(accessToken: fixture.storage.record!.tokens.accessToken, request: proof)
        if senderPreconfirmed { senderFinalKeys[request.requestID] = sender }
        return record
    }
    private func pairPayload(request: AccountInvitationRequest, target: AccountInvitationEndpoint,
                             linkVersion: UInt64) throws -> AccountInvitationPair {
        let fields = ["purpose": "dropmesh.account.invitation.pair.v1", "audience": request.sender.audience,
            "origin": request.origin, "requestID": request.requestID, "grantID": request.grantID,
            "linkVersion": String(linkVersion), "targetLinkHash": request.targetLinkHash.base64EncodedString(),
            "issuedAtMilliseconds": String(request.issuedAtMilliseconds),
            "expiresAtMilliseconds": String(request.expiresAtMilliseconds),
            "senderAudience": request.sender.audience, "senderAccountID": request.sender.accountID,
            "senderGroupID": request.sender.groupID, "senderGeneration": String(request.sender.generation),
            "senderDeviceID": request.sender.deviceID, "senderPublicKey": request.sender.publicKey.base64EncodedString(),
            "targetAudience": target.audience, "targetAccountID": target.accountID, "targetGroupID": target.groupID,
            "targetGeneration": String(target.generation), "targetDeviceID": target.deviceID,
            "targetPublicKey": target.publicKey.base64EncodedString()]
        return try AccountInvitationPair(canonicalPayload: invitationJSON(fields))
    }
}
