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

    func testCallbackGateRejectsDuplicateAndStaleDelegates() {
        var gate = MobileAppleCallbackGate()
        XCTAssertTrue(gate.begin())
        XCTAssertFalse(gate.begin())
        XCTAssertTrue(gate.consume())
        XCTAssertFalse(gate.consume())
        XCTAssertTrue(gate.begin())
    }

    private func makeAttempt(expiry: Date = Date().addingTimeInterval(300)) -> AccountLoginAttempt {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        return AccountLoginAttempt(id: id, challenge: AccountLoginChallenge(
            challengeID: "challenge-id-value", nonce: "server-nonce-value", expiresAt: expiry))
    }
}
