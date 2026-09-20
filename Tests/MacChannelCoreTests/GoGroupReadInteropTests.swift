import Foundation
import XCTest
@testable import MacChannelCore

/// Real Swift request signatures, production page parsing/collection and native
/// checkpoint verification against the real Go handler. Session storage/auth and
/// Apple are synthetic in the Go fixture; no OS Keychain or phone is exercised.
final class GoGroupReadInteropTests: XCTestCase, @unchecked Sendable {
    func testRealGoPagesArePinnedAcceptedAndRollbackProtected() async throws {
        let fixture = try GroupReadInteropFixture.fromEnvironment()
        let identity = try DeviceIdentity.ephemeral()
        let trustedOrigin = URL(string: "https://account-group-read-fixture.invalid")!
        let transport = GroupReadLoopbackTransport(origin: fixture.loopback)
        let client = try AccountServiceClient(identity: identity, origin: trustedOrigin,
            audience: fixture.audience, transport: transport,
            now: Date.init, nonce: { Data(UUID().uuidString.utf8.prefix(32)) })

        let history = try await client.groupHistory(accessToken: fixture.token, groupID: fixture.groupID)
        XCTAssertEqual(history.count, 19)
        XCTAssertEqual(history.map(\.sequence), (1...19).map(UInt64.init))
        XCTAssertEqual(try XCTUnwrap(history.last).digest(), fixture.headHash)
        XCTAssertEqual(history[0], fixture.anchor)
        XCTAssertEqual(try fixture.anchor.digest(), fixture.anchorHash)
        XCTAssertEqual(transport.requests(), [
            GroupReadRequest(afterSequence: "0", expectedHeadHash: "", token: fixture.token,
                audience: fixture.audience, groupID: fixture.groupID),
            GroupReadRequest(afterSequence: "16", expectedHeadHash: fixture.headHash.base64EncodedString(),
                token: fixture.token, audience: fixture.audience, groupID: fixture.groupID),
        ])

        let binding = try AccountSessionBinding(deviceID: identity.id.rawValue,
            audience: fixture.audience, origin: trustedOrigin)
        let secret = GroupReadMemorySecretStore()
        let firstStorage = KeychainAccountGroupCheckpointStorage(store: secret)
        let firstVerifier = AccountGroupHistoryVerifier(storage: firstStorage)

        // Authority comes from the separately supplied public fixture anchor and
        // hash, not from automatically pinning the server-returned first event.
        let confirmed = try await firstVerifier.confirm(anchor: fixture.anchor,
            expectedAccountID: fixture.accountID, expectedGroupID: fixture.groupID,
            expectedGeneration: 1, expectedAnchorHash: fixture.anchorHash, binding: binding)
        assertOnlyFixtureOwner(confirmed, fixture: fixture)
        XCTAssertEqual(confirmed.sequence, 1)

        let accepted = try await firstVerifier.accept(history: history, binding: binding,
            accountID: fixture.accountID, groupID: fixture.groupID)
        XCTAssertEqual(accepted.sequence, 19)
        XCTAssertEqual(accepted.headHash, fixture.headHash)
        assertOnlyFixtureOwner(accepted, fixture: fixture)
        let persisted = try await firstStorage.load(binding: binding,
            accountID: fixture.accountID, groupID: fixture.groupID)
        XCTAssertEqual(persisted?.sequence, 19)
        XCTAssertEqual(persisted?.headHash, fixture.headHash)

        // A new verifier and storage actor prove the high-water mark survives
        // replacement owners of the same injected persistence, without Keychain.
        let restartedStorage = KeychainAccountGroupCheckpointStorage(store: secret)
        let restartedVerifier = AccountGroupHistoryVerifier(storage: restartedStorage)
        await expectGroupCheckpointFailure(.invalidHistory) {
            try await restartedVerifier.accept(history: Array(history.prefix(16)), binding: binding,
                accountID: fixture.accountID, groupID: fixture.groupID)
        }
        let restored = try await restartedVerifier.accept(history: history, binding: binding,
            accountID: fixture.accountID, groupID: fixture.groupID)
        XCTAssertEqual(restored.sequence, 19)
        XCTAssertEqual(restored.headHash, fixture.headHash)
        assertOnlyFixtureOwner(restored, fixture: fixture)
    }

    private func assertOnlyFixtureOwner(_ snapshot: AccountGroupSnapshot,
                                        fixture: GroupReadInteropFixture,
                                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(snapshot.accountID, fixture.accountID, file: file, line: line)
        XCTAssertEqual(snapshot.groupID, fixture.groupID, file: file, line: line)
        XCTAssertEqual(snapshot.generation, 1, file: file, line: line)
        XCTAssertEqual(snapshot.members.map(\.deviceID), [fixture.anchor.actorDeviceID], file: file, line: line)
        XCTAssertEqual(snapshot.members.map(\.publicKey), [fixture.anchor.actorPublicKey], file: file, line: line)
    }
}

