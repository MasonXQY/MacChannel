import Darwin
import Foundation

public enum RendezvousTURNClientError: Error, Equatable, Sendable {
    case insecureOrigin
    case authenticationRejected
    case unavailable
    case invalidResponse
    case transport
}

public protocol RendezvousTURNCredentialFetching: Sendable {
    func fetch() async throws -> RendezvousTURNCredentials
}

public protocol ICEConfigurationProviding: Sendable {
    func configuration(for route: ConnectionRoute) async throws -> ICEConfiguration
}

public struct StaticICEConfigurationProvider: ICEConfigurationProviding {
    private let configuration: ICEConfiguration

    public init(_ configuration: ICEConfiguration) {
        self.configuration = configuration
    }

    public func configuration(for route: ConnectionRoute) async throws -> ICEConfiguration {
        _ = route
        return configuration
    }
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
            turnServers: turn.isEmpty
                ? []
                : [
                    TURNServer(
                        urls: turn,
                        username: username,
                        credential: credential
                    )
                ]
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
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder.sorted.encode(envelope)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await BoundedURLSessionRequest(
                maximumBytes: 65_536,
                upstreamDelegate: session.delegate
            ).perform(
                configuration: session.configuration,
                request: request
            )
        } catch let error as RendezvousTURNClientError {
            throw error
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
        guard data.count <= 65_536 else {
            throw RendezvousTURNClientError.invalidResponse
        }
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
        let expiry =
            formatter.date(from: decoded.expiresAt)
            ?? ISO8601DateFormatter().date(from: decoded.expiresAt)
        let schemes = decoded.urls.compactMap { $0.split(separator: ":", maxSplits: 1).first }
            .map { $0.lowercased() }
        guard (1...8).contains(decoded.urls.count),
            Set(decoded.urls).count == decoded.urls.count,
            decoded.urls.allSatisfy(Self.isStrictICEURL),
            !decoded.username.isEmpty,
            decoded.username.utf8.count <= 256,
            decoded.username.unicodeScalars.allSatisfy({
                !$0.properties.isWhitespace && !CharacterSet.controlCharacters.contains($0)
            }),
            !decoded.credential.isEmpty,
            decoded.credential.utf8.count <= 512,
            decoded.credential.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            }),
            decoded.expiresAt.utf8.count <= 64,
            let expiry,
            expiry > requestDate,
            expiry.timeIntervalSince(requestDate) <= 660,
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

    private static func isStrictICEURL(_ value: String) -> Bool {
        guard !value.isEmpty,
            value.utf8.count <= 2_048,
            value.unicodeScalars.allSatisfy({
                $0.isASCII && !$0.properties.isWhitespace
                    && !CharacterSet.controlCharacters.contains($0)
            }),
            let schemeEnd = value.firstIndex(of: ":")
        else { return false }
        let scheme = value[..<schemeEnd].lowercased()
        guard ["stun", "stuns", "turn", "turns"].contains(scheme) else { return false }
        let remainderStart = value.index(after: schemeEnd)
        let remainder = value[remainderStart...]
        guard !remainder.hasPrefix("//") else { return false }
        let pieces = remainder.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard !pieces.isEmpty, pieces.count <= 2, validHostAndPort(pieces[0]) else { return false }
        let query = pieces.count == 2 ? String(pieces[1]) : nil
        switch scheme {
        case "stun", "stuns":
            return query == nil
        case "turn":
            return query == "transport=udp" || query == "transport=tcp"
        case "turns":
            return query == "transport=tcp"
        default:
            return false
        }
    }

    private static func validHostAndPort(_ value: Substring) -> Bool {
        guard !value.isEmpty else { return false }
        let host: Substring
        let portText: Substring
        if value.first == "[" {
            guard let closing = value.firstIndex(of: "]"),
                closing > value.startIndex,
                value.index(after: closing) < value.endIndex,
                value[value.index(after: closing)] == ":"
            else { return false }
            host = value[value.index(after: value.startIndex)..<closing]
            portText = value[value.index(closing, offsetBy: 2)...]
            var address = in6_addr()
            let parsed = String(host).withCString { inet_pton(AF_INET6, $0, &address) }
            guard parsed == 1 else { return false }
        } else {
            guard let separator = value.lastIndex(of: ":"),
                separator > value.startIndex,
                value.index(after: separator) < value.endIndex
            else { return false }
            host = value[..<separator]
            portText = value[value.index(after: separator)...]
            guard !host.contains(":"),
                host.allSatisfy({
                    $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-")
                }),
                host.first != ".",
                host.last != ".",
                host.utf8.count <= 253,
                host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                    (1...63).contains(label.utf8.count)
                        && label.first.map({ $0.isLetter || $0.isNumber }) == true
                        && label.last.map({ $0.isLetter || $0.isNumber }) == true
                })
            else { return false }
        }
        guard let port = UInt16(portText), port > 0 else { return false }
        return true
    }
}

private final class BoundedURLSessionRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable
{
    private let maximumBytes: Int
    private let upstreamDelegate: (any URLSessionDelegate)?
    private let lock = NSLock()
    private var body = Data()
    private var response: URLResponse?
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var finished = false

    init(maximumBytes: Int, upstreamDelegate: (any URLSessionDelegate)?) {
        self.maximumBytes = maximumBytes
        self.upstreamDelegate = upstreamDelegate
    }

