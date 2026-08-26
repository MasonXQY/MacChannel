import Foundation

public protocol RendezvousSignalSession: Sendable {
    func signalFrames() async -> AsyncStream<RendezvousSignalFrame>
    func sendSignal(_ payload: Data, to device: DeviceID) async throws
}

extension AuthenticatedPresenceSession: RendezvousSignalSession {}

public struct IncomingWebRTCOffer: Equatable, Sendable {
    public let remoteDevice: DeviceID
    public let connectionID: UUID
    public let route: ConnectionRoute

    public init(remoteDevice: DeviceID, connectionID: UUID, route: ConnectionRoute) {
        self.remoteDevice = remoteDevice
        self.connectionID = connectionID
        self.route = route
    }
}

/// Demultiplexes WebRTC attempts from Task 5's sole authenticated rendezvous
/// signal stream. It never owns or opens a WebSocket.
public actor RendezvousWebRTCSignaling: WebRTCSignalTransport {
    private struct Key: Hashable, Sendable {
        let device: DeviceID
        let connectionID: UUID
    }

    private struct Envelope: Codable, Sendable {
        let connectionID: UUID
        let message: WebRTCSignalMessage
    }

    private struct Subscriber {
        let token: UUID
        let continuation: AsyncThrowingStream<WebRTCSignalMessage, Error>.Continuation
    }

    private struct PendingBucket {
        var messages: [WebRTCSignalMessage] = []
        var bytes = 0
    }

    private static let maximumPendingConnections = 64
    private static let maximumPendingBytes = 4 * 1024 * 1024
    private static let maximumPendingBytesPerConnection = 512 * 1024

    private let session: any RendezvousSignalSession
    private var subscribers: [Key: Subscriber] = [:]
    private var pendingMessages: [Key: PendingBucket] = [:]
    private var pendingOrder: [Key] = []
    private var pendingBytes = 0
    private var announcedOffers: Set<Key> = []
    private var readerTask: Task<Void, Never>?
    private let incomingOfferStream: AsyncStream<IncomingWebRTCOffer>
    private let incomingOfferContinuation: AsyncStream<IncomingWebRTCOffer>.Continuation

    public init(session: any RendezvousSignalSession) {
        self.session = session
        var continuation: AsyncStream<IncomingWebRTCOffer>.Continuation!
        incomingOfferStream = AsyncStream(bufferingPolicy: .bufferingOldest(64)) { continuation = $0 }
        incomingOfferContinuation = continuation
    }

    deinit { readerTask?.cancel() }

    public func messages(from remoteDevice: DeviceID, connectionID: UUID) async -> AsyncThrowingStream<WebRTCSignalMessage, Error> {
        await ensureReader()
        let key = Key(device: remoteDevice, connectionID: connectionID)
        let token = UUID()
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(128)) { continuation in
            subscribers.removeValue(forKey: key)?.continuation.finish(throwing: WebRTCFactoryError.signalingEnded)
            subscribers[key] = Subscriber(token: token, continuation: continuation)
            for message in takePendingMessages(for: key) {
                continuation.yield(message)
            }
            announcedOffers.remove(key)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(key, token: token) }
            }
        }
    }

    public func incomingOffers() async -> AsyncStream<IncomingWebRTCOffer> {
        await ensureReader()
        return incomingOfferStream
    }

    public func send(_ message: WebRTCSignalMessage, to remoteDevice: DeviceID, connectionID: UUID) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try await session.sendSignal(
            encoder.encode(Envelope(connectionID: connectionID, message: message)),
            to: remoteDevice
        )
    }

    private func ensureReader() async {
        guard readerTask == nil else { return }
        let frames = await session.signalFrames()
        readerTask = Task { [weak self] in
            for await frame in frames {
                guard !Task.isCancelled else { return }
                await self?.receive(frame)
            }
            await self?.finishSubscribers()
        }
    }

    private func receive(_ frame: RendezvousSignalFrame) {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: frame.payload) else { return }
        let key = Key(device: frame.from, connectionID: envelope.connectionID)
        if let subscriber = subscribers[key] {
            switch subscriber.continuation.yield(envelope.message) {
            case .enqueued:
                break
            case .dropped, .terminated:
                subscriber.continuation.finish(throwing: WebRTCFactoryError.signalingEnded)
                subscribers.removeValue(forKey: key)
            @unknown default:
                subscriber.continuation.finish(throwing: WebRTCFactoryError.signalingEnded)
                subscribers.removeValue(forKey: key)
            }
            return
        }
        guard buffer(envelope.message, for: key) else { return }
        if case let .offer(_, route) = envelope.message, announcedOffers.insert(key).inserted {
            let offer = IncomingWebRTCOffer(
                remoteDevice: frame.from,
                connectionID: envelope.connectionID,
                route: route
            )
            switch incomingOfferContinuation.yield(offer) {
            case .enqueued:
                break
            case .dropped, .terminated:
                removePendingMessages(for: key)
                announcedOffers.remove(key)
            @unknown default:
                removePendingMessages(for: key)
                announcedOffers.remove(key)
            }
        }
    }

    private func buffer(_ message: WebRTCSignalMessage, for key: Key) -> Bool {
        let messageBytes = estimatedBytes(of: message)
        guard messageBytes <= Self.maximumPendingBytesPerConnection else { return false }
        if var bucket = pendingMessages[key] {
            guard bucket.bytes + messageBytes <= Self.maximumPendingBytesPerConnection,
                  pendingBytes + messageBytes <= Self.maximumPendingBytes
            else {
                removePendingMessages(for: key)
                announcedOffers.remove(key)
                return false
            }
            bucket.messages.append(message)
            bucket.bytes += messageBytes
            pendingMessages[key] = bucket
            pendingBytes += messageBytes
            return true
        }
        while pendingMessages.count >= Self.maximumPendingConnections
                || pendingBytes + messageBytes > Self.maximumPendingBytes {
            guard let oldest = pendingOrder.first else { return false }
            removePendingMessages(for: oldest)
            announcedOffers.remove(oldest)
        }
        pendingMessages[key] = PendingBucket(messages: [message], bytes: messageBytes)
        pendingOrder.append(key)
        pendingBytes += messageBytes
        return true
    }

    private func takePendingMessages(for key: Key) -> [WebRTCSignalMessage] {
        guard let bucket = pendingMessages.removeValue(forKey: key) else { return [] }
        pendingBytes -= bucket.bytes
        pendingOrder.removeAll { $0 == key }
        return bucket.messages
    }

    private func removePendingMessages(for key: Key) {
        _ = takePendingMessages(for: key)
    }

    private func estimatedBytes(of message: WebRTCSignalMessage) -> Int {
        switch message {
        case let .offer(sdp, _), let .answer(sdp):
            sdp.utf8.count + 128
        case let .candidate(sdp, _, mid):
            sdp.utf8.count + (mid?.utf8.count ?? 0) + 128
        }
    }

    private func removeSubscriber(_ key: Key, token: UUID) {
        guard subscribers[key]?.token == token else { return }
        subscribers.removeValue(forKey: key)
    }

    private func finishSubscribers() {
        let active = subscribers.values
        subscribers.removeAll()
        active.forEach { $0.continuation.finish(throwing: WebRTCFactoryError.signalingEnded) }
        incomingOfferContinuation.finish()
        readerTask = nil
    }
}

