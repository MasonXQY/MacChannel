import Foundation

public struct AccountSessionBinding: Equatable, Sendable {
    public let deviceID: UUID
    public let audience: String
    public let origin: URL

    public init(deviceID: UUID, audience: String, origin: URL) throws {
        guard AccountServiceClient.validOrigin(origin), AccountServiceClient.validAudience(audience),
              var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)
        else { throw AccountSessionControllerError.unavailable }
        components.scheme = "https"
        components.host = components.host?.lowercased()
        components.port = nil
        components.path = ""
        guard let normalized = components.url else { throw AccountSessionControllerError.unavailable }
        self.deviceID = deviceID
        self.audience = audience
        self.origin = normalized
    }
}

public struct AccountStoredSession: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public enum Phase: String, Sendable { case active, refreshPending }
    public let version: Int
    public let binding: AccountSessionBinding
    public let tokens: AccountSessionTokens
    public let phase: Phase

    public init(binding: AccountSessionBinding, tokens: AccountSessionTokens, phase: Phase = .active) throws {
        let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        guard tokens.identity.deviceID == binding.deviceID, tokens.identity.audience == binding.audience,
              tokens.identity.accountID != zero, tokens.identity.sessionID != zero,
              AccountServiceClient.validToken(tokens.accessToken), AccountServiceClient.validToken(tokens.refreshToken),
              tokens.accessToken != tokens.refreshToken,
              let access = AccountServiceClient.validEpochMilliseconds(tokens.accessExpiresAt),
              let refresh = AccountServiceClient.validEpochMilliseconds(tokens.refreshExpiresAt), access <= refresh
        else { throw AccountSessionControllerError.secureStorage }
        version = 1
        self.binding = binding
        self.tokens = tokens
        self.phase = phase
    }

    public var description: String { "AccountStoredSession(<redacted>)" }
    public var debugDescription: String { description }
}

public protocol AccountSessionStorage: Sendable {
    func load() async throws -> AccountStoredSession?
    func save(_ record: AccountStoredSession) async throws
    func remove() async throws
}

/// Owns a dedicated Keychain namespace. No device identity policy/store can be injected publicly.
public actor KeychainAccountSessionStorage: AccountSessionStorage {
    static let policy = KeychainPolicy(service: "com.zensystech.dropmesh.account-session", accessGroup: nil,
                                       accessibility: .afterFirstUnlockThisDeviceOnly, synchronizable: false)
    static let account = "session-v1"
    private let store: any SecretStore & Sendable
    private let removeRecord: @Sendable () throws -> Void

    public init() {
        let dedicated = KeychainStore(policy: Self.policy)
        store = dedicated
        removeRecord = { try dedicated.removeAll() }
    }

    init(store: any SecretStore & Sendable, remove: @escaping @Sendable () throws -> Void) {
        self.store = store
        removeRecord = remove
    }

    public func load() async throws -> AccountStoredSession? {
        do {
            guard let data = try store.data(for: Self.account, policy: Self.policy) else { return nil }
            return try Self.decode(data)
        } catch { throw AccountSessionControllerError.secureStorage }
    }

    public func save(_ record: AccountStoredSession) async throws {
        do {
            // A failed read/decode must never turn into an overwrite of protected data.
            if let previous = try store.data(for: Self.account, policy: Self.policy) { _ = try Self.decode(previous) }
            let data = try JSONEncoder().encode(RecordDTO(record))
            guard data.count <= 16_384 else { throw AccountSessionControllerError.secureStorage }
            try store.store(data, for: Self.account, policy: Self.policy)
        } catch { throw AccountSessionControllerError.secureStorage }
    }

    public func remove() async throws {
        do { try removeRecord() } catch { throw AccountSessionControllerError.secureStorage }
    }

    private static func decode(_ data: Data) throws -> AccountStoredSession {
        guard data.count <= 16_384 else { throw AccountSessionControllerError.secureStorage }
        return try JSONDecoder().decode(RecordDTO.self, from: data).record()
    }
}

private struct RecordDTO: Codable {
    let version: Int
    let phase: String
    let deviceID: UUID
    let audience: String
    let origin: URL
    let accountID: UUID
    let sessionID: UUID
    let accessToken: String
    let refreshToken: String
    let accessExpiresAt: Int64
    let refreshExpiresAt: Int64

    init(_ record: AccountStoredSession) throws {
        guard let access = AccountServiceClient.validEpochMilliseconds(record.tokens.accessExpiresAt),
              let refresh = AccountServiceClient.validEpochMilliseconds(record.tokens.refreshExpiresAt)
        else { throw AccountSessionControllerError.secureStorage }
        version = record.version; phase = record.phase.rawValue
        deviceID = record.binding.deviceID; audience = record.binding.audience; origin = record.binding.origin
        accountID = record.tokens.identity.accountID; sessionID = record.tokens.identity.sessionID
        accessToken = record.tokens.accessToken; refreshToken = record.tokens.refreshToken
        accessExpiresAt = access; refreshExpiresAt = refresh
    }

    func record() throws -> AccountStoredSession {
        let access = Date(timeIntervalSince1970: Double(accessExpiresAt) / 1_000)
        let refresh = Date(timeIntervalSince1970: Double(refreshExpiresAt) / 1_000)
        guard version == 1, let phase = AccountStoredSession.Phase(rawValue: phase),
              AccountServiceClient.validEpochMilliseconds(access) == accessExpiresAt,
              AccountServiceClient.validEpochMilliseconds(refresh) == refreshExpiresAt
        else { throw AccountSessionControllerError.secureStorage }
        let binding = try AccountSessionBinding(deviceID: deviceID, audience: audience, origin: origin)
        return try AccountStoredSession(binding: binding, tokens: .init(
            identity: .init(accountID: accountID, sessionID: sessionID, deviceID: deviceID, audience: audience),
            accessToken: accessToken, refreshToken: refreshToken, accessExpiresAt: access, refreshExpiresAt: refresh), phase: phase)
    }
}
