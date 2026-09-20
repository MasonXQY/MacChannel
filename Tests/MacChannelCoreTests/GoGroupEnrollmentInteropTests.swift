import Foundation
import XCTest
@testable import MacChannelCore

/// Synthetic session provisioning and injected persistence; real native controller,
/// signed HTTP, Go envelope verification and PostgreSQL journal acceptance.
final class GoGroupEnrollmentInteropTests: XCTestCase, @unchecked Sendable {
    func testExplicitConsentPersistsExactEventThroughHTTPFailureAndReconstruction() async throws {
        let f = try EnrollmentInteropFixture()
        let identity = try DeviceIdentity.ephemeral()
        let origin = URL(string: "https://account-enrollment-fixture.invalid")!
        let transport = EnrollmentInteropTransport(loopback: f.loopback, origin: origin)
        let client = try AccountServiceClient(identity: identity, origin: origin,
            audience: f.audience, transport: transport,
            now: Date.init, nonce: { Data(UUID().uuidString.utf8.prefix(32)) })
        let binding = try AccountSessionBinding(deviceID: identity.id.rawValue, audience: f.audience, origin: origin)
        let sessionSecret = EnrollmentInteropSecrets(), intentSecret = EnrollmentInteropSecrets()
        let checkpointSecret = EnrollmentInteropSecrets()
        let tokens = AccountSessionTokens(identity: .init(accountID: f.account, sessionID: f.session,
            deviceID: identity.id.rawValue, audience: f.audience), accessToken: f.token,
            refreshToken: Data(repeating: 7, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: ""),
            accessExpiresAt: f.expiry, refreshExpiresAt: f.expiry.addingTimeInterval(3600))
        func sessionStore() -> KeychainAccountSessionStorage {
            KeychainAccountSessionStorage(store: sessionSecret, remove: { sessionSecret.clear() })
        }
        try await sessionStore().save(AccountStoredSession(binding: binding, tokens: tokens))
        func controller() -> AccountSessionController {
            AccountSessionController(service: client, storage: sessionStore(), binding: binding,
                groupVerifier: AccountGroupHistoryVerifier(storage: KeychainAccountGroupCheckpointStorage(store: checkpointSecret)),
                firstDeviceEnrollment: .init(identity: identity,
                    intentStorage: KeychainAccountGroupBootstrapIntentStorage(store: intentSecret)))
        }
        let first = controller()
        await first.restore()
        let initial = try await first.discoverAccountGroup()
        XCTAssertEqual(initial, .absent)
        let ticket = try await first.prepareFirstDeviceJoin()
        let before = try await f.status()
        XCTAssertEqual(before.mutations, 0)
        XCTAssertEqual(before.events, 0)
        XCTAssertTrue(intentSecret.isEmpty)
        XCTAssertTrue(checkpointSecret.isEmpty)

        // The fixture commits the real SQL write, then damages its first HTTP
        // acknowledgment. No membership may be published from that response.
        do {
            _ = try await first.confirmFirstDeviceJoin(attemptID: ticket)
            XCTFail("Malformed bootstrap acknowledgment granted membership")
        } catch { XCTAssertEqual(error as? AccountServiceError, .invalidResponse) }
        XCTAssertTrue(checkpointSecret.isEmpty)
        let storage = KeychainAccountGroupBootstrapIntentStorage(store: intentSecret)
        let saved = try await storage.load(binding: binding, accountID: f.account.uuidString.lowercased())
        let intent = try XCTUnwrap(saved)
        XCTAssertEqual(intent.event.actorPublicKey, identity.publicKey.rawRepresentation)
        let afterFailure = try await f.status()
        XCTAssertEqual(afterFailure.mutations, 1)
        XCTAssertEqual(afterFailure.events, 1, "Acknowledgment must correspond to a durable SQL event")

        for _ in 0..<2 {
            let restarted = controller()
            await restarted.restore()
            let found = try await restarted.discoverAccountGroup()
            guard case let .present(metadata) = found else { return XCTFail("Committed group disappeared after reconstruction") }
            XCTAssertEqual(metadata.anchor, intent.event)
            XCTAssertEqual(metadata.anchorHash, try intent.event.digest())
            let retry = try await restarted.prepareFirstDeviceJoin()
            let snapshot = try await restarted.confirmFirstDeviceJoin(attemptID: retry)
            XCTAssertEqual(snapshot.accountID, f.account.uuidString.lowercased())
            XCTAssertEqual(snapshot.groupID, intent.event.groupID)
            XCTAssertEqual(snapshot.sequence, 1)
            XCTAssertEqual(snapshot.headHash, try intent.event.digest())
            XCTAssertEqual(snapshot.members.map(\.deviceID), [identity.id.rawValue.uuidString.lowercased()])
            XCTAssertEqual(snapshot.members.map(\.publicKey), [identity.publicKey.rawRepresentation])
            let reloaded = try await KeychainAccountGroupBootstrapIntentStorage(store: intentSecret)
                .load(binding: binding, accountID: f.account.uuidString.lowercased())
            XCTAssertEqual(reloaded?.event, intent.event)
        }

        // A correctly signed event from this device for a foreign account passes
        // local proof validation and must be rejected by real HTTP session binding.
        let foreign = try foreignEvent(identity: identity, template: intent.event)
        do {
            try await client.recordGroupBootstrap(accessToken: f.token, event: foreign)
            XCTFail("Foreign-account signed bootstrap accepted")
        } catch { XCTAssertEqual(error as? AccountServiceError, .authenticationRejected) }
        do {
            _ = try await client.discoverGroup(accessToken: f.token, accountID: foreign.accountID)
            XCTFail("Foreign-account discovery accepted")
        } catch { XCTAssertEqual(error as? AccountServiceError, .invalidResponse) }
        let final = try await f.status()
        XCTAssertEqual(final.mutations, 4)
        XCTAssertEqual(final.events, 1)
    }