public enum ConnectionAttemptError: Error, Equatable, Sendable {
    case timeout
    case iceFailed
    case routeUnavailable
    case signalingFailed
    case authenticationFailed
}

public protocol ConnectionAttempting: Sendable {
    func connect(to device: DeviceID, route: ConnectionRoute) async throws -> any SecureChannel
}

public enum ConnectionCoordinatorError: Error, Equatable, Sendable {
    case allRoutesFailed
}

/// Applies the product's fixed route policy. Each attempt owns a fresh peer
/// connection so failed ICE state cannot leak into the next route.
public struct ConnectionCoordinator: PeerConnector, Sendable {
    private let attempts: any ConnectionAttempting

    public init(attempts: any ConnectionAttempting) {
        self.attempts = attempts
    }

    public init(
        directory: DeviceDirectory,
        identity: DeviceIdentity,
        trustRepository: TrustRepository,
        signaling: any WebRTCSignalTransport,
        ice: ICEConfiguration,
        factory: WebRTCFactory = WebRTCFactory()
    ) {
        attempts = WebRTCConnectionAttempts(
            directory: directory,
            identity: identity,
            trustRepository: trustRepository,
            signaling: signaling,
            ice: ice,
            factory: factory
        )
    }

    public func connect(to device: DeviceID) async throws -> any SecureChannel {
        for route in [ConnectionRoute.lan, .directInternet, .relay] {
            do {
                return try await attempts.connect(to: device, route: route)
            } catch is CancellationError {
                throw CancellationError()
            } catch ConnectionAttemptError.authenticationFailed {
                throw ConnectionAttemptError.authenticationFailed
            } catch WebRTCSecureChannelError.authenticationFailed {
                throw WebRTCSecureChannelError.authenticationFailed
            } catch {
                continue
            }
        }
        throw ConnectionCoordinatorError.allRoutesFailed
    }
}

