import Foundation
import XCTest
@testable import MacChannelCore

final class GoDeviceApprovalInteropTests: XCTestCase, @unchecked Sendable {
    func testTwoControllersSignedHTTPAndDurableSQLApproval() async throws {
        let fixture = try ApprovalInteropHTTP()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("approval-native-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let actorIdentity = try DeviceIdentity.loadOrCreate(keychain: ApprovalInteropSecrets(root.appendingPathComponent("actor-identity")))
        let subjectIdentity = try DeviceIdentity.loadOrCreate(keychain: ApprovalInteropSecrets(root.appendingPathComponent("subject-identity")))
        let provision = try await fixture.provision([actorIdentity, subjectIdentity])
        let actor = try ApprovalInteropPeer(root: root, name: "actor", identity: actorIdentity, provision: provision, index: 0, fixture: fixture)
        let subject = try ApprovalInteropPeer(root: root, name: "subject", identity: subjectIdentity, provision: provision, index: 1, fixture: fixture)
        try await actor.seed(); try await subject.seed()
        let a = actor.controller(), s = subject.controller()
        await a.restore(); await s.restore()
        let signedInA = await a.snapshot(), signedInS = await s.snapshot()
        XCTAssertEqual(signedInA.phase, .signedIn); XCTAssertEqual(signedInS.phase, .signedIn)
        let absent = try await a.discoverAccountGroup(); XCTAssertEqual(absent, .absent)
        let bootstrap = try await a.prepareFirstDeviceJoin()
        let beforeBootstrap = try await fixture.status(); XCTAssertEqual(beforeBootstrap.Events, 0)
        let initial = try await a.confirmFirstDeviceJoin(attemptID: bootstrap)
        XCTAssertEqual(initial.sequence, 1); XCTAssertEqual(initial.members.count, 1)
        guard case .present(let discovery) = try await s.discoverAccountGroup() else { return XCTFail("Subject must discover actor group") }
        XCTAssertEqual(discovery.groupID, initial.groupID)
        XCTAssertEqual(subject.checkpoint.writes, 0)
        do { _ = try await s.syncGroup(groupID: initial.groupID); XCTFail("Discovery granted an unconfirmed membership pin") }
        catch { XCTAssertEqual(error as? AccountGroupCheckpointError, .missingCheckpoint) }

        // A rejected request must not commit even via a correctly signed route.
        let rejectedTicket = try await s.prepareDeviceJoin()
        XCTAssertEqual(subject.intents.writes, 0)
        let beforeCreate = try await fixture.status(); XCTAssertEqual(beforeCreate.Pending, 0)
        let rejectedRequest = try await s.confirmDeviceJoin(ticketID: rejectedTicket.id)
        let rejectedID = rejectedRequest.summary.requestID
        let rejected = try await a.rejectDeviceJoin(requestID: rejectedID)
        XCTAssertEqual(rejected.phase, .rejected)
        do {
            _ = try await actor.client.commitGroupJoin(accessToken: actor.token, accountID: actor.account,
                requestID: rejectedID, draftHash: Data(repeating: 7, count: 32))
            XCTFail("Rejected SQL request committed")
        } catch { XCTAssertEqual(error as? AccountGroupEnrollmentError, .conflict) }
        _ = try await s.resumeDeviceApproval(requestID: rejectedID)
        let afterReject = try await fixture.status()
        XCTAssertEqual(afterReject.Events, 1); XCTAssertEqual(afterReject.Rejected, 1)

        let mutationsBeforePrepare = afterReject.mutations
        let ticket = try await s.prepareDeviceJoin()
        let prepared = try await fixture.status(); XCTAssertEqual(prepared.mutations, mutationsBeforePrepare)
        let request = try await s.confirmDeviceJoin(ticketID: ticket.id)
        let id = request.summary.requestID
        let independentRequestCode = try XCTUnwrap(request.requestCode)
        let created = try await fixture.status(); XCTAssertEqual(created.Pending, 2)
        let writesBeforeReads = [actor.intents.writes, subject.intents.writes, actor.checkpoint.writes, subject.checkpoint.writes]
        _ = try await a.pendingDeviceApprovals()
        do { _ = try await s.pendingDeviceApprovals(); XCTFail("Unjoined subject listed member-only requests") }
        catch { XCTAssertEqual(error as? AccountGroupEnrollmentError, .conflict) }
        let actorRead = try await a.deviceApproval(requestID: id), subjectRead = try await s.deviceApproval(requestID: id)
        XCTAssertNil(actorRead.snapshot); XCTAssertNil(subjectRead.snapshot)
        XCTAssertEqual(writesBeforeReads, [actor.intents.writes, subject.intents.writes, actor.checkpoint.writes, subject.checkpoint.writes])
        let readStatus = try await fixture.status(); XCTAssertEqual(readStatus.mutations, created.mutations)
        let wrong = try await a.prepareDeviceApproval(requestID: id)
        let approvalWrites = actor.intents.writes
        do { _ = try await a.confirmDeviceApproval(ticketID: wrong.id, joiningCode: "wrong-independent-code"); XCTFail("Wrong code proposed") }
        catch { XCTAssertEqual(error as? AccountDeviceApprovalError, .verificationMismatch) }
        XCTAssertEqual(actor.intents.writes, approvalWrites)
        let wrongStatus = try await fixture.status(); XCTAssertEqual(wrongStatus.count("propose"), 0)
        let review = try await a.prepareDeviceApproval(requestID: id)
        let proposed = try await a.confirmDeviceApproval(ticketID: review.id, joiningCode: independentRequestCode)
        XCTAssertEqual(proposed.phase, .waitingForSubject); XCTAssertNil(proposed.snapshot)
        let independentCapsule = try XCTUnwrap(proposed.memberCode)
        let proposedRecord = try await actor.client.groupJoin(accessToken: actor.token, accountID: actor.account, requestID: id)
        let actorRecords = try await actor.intentStore().list(binding: actor.binding, accountID: actor.account)
        let retainedActor = try XCTUnwrap(actorRecords.first)
        guard case .actorProposed(let actorProof) = retainedActor.activePredecessor else { return XCTFail("Missing exact actor proof") }
        XCTAssertEqual(proposedRecord.draft, actorProof.draft)
        let subjectReview = try await s.prepareDeviceJoinConfirmation(requestID: id, memberCode: independentCapsule)
        XCTAssertEqual(subject.checkpoint.writes, 0)
        // The first real SQL countersign succeeds; only its HTTP acknowledgment is damaged.
        do { _ = try await s.confirmDeviceJoinConfirmation(ticketID: subjectReview.id); XCTFail("Damaged acknowledgment accepted") }
        catch { XCTAssertEqual(error as? AccountServiceError, .invalidResponse) }
        let subjectRecords = try await subject.intentStore().list(binding: subject.binding, accountID: subject.account)
        let saved = try XCTUnwrap(subjectRecords.first)
        guard case .subjectCountersigned(let proof, let event) = saved.activePredecessor else { return XCTFail("Missing retained countersign") }
        XCTAssertEqual(saved.originalSessionIdentity.sessionID, subject.sessionID)
        XCTAssertEqual(proof.draft, actorProof.draft)
        let sqlReceipt = try await actor.client.groupJoin(accessToken: actor.token, accountID: actor.account, requestID: id)
        XCTAssertEqual(sqlReceipt.summary.status, .countersigned); XCTAssertEqual(sqlReceipt.event, event)
        XCTAssertEqual(subject.checkpoint.writes, 0)
        // Recreate every injected persistence adapter from its real disk file.
        let reloadedIdentity = try DeviceIdentity.loadOrCreate(keychain: ApprovalInteropSecrets(root.appendingPathComponent("subject-identity")))
        XCTAssertEqual(reloadedIdentity.publicKey.rawRepresentation, subjectIdentity.publicKey.rawRepresentation)
        let restarted = try ApprovalInteropPeer(root: root, name: "subject", identity: reloadedIdentity, provision: provision, index: 1, fixture: fixture)
        let recovered = restarted.controller(); await recovered.restore()
        let retry = try await recovered.resumeDeviceApproval(requestID: id)
        XCTAssertEqual(retry.phase, .waitingForActor); XCTAssertNil(retry.snapshot)
        let restartedRecords = try await restarted.intentStore().list(binding: restarted.binding, accountID: restarted.account)
        let savedAgain = try XCTUnwrap(restartedRecords.first)
        XCTAssertEqual(saved, savedAgain, "Retry must retain exact proof and original session, not sign again")
        let joinedActor = try await a.resumeDeviceApproval(requestID: id)
        let actorSnapshot = try XCTUnwrap(joinedActor.snapshot)
        XCTAssertEqual(joinedActor.phase, .joined)
        let observed = try await recovered.deviceApproval(requestID: id)
        XCTAssertEqual(observed.phase, .verifyingHistory); XCTAssertNil(observed.snapshot)
        XCTAssertEqual(restarted.checkpoint.writes, 0)
        // Expired mutation consent cannot be revived. Historical verification uses
        // a new explicit verification ticket and full local-key/history validation.
        restarted.clock.advance(301)
        let beforeRecovery = try await fixture.status()
        let ids = try await recovered.retainedDeviceApprovalRequestIDs(); XCTAssertEqual(ids, [id])
        let verification = try await recovered.prepareDeviceJoinConfirmation(requestID: id, memberCode: independentCapsule)
        XCTAssertEqual(verification.operation, .verifyCommitted)
        let joinedSubject = try await recovered.confirmDeviceJoinConfirmation(ticketID: verification.id)
        let snapshot = try XCTUnwrap(joinedSubject.snapshot)
        XCTAssertEqual(joinedSubject.phase, .joined); XCTAssertEqual(snapshot, actorSnapshot)
        XCTAssertEqual(snapshot.accountID, actor.account); XCTAssertEqual(snapshot.groupID, initial.groupID)
        XCTAssertEqual(snapshot.generation, 1); XCTAssertEqual(snapshot.sequence, 2)
        XCTAssertEqual(snapshot.headHash, try event.digest())
        XCTAssertEqual(Set(snapshot.members.map(\.deviceID)), Set([actorIdentity.id.rawValue.uuidString.lowercased(),subjectIdentity.id.rawValue.uuidString.lowercased()]))
        XCTAssertEqual(Set(snapshot.members.map(\.publicKey)), Set([actorIdentity.publicKey.rawRepresentation,subjectIdentity.publicKey.rawRepresentation]))
        let final = try await fixture.status()
        XCTAssertEqual(final.mutations, beforeRecovery.mutations)
        XCTAssertEqual(final.Events, 2); XCTAssertEqual(final.Committed, 1); XCTAssertEqual(final.Rejected, 1)
        XCTAssertEqual(final.count("countersign"), 2)
        // Same-account token possession cannot authorize the other exact device.
        do { _ = try await subject.client.status(accessToken: actor.token); XCTFail("Actor token accepted on subject identity") }
        catch { XCTAssertEqual(error as? AccountServiceError, .authenticationRejected) }
        XCTAssertFalse(actor.manualTrust.isTrusted(subjectIdentity.id)); XCTAssertFalse(subject.manualTrust.isTrusted(actorIdentity.id))
        XCTAssertEqual(actor.manualTrust.persistedGeneration, 0); XCTAssertEqual(subject.manualTrust.persistedGeneration, 0)
        XCTAssertEqual(actor.manualSecrets.writes, 0); XCTAssertEqual(subject.manualSecrets.writes, 0)
    }
}

private struct ApprovalInteropHTTP: Sendable {
    let origin = URL(string: "https://approval-interop.invalid")!
    let audience = "com.zensystech.dropmesh"
    let loopback: URL
    init() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["DROPMESH_RUN_NATIVE_DEVICE_APPROVAL"] == "1" else { throw XCTSkip("Requires isolated native approval launcher") }
        guard let raw = env["DROPMESH_APPROVAL_URL"], let url = URL(string: raw), url.scheme == "http", url.host == "127.0.0.1",
              let port = url.port, (1...65535).contains(port), url.path.isEmpty, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
        else { throw AccountServiceError.invalidConfiguration }
        loopback = url
    }
    struct Peer: Decodable { let Device, Session, Token: String; let Key: Data }
    struct Provision: Decodable { let Account: String; let Expiry: Int64; let Peers: [Peer] }
    func provision(_ identities: [DeviceIdentity]) async throws -> Provision {
        struct PublicDevice: Encodable { let Device: String; let Key: Data }
        var request = URLRequest(url: loopback.appendingPathComponent("fixture-provision")); request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(identities.map { PublicDevice(Device: $0.id.rawValue.uuidString.lowercased(), Key: $0.publicKey.rawRepresentation) })
        let (data,response) = try await LiveAccountServiceTransport().send(request)
        guard response.statusCode == 200 else { throw AccountServiceError.invalidResponse }
        let value = try JSONDecoder().decode(Provision.self, from: data)
        guard value.Peers.count == 2, UUID(uuidString: value.Account) != nil else { throw AccountServiceError.invalidResponse }
        for (p,identity) in zip(value.Peers,identities) {
            guard p.Device == identity.id.rawValue.uuidString.lowercased(), p.Key == identity.publicKey.rawRepresentation,
                UUID(uuidString: p.Session) != nil, AccountServiceClient.validToken(p.Token) else { throw AccountServiceError.invalidResponse }
        }
        return value
    }
    struct Status: Decodable {
        let Events, Pending, Committed, Rejected: Int
        let Routes: [String:Int]
        func count(_ operation: String) -> Int { Routes["/v1/account/group/join/" + operation, default: 0] }
        var mutations: Int { ["create","propose","countersign","commit","reject","cancel"].reduce(0) { $0 + count($1) } }
    }
    func status() async throws -> Status {
        let (data,response) = try await LiveAccountServiceTransport().send(URLRequest(url: loopback.appendingPathComponent("fixture-status")))
        guard response.statusCode == 200 else { throw AccountServiceError.invalidResponse }
        return try JSONDecoder().decode(Status.self, from: data)
    }
}