private struct GroupReadInteropFixture {
    let audience = "com.zensystech.dropmesh"
    let loopback: URL
    let token: String
    let accountID: String
    let groupID: String
    let anchor: AccountGroupEvent
    let anchorHash: Data
    let headHash: Data

    static func fromEnvironment() throws -> Self {
        let environment = ProcessInfo.processInfo.environment
        let names = [
            "DROPMESH_GO_GROUP_READ_TEST_URL", "DROPMESH_GO_GROUP_READ_TEST_TOKEN",
            "DROPMESH_GO_GROUP_READ_TEST_ACCOUNT", "DROPMESH_GO_GROUP_READ_TEST_GROUP",
            "DROPMESH_GO_GROUP_READ_TEST_ANCHOR", "DROPMESH_GO_GROUP_READ_TEST_ANCHOR_HASH",
            "DROPMESH_GO_GROUP_READ_TEST_HEAD_HASH",
        ]
        guard names.allSatisfy({ environment[$0] != nil }) else {
            throw XCTSkip("Requires isolated Go group-read integration launcher")
        }
        guard let rawURL = environment[names[0]], rawURL.utf8.count <= 128,
              let loopback = URL(string: rawURL), loopback.scheme == "http",
              loopback.host == "127.0.0.1", loopback.port != nil,
              let token = environment[names[1]], token.utf8.count == 43,
              let accountID = environment[names[2]], canonicalUUID(accountID),
              let groupID = environment[names[3]], canonicalUUID(groupID),
              let rawAnchor = environment[names[4]], rawAnchor.utf8.count <= 12_000,
              let anchorJSON = canonicalBase64(rawAnchor, maximum: 8_192),
              let anchorWire = try? AccountGroupWireEvent.decodeJSON(anchorJSON),
              let anchor = try? AccountGroupEvent(wire: anchorWire),
              let rawAnchorHash = environment[names[5]],
              let anchorHash = canonicalBase64(rawAnchorHash, maximum: 32), anchorHash.count == 32,
              let rawHeadHash = environment[names[6]],
              let headHash = canonicalBase64(rawHeadHash, maximum: 32), headHash.count == 32 else {
            throw AccountServiceError.invalidConfiguration
        }
        return Self(loopback: loopback, token: token, accountID: accountID, groupID: groupID,
            anchor: anchor, anchorHash: anchorHash, headHash: headHash)
    }

    private static func canonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    private static func canonicalBase64(_ value: String, maximum: Int) -> Data? {
        guard value.utf8.count <= ((maximum + 2) / 3) * 4,
              let data = Data(base64Encoded: value), data.count <= maximum,
              data.base64EncodedString() == value else { return nil }
        return data
    }
}

private final class GroupReadMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: Data] = [:]

    func data(for account: String, policy: KeychainPolicy) throws -> Data? {
        lock.withLock { records[account] }
    }

    func store(_ data: Data, for account: String, policy: KeychainPolicy) throws {
        lock.withLock { records[account] = data }
    }
}

/// Test-only HTTP rewrite; the shipping client still validates a trusted HTTPS origin.
private struct GroupReadRequest: Equatable {
    let afterSequence: String
    let expectedHeadHash: String
    let token: String
    let audience: String
    let groupID: String
}

private final class GroupReadLoopbackTransport: AccountServiceTransport, @unchecked Sendable {
    let origin: URL
    private let lock = NSLock()
    private var observed: [GroupReadRequest] = []

    init(origin: URL) { self.origin = origin }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url?.path == "/v1/account/group/events" {
            guard let body = request.httpBody,
                  let envelope = try? JSONDecoder().decode(RendezvousSignedEnvelope.self, from: body),
                  let fields = try? JSONDecoder().decode([String: String].self, from: envelope.payload),
                  Set(fields.keys) == Set(["purpose", "audience", "accessToken", "groupID",
                    "afterSequence", "expectedHeadHash"]),
                  fields["purpose"] == "dropmesh.account.group.events.v1",
                  let after = fields["afterSequence"], let head = fields["expectedHeadHash"],
                  let token = fields["accessToken"], let audience = fields["audience"],
                  let group = fields["groupID"] else { throw AccountServiceError.transport }
            lock.withLock {
                observed.append(GroupReadRequest(afterSequence: after, expectedHeadHash: head,
                    token: token, audience: audience, groupID: group))
            }
        }
        var mapped = request
        mapped.url = origin.appendingPathComponent(try XCTUnwrap(request.url).path)
        return try await LiveAccountServiceTransport().send(mapped)
    }

    func requests() -> [GroupReadRequest] { lock.withLock { observed } }
}

private func expectGroupCheckpointFailure<T>(_ expected: AccountGroupCheckpointError,
                                             file: StaticString = #filePath, line: UInt = #line,
                                             _ action: () async throws -> T) async {
    do {
        _ = try await action()
        XCTFail("Expected checkpoint rejection", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? AccountGroupCheckpointError, expected, file: file, line: line)
    }
}
