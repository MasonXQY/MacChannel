import Foundation

public enum RendezvousTURNClientError: Error, Equatable, Sendable {
    case insecureOrigin
    case authenticationRejected
    case unavailable
    case invalidResponse
    case transport
}

public struct RendezvousTURNCredentials: Equatable, Sendable {
    public let urls: [String]
    public let username: String
    public let credential: String
    public let expiresAt: Date

    public init(
        urls: [String],
        username: String,
        credential: String,
        expiresAt: Date
    ) {
        self.urls = urls
        self.username = username
        self.credential = credential
        self.expiresAt = expiresAt
    }

    public var iceConfiguration: ICEConfiguration {
        let stun = urls.filter { value in
            let scheme = URLComponents(string: value)?.scheme?.lowercased()
            return scheme == "stun" || scheme == "stuns"
        }
        let turn = urls.filter { value in
            let scheme = URLComponents(string: value)?.scheme?.lowercased()
            return scheme == "turn" || scheme == "turns"
        }
        return ICEConfiguration(
            stunURLs: stun,
            turnServers: turn.isEmpty ? [] : [TURNServer(
                urls: turn,
                username: username,
                credential: credential
            )]
        )
    }

    public func isUsable(at date: Date = Date()) -> Bool {
        expiresAt > date && !iceConfiguration.turnServers.isEmpty
    }
}

/// Fetches coturn REST credentials through the same canonical signed-envelope
/// authentication used by pairing HTTP and WebSocket presence.
public struct RendezvousTURNCredentialClient: Sendable {
    private let identity: DeviceIdentity
    private let origin: URL
    private let session: URLSession
    private let now: @Sendable () -> Date

    public init(
        identity: DeviceIdentity,
        origin: URL,
        session: URLSession = .shared
    ) throws {
        try self.init(
            identity: identity,
            origin: origin,
            session: session,
            now: Date.init,
            allowInsecureForTesting: false
        )
    }

    init(
        identity: DeviceIdentity,
        origin: URL,
        session: URLSession,
        now: @escaping @Sendable () -> Date,
        allowInsecureForTesting: Bool
    ) throws {
        let scheme = origin.scheme?.lowercased()
        guard origin.host != nil,
              scheme == "https" || (allowInsecureForTesting && scheme == "http")
        else { throw RendezvousTURNClientError.insecureOrigin }
        self.identity = identity
        self.origin = origin
        self.session = session
        self.now = now
    }

    public func fetch() async throws -> RendezvousTURNCredentials {
        let requestDate = now()
        let payload = Data("{\"type\":\"turn-credentials-v1\"}".utf8)
        var random = SystemRandomNumberGenerator()
        let nonce = Data(
            (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) }
        )
        let epochMilliseconds = Int64(requestDate.timeIntervalSince1970 * 1_000)
        let unsigned = RendezvousSignedEnvelope(
            deviceID: identity.id.rawValue.uuidString.lowercased(),
            nonce: nonce,
            payload: payload,
            publicKey: identity.publicKey.rawRepresentation,
            epochMilliseconds: epochMilliseconds,
            signature: Data()
        )
        let envelope = RendezvousSignedEnvelope(
            deviceID: unsigned.deviceID,
            nonce: nonce,
            payload: payload,
            publicKey: unsigned.publicKey,
            epochMilliseconds: epochMilliseconds,
            signature: try identity.sign(unsigned.canonicalPayload()).derRepresentation
        )
        var components = URLComponents(
            url: origin,
            resolvingAgainstBaseURL: false
        )
        components?.path = "/v1/turn-credentials"
        components?.query = nil
        components?.fragment = nil
        guard let url = components?.url else {
            throw RendezvousTURNClientError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpBody = try JSONEncoder.sorted.encode(envelope)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RendezvousTURNClientError.transport
        }
        guard let http = response as? HTTPURLResponse else {
            throw RendezvousTURNClientError.invalidResponse
        }
        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw RendezvousTURNClientError.authenticationRejected
        case 503:
            throw RendezvousTURNClientError.unavailable
        default:
            throw RendezvousTURNClientError.invalidResponse
        }
        return try decode(data, requestDate: requestDate)
    }

    private func decode(_ data: Data, requestDate: Date) throws -> RendezvousTURNCredentials {
        struct Response: Decodable {
            let urls: [String]
            let username: String
            let credential: String
            let expiresAt: String
        }
        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw RendezvousTURNClientError.invalidResponse
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiry = formatter.date(from: decoded.expiresAt)
            ?? ISO8601DateFormatter().date(from: decoded.expiresAt)
        let schemes = decoded.urls.compactMap {
            URLComponents(string: $0)?.scheme?.lowercased()
        }
        guard decoded.urls.count == schemes.count,
              !decoded.username.isEmpty,
              !decoded.credential.isEmpty,
              let expiry,
              expiry > requestDate,
              expiry.timeIntervalSince(requestDate) <= 600,
              schemes.contains(where: { $0 == "turn" || $0 == "turns" }),
              schemes.allSatisfy({ ["stun", "stuns", "turn", "turns"].contains($0) }),
              let separator = decoded.username.firstIndex(of: ":"),
              let usernameExpiry = Int64(decoded.username[..<separator]),
              usernameExpiry == Int64(expiry.timeIntervalSince1970),
              decoded.username.index(after: separator) < decoded.username.endIndex
        else { throw RendezvousTURNClientError.invalidResponse }
        return RendezvousTURNCredentials(
            urls: decoded.urls,
            username: decoded.username,
            credential: decoded.credential,
            expiresAt: expiry
        )
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
