import Foundation

public struct AccountLoginChallenge: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let challengeID: String
    public let nonce: String
    public let expiresAt: Date

    public init(challengeID: String, nonce: String, expiresAt: Date) {
        self.challengeID = challengeID
        self.nonce = nonce
        self.expiresAt = expiresAt
    }

    public var description: String { "AccountLoginChallenge(<redacted>)" }
    public var debugDescription: String { description }
}

public struct AccountSessionIdentity: Equatable, Sendable {
    public let accountID: UUID
    public let sessionID: UUID
    public let deviceID: UUID
    public let audience: String

    public init(accountID: UUID, sessionID: UUID, deviceID: UUID, audience: String) {
        self.accountID = accountID
        self.sessionID = sessionID
        self.deviceID = deviceID
        self.audience = audience
    }
}

public struct AccountSessionTokens: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let identity: AccountSessionIdentity
    public let accessToken: String
    public let refreshToken: String
    public let accessExpiresAt: Date
    public let refreshExpiresAt: Date

    public init(
        identity: AccountSessionIdentity,
        accessToken: String,
        refreshToken: String,
        accessExpiresAt: Date,
        refreshExpiresAt: Date
    ) {
        self.identity = identity
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accessExpiresAt = accessExpiresAt
        self.refreshExpiresAt = refreshExpiresAt
    }

    public var description: String {
        "AccountSessionTokens(identity: \(identity), tokens: <redacted>)"
    }
    public var debugDescription: String { description }
}

public enum AccountServiceError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidRequest
    case invalidResponse
    case authenticationRejected
    case rateLimited
    case unavailable
    case transport
}
