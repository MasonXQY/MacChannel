import Darwin
import Foundation
import Security

public struct AccountServiceClient: Sendable {
    private let identity: DeviceIdentity
    private let origin: URL
    let audience: String
    private let transport: any AccountServiceTransport
    private let now: @Sendable () -> Date
    private let nonce: @Sendable () throws -> Data

    public init(identity: DeviceIdentity, origin: URL, audience: String) throws {
        try self.init(
            identity: identity,
            origin: origin,
            audience: audience,
            transport: LiveAccountServiceTransport(),
            now: Date.init,
            nonce: Self.secureNonce
        )
    }

    init(
        identity: DeviceIdentity,
        origin: URL,
        audience: String,
        transport: any AccountServiceTransport,
        now: @escaping @Sendable () -> Date,
        nonce: @escaping @Sendable () throws -> Data
    ) throws {
        guard Self.validOrigin(origin), Self.validAudience(audience) else {
            throw AccountServiceError.invalidConfiguration
        }
        self.identity = identity
        self.origin = origin
        self.audience = audience
        self.transport = transport
        self.now = now
        self.nonce = nonce
    }

    public func challenge() async throws -> AccountLoginChallenge {
        let requestDate = try requestDate()
        let data = try await send(
            path: "/v1/account/login/challenge",
            fields: ["purpose": "dropmesh.account.login.challenge.v1", "audience": audience],
            requestDate: requestDate
        )
        let value: ChallengeResponse = try decode(
            data, keys: ["challengeID", "nonce", "expiresAt"])
        guard Self.validToken(value.challengeID), Self.validToken(value.nonce),
            value.challengeID != value.nonce,
            let expiry = Self.date(milliseconds: value.expiresAt), expiry > requestDate
        else { throw AccountServiceError.invalidResponse }
        return AccountLoginChallenge(
            challengeID: value.challengeID, nonce: value.nonce, expiresAt: expiry)
    }

    public func complete(
        challengeID: String,
        code: String,
        identityToken: String
    ) async throws -> AccountSessionTokens {
        guard Self.validToken(challengeID), Self.validCredential(code, maximumBytes: 4_096),
            Self.validCredential(identityToken, maximumBytes: 16_384)
        else { throw AccountServiceError.invalidRequest }
        let requestDate = try requestDate()
        let data = try await send(
            path: "/v1/account/login/complete",
            fields: [
                "purpose": "dropmesh.account.login.complete.v1", "audience": audience,
                "challengeID": challengeID, "code": code, "identityToken": identityToken,
            ],
            requestDate: requestDate
        )
        return try decodeTokens(data, requestDate: requestDate)
    }

    public func status(accessToken: String) async throws -> AccountSessionIdentity {
        guard Self.validToken(accessToken) else { throw AccountServiceError.invalidRequest }
        let requestDate = try requestDate()
        let data = try await send(
            path: "/v1/account/session/status",
            fields: [
                "purpose": "dropmesh.account.session.status.v1", "audience": audience,
                "accessToken": accessToken,
            ],
            requestDate: requestDate
        )
        let response: IdentityResponse = try decode(
            data, keys: ["accountID", "sessionID", "deviceID", "audience"])
        return try validatedIdentity(response)
    }

    public func refresh(refreshToken: String) async throws -> AccountSessionTokens {
        guard Self.validToken(refreshToken) else { throw AccountServiceError.invalidRequest }
        let requestDate = try requestDate()
        let data = try await send(
            path: "/v1/account/session/refresh",
            fields: [
                "purpose": "dropmesh.account.session.refresh.v1", "audience": audience,
                "refreshToken": refreshToken,
            ],
            requestDate: requestDate
        )
        return try decodeTokens(data, requestDate: requestDate)
    }

    public func logout(accessToken: String) async throws {
        guard Self.validToken(accessToken) else { throw AccountServiceError.invalidRequest }
        let requestDate = try requestDate()
        let data = try await send(
            path: "/v1/account/session/logout",
            fields: [
                "purpose": "dropmesh.account.session.logout.v1", "audience": audience,
                "accessToken": accessToken,
            ],
            requestDate: requestDate
        )
        let value: LogoutResponse = try decode(data, keys: ["signedOut"])
        guard value.signedOut else { throw AccountServiceError.invalidResponse }
    }

