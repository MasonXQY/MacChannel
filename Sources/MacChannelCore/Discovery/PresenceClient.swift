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

public struct RendezvousSignalFrame: Equatable, Sendable {
    public let from: DeviceID
    public let payload: Data
}

public enum RendezvousTrustResult: Equatable, Sendable { case accepted, rejected }
public struct RendezvousProtocolError: Equatable, Sendable {
    public let code: String
    public let device: DeviceID?

    public init(code: String, device: DeviceID? = nil) {
        self.code = code
        self.device = device
    }
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

    public init(origin: URL, session suppliedSession: URLSession? = nil) throws {
        guard origin.scheme?.lowercased() == "wss", origin.host != nil else {
            throw AuthenticatedPresenceError.insecureOrigin
        }
        if let suppliedSession {
            session = suppliedSession
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            session = URLSession(configuration: configuration)
        }
        task = session.webSocketTask(
            with: origin, protocols: [AuthenticatedPresenceSession.subprotocol])
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

    public init(
        directory: DeviceDirectory,
        heartbeatInterval: TimeInterval = PresenceClient.heartbeatInterval
    ) {
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
    public static let maximumSignalPayloadBytes = 64 * 1024
    public static let maximumFrameBytes = 128 * 1024

    private let identity: DeviceIdentity
    private let origin: URL
    private let socket: any PresenceWebSocket
    private let client: PresenceClient
    private let trustRepository: TrustRepository?
    private var running = false
    private var readerActive = false
    private let presenceStream: AsyncStream<RendezvousPresenceEvent>
    private let signalStream: AsyncStream<RendezvousSignalFrame>
    private let trustResultStream: AsyncStream<RendezvousTrustResult>
    private let protocolErrorStream: AsyncStream<RendezvousProtocolError>
    private let trustRecordStream: AsyncStream<SignedTrustRecord>
    private let presenceContinuation: AsyncStream<RendezvousPresenceEvent>.Continuation
    private let signalContinuation: AsyncStream<RendezvousSignalFrame>.Continuation
    private let trustResultContinuation: AsyncStream<RendezvousTrustResult>.Continuation
    private let protocolErrorContinuation: AsyncStream<RendezvousProtocolError>.Continuation
    private let trustRecordContinuation: AsyncStream<SignedTrustRecord>.Continuation
    private var pendingTrustRecords: [SignedTrustRecord] = []
    private var streamsFinished = false

    public init(
        identity: DeviceIdentity, origin: URL, socket: any PresenceWebSocket,
        client: PresenceClient,
        trustRepository: TrustRepository? = nil
    ) throws {
        try self.init(
            identity: identity,
            origin: origin,
            socket: socket,
            client: client,
            trustRepository: trustRepository,
            allowInsecureForTesting: false
        )
    }

    init(
        identity: DeviceIdentity, origin: URL, socket: any PresenceWebSocket,
        client: PresenceClient,
        trustRepository: TrustRepository? = nil, allowInsecureForTesting: Bool
    ) throws {
        let scheme = origin.scheme?.lowercased()
        guard origin.host != nil,
            scheme == "wss" || (allowInsecureForTesting && scheme == "ws")
        else { throw AuthenticatedPresenceError.insecureOrigin }
        self.identity = identity
        self.origin = origin
        self.socket = socket
        self.client = client
        self.trustRepository = trustRepository
        var presenceContinuation: AsyncStream<RendezvousPresenceEvent>.Continuation!
        presenceStream = AsyncStream(bufferingPolicy: .bufferingNewest(32)) {
            presenceContinuation = $0
        }
        self.presenceContinuation = presenceContinuation
        var signalContinuation: AsyncStream<RendezvousSignalFrame>.Continuation!
        // Bound memory while preserving realistic ICE candidate bursts. A
        // larger burst fails the session instead of silently dropping a route.
        signalStream = AsyncStream(bufferingPolicy: .bufferingOldest(256)) {
            signalContinuation = $0
        }
        self.signalContinuation = signalContinuation
        var trustResultContinuation: AsyncStream<RendezvousTrustResult>.Continuation!
        trustResultStream = AsyncStream(bufferingPolicy: .bufferingNewest(32)) {
            trustResultContinuation = $0
        }
        self.trustResultContinuation = trustResultContinuation
        var protocolErrorContinuation: AsyncStream<RendezvousProtocolError>.Continuation!
        protocolErrorStream = AsyncStream(bufferingPolicy: .bufferingNewest(32)) {
            protocolErrorContinuation = $0
        }
        self.protocolErrorContinuation = protocolErrorContinuation
        var trustRecordContinuation: AsyncStream<SignedTrustRecord>.Continuation!
        trustRecordStream = AsyncStream(bufferingPolicy: .bufferingNewest(32)) {
            trustRecordContinuation = $0
        }
        self.trustRecordContinuation = trustRecordContinuation
    }

    /// Streams belong to this session instance and finish exactly once when it
    /// stops or its sole reader reaches a terminal transport/protocol error.
    public func presenceEvents() -> AsyncStream<RendezvousPresenceEvent> { presenceStream }
    public func signalFrames() -> AsyncStream<RendezvousSignalFrame> { signalStream }
    public func trustResults() -> AsyncStream<RendezvousTrustResult> { trustResultStream }
    public func protocolErrors() -> AsyncStream<RendezvousProtocolError> { protocolErrorStream }
    public func verifiedTrustRecords() -> AsyncStream<SignedTrustRecord> { trustRecordStream }

    /// Sends opaque WebRTC signaling through the already authenticated socket.
    /// This actor remains the only owner and reader of `/v1/ws`.
    public func sendSignal(_ payload: Data, to device: DeviceID) async throws {
        guard running else { throw AuthenticatedPresenceError.authenticationRejected }
        guard !payload.isEmpty, payload.count <= Self.maximumSignalPayloadBytes else {
            throw AuthenticatedPresenceError.frameTooLarge
        }
        let frame: [String: Any] = [
            "type": "signal",
            "to": device.rawValue.uuidString.lowercased(),
            "payload": payload.base64EncodedString(),
        ]
        do {
            try await socket.send(
                JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys]))
        } catch let error as AuthenticatedPresenceError {
            throw error
        } catch {
            throw AuthenticatedPresenceError.transport("send_failed")
        }
    }

