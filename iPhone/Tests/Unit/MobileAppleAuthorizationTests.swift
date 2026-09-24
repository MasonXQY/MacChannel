import AuthenticationServices
import MacChannelCore
import XCTest
@testable import DropMeshTestHost

@MainActor
final class MobileAppleAuthorizationTests: XCTestCase {
    func testRequestUsesExactNonceAndAttemptStateWithoutScopes() throws {
        let attempt = makeAttempt()
        let request = MobileAppleAuthorization.makeRequest(for: attempt)
        XCTAssertEqual(request.nonce, "server-nonce-value")
        XCTAssertEqual(request.state, attempt.id.uuidString)
        XCTAssertTrue(request.requestedScopes?.isEmpty ?? true)
    }

    func testCredentialExtractionRejectsMissingMalformedOrMismatchedValues() throws {
        let attempt = makeAttempt()
        XCTAssertThrowsError(try MobileAppleAuthorization.credential(
            authorizationCode: nil, identityToken: Data("token".utf8), state: attempt.id.uuidString,
            attempt: attempt, now: Date()))
        XCTAssertThrowsError(try MobileAppleAuthorization.credential(
            authorizationCode: Data([0xFF]), identityToken: Data("token".utf8), state: attempt.id.uuidString,
            attempt: attempt, now: Date()))
        XCTAssertThrowsError(try MobileAppleAuthorization.credential(
            authorizationCode: Data("code".utf8), identityToken: Data("token".utf8), state: UUID().uuidString,
            attempt: attempt, now: Date()))
        XCTAssertThrowsError(try MobileAppleAuthorization.credential(
            authorizationCode: Data("code".utf8), identityToken: Data("token".utf8), state: attempt.id.uuidString,
            attempt: makeAttempt(expiry: Date(timeIntervalSince1970: 1)), now: Date(timeIntervalSince1970: 2)))
    }

    func testCredentialDescriptionIsRedacted() throws {
        let credential = try MobileAppleAuthorization.credential(
            authorizationCode: Data("private-code".utf8), identityToken: Data("private-token".utf8),
            state: makeAttempt().id.uuidString, attempt: makeAttempt(), now: Date())
        XCTAssertEqual(credential.description, "MobileAppleCredential(<redacted>)")
        XCTAssertFalse(String(describing: credential).contains("private"))
    }

    func testAdapterRejectsWrongControllerAndCompletesContinuationExactlyOnce() async throws {
        let adapter = MobileAppleAuthorization()
        let expected = NSObject()
        let stale = NSObject()
        let attempt = makeAttempt()
        let task = Task { try await adapter.authorizeForTesting(
            attempt: attempt, controllerIdentity: ObjectIdentifier(expected)) }
        await waitUntilPending(adapter)

        adapter.completeForTesting(controllerIdentity: ObjectIdentifier(stale),
            authorizationCode: Data("wrong".utf8), identityToken: Data("wrong".utf8),
            state: attempt.id.uuidString, now: Date())
        XCTAssertTrue(adapter.hasPendingAuthorizationForTesting)
        XCTAssertEqual(adapter.resumedContinuationCountForTesting, 0)

        adapter.completeForTesting(controllerIdentity: ObjectIdentifier(expected),
            authorizationCode: Data("code".utf8), identityToken: Data("token".utf8),
            state: attempt.id.uuidString, now: Date())
        let credential = try await task.value
        XCTAssertEqual(credential.code, "code")
        XCTAssertEqual(adapter.resumedContinuationCountForTesting, 1)
        adapter.completeForTesting(controllerIdentity: ObjectIdentifier(expected),
            authorizationCode: Data("duplicate".utf8), identityToken: Data("duplicate".utf8),
            state: attempt.id.uuidString, now: Date())
        XCTAssertEqual(adapter.resumedContinuationCountForTesting, 1)
    }

    func testAdapterCancellationCleansUpAndStaleOldCallbackCannotFinishNewAttempt() async throws {
        let adapter = MobileAppleAuthorization()
        let old = NSObject(); let current = NSObject()
        let attempt = makeAttempt()
        let first = Task { try await adapter.authorizeForTesting(
            attempt: attempt, controllerIdentity: ObjectIdentifier(old)) }
        await waitUntilPending(adapter)
        adapter.cancel()
        do { _ = try await first.value; XCTFail("expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(adapter.hasPendingAuthorizationForTesting)

        let second = Task { try await adapter.authorizeForTesting(
            attempt: attempt, controllerIdentity: ObjectIdentifier(current)) }
        await waitUntilPending(adapter)
        adapter.completeForTesting(controllerIdentity: ObjectIdentifier(old),
            authorizationCode: Data("stale".utf8), identityToken: Data("stale".utf8),
            state: attempt.id.uuidString, now: Date())
        XCTAssertTrue(adapter.hasPendingAuthorizationForTesting)
        adapter.completeForTesting(controllerIdentity: ObjectIdentifier(current),
            authorizationCode: Data("new-code".utf8), identityToken: Data("new-token".utf8),
            state: attempt.id.uuidString, now: Date())
        let secondCredential = try await second.value
        XCTAssertEqual(secondCredential.code, "new-code")
        XCTAssertFalse(adapter.hasPendingAuthorizationForTesting)
        XCTAssertEqual(adapter.resumedContinuationCountForTesting, 2)
    }

    private func waitUntilPending(_ adapter: MobileAppleAuthorization) async {
        while !adapter.hasPendingAuthorizationForTesting { await Task.yield() }
    }

    private func makeAttempt(expiry: Date = Date().addingTimeInterval(300)) -> AccountLoginAttempt {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        return AccountLoginAttempt(id: id, challenge: AccountLoginChallenge(
            challengeID: "challenge-id-value", nonce: "server-nonce-value", expiresAt: expiry))
    }
}