    func send(
        path: String,
        fields: [String: String],
        requestDate: Date
    ) async throws -> Data {
        let payload: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            payload = try encoder.encode(fields)
        } catch { throw AccountServiceError.invalidRequest }
        guard payload.count <= 24_576 else { throw AccountServiceError.invalidRequest }
        let nonce: Data
        do { nonce = try self.nonce() } catch { throw AccountServiceError.transport }
        guard nonce.count == 32 else { throw AccountServiceError.transport }
        guard let milliseconds = Self.validEpochMilliseconds(requestDate) else {
            throw AccountServiceError.invalidRequest
        }
        let unsigned = RendezvousSignedEnvelope(
            deviceID: identity.id.rawValue.uuidString.lowercased(), nonce: nonce,
            payload: payload, publicKey: identity.publicKey.rawRepresentation,
            epochMilliseconds: milliseconds, signature: Data())
        let envelope: RendezvousSignedEnvelope
        do {
            envelope = RendezvousSignedEnvelope(
                deviceID: unsigned.deviceID, nonce: nonce, payload: payload,
                publicKey: unsigned.publicKey, epochMilliseconds: milliseconds,
                signature: try identity.sign(unsigned.canonicalPayload()).derRepresentation)
        } catch { throw AccountServiceError.invalidRequest }
        let body: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            body = try encoder.encode(envelope)
        } catch { throw AccountServiceError.invalidRequest }
        guard body.count <= 65_536 else { throw AccountServiceError.invalidRequest }
        var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)
        components?.path = path
        components?.query = nil
        components?.fragment = nil
        guard let url = components?.url else { throw AccountServiceError.invalidConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let result: (Data, HTTPURLResponse)
        do { result = try await transport.send(request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as AccountServiceError { throw error }
        catch { throw AccountServiceError.transport }
        if path == "/v1/account/group/events" {
            if result.1.statusCode == 404 { throw AccountServiceError.unavailable }
            if result.1.statusCode == 409 { throw AccountGroupServiceError.changedHead }
        }
        switch result.1.statusCode {
        case 200: break
        case 400: throw AccountServiceError.invalidRequest
        case 401, 403: throw AccountServiceError.authenticationRejected
        case 429: throw AccountServiceError.rateLimited
        case 503: throw AccountServiceError.unavailable
        default: throw AccountServiceError.invalidResponse
        }
        guard result.0.count <= 65_536, Self.validJSONContentType(result.1) else {
            throw AccountServiceError.invalidResponse
        }
        return result.0
    }

    private func decodeTokens(_ data: Data, requestDate: Date) throws -> AccountSessionTokens {
        let keys: Set<String> = [
            "accountID", "sessionID", "deviceID", "audience", "accessToken",
            "refreshToken", "accessExpiresAt", "refreshExpiresAt",
        ]
        let value: TokensResponse = try decode(data, keys: keys)
        let identity = try validatedIdentity(value.identity)
        guard Self.validToken(value.accessToken), Self.validToken(value.refreshToken),
            value.accessToken != value.refreshToken,
            let accessExpiry = Self.date(milliseconds: value.accessExpiresAt),
            let refreshExpiry = Self.date(milliseconds: value.refreshExpiresAt),
            accessExpiry > requestDate, refreshExpiry > requestDate,
            accessExpiry <= refreshExpiry
        else { throw AccountServiceError.invalidResponse }
        return AccountSessionTokens(
            identity: identity, accessToken: value.accessToken,
            refreshToken: value.refreshToken, accessExpiresAt: accessExpiry,
            refreshExpiresAt: refreshExpiry)
    }

    private func validatedIdentity(_ value: IdentityResponse) throws -> AccountSessionIdentity {
        guard let accountID = Self.canonicalUUID(value.accountID), accountID != Self.zeroUUID,
            let sessionID = Self.canonicalUUID(value.sessionID), sessionID != Self.zeroUUID,
            let deviceID = Self.canonicalUUID(value.deviceID),
            deviceID == identity.id.rawValue, value.audience == audience
        else { throw AccountServiceError.invalidResponse }
        return AccountSessionIdentity(
            accountID: accountID, sessionID: sessionID, deviceID: deviceID, audience: audience)
    }

    private func decode<T: Decodable>(_ data: Data, keys: Set<String>) throws -> T {
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                Set(object.keys) == keys
            else { throw AccountServiceError.invalidResponse }
            return try JSONDecoder().decode(T.self, from: data)
        } catch let error as AccountServiceError { throw error }
        catch { throw AccountServiceError.invalidResponse }
    }

    func requestDate() throws -> Date {
        let value = now()
        guard value.timeIntervalSince1970.isFinite, value.timeIntervalSince1970 > 0 else {
            throw AccountServiceError.invalidRequest
        }
        return value
    }

    private static func secureNonce() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AccountServiceError.transport
        }
        return Data(bytes)
    }

    static func validOrigin(_ value: URL) -> Bool {
        guard let components = URLComponents(url: value, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == "https",
            let rawHost = components.host?.lowercased(), !rawHost.isEmpty,
            components.user == nil, components.password == nil,
            components.query == nil, components.fragment == nil,
            components.path.isEmpty || components.path == "/",
            components.port == nil || components.port == 443,
            {
                var host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                while host.hasSuffix(".") { host.removeLast() }
                return host != "localhost" && !host.hasSuffix(".localhost")
                    && host != "127" && !host.hasPrefix("127.")
                    && !host.isEmpty && !host.contains("%")
                    && !Self.isLoopbackIPAddress(host)
            }()
        else { return false }
        return true
    }

    static func validAudience(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 && value.unicodeScalars.allSatisfy {
            !$0.properties.isWhitespace && !CharacterSet.controlCharacters.contains($0)
        }
    }

    private static func validCredential(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes && value.unicodeScalars.allSatisfy {
            !$0.properties.isWhitespace && !CharacterSet.controlCharacters.contains($0)
        }
    }

    static func validToken(_ value: String) -> Bool {
        guard value.utf8.count == 43, value.unicodeScalars.allSatisfy({
            $0.isASCII && !$0.properties.isWhitespace
                && !CharacterSet.controlCharacters.contains($0)
        }) else { return false }
        let standard = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + "="
        guard let bytes = Data(base64Encoded: standard), bytes.count == 32 else { return false }
        return bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "") == value
    }

    private static func validJSONContentType(_ response: HTTPURLResponse) -> Bool {
        guard let raw = response.value(forHTTPHeaderField: "Content-Type") else { return false }
        let parts = raw.lowercased().split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.first == "application/json", parts.count <= 2 else { return false }
        return parts.count == 1 || parts[1] == "charset=utf-8" || parts[1] == "charset=\"utf-8\""
    }

    private static func canonicalUUID(_ value: String) -> UUID? {
        guard value == value.lowercased(), let uuid = UUID(uuidString: value),
            uuid.uuidString.lowercased() == value
        else { return nil }
        return uuid
    }

    private static func date(milliseconds: Double) -> Date? {
        guard let value = Int64(exactly: milliseconds), value > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(value) / 1_000)
    }

    static func validEpochMilliseconds(_ date: Date) -> Int64? {
        let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded(.towardZero)
        guard let value = Int64(exactly: milliseconds), value > 0 else { return nil }
        return value
    }

    private static func isLoopbackIPAddress(_ host: String) -> Bool {
        var ipv4 = in_addr()
        let isIPv4 = host.withCString { inet_aton($0, &ipv4) != 0 }
        if isIPv4 {
            let hostOrder = UInt32(bigEndian: ipv4.s_addr)
            return hostOrder >> 24 == 127
        }

        var ipv6 = [UInt8](repeating: 0, count: 16)
        let isIPv6 = host.withCString { inet_pton(AF_INET6, $0, &ipv6) == 1 }
        guard isIPv6 else { return false }
        let loopback = ipv6.dropLast() == Array(repeating: 0, count: 15) && ipv6[15] == 1
        let mappedIPv4Loopback = ipv6.prefix(10).allSatisfy { $0 == 0 }
            && ipv6[10] == 0xff && ipv6[11] == 0xff && ipv6[12] == 127
        return loopback || mappedIPv4Loopback
    }

    private static let zeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}

private struct ChallengeResponse: Decodable {
    let challengeID: String
    let nonce: String
    let expiresAt: Double
}

private struct IdentityResponse: Decodable {
    let accountID: String
    let sessionID: String
    let deviceID: String
    let audience: String
}

private struct TokensResponse: Decodable {
    let accountID: String
    let sessionID: String
    let deviceID: String
    let audience: String
    let accessToken: String
    let refreshToken: String
    let accessExpiresAt: Double
    let refreshExpiresAt: Double

    var identity: IdentityResponse {
        IdentityResponse(
            accountID: accountID, sessionID: sessionID,
            deviceID: deviceID, audience: audience)
    }
}

private struct LogoutResponse: Decodable { let signedOut: Bool }