private final class ApprovalInteropClock: @unchecked Sendable {
    private let lock = NSLock(); private var offset: TimeInterval = 0
    func now() -> Date { lock.withLock { Date().addingTimeInterval(offset) } }
    func advance(_ seconds: TimeInterval) { lock.withLock { offset += seconds } }
}

private struct ApprovalInteropPeer: Sendable {
    let identity: DeviceIdentity; let client: AccountServiceClient; let binding: AccountSessionBinding
    let account, token: String; let sessionID: UUID; let expiry: Date
    let session, bootstrap, intents, checkpoint, manualSecrets: ApprovalInteropSecrets
    let manualTrust: TrustStore
    let clock = ApprovalInteropClock()
    init(root: URL, name: String, identity: DeviceIdentity, provision: ApprovalInteropHTTP.Provision, index: Int, fixture: ApprovalInteropHTTP) throws {
        self.identity = identity; account = provision.Account; token = provision.Peers[index].Token
        sessionID = UUID(uuidString: provision.Peers[index].Session)!; expiry = Date(timeIntervalSince1970: Double(provision.Expiry))
        binding = try .init(deviceID: identity.id.rawValue, audience: fixture.audience, origin: fixture.origin)
        client = try .init(identity: identity, origin: fixture.origin, audience: fixture.audience,
            transport: ApprovalInteropTransport(fixture: fixture), now: Date.init, nonce: { Data(UUID().uuidString.utf8.prefix(32)) })
        session = ApprovalInteropSecrets(root.appendingPathComponent(name + "-session"))
        bootstrap = ApprovalInteropSecrets(root.appendingPathComponent(name + "-bootstrap"))
        intents = ApprovalInteropSecrets(root.appendingPathComponent(name + "-approval"))
        checkpoint = ApprovalInteropSecrets(root.appendingPathComponent(name + "-checkpoint"))
        manualSecrets = ApprovalInteropSecrets(root.appendingPathComponent(name + "-manual"))
        manualTrust = TrustStore(owner: identity.id)
    }
    func sessionStore() -> KeychainAccountSessionStorage { .init(store: session, remove: { try session.clear() }) }
    func intentStore() -> KeychainAccountGroupApprovalIntentStorage { .init(store: intents) }
    func seed() async throws {
        let tokens = AccountSessionTokens(identity: .init(accountID: UUID(uuidString: account)!, sessionID: sessionID,
            deviceID: identity.id.rawValue, audience: binding.audience), accessToken: token,
            refreshToken: Data(repeating: 7, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: ""),
            accessExpiresAt: expiry, refreshExpiresAt: expiry.addingTimeInterval(3600))
        try await sessionStore().save(AccountStoredSession(binding: binding, tokens: tokens))
    }
    func controller() -> AccountSessionController {
        .init(service: client, storage: sessionStore(), binding: binding,
            groupVerifier: .init(storage: KeychainAccountGroupCheckpointStorage(store: checkpoint)),
            firstDeviceEnrollment: .init(identity: identity, intentStorage: KeychainAccountGroupBootstrapIntentStorage(store: bootstrap)),
            deviceApproval: .init(identity: identity, intentStorage: intentStore()), now: { clock.now() })
    }
}