public actor WebRTCConnectionAttempts: ConnectionAttempting {
    private let directory: DeviceDirectory
    private let identity: DeviceIdentity
    private let trustRepository: TrustRepository
    private let signaling: any WebRTCSignalTransport
    private let ice: ICEConfiguration
    private let factory: WebRTCFactory

    public init(
        directory: DeviceDirectory,
        identity: DeviceIdentity,
        trustRepository: TrustRepository,
        signaling: any WebRTCSignalTransport,
        ice: ICEConfiguration,
        factory: WebRTCFactory = WebRTCFactory()
    ) {
        self.directory = directory
        self.identity = identity
        self.trustRepository = trustRepository
        self.signaling = signaling
        self.ice = ice
        self.factory = factory
    }

    public func connect(to device: DeviceID, route: ConnectionRoute) async throws -> any SecureChannel {
        if route == .lan, await directory.endpoint(for: device) == nil {
            throw ConnectionAttemptError.routeUnavailable
        }
        guard let remotePublicKey = await trustRepository.publicKey(for: device) else {
            throw ConnectionAttemptError.authenticationFailed
        }
        let channel = try await factory.connect(
            localIdentity: identity,
            remoteDevice: device,
            remotePublicKey: remotePublicKey,
            connectionID: UUID(),
            role: .offerer,
            route: route,
            ice: ice,
            signaling: signaling
        )
        guard await trustRepository.publicKey(for: device) == remotePublicKey else {
            await channel.close()
            throw ConnectionAttemptError.authenticationFailed
        }
        return channel
    }
}

/// Accepts offers discovered by `RendezvousWebRTCSignaling` and produces the
/// authenticated receive-side channels needed by transfer orchestration.
public actor WebRTCConnectionListener {
    private struct Acceptance {
        let remoteDevice: DeviceID
        let task: Task<Void, Never>
    }

    private static let maximumConcurrentAcceptances = 8
    private static let maximumConcurrentAcceptancesPerDevice = 2

    private let directory: DeviceDirectory
    private let identity: DeviceIdentity
    private let trustRepository: TrustRepository
    private let signaling: RendezvousWebRTCSignaling
    private let ice: ICEConfiguration
    private let factory: any WebRTCChannelFactory
    private let channelStream: AsyncThrowingStream<WebRTCSecureChannel, Error>
    private let channelContinuation: AsyncThrowingStream<WebRTCSecureChannel, Error>.Continuation
    private var readerTask: Task<Void, Never>?
    private var acceptanceTasks: [UUID: Acceptance] = [:]
    private var stopped = false

    public init(
        directory: DeviceDirectory,
        identity: DeviceIdentity,
        trustRepository: TrustRepository,
        signaling: RendezvousWebRTCSignaling,
        ice: ICEConfiguration,
        factory: any WebRTCChannelFactory = WebRTCFactory()
    ) {
        self.directory = directory
        self.identity = identity
        self.trustRepository = trustRepository
        self.signaling = signaling
        self.ice = ice
        self.factory = factory
        var continuation: AsyncThrowingStream<WebRTCSecureChannel, Error>.Continuation!
        channelStream = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(32)) { continuation = $0 }
        channelContinuation = continuation
    }

    deinit { readerTask?.cancel() }

    public func channels() async -> AsyncThrowingStream<WebRTCSecureChannel, Error> {
        if !stopped, readerTask == nil {
            let offers = await signaling.incomingOffers()
            readerTask = Task { [weak self] in
                for await offer in offers {
                    guard !Task.isCancelled else { return }
                    await self?.beginAccepting(offer)
                }
            }
        }
        return channelStream
    }

    public func stop() {
        guard !stopped else { return }
        stopped = true
        readerTask?.cancel()
        readerTask = nil
        acceptanceTasks.values.forEach { $0.task.cancel() }
        acceptanceTasks.removeAll()
        channelContinuation.finish()
    }

    private func beginAccepting(_ offer: IncomingWebRTCOffer) {
        guard !stopped,
              acceptanceTasks.count < Self.maximumConcurrentAcceptances,
              acceptanceTasks.values.lazy.filter({ $0.remoteDevice == offer.remoteDevice }).count
                < Self.maximumConcurrentAcceptancesPerDevice
        else { return }
        let token = UUID()
        let task = Task { [weak self] in
            await self?.accept(offer)
            await self?.acceptanceFinished(token)
        }
        acceptanceTasks[token] = Acceptance(remoteDevice: offer.remoteDevice, task: task)
    }

    private func acceptanceFinished(_ token: UUID) {
        acceptanceTasks.removeValue(forKey: token)
    }

    private func accept(_ offer: IncomingWebRTCOffer) async {
        if offer.route == .lan, await directory.endpoint(for: offer.remoteDevice) == nil { return }
        guard let remotePublicKey = await trustRepository.publicKey(for: offer.remoteDevice) else { return }
        do {
            let channel = try await factory.connect(
                localIdentity: identity,
                remoteDevice: offer.remoteDevice,
                remotePublicKey: remotePublicKey,
                connectionID: offer.connectionID,
                role: .answerer,
                route: offer.route,
                ice: ice,
                signaling: signaling
            )
            guard await trustRepository.publicKey(for: offer.remoteDevice) == remotePublicKey else {
                await channel.close()
                return
            }
            guard !stopped else {
                await channel.close()
                return
            }
            switch channelContinuation.yield(channel) {
            case .enqueued:
                break
            case .dropped(let dropped):
                await dropped.close()
                await channel.close()
            case .terminated:
                await channel.close()
            @unknown default:
                await channel.close()
            }
        } catch {
            // A failed inbound attempt is isolated; later route offers remain usable.
        }
    }
}
