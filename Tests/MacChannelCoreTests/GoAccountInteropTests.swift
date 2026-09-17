import Foundation
import XCTest
@testable import MacChannelCore

/// Real Swift signatures and Go/PostgreSQL sessions. Apple exchange is synthetic.
final class GoAccountInteropTests: XCTestCase {
    func testLiveControllerPersistsRestoresRotatesAndLogsOut() async throws {
        guard let raw = ProcessInfo.processInfo.environment["DROPMESH_GO_ACCOUNT_TEST_URL"],
              let loopback = URL(string: raw), loopback.scheme == "http",
              loopback.host == "127.0.0.1", loopback.port != nil else {
            throw XCTSkip("Requires isolated Go account integration launcher")
        }
        let identity = try DeviceIdentity.ephemeral()
        let client = try makeClient(identity, loopback: loopback)
        let binding = try AccountSessionBinding(deviceID: identity.id.rawValue,
            audience: "com.zensystech.dropmesh", origin: URL(string: "https://account-fixture.invalid")!)
        // Use the shipping record encoder/decoder, but never touch real Keychain.
        let secret = InteropSessionSecret()
        func makeStorage() -> KeychainAccountSessionStorage {
            KeychainAccountSessionStorage(store: secret, remove: { secret.remove() })
        }
        let storage = makeStorage()
        let controller = AccountSessionController(service: client, storage: storage, binding: binding)
        await controller.restore()
        let empty = await controller.snapshot()
        XCTAssertEqual(empty.phase, .signedOut)
        let attempt = try await controller.beginLogin()
        try await controller.completeLogin(attemptID: attempt.id,
            code: "synthetic-code", identityToken: "synthetic-identity-token")
        let firstRecord = try await storage.load()
        let first = try XCTUnwrap(firstRecord)
        let signedIn = await controller.snapshot()
        XCTAssertEqual(signedIn.phase, .signedIn)
        XCTAssertEqual(signedIn.identity, first.tokens.identity)

        // Replacement owners, not concurrent users of the same persisted record.
        let restored = AccountSessionController(service: client, storage: makeStorage(), binding: binding)
        await restored.restore()
        let restoredState = await restored.snapshot()
        XCTAssertEqual(restoredState.identity, signedIn.identity)
        try await restored.refresh()
        let secondRecord = try await storage.load()
        let second = try XCTUnwrap(secondRecord)
        XCTAssertEqual(second.phase, .active)
        XCTAssertNotEqual(second.tokens.refreshToken, first.tokens.refreshToken)
        XCTAssertEqual(second.tokens.identity.accountID, first.tokens.identity.accountID)
        await rejected { _ = try await client.status(accessToken: first.tokens.accessToken) }

        // Fresh-controller logout must load and revoke persisted credentials.
        let logoutOwner = AccountSessionController(service: client, storage: makeStorage(), binding: binding)
        try await logoutOwner.logout()
        let loggedOut = await logoutOwner.snapshot()
        XCTAssertEqual(loggedOut.phase, .signedOut)
        let removed = try await storage.load()
        XCTAssertNil(removed)
        await rejected { _ = try await client.status(accessToken: second.tokens.accessToken) }
        await rejected { _ = try await client.refresh(refreshToken: second.tokens.refreshToken) }
        let finalOwner = AccountSessionController(service: client, storage: makeStorage(), binding: binding)
        await finalOwner.restore()
        let finalState = await finalOwner.snapshot()
        XCTAssertEqual(finalState.phase, .signedOut)
        XCTAssertNil(finalState.identity)
    }

    func testLiveSignedAccountSessionLifecycle() async throws {
        guard let raw = ProcessInfo.processInfo.environment["DROPMESH_GO_ACCOUNT_TEST_URL"],
              let loopback = URL(string: raw), loopback.scheme == "http",
              loopback.host == "127.0.0.1", loopback.port != nil else {
            throw XCTSkip("Requires isolated Go account integration launcher")
        }
        let identity = try DeviceIdentity.ephemeral()
        let client = try makeClient(identity, loopback: loopback)
        let challenge = try await client.challenge()
        let first = try await client.complete(challengeID: challenge.challengeID,
            code: "synthetic-code", identityToken: "synthetic-identity-token")
        XCTAssertEqual(first.identity.deviceID, identity.id.rawValue)
        let authenticated = try await client.status(accessToken: first.accessToken)
        XCTAssertEqual(authenticated, first.identity)

        let stranger = try makeClient(DeviceIdentity.ephemeral(), loopback: loopback)
        await rejected { _ = try await stranger.refresh(refreshToken: first.refreshToken) }
        // A wrong device must not revoke the legitimate family.
        let stillValid = try await client.status(accessToken: first.accessToken)
        XCTAssertEqual(stillValid, first.identity)
        let second = try await client.refresh(refreshToken: first.refreshToken)
        XCTAssertNotEqual(first.accessToken, second.accessToken)
        XCTAssertNotEqual(first.refreshToken, second.refreshToken)
        XCTAssertEqual(first.identity.accountID, second.identity.accountID)
        await rejected { _ = try await client.status(accessToken: first.accessToken) }
        try await client.logout(accessToken: second.accessToken)
        await rejected { _ = try await client.status(accessToken: second.accessToken) }
        await rejected { _ = try await client.refresh(refreshToken: second.refreshToken) }

        // New login remains usable, but replaying its consumed refresh revokes it.
        let nextChallenge = try await client.challenge()
        let third = try await client.complete(challengeID: nextChallenge.challengeID,
            code: "synthetic-code", identityToken: "synthetic-identity-token")
        XCTAssertEqual(third.identity.accountID, first.identity.accountID)
        await rejected {
            _ = try await client.complete(challengeID: nextChallenge.challengeID,
                code: "synthetic-code", identityToken: "synthetic-identity-token")
        }
        let fourth = try await client.refresh(refreshToken: third.refreshToken)
        await rejected { _ = try await client.refresh(refreshToken: third.refreshToken) }
        await rejected { _ = try await client.status(accessToken: fourth.accessToken) }
    }

    private func makeClient(_ identity: DeviceIdentity, loopback: URL) throws -> AccountServiceClient {
        try AccountServiceClient(identity: identity,
            origin: URL(string: "https://account-fixture.invalid")!,
            audience: "com.zensystech.dropmesh",
            transport: AccountLoopbackTransport(origin: loopback), now: Date.init,
            nonce: { Data(UUID().uuidString.utf8.prefix(32)) })
    }

    private func rejected(_ action: () async throws -> Void) async {
        do { try await action(); XCTFail("Expected authentication rejection") }
        catch { XCTAssertEqual(error as? AccountServiceError, .authenticationRejected) }
    }
}

/// Synthetic byte persistence exercises the actual storage DTO, not OS entitlement behavior.
private final class InteropSessionSecret: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data?
    func data(for account: String, policy: KeychainPolicy) throws -> Data? {
        lock.withLock { bytes }
    }
    func store(_ data: Data, for account: String, policy: KeychainPolicy) throws {
        lock.withLock { bytes = data }
    }
    func remove() { lock.withLock { bytes = nil } }
}

/// Test-only rewrite; shipping initializer still requires trusted HTTPS.
private struct AccountLoopbackTransport: AccountServiceTransport {
    let origin: URL
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var mapped = request
        mapped.url = origin.appendingPathComponent(try XCTUnwrap(request.url).path)
        return try await LiveAccountServiceTransport().send(mapped)
    }
}