    public func sendTrustUpdate(_ records: [SignedTrustRecord]) async throws {
        guard running else { throw AuthenticatedPresenceError.authenticationRejected }
        guard !records.isEmpty, records.count <= 256 else {
            throw AuthenticatedPresenceError.frameTooLarge
        }
        struct TrustUpdate: Encodable {
            let type = "trust-update"
            let trustRecords: [SignedTrustRecord]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let frame = try encoder.encode(TrustUpdate(trustRecords: records))
        guard frame.count <= Self.maximumFrameBytes else {
            throw AuthenticatedPresenceError.frameTooLarge
        }
        do {
            try await socket.send(frame)
        } catch let error as AuthenticatedPresenceError {
            throw error
        } catch {
            throw AuthenticatedPresenceError.transport("send_failed")
        }
    }

    public func connect() async throws {
        await client.disconnect()
        let challenge = try decodeChallenge(try await receiveFrame())
        let trustRecords =
            if let trustRepository {
                await trustRepository.authenticationRecords()
            } else {
                [SignedTrustRecord]()
            }
        let auth = try makeAuthentication(challenge: challenge, trustRecords: trustRecords)
        guard auth.count <= Self.maximumFrameBytes else {
            throw AuthenticatedPresenceError.frameTooLarge
        }
        try await socket.send(auth)
        let confirmation = try decodeFrame(try await receiveFrame())
        guard confirmation.type == "auth-ok",
            confirmation.deviceID == identity.id.rawValue.uuidString.lowercased()
        else {
            throw AuthenticatedPresenceError.authenticationRejected
        }
        running = true
        await client.startHeartbeats()
    }

    public func run() async throws {
        guard running else { throw AuthenticatedPresenceError.authenticationRejected }
        guard !readerActive else {
            throw AuthenticatedPresenceError.transport("reader_already_active")
        }
        readerActive = true
        defer {
            readerActive = false
            if !running { finishStreams() }
        }
        do {
            while running {
                let frame = try decodeFrame(try await receiveFrame())
                switch frame.type {
                case "presence":
                    guard let deviceID = frame.deviceID, let availability = frame.availability,
                        let uuid = UUID(uuidString: deviceID),
                        availability == "internet" || availability == "offline"
                    else { throw AuthenticatedPresenceError.invalidFrame }
                    let event = RendezvousPresenceEvent.availability(
                        device: DeviceID(rawValue: uuid), isOnline: availability == "internet")
                    await client.receiveAuthenticated(event)
                    presenceContinuation.yield(event)
                case "trust-record":
                    guard let trustRepository, let record = frame.record else {
                        throw AuthenticatedPresenceError.invalidFrame
                    }
                    let signedRecord = try decodeTrustRecord(record)
                    try await ingestMembershipCatchUp(
                        signedRecord,
                        into: trustRepository
                    )
                case "signal":
                    guard let from = frame.from, let uuid = UUID(uuidString: from),
                        let payload = frame.payload
                    else { throw AuthenticatedPresenceError.invalidFrame }
                    guard payload.count <= Self.maximumSignalPayloadBytes else {
                        throw AuthenticatedPresenceError.frameTooLarge
                    }
                    switch signalContinuation.yield(
                        RendezvousSignalFrame(from: DeviceID(rawValue: uuid), payload: payload))
                    {
                    case .enqueued:
                        break
                    case .dropped, .terminated:
                        throw AuthenticatedPresenceError.transport("signal_buffer_overflow")
                    @unknown default:
                        throw AuthenticatedPresenceError.transport("signal_buffer_overflow")
                    }
                case "signal-error":
                    guard let code = frame.code else {
                        throw AuthenticatedPresenceError.invalidFrame
                    }
                    let target = frame.to
                        .flatMap(UUID.init(uuidString:))
                        .map(DeviceID.init(rawValue:))
                    protocolErrorContinuation.yield(
                        RendezvousProtocolError(code: code, device: target)
                    )
                case "trust-ok": trustResultContinuation.yield(.accepted)
                case "trust-error": trustResultContinuation.yield(.rejected)
                case "protocol-error":
                    guard let code = frame.code else {
                        throw AuthenticatedPresenceError.invalidFrame
                    }
                    protocolErrorContinuation.yield(RendezvousProtocolError(code: code))
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
        pendingTrustRecords.removeAll()
        finishStreams()
        await client.disconnect()
        await socket.close()
    }

    private func ingestMembershipCatchUp(
        _ record: SignedTrustRecord,
        into repository: TrustRepository
    ) async throws {
        do {
            if try await repository.ingestIfNew(record) {
                trustRecordContinuation.yield(record)
            }
        } catch TrustStoreError.untrustedIssuer {
            guard pendingTrustRecords.count < 256 else {
                throw AuthenticatedPresenceError.frameTooLarge
            }
            if !pendingTrustRecords.contains(where: { $0.signature == record.signature }) {
                pendingTrustRecords.append(record)
            }
            return
        }

        var madeProgress = true
        while madeProgress && !pendingTrustRecords.isEmpty {
            madeProgress = false
            var stillPending: [SignedTrustRecord] = []
            for candidate in pendingTrustRecords {
                do {
                    if try await repository.ingestIfNew(candidate) {
                        trustRecordContinuation.yield(candidate)
                    }
                    madeProgress = true
                } catch TrustStoreError.untrustedIssuer {
                    stillPending.append(candidate)
                }
            }
            pendingTrustRecords = stillPending
        }
    }

    private func finishStreams() {
        guard !streamsFinished else { return }
        streamsFinished = true
        presenceContinuation.finish()
        signalContinuation.finish()
        trustResultContinuation.finish()
        protocolErrorContinuation.finish()
        trustRecordContinuation.finish()
    }

    private func receiveFrame() async throws -> Data {
        do {
            let data = try await socket.receive()
            guard data.count <= Self.maximumFrameBytes else {
                throw AuthenticatedPresenceError.frameTooLarge
            }
            return data
        } catch let error as AuthenticatedPresenceError { throw error } catch {
            throw AuthenticatedPresenceError.transport("receive_failed")
        }
    }

    private func makeAuthentication(
        challenge: Challenge,
        trustRecords: [SignedTrustRecord]
    ) throws -> Data {
        let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
        let publicKey = identity.publicKey.rawRepresentation
        let unsigned = RendezvousSignedEnvelope(
            deviceID: identity.id.rawValue.uuidString.lowercased(),
            nonce: challenge.nonce,
            payload: Self.authenticationPayload,
            publicKey: publicKey,
            epochMilliseconds: timestamp,
            signature: Data()
        )
        let envelope = RendezvousSignedEnvelope(
            deviceID: unsigned.deviceID,
            nonce: unsigned.nonce,
            payload: unsigned.payload,
            publicKey: unsigned.publicKey,
            epochMilliseconds: unsigned.epochMilliseconds,
            signature: try identity.sign(unsigned.canonicalPayload()).derRepresentation
        )
        struct Authentication: Encodable {
            let envelope: RendezvousSignedEnvelope
            let trustRecords: [SignedTrustRecord]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Authentication(envelope: envelope, trustRecords: trustRecords))
    }

    private struct Challenge { let nonce: Data }
    private struct Frame {
        let type: String
        let deviceID: String?
        let availability: String?
        let record: [String: Any]?
        let from: String?
        let to: String?
        let payload: Data?
        let code: String?
    }

    private func decodeChallenge(_ data: Data) throws -> Challenge {
        let object = try strictObject(data, keys: ["type", "nonce", "expiresAt"])
        guard object["type"] as? String == "challenge", let encoded = object["nonce"] as? String,
            let nonce = Data(base64Encoded: encoded), nonce.count == 32,
            object["expiresAt"] is NSNumber
        else { throw AuthenticatedPresenceError.invalidChallenge }
        return Challenge(nonce: nonce)
    }

    private func decodeFrame(_ data: Data) throws -> Frame {
        let object = try strictObject(
            data, keys: ["type", "deviceID", "availability", "code", "from", "to", "payload", "record"])
        guard let type = object["type"] as? String else {
            throw AuthenticatedPresenceError.invalidFrame
        }
        let payload = (object["payload"] as? String).flatMap { Data(base64Encoded: $0) }
        return Frame(
            type: type, deviceID: object["deviceID"] as? String,
            availability: object["availability"] as? String,
            record: object["record"] as? [String: Any],
            from: object["from"] as? String, to: object["to"] as? String,
            payload: payload, code: object["code"] as? String)
    }

    private func strictObject(_ data: Data, keys: Set<String>) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys).isSubset(of: keys)
        else { throw AuthenticatedPresenceError.invalidFrame }
        return object
    }

    private func decodeTrustRecord(_ object: [String: Any]) throws -> SignedTrustRecord {
        let required: Set<String> = [
            "action", "epochMilliseconds", "issuer", "issuerPublicKey", "issuerSequence", "subject",
            "subjectPublicKey", "signature",
        ]
        guard Set(object.keys) == required,
            let data = try? JSONSerialization.data(withJSONObject: object),
            let record = try? JSONDecoder().decode(TrustRecordWire.self, from: data),
            let issuer = UUID(uuidString: record.issuer),
            let subject = UUID(uuidString: record.subject)
        else { throw AuthenticatedPresenceError.invalidFrame }
        return SignedTrustRecord(
            issuer: DeviceID(rawValue: issuer), issuerPublicKey: record.issuerPublicKey,
            subject: DeviceID(rawValue: subject), subjectPublicKey: record.subjectPublicKey,
            action: record.action, issuerSequence: record.issuerSequence,
            epochMilliseconds: record.epochMilliseconds, signature: record.signature)
    }

    private struct TrustRecordWire: Decodable {
        let action: TrustAction
        let epochMilliseconds: Int64
        let issuer: String
        let issuerPublicKey: Data
        let issuerSequence: UInt64
        let subject: String
        let subjectPublicKey: Data
        let signature: Data
    }
}
