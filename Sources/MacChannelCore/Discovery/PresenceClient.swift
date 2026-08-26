import Foundation

public enum RendezvousPresenceEvent: Equatable, Sendable {
    case availability(device: DeviceID, isOnline: Bool)
}

public enum AuthenticatedPresenceError: Error, Equatable, Sendable {
    case insecureOrigin
    case invalidChallenge
    case invalidFrame
    case frameTooLarge
    case authenticationRejected
    case transport(String)
}

/// Narrow transport seam for URLSessionWebSocketTask and deterministic tests.
public protocol PresenceWebSocket: Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close() async
}

/// Production `/v1/ws` transport. The session layer supplies the required
/// subprotocol and performs the signed challenge exchange before any event is
/// accepted by `PresenceClient`.
public final class URLSessionPresenceWebSocket: PresenceWebSocket, @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    public init(origin: URL) throws {
        guard origin.scheme?.lowercased() == "wss", origin.host != nil else {
            throw AuthenticatedPresenceError.insecureOrigin
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
        task = session.webSocketTask(with: origin, protocols: [AuthenticatedPresenceSession.subprotocol])
        task.resume()
    }

    public func send(_ data: Data) async throws {
        try await task.send(.data(data))
    }

    public func receive() async throws -> Data {
        switch try await task.receive() {
        case let .data(data): data
        case let .string(text): Data(text.utf8)
        @unknown default: throw AuthenticatedPresenceError.transport("unsupported_message")
        }
    }

    public func close() async {
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }
}

public actor PresenceClient {
    public static let heartbeatInterval: TimeInterval = 20

    private let directory: DeviceDirectory
    private let heartbeatInterval: TimeInterval
    private var onlineDevices: Set<DeviceID> = []
    private var heartbeatTask: Task<Void, Never>?

    public init(directory: DeviceDirectory, heartbeatInterval: TimeInterval = PresenceClient.heartbeatInterval) {
        self.directory = directory
        self.heartbeatInterval = heartbeatInterval
    }

    deinit { heartbeatTask?.cancel() }

    func receiveAuthenticated(_ event: RendezvousPresenceEvent) async {
        switch event {
        case let .availability(device, isOnline):
            if isOnline { onlineDevices.insert(device) } else { onlineDevices.remove(device) }
            await directory.apply(.internet(device, online: isOnline))
        }
    }

    func startHeartbeats() {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self.heartbeatInterval))
                guard !Task.isCancelled else { return }
                await self.renewOnlinePresence()
            }
        }
    }

    func stopHeartbeats() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    func disconnect() async {
        stopHeartbeats()
        let previouslyOnline = onlineDevices
        onlineDevices = []
        for device in previouslyOnline {
            await directory.apply(.internet(device, online: false))
        }
    }

    func renewOnlinePresence() async {
        for device in onlineDevices {
            await directory.apply(.internet(device, online: true))
        }
    }
}

