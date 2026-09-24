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
    func ping() async throws
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

    public func ping() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            task.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
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

    private let applyPresence: @Sendable (DevicePresence) async -> Void
    private let onDeliveryAdmitted: (@Sendable (DevicePresence) -> Void)?
    private let heartbeatInterval: TimeInterval
    private var onlineDevices: Set<DeviceID> = []
    // Includes offline peers until drain: an older in-flight renewal may still
    // land after their offline event, so final cleanup must clear them too.
    private var touchedDevices: Set<DeviceID> = []
    private var heartbeatTask: Task<Void, Never>?
    private var disconnectTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var acceptingEvents = true
    private var deliveries: [UUID: Task<Void, Never>] = [:]
    private var deliveryTails: [DeviceID: (id: UUID, task: Task<Void, Never>)] = [:]

    public init(
        directory: DeviceDirectory,
        heartbeatInterval: TimeInterval = PresenceClient.heartbeatInterval
    ) {
        self.applyPresence = { await directory.apply($0) }
        self.onDeliveryAdmitted = nil
        self.heartbeatInterval = heartbeatInterval
    }

    /// Internal directory-delivery seam for deterministic actor-hop drain tests.
    init(heartbeatInterval: TimeInterval,
         applyPresence: @escaping @Sendable (DevicePresence) async -> Void,
         onDeliveryAdmitted: (@Sendable (DevicePresence) -> Void)? = nil) {
        self.heartbeatInterval = heartbeatInterval
        self.applyPresence = applyPresence
        self.onDeliveryAdmitted = onDeliveryAdmitted
    }

    deinit { heartbeatTask?.cancel() }

    func receiveAuthenticated(_ event: RendezvousPresenceEvent) async {
        guard acceptingEvents else { return }
        switch event {
        case let .availability(device, isOnline):
            touchedDevices.insert(device)
            if isOnline { onlineDevices.insert(device) } else { onlineDevices.remove(device) }
            await deliver(.internet(device, online: isOnline), for: device)
        }
    }

    func startHeartbeats() {
        guard heartbeatTask == nil, disconnectTask == nil else { return }
        acceptingEvents = true
        heartbeatTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self.heartbeatInterval))
                guard !Task.isCancelled else { return }
                await self.renewOnlinePresence()
            }
        }
    }

    func stopHeartbeats() async {
        let heartbeat = heartbeatTask
        heartbeat?.cancel()
        await heartbeat?.value
        heartbeatTask = nil
    }

    func disconnect() async {
        if let disconnectTask { await disconnectTask.value; return }
        // Retire renewal before any directory/heartbeat actor hop. Keep the
        // handle until joined so concurrent disconnects share the same drain.
        generation += 1
        acceptingEvents = false
        heartbeatTask?.cancel()
        let pendingDeliveries = Array(deliveries.values)
        let previouslyOnline = touchedDevices
        touchedDevices = []
        onlineDevices = []
        let drain = Task {
            await stopHeartbeats()
            for delivery in pendingDeliveries { await delivery.value }
            for device in previouslyOnline {
                await applyPresence(.internet(device, online: false))
            }
        }
        disconnectTask = drain
        await drain.value
        disconnectTask = nil
    }

    func renewOnlinePresence() async {
        let currentGeneration = generation
        for device in onlineDevices {
            guard generation == currentGeneration, !Task.isCancelled else { return }
            guard acceptingEvents, onlineDevices.contains(device) else { continue }
            await deliver(.internet(device, online: true), for: device)
        }
    }

    /// Preserve admission order per peer across actor hops. A newer offline
    /// event waits for an already admitted renewal, while unrelated peers can
    /// still go offline immediately. Disconnect joins every admitted delivery.
    private func deliver(_ event: DevicePresence, for device: DeviceID) async {
        let id = UUID()
        let previous = deliveryTails[device]?.task
        let delivery = Task {
            await previous?.value
            await applyPresence(event)
        }
        deliveries[id] = delivery
        deliveryTails[device] = (id, delivery)
        // Synchronous internal observation: tests can release a held predecessor
        // only after this delivery is queued, without introducing an actor hop.
        onDeliveryAdmitted?(event)
        await delivery.value
        deliveries[id] = nil
        if deliveryTails[device]?.id == id { deliveryTails[device] = nil }
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
    static let livenessInterval: Duration = .seconds(20)
    static let livenessTimeout: Duration = .seconds(10)

    private let identity: DeviceIdentity
    private let origin: URL
    private let socket: any PresenceWebSocket
    private let client: PresenceClient
    private let trustRepository: TrustRepository?
    private let livenessInterval: Duration
    private let livenessTimeout: Duration
    private var running = false
    private var readerActive = false
    private var livenessTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var retired = false
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
    private enum AccountPhase { case challenge, bind, unbind }
    private struct AccountOperation {
        let id: UUID
        var phase: AccountPhase
        var payload: Data?
        let continuation: CheckedContinuation<Void, Error>
    }
    private var accountOperation: AccountOperation?
    private var accountTimeoutTask: Task<Void, Never>?
    private var accountSendTasks: [UUID: Task<Void, Never>] = [:]

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
        trustRepository: TrustRepository? = nil,
        livenessInterval: Duration = AuthenticatedPresenceSession.livenessInterval,
        livenessTimeout: Duration = AuthenticatedPresenceSession.livenessTimeout,
        allowInsecureForTesting: Bool
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
        self.livenessInterval = livenessInterval
        self.livenessTimeout = livenessTimeout
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

    /// Requires a connected session with its run loop active. Only one account
    /// control operation may be pending; admission remains busy until all prior
    /// sends return, even after acknowledgement. Failure retires the socket because the
    /// wire acknowledgements have no request IDs. Success grants no local trust.
    public func bindAccountRoute(accessToken: String, audience: String, groupID: String,
                                 generation: UInt64, timeout: Duration = .seconds(10)) async throws {
        guard (1...4096).contains(accessToken.utf8.count), (1...255).contains(audience.utf8.count),
              let group = UUID(uuidString: groupID), group.uuidString.lowercased() == groupID,
              generation > 0, generation <= UInt64(Int64.max) else {
            throw AuthenticatedPresenceError.invalidFrame
        }
        let payload = try JSONSerialization.data(withJSONObject: [
            "type": "account-route-bind-v1", "accessToken": accessToken,
            "audience": audience, "groupID": groupID, "generation": generation,
        ], options: [.sortedKeys, .withoutEscapingSlashes])
        try await performAccountOperation(phase: .challenge, payload: payload, timeout: timeout)
    }

    /// An acknowledgement confirms only the socket control operation. It grants
    /// no local trust or transfer authority; callers still use route admission.
    public func unbindAccountRoute(timeout: Duration = .seconds(10)) async throws {
        try await performAccountOperation(phase: .unbind, payload: nil, timeout: timeout)
    }

    private func performAccountOperation(phase: AccountPhase, payload: Data?, timeout: Duration) async throws {
        try Task.checkCancellation()
        guard running, readerActive, !retired else {
            throw AuthenticatedPresenceError.transport("account_route_unavailable")
        }
        guard accountOperation == nil, accountSendTasks.isEmpty else {
            throw AuthenticatedPresenceError.transport("account_route_busy")
        }
        guard timeout > .zero, timeout <= .seconds(60) else {
            throw AuthenticatedPresenceError.invalidFrame
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                accountOperation = AccountOperation(id: id, phase: phase, payload: payload, continuation: continuation)
                accountTimeoutTask = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    await self?.failAccountOperation(id: id, error: AuthenticatedPresenceError.transport("account_route_timeout"))
                }
                let frame = Data("{\"type\":\"\(phase == .unbind ? "account-route-unbind" : "account-route-bind-challenge")\"}".utf8)
                sendAccountFrame(frame, id: id)
            }
        } onCancel: {
            Task { await self.failAccountOperation(id: id, error: CancellationError()) }
        }
    }

    private func sendAccountFrame(_ data: Data, id: UUID) {
        let sendID = UUID()
        accountSendTasks[sendID] = Task { [weak self, socket] in
            do {
                try Task.checkCancellation()
                try await socket.send(data)
            } catch {
                await self?.failAccountOperation(id: id, error: AuthenticatedPresenceError.transport("account_route_send_failed"))
            }
            await self?.accountSendFinished(sendID)
        }
    }

    private func accountSendFinished(_ id: UUID) {
        accountSendTasks[id] = nil
    }

    private func finishAccountOperation(_ result: Result<Void, Error>) {
        guard let operation = accountOperation else { return }
        accountOperation = nil
        accountTimeoutTask?.cancel()
        accountTimeoutTask = nil
        operation.continuation.resume(with: result)
    }

    private func failAccountOperation(id: UUID, error: Error) {
        guard accountOperation?.id == id else { return }
        finishAccountOperation(.failure(error))
        // The protocol has no request IDs: never let a late acknowledgement
        // from an abandoned operation satisfy a later operation on this socket.
        _ = beginStop()
    }

    private func receiveAccountFrame(_ data: Data) throws {
        guard var operation = accountOperation else { throw AuthenticatedPresenceError.invalidFrame }
        let object = try strictObject(data, keys: ["type", "nonce", "expiresAt", "code"])
        let type = object["type"] as? String
        if type == "account-route-bind-error" {
            guard Set(object.keys) == ["type", "code"], object["code"] is String else {
                throw AuthenticatedPresenceError.invalidFrame
            }
            failAccountOperation(id: operation.id, error: AuthenticatedPresenceError.transport("account_route_rejected"))
            return
        }
        switch operation.phase {
        case .challenge:
            struct WireChallenge: Decodable { let type: String; let nonce: Data; let expiresAt: Int64 }
            guard Set(object.keys) == ["type", "nonce", "expiresAt"],
                  let challenge = try? JSONDecoder().decode(WireChallenge.self, from: data),
                  challenge.type == "account-route-bind-challenge", challenge.nonce.count == 32,
                  challenge.expiresAt > Int64(Date().timeIntervalSince1970 * 1000),
                  let payload = operation.payload else { throw AuthenticatedPresenceError.invalidChallenge }
            let unsigned = RendezvousSignedEnvelope(deviceID: identity.id.rawValue.uuidString.lowercased(),
                nonce: challenge.nonce, payload: payload, publicKey: identity.publicKey.rawRepresentation,
                epochMilliseconds: Int64(Date().timeIntervalSince1970 * 1000), signature: Data())
            let signed = RendezvousSignedEnvelope(deviceID: unsigned.deviceID, nonce: unsigned.nonce,
                payload: unsigned.payload, publicKey: unsigned.publicKey, epochMilliseconds: unsigned.epochMilliseconds,
                signature: try identity.sign(unsigned.canonicalPayload()).derRepresentation)
            struct Bind: Encodable { let type = "account-route-bind"; let envelope: RendezvousSignedEnvelope }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let frame = try encoder.encode(Bind(envelope: signed))
            operation.phase = .bind
            operation.payload = nil
            accountOperation = operation
            sendAccountFrame(frame, id: operation.id)
        case .bind, .unbind:
            guard Set(object.keys) == ["type"],
                  type == (operation.phase == .bind ? "account-route-bind-ok" : "account-route-unbind-ok") else {
                throw AuthenticatedPresenceError.invalidFrame
            }
            finishAccountOperation(.success(()))
        }
    }

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

    /// True only for an explicit service rejection of the nonempty proof batch
    /// submitted by this attempt; ordinary identity/transport failures differ.
    public private(set) var trustAuthenticationRejected = false
    /// Capacity is a retryable service condition, not an identity rejection.
    public private(set) var authenticationCapacityRejected = false

    public func connect(includeTrustRecords: Bool = true) async throws {
        guard !retired else { throw AuthenticatedPresenceError.transport("session_retired") }
        trustAuthenticationRejected = false
        authenticationCapacityRejected = false
        await client.disconnect()
        let challenge = try decodeChallenge(try await receiveFrame())
        let trustRecords =
            if includeTrustRecords, let trustRepository {
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
        authenticationCapacityRejected = confirmation.type == "auth-error"
            && confirmation.code == "capacity_reached"
        trustAuthenticationRejected = !trustRecords.isEmpty
            && confirmation.type == "auth-error"
            && confirmation.code == "authentication_failed"
        guard confirmation.type == "auth-ok",
            confirmation.deviceID == identity.id.rawValue.uuidString.lowercased()
        else {
            throw AuthenticatedPresenceError.authenticationRejected
        }
        guard !retired else { throw AuthenticatedPresenceError.transport("session_retired") }
        running = true
        await client.startHeartbeats()
        guard !retired else {
            await client.disconnect()
            throw AuthenticatedPresenceError.transport("session_retired")
        }
    }

    public func run() async throws {
        try await run(onStarted: {}, onTrustResult: nil)
    }

    /// The shared owner starts its writer only after this sole reader is active.
    /// Internal delivery avoids competing consumers of the public result stream.
    func run(onStarted: @Sendable () async -> Void,
             onTrustResult: (@Sendable (RendezvousTrustResult) async -> Void)?) async throws {
        guard running else { throw AuthenticatedPresenceError.authenticationRejected }
        guard !readerActive else {
            throw AuthenticatedPresenceError.transport("reader_already_active")
        }
        readerActive = true
        startLivenessMonitoring()
        defer {
            readerActive = false
            if !running { finishStreams() }
        }
        do {
            await onStarted()
            while running {
                let data = try await receiveFrame()
                guard running, !retired else { break }
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let type = object["type"] as? String, type.hasPrefix("account-route-") {
                    try receiveAccountFrame(data)
                    continue
                }
                let frame = try decodeFrame(data)
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
                case "trust-ok", "trust-error":
                    let result: RendezvousTrustResult = frame.type == "trust-ok" ? .accepted : .rejected
                    if let onTrustResult { await onTrustResult(result) }
                    else { trustResultContinuation.yield(result) }
                case "protocol-error":
                    guard let code = frame.code else {
                        throw AuthenticatedPresenceError.invalidFrame
                    }
                    protocolErrorContinuation.yield(RendezvousProtocolError(code: code))
                    if let operation = accountOperation {
                        failAccountOperation(id: operation.id, error: AuthenticatedPresenceError.transport("account_route_rejected"))
                    }
                default:
                    throw AuthenticatedPresenceError.invalidFrame
                }
            }
        } catch {
            await stop()
            throw error
        }
        await stop()
    }

    public func stop() async {
        await beginStop().value
    }

    /// A liveness callback may initiate this cleanup but must not await it:
    /// the cleanup joins that callback's task. External stop/run callers join.
    private func beginStop() -> Task<Void, Never> {
        if let stopTask { return stopTask }
        retired = true
        running = false
        finishAccountOperation(.failure(AuthenticatedPresenceError.transport("session_retired")))
        let accountSends = Array(accountSendTasks.values)
        accountSendTasks.removeAll()
        accountSends.forEach { $0.cancel() }
        let liveness = livenessTask
        liveness?.cancel()
        pendingTrustRecords.removeAll()
        finishStreams()
        let drain = Task {
            // Closing first releases production ping/receive continuations.
            // Cancellation-insensitive transports still keep the drain pending.
            await socket.close()
            for send in accountSends { await send.value }
            await liveness?.value
            await client.disconnect()
        }
        stopTask = drain
        return drain
    }

    private func startLivenessMonitoring() {
        guard !retired, livenessTask == nil else { return }
        let interval = livenessInterval
        let timeout = livenessTimeout
        let socket = socket
        livenessTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                    try Task.checkCancellation()
                    try await Self.verifyLiveness(of: socket, timeout: timeout)
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    await self?.failStaleConnection()
                    return
                }
            }
        }
    }

    private static func verifyLiveness(
        of socket: any PresenceWebSocket,
        timeout: Duration
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await socket.ping() }
            group.addTask {
                try await Task.sleep(for: timeout)
                await socket.close()
                throw AuthenticatedPresenceError.transport("liveness_timeout")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw AuthenticatedPresenceError.transport("liveness_cancelled")
            }
            return first
        }
    }

    private func failStaleConnection() {
        guard running else { return }
        _ = beginStop()
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