    func perform(
        configuration: URLSessionConfiguration,
        request: URLRequest
    ) async throws -> (Data, URLResponse) {
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: delegateQueue
        )
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if response.expectedContentLength > Int64(maximumBytes) {
            finish(.failure(RendezvousTURNClientError.invalidResponse), session: session)
            completionHandler(.cancel)
            return
        }
        lock.lock()
        self.response = response
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let wouldOverflow = data.count > maximumBytes || body.count > maximumBytes - data.count
        if !wouldOverflow { body.append(data) }
        lock.unlock()
        if wouldOverflow {
            dataTask.cancel()
            finish(.failure(RendezvousTURNClientError.invalidResponse), session: session)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if let error {
            finish(.failure(error), session: session)
            return
        }
        lock.lock()
        let response = self.response
        let body = self.body
        lock.unlock()
        guard let response else {
            finish(.failure(RendezvousTURNClientError.invalidResponse), session: session)
            return
        }
        finish(.success((body, response)), session: session)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?)
            ->
            Void
    ) {
        if let upstreamDelegate,
            upstreamDelegate.responds(
                to: #selector(URLSessionDelegate.urlSession(_:didReceive:completionHandler:)))
        {
            upstreamDelegate.urlSession?(
                session,
                didReceive: challenge,
                completionHandler: completionHandler
            )
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?)
            ->
            Void
    ) {
        if let upstream = upstreamDelegate as? any URLSessionTaskDelegate,
            upstream.responds(
                to: #selector(
                    URLSessionTaskDelegate.urlSession(_:task:didReceive:completionHandler:)))
        {
            upstream.urlSession?(
                session,
                task: task,
                didReceive: challenge,
                completionHandler: completionHandler
            )
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    private func finish(
        _ result: Result<(Data, URLResponse), Error>,
        session: URLSession
    ) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        session.invalidateAndCancel()
        continuation?.resume(with: result)
    }
}

extension RendezvousTURNCredentialClient: RendezvousTURNCredentialFetching {}

/// Resolves public STUN configuration locally and obtains authenticated ICE
/// endpoints when a public route needs them. TURN secrets are exposed only to
/// relay attempts, remain in memory, and concurrent refreshes are coalesced.
public actor RefreshingICEConfigurationProvider: ICEConfigurationProviding {
    private let base: ICEConfiguration
    private let fetcher: any RendezvousTURNCredentialFetching
    private let now: @Sendable () -> Date
    private let minimumRemainingLifetime: TimeInterval
    private var cached: RendezvousTURNCredentials?
    private var refreshTask: Task<RendezvousTURNCredentials, Error>?
    private var refreshGeneration = 0
    private var refreshWaiters: Set<UUID> = []

    public init(
        base: ICEConfiguration,
        fetcher: any RendezvousTURNCredentialFetching,
        now: @escaping @Sendable () -> Date = Date.init,
        minimumRemainingLifetime: TimeInterval = 30
    ) {
        self.base = ICEConfiguration(stunURLs: base.stunURLs, turnServers: [])
        self.fetcher = fetcher
        self.now = now
        self.minimumRemainingLifetime = max(0, minimumRemainingLifetime)
    }

    public func configuration(for route: ConnectionRoute) async throws -> ICEConfiguration {
        try Task.checkCancellation()
        if route == .lan || (route == .directInternet && !base.stunURLs.isEmpty) {
            return base
        }
        let requestDate = now()
        if let cached,
            cached.isUsable(at: requestDate.addingTimeInterval(minimumRemainingLifetime))
        {
            return combined(with: cached, for: route)
        }
        let task: Task<RendezvousTURNCredentials, Error>
        let generation: Int
        let waiter = UUID()
        if let refreshTask {
            task = refreshTask
            generation = refreshGeneration
            refreshWaiters.insert(waiter)
        } else {
            let fetcher = self.fetcher
            task = Task { try await fetcher.fetch() }
            refreshGeneration += 1
            generation = refreshGeneration
            refreshTask = task
            refreshWaiters = [waiter]
        }
        do {
            let credentials = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                Task { await self.cancel(waiter: waiter, generation: generation) }
            }
            try Task.checkCancellation()
            guard
                credentials.isUsable(
                    at: now().addingTimeInterval(minimumRemainingLifetime)
                )
            else {
                finish(waiter: waiter, generation: generation)
                throw RendezvousTURNClientError.invalidResponse
            }
            cached = credentials
            finish(waiter: waiter, generation: generation)
            return combined(with: credentials, for: route)
        } catch {
            finish(waiter: waiter, generation: generation)
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private func cancel(waiter: UUID, generation: Int) {
        guard refreshGeneration == generation else { return }
        refreshWaiters.remove(waiter)
        guard refreshWaiters.isEmpty else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(10))
            await self?.cancelRefreshIfUnobserved(generation: generation)
        }
    }

    private func cancelRefreshIfUnobserved(generation: Int) {
        guard refreshGeneration == generation, refreshWaiters.isEmpty else { return }
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func finish(waiter: UUID, generation: Int) {
        guard refreshGeneration == generation else { return }
        refreshWaiters.remove(waiter)
        if refreshWaiters.isEmpty { refreshTask = nil }
    }

    private func combined(
        with credentials: RendezvousTURNCredentials,
        for route: ConnectionRoute
    ) -> ICEConfiguration {
        ICEConfiguration(
            stunURLs: base.stunURLs + credentials.iceConfiguration.stunURLs,
            turnServers: route == .relay ? credentials.iceConfiguration.turnServers : []
        )
    }
}

extension JSONEncoder {
    fileprivate static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
