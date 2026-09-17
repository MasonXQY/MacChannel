import Foundation
import XCTest
@testable import MacChannelCore

/// Real Swift signatures and Go/PostgreSQL sessions. Apple exchange is synthetic.
final class GoAccountInteropTests: XCTestCase {
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

/// Test-only rewrite; shipping initializer still requires trusted HTTPS.
private struct AccountLoopbackTransport: AccountServiceTransport {
    let origin: URL
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var mapped = request
        mapped.url = origin.appendingPathComponent(try XCTUnwrap(request.url).path)
        return try await LiveAccountServiceTransport().send(mapped)
    }
}