/// Actual disk round-trips, separate namespaces, no OS Keychain or personal store.
private final class ApprovalInteropSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock(); private let url: URL; private var writeCount = 0
    var writes: Int { lock.withLock { writeCount } }
    init(_ url: URL) { self.url = url }
    private func read() throws -> [String:Data] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try PropertyListDecoder().decode([String:Data].self, from: Data(contentsOf: url))
    }
    func data(for account: String, policy: KeychainPolicy) throws -> Data? { try lock.withLock { try read()[policy.service + ":" + account] } }
    func store(_ data: Data, for account: String, policy: KeychainPolicy) throws {
        try lock.withLock {
            var values = try read(); values[policy.service + ":" + account] = data
            try PropertyListEncoder().encode(values).write(to: url, options: .atomic); writeCount += 1
        }
    }
    func clear() throws { try lock.withLock { if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } } }
}

private struct ApprovalInteropTransport: AccountServiceTransport {
    let fixture: ApprovalInteropHTTP
    func send(_ request: URLRequest) async throws -> (Data,HTTPURLResponse) {
        let allowed = ["/v1/account/session/status","/v1/account/group/discover","/v1/account/group/bootstrap","/v1/account/group/events"] +
            ["create","get","list","propose","countersign","commit","cancel","reject"].map { "/v1/account/group/join/" + $0 }
        guard let url = request.url, url.scheme == fixture.origin.scheme, url.host == fixture.origin.host,
            url.port == nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, allowed.contains(url.path)
        else { throw AccountServiceError.transport }
        var mapped = request; mapped.url = fixture.loopback.appendingPathComponent(url.path)
        return try await LiveAccountServiceTransport().send(mapped)
    }
}