    private func foreignEvent(identity: DeviceIdentity, template: AccountGroupEvent) throws -> AccountGroupEvent {
        func event(signature: Data) throws -> AccountGroupEvent {
            try AccountGroupEvent(accountID: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
                groupID: template.groupID, generation: 1, sequence: 1, previousHash: Data(), action: "bootstrap",
                actorDeviceID: template.actorDeviceID, actorPublicKey: template.actorPublicKey,
                subjectDeviceID: template.subjectDeviceID, subjectPublicKey: template.subjectPublicKey,
                epochMilliseconds: template.epochMilliseconds, signature: signature)
        }
        let unsigned = try event(signature: Data())
        return try event(signature: identity.sign(unsigned.canonicalPayload()).derRepresentation)
    }
}

private struct EnrollmentInteropFixture {
    let audience = "com.zensystech.dropmesh"
    let loopback: URL
    let account: UUID
    let session: UUID
    let token: String
    let expiry: Date

    init() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["DROPMESH_RUN_NATIVE_GROUP_ENROLLMENT"] == "1" else {
            throw XCTSkip("Requires isolated Go native enrollment launcher")
        }
        guard let raw = env["DROPMESH_ENROLLMENT_URL"], let url = URL(string: raw),
              url.scheme == "http", url.host == "127.0.0.1", let port = url.port, (1...65535).contains(port),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.path.isEmpty,
              let accountRaw = env["DROPMESH_ENROLLMENT_ACCOUNT"], let account = UUID(uuidString: accountRaw),
              account.uuidString.lowercased() == accountRaw,
              let sessionRaw = env["DROPMESH_ENROLLMENT_SESSION"], let session = UUID(uuidString: sessionRaw),
              session.uuidString.lowercased() == sessionRaw,
              let token = env["DROPMESH_ENROLLMENT_TOKEN"], AccountServiceClient.validToken(token),
              let expiryRaw = env["DROPMESH_ENROLLMENT_EXPIRY"], let seconds = Double(expiryRaw), seconds.isFinite,
              seconds > Date().timeIntervalSince1970, seconds < Date().addingTimeInterval(1800).timeIntervalSince1970
        else { throw AccountServiceError.invalidConfiguration }
        loopback = url; self.account = account; self.session = session; self.token = token
        expiry = Date(timeIntervalSince1970: seconds)
    }

    struct Status: Decodable { let mutations: Int; let events: Int }
    func status() async throws -> Status {
        let request = URLRequest(url: loopback.appendingPathComponent("fixture-status"))
        let (data, response) = try await LiveAccountServiceTransport().send(request)
        XCTAssertEqual(response.statusCode, 200)
        return try JSONDecoder().decode(Status.self, from: data)
    }
}

private final class EnrollmentInteropSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: Data] = [:]
    var isEmpty: Bool { lock.withLock { records.isEmpty } }
    func clear() { lock.withLock { records.removeAll() } }
    func data(for account: String, policy: KeychainPolicy) throws -> Data? { lock.withLock { records[account] } }
    func store(_ data: Data, for account: String, policy: KeychainPolicy) throws { lock.withLock { records[account] = data } }
}

/// No production insecure-origin switch: only the validated fixture URL is used.
private struct EnrollmentInteropTransport: AccountServiceTransport {
    let loopback: URL
    let origin: URL
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, url.scheme == origin.scheme, url.host == origin.host,
              url.port == nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              ["/v1/account/session/status", "/v1/account/group/discover", "/v1/account/group/bootstrap",
               "/v1/account/group/events"].contains(url.path) else { throw AccountServiceError.transport }
        var mapped = request
        mapped.url = loopback.appendingPathComponent(url.path)
        return try await LiveAccountServiceTransport().send(mapped)
    }
}