/// Authenticates exactly as Task 4's `/v1/ws` endpoint expects: a server
/// challenge followed by an envelope whose P-256 signature covers the canonical
/// nonce, identity key, fixed websocket payload, and millisecond timestamp.
public actor AuthenticatedPresenceSession {
    public static let subprotocol = "macchannel.auth.v1"
    public static let authenticationPayload = Data("{\"type\":\"websocket-auth-v1\"}".utf8)
    public static let maximumFrameBytes = 64 * 1024

    private let identity: DeviceIdentity
    private let origin: URL
    private let socket: any PresenceWebSocket
    private let client: PresenceClient
    private let trustRepository: TrustRepository?
    private var running = false

    public init(identity: DeviceIdentity, origin: URL, socket: any PresenceWebSocket, client: PresenceClient, trustRepository: TrustRepository? = nil) throws {
        guard origin.scheme?.lowercased() == "wss", origin.host != nil else { throw AuthenticatedPresenceError.insecureOrigin }
        self.identity = identity; self.origin = origin; self.socket = socket; self.client = client; self.trustRepository = trustRepository
    }

    public func connect() async throws {
        await client.disconnect()
        let challenge = try decodeChallenge(try await receiveFrame())
        let auth = try makeAuthentication(challenge: challenge)
        try await socket.send(auth)
        let confirmation = try decodeFrame(try await receiveFrame())
        guard confirmation.type == "auth-ok", confirmation.deviceID == identity.id.rawValue.uuidString.lowercased() else {
            throw AuthenticatedPresenceError.authenticationRejected
        }
        running = true
        await client.startHeartbeats()
    }

    public func run() async throws {
        guard running else { throw AuthenticatedPresenceError.authenticationRejected }
        do {
            while running {
                let frame = try decodeFrame(try await receiveFrame())
                switch frame.type {
                case "presence":
                    guard let deviceID = frame.deviceID, let availability = frame.availability,
                          let uuid = UUID(uuidString: deviceID), availability == "internet" || availability == "offline"
                    else { throw AuthenticatedPresenceError.invalidFrame }
                    await client.receiveAuthenticated(.availability(device: DeviceID(rawValue: uuid), isOnline: availability == "internet"))
                case "trust-record":
                    guard let trustRepository, let record = frame.record else { throw AuthenticatedPresenceError.invalidFrame }
                    try await trustRepository.ingest(try decodeTrustRecord(record))
                case "signal", "signal-error", "trust-ok", "protocol-error":
                    // ConnectionCoordinator consumes the same authenticated
                    // socket's typed stream in Task 6; these legal frames must
                    // not tear down presence while no consumer is attached yet.
                    continue
                default:
                    throw AuthenticatedPresenceError.invalidFrame
                }
            }
        } catch {
            running = false
            await client.disconnect()
            throw error
        }
    }

    public func stop() async {
        running = false
        await client.disconnect()
        await socket.close()
    }

    private func receiveFrame() async throws -> Data {
        do {
            let data = try await socket.receive()
            guard data.count <= Self.maximumFrameBytes else { throw AuthenticatedPresenceError.frameTooLarge }
            return data
        } catch let error as AuthenticatedPresenceError { throw error }
        catch { throw AuthenticatedPresenceError.transport("receive_failed") }
    }

    private func makeAuthentication(challenge: Challenge) throws -> Data {
        let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
        let publicKey = identity.publicKey.rawRepresentation
        struct Canonical: Encodable {
            let deviceID: String; let nonce: String; let payload: String; let publicKey: String; let epochMilliseconds: Int64
        }
        let canonical = Canonical(deviceID: identity.id.rawValue.uuidString.lowercased(), nonce: challenge.nonce.base64EncodedString(), payload: Self.authenticationPayload.base64EncodedString(), publicKey: publicKey.base64EncodedString(), epochMilliseconds: timestamp)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let signature = try identity.sign(encoder.encode(canonical)).derRepresentation
        let envelope: [String: Any] = [
            "deviceID": identity.id.rawValue.uuidString.lowercased(), "nonce": challenge.nonce.base64EncodedString(),
            "payload": Self.authenticationPayload.base64EncodedString(), "publicKey": publicKey.base64EncodedString(),
            "epochMilliseconds": timestamp, "signature": signature.base64EncodedString(),
        ]
        return try JSONSerialization.data(withJSONObject: ["envelope": envelope], options: [.sortedKeys])
    }

    private struct Challenge { let nonce: Data }
    private struct Frame { let type: String; let deviceID: String?; let availability: String?; let record: [String: Any]? }

    private func decodeChallenge(_ data: Data) throws -> Challenge {
        let object = try strictObject(data, keys: ["type", "nonce", "expiresAt"])
        guard object["type"] as? String == "challenge", let encoded = object["nonce"] as? String,
              let nonce = Data(base64Encoded: encoded), nonce.count == 32, object["expiresAt"] is NSNumber
        else { throw AuthenticatedPresenceError.invalidChallenge }
        return Challenge(nonce: nonce)
    }

    private func decodeFrame(_ data: Data) throws -> Frame {
        let object = try strictObject(data, keys: ["type", "deviceID", "availability", "code", "from", "payload", "record"])
        guard let type = object["type"] as? String else { throw AuthenticatedPresenceError.invalidFrame }
        return Frame(type: type, deviceID: object["deviceID"] as? String, availability: object["availability"] as? String, record: object["record"] as? [String: Any])
    }

    private func strictObject(_ data: Data, keys: Set<String>) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: keys)
        else { throw AuthenticatedPresenceError.invalidFrame }
        return object
    }

    private func decodeTrustRecord(_ object: [String: Any]) throws -> SignedTrustRecord {
        let required: Set<String> = ["action", "epochMilliseconds", "issuer", "issuerPublicKey", "issuerSequence", "subject", "subjectPublicKey", "signature"]
        guard Set(object.keys) == required,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let record = try? JSONDecoder().decode(TrustRecordWire.self, from: data),
              let issuer = UUID(uuidString: record.issuer), let subject = UUID(uuidString: record.subject)
        else { throw AuthenticatedPresenceError.invalidFrame }
        return SignedTrustRecord(issuer: DeviceID(rawValue: issuer), issuerPublicKey: record.issuerPublicKey, subject: DeviceID(rawValue: subject), subjectPublicKey: record.subjectPublicKey, action: record.action, issuerSequence: record.issuerSequence, epochMilliseconds: record.epochMilliseconds, signature: record.signature)
    }

    private struct TrustRecordWire: Decodable {
        let action: TrustAction; let epochMilliseconds: Int64; let issuer: String; let issuerPublicKey: Data; let issuerSequence: UInt64; let subject: String; let subjectPublicKey: Data; let signature: Data
    }
}
