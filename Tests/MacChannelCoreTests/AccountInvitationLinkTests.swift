import Foundation
import XCTest
@testable import MacChannelCore

final class AccountInvitationLinkTests: XCTestCase {
    private let token = String(repeating: "A", count: 43)

    func testExactLinkRoundTrip() throws {
        let link = try AccountInvitationLink(token: token)
        XCTAssertEqual(link.shareURL.absoluteString, "dropmesh://connect?v=1&token=" + token)
        XCTAssertEqual(try AccountInvitationLink(sharedText: link.shareURL.absoluteString), link)
        XCTAssertEqual(try AccountInvitationLink(sharedText: " \n" + link.shareURL.absoluteString + "\n"), link)
        XCTAssertEqual(link.tokenHash.map { String(format: "%02x", $0) }.joined(),
                       "66687aadf862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925")
    }

    func testRejectsAlternateAuthorityAndAmbiguousURLs() throws {
        let valid = "dropmesh://connect?v=1&token=" + token
        let invalid = [
            valid + "&token=" + token, valid + "&origin=https://evil.example", valid + "#fragment",
            valid.replacingOccurrences(of: "?v=1&", with: "?v=2&"),
            valid.replacingOccurrences(of: "connect?", with: "connect/?"),
            valid.replacingOccurrences(of: "connect?", with: "connect:443?"),
            valid.replacingOccurrences(of: "connect?", with: "user@connect?"),
            valid.replacingOccurrences(of: "connect?", with: "connect.evil.example?"),
            valid.replacingOccurrences(of: "dropmesh:", with: "https:"),
            valid.replacingOccurrences(of: "dropmesh:", with: "DROPMESH:"),
            valid.replacingOccurrences(of: "token=", with: "to%6ben="),
            valid.replacingOccurrences(of: "?v=1&token=", with: "?token="),
            valid.replacingOccurrences(of: "connect", with: "connect\n"),
            "Please open " + valid, token, "", String(repeating: " ", count: 2048) + valid,
        ]
        for value in invalid { XCTAssertThrowsError(try AccountInvitationLink(sharedText: value), value) }
    }

    func testRejectsNonCanonicalTokens() {
        let invalid: [String] = ["", String(repeating: "A", count: 42), token + "A", token + "=",
                      String(repeating: "A", count: 42) + "B", token + "\n",
                      "+" + String(token.dropFirst()), "/" + String(token.dropFirst()), "%" + String(token.dropFirst())]
        for value in invalid {
            XCTAssertThrowsError(try AccountInvitationLink(token: value))
        }
    }

    func testGenerationAndDiagnostics() throws {
        var tokens = Set<String>()
        for _ in 0..<64 {
            let link = try AccountInvitationLink.generate()
            XCTAssertEqual(link.token.count, 43)
            XCTAssertEqual(link.tokenHash.count, 32)
            XCTAssertEqual(try AccountInvitationLink(sharedText: link.shareURL.absoluteString), link)
            XCTAssertFalse(String(describing: link).contains(link.token))
            XCTAssertFalse(String(reflecting: link).contains(link.token))
            tokens.insert(link.token)
        }
        XCTAssertEqual(tokens.count, 64)
    }
}
