import CryptoKit
import Foundation
import Security

public enum AccountInvitationLinkError: Error, Equatable, Sendable {
    case invalidLink
    case randomUnavailable
}

/// A request capability, never a pairing grant or a service URL.
/// Keep the value out of logs and persist it only in scoped secure storage.
public struct AccountInvitationLink: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let token: String

    public init(token: String) throws {
        guard token.utf8.count == 43,
              token.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              let bytes = Self.decode(token), bytes.count == 32,
              Self.encode(bytes) == token else { throw AccountInvitationLinkError.invalidLink }
        self.token = token
    }

    public init(sharedText: String) throws {
        guard sharedText.utf8.count <= 256 else { throw AccountInvitationLinkError.invalidLink }
        let text = sharedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "dropmesh://connect?v=1&token="
        // Exact grammar avoids percent-decoding aliases, duplicate parameters,
        // userinfo, extra scopes and attacker-controlled service origins.
        guard text.hasPrefix(prefix) else { throw AccountInvitationLinkError.invalidLink }
        try self.init(token: String(text.dropFirst(prefix.count)))
    }

    public static func generate() throws -> Self {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
        else { throw AccountInvitationLinkError.randomUnavailable }
        return try Self(token: encode(Data(bytes)))
    }
    public var shareURL: URL { URL(string: "dropmesh://connect?v=1&token=" + token)! }
    public var tokenHash: Data { Data(SHA256.hash(data: Self.decode(token)!)) }
    public var description: String { "AccountInvitationLink(<redacted>)" }
    public var debugDescription: String { description }

    private static func decode(_ token: String) -> Data? {
        Data(base64Encoded: token.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + "=")
    }

    private static func encode(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
