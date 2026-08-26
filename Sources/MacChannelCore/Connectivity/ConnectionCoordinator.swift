import Foundation

public protocol RendezvousSignalSession: Sendable {
    func signalFrames() async -> AsyncStream<RendezvousSignalFrame>
    func sendSignal(_ payload: Data, to device: DeviceID) async throws
}

extension AuthenticatedPresenceSession: RendezvousSignalSession {}

private actor BoundedWebRTCSignalMailbox {
    private struct Item {
        let message: WebRTCSignalMessage
        let bytes: Int
    }

    private static let maximumMessages = 128
    private static let maximumBytes = 512 * 1024

    private var queued: [Item] = []
    private var queuedBytes = 0
    private var waiter: CheckedContinuation<WebRTCSignalMessage?, Error>?
    private var terminalError: WebRTCFactoryError?

    func push(_ message: WebRTCSignalMessage, bytes: Int) -> Bool {
        guard terminalError == nil, bytes <= Self.maximumBytes else {
            finish(.signalingOverflow)
            return false
        }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: message)
            return true
        }
        guard queued.count < Self.maximumMessages,
              queuedBytes + bytes <= Self.maximumBytes
        else {
            finish(.signalingOverflow)
            return false
        }
        queued.append(Item(message: message, bytes: bytes))
        queuedBytes += bytes
        return true
    }

    func next() async throws -> WebRTCSignalMessage? {
        if Task.isCancelled { throw CancellationError() }
        if let terminalError { throw terminalError }
        if !queued.isEmpty {
            let item = queued.removeFirst()
            queuedBytes -= item.bytes
            return item.message
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if let terminalError {
                    continuation.resume(throwing: terminalError)
                } else if let existing = waiter {
                    waiter = nil
                    terminalError = .signalingOverflow
                    existing.resume(throwing: WebRTCFactoryError.signalingOverflow)
                    continuation.resume(throwing: WebRTCFactoryError.signalingOverflow)
                } else {
                    waiter = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter() }
        }
    }

    func finish(_ error: WebRTCFactoryError) {
        guard terminalError == nil else { return }
        terminalError = error
        queued.removeAll(keepingCapacity: false)
        queuedBytes = 0
        let waiter = self.waiter
        self.waiter = nil
        waiter?.resume(throwing: error)
    }

    private func cancelWaiter() {
        let waiter = self.waiter
        self.waiter = nil
        waiter?.resume(throwing: CancellationError())
    }
}

private final class SignalSubscriptionLease: @unchecked Sendable {
    private let onTermination: @Sendable () -> Void

    init(onTermination: @escaping @Sendable () -> Void) {
        self.onTermination = onTermination
    }

    deinit { onTermination() }
}

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
        weak var mailbox: BoundedWebRTCSignalMailbox?
    }

    private struct PendingBucket {
        var messages: [WebRTCSignalMessage] = []
        var bytes = 0
        var terminalError: WebRTCFactoryError?
    }

    private static let maximumPendingConnections = 64
    private static let maximumPendingMessagesPerConnection = 128
    private static let maximumPendingBytes = 4 * 1024 * 1024
    private static let maximumPendingBytesPerConnection = 512 * 1024

    private let session: any RendezvousSignalSession
    private var subscribers: [Key: Subscriber] = [:]
    private var pendingMessages: [Key: PendingBucket] = [:]
    private var pendingOrder: [Key] = []
    private var pendingBytes = 0
    private var announcedOffers: Set<Key> = []
    private var receivedFrameCount = 0
    private var routerTerminalError: WebRTCFactoryError?
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
        if let routerTerminalError {
            return AsyncThrowingStream { $0.finish(throwing: routerTerminalError) }
        }
        if let previous = subscribers.removeValue(forKey: key)?.mailbox {
            await previous.finish(.signalingEnded)
        }
        let mailbox = BoundedWebRTCSignalMailbox()
        var failed = false
        while let pending = takePendingBucket(for: key) {
            if let error = pending.terminalError {
                await mailbox.finish(error)
                failed = true
                break
            }
            for message in pending.messages {
                guard await mailbox.push(message, bytes: estimatedBytes(of: message)) else {
                    await failPendingConnection(key, with: .signalingOverflow)
                    failed = true
                    break
                }
            }
            if failed { break }
        }
        if !failed { subscribers[key] = Subscriber(token: token, mailbox: mailbox) }
        announcedOffers.remove(key)
        let lease = SignalSubscriptionLease { [weak self] in
            Task { await self?.removeSubscriber(key, token: token) }
        }
        return AsyncThrowingStream(unfolding: { [mailbox, lease] in
            _ = lease
            return try await mailbox.next()
        })
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
        guard readerTask == nil, routerTerminalError == nil else { return }
        let frames = await session.signalFrames()
        readerTask = Task { [weak self] in
            for await frame in frames {
                guard !Task.isCancelled else { return }
                await self?.receive(frame)
            }
            await self?.finishSubscribers()
        }
    }

    private func receive(_ frame: RendezvousSignalFrame) async {
        guard routerTerminalError == nil else { return }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: frame.payload) else { return }
        if receivedFrameCount < Int.max { receivedFrameCount += 1 }
        let key = Key(device: frame.from, connectionID: envelope.connectionID)
        if let subscriber = subscribers[key], let mailbox = subscriber.mailbox {
            guard await mailbox.push(
                envelope.message,
                bytes: estimatedBytes(of: envelope.message)
            ) else {
                subscribers.removeValue(forKey: key)
                await failPendingConnection(key, with: .signalingOverflow)
                return
            }
            return
        } else if subscribers.removeValue(forKey: key) != nil {
            // The consumer released its stream before the lease cleanup ran.
        }
        guard await buffer(envelope.message, for: key) else { return }
        if case let .offer(_, route) = envelope.message, announcedOffers.insert(key).inserted {
            let offer = IncomingWebRTCOffer(
                remoteDevice: frame.from,
                connectionID: envelope.connectionID,
                route: route
            )
            switch incomingOfferContinuation.yield(offer) {
            case .enqueued:
                break
            case .dropped:
                await failPendingConnection(key, with: .signalingOverflow)
            case .terminated:
                await failRouter(with: .signalingEnded)
            @unknown default:
                await failRouter(with: .signalingOverflow)
            }
        }
    }

    private func buffer(_ message: WebRTCSignalMessage, for key: Key) async -> Bool {
        let messageBytes = estimatedBytes(of: message)
        guard messageBytes <= Self.maximumPendingBytesPerConnection else {
            await failPendingConnection(key, with: .signalingOverflow)
            return false
        }
        if var bucket = pendingMessages[key] {
            guard bucket.terminalError == nil else { return false }
            guard bucket.messages.count < Self.maximumPendingMessagesPerConnection,
                  bucket.bytes + messageBytes <= Self.maximumPendingBytesPerConnection,
                  pendingBytes + messageBytes <= Self.maximumPendingBytes
            else {
                await failPendingConnection(key, with: .signalingOverflow)
                return false
            }
            bucket.messages.append(message)
            bucket.bytes += messageBytes
            pendingMessages[key] = bucket
            pendingBytes += messageBytes
            return true
        }
        guard pendingMessages.count < Self.maximumPendingConnections,
              pendingBytes + messageBytes <= Self.maximumPendingBytes
        else {
            await failRouter(with: .signalingOverflow)
            return false
        }
        pendingMessages[key] = PendingBucket(
            messages: [message],
            bytes: messageBytes,
            terminalError: nil
        )
        pendingOrder.append(key)
        pendingBytes += messageBytes
        return true
    }

    private func takePendingBucket(for key: Key) -> PendingBucket? {
        guard let bucket = pendingMessages.removeValue(forKey: key) else { return nil }
        pendingBytes -= bucket.bytes
        pendingOrder.removeAll { $0 == key }
        return bucket
    }

    private func removePendingMessages(for key: Key) {
        _ = takePendingBucket(for: key)
    }

    private func failPendingConnection(_ key: Key, with error: WebRTCFactoryError) async {
        if pendingMessages[key] == nil, pendingMessages.count >= Self.maximumPendingConnections {
            await failRouter(with: error)
            return
        }
        removePendingMessages(for: key)
        pendingMessages[key] = PendingBucket(messages: [], bytes: 0, terminalError: error)
        pendingOrder.append(key)
        announcedOffers.remove(key)
    }

    private func failRouter(with error: WebRTCFactoryError) async {
        guard routerTerminalError == nil else { return }
        routerTerminalError = error
        readerTask?.cancel()
        readerTask = nil
        let active = subscribers.values.compactMap(\.mailbox)
        subscribers.removeAll()
        pendingMessages.removeAll()
        pendingOrder.removeAll()
        pendingBytes = 0
        announcedOffers.removeAll()
        incomingOfferContinuation.finish()
        for mailbox in active { await mailbox.finish(error) }
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

    private func finishSubscribers() async {
        guard routerTerminalError == nil else { return }
        routerTerminalError = .signalingEnded
        let active = subscribers.values.compactMap(\.mailbox)
        subscribers.removeAll()
        pendingMessages.removeAll()
        pendingOrder.removeAll()
        pendingBytes = 0
        announcedOffers.removeAll()
        incomingOfferContinuation.finish()
        readerTask = nil
        for mailbox in active { await mailbox.finish(.signalingEnded) }
    }

    func _testOnlyReceivedFrameCount() -> Int { receivedFrameCount }
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

public protocol TransferAwareConnectionAttempting: ConnectionAttempting {
    func connect(
        to device: DeviceID,
        route: ConnectionRoute,
        transferID: TransferID
    ) async throws -> any SecureChannel
}

public enum ConnectionCoordinatorError: Error, Equatable, Sendable {
    case allRoutesFailed
}

/// Applies the product's fixed route policy. Each attempt owns a fresh peer
/// connection so failed ICE state cannot leak into the next route.
public struct ConnectionCoordinator: TransferAwarePeerConnector, Sendable {
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
        try await connectAcrossRoutes(to: device, transferID: nil)
    }

    public func connect(
        to device: DeviceID,
        transferID: TransferID
    ) async throws -> any SecureChannel {
        try await connectAcrossRoutes(to: device, transferID: transferID)
    }

    private func connectAcrossRoutes(
        to device: DeviceID,
        transferID: TransferID?
    ) async throws -> any SecureChannel {
        for route in [ConnectionRoute.lan, .directInternet, .relay] {
            do {
                if let transferID,
                    let transferAttempts = attempts as? any TransferAwareConnectionAttempting
                {
                    return try await transferAttempts.connect(
                        to: device,
                        route: route,
                        transferID: transferID
                    )
                }
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

public actor WebRTCConnectionAttempts: TransferAwareConnectionAttempting {
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

    public func connect(
        to device: DeviceID,
        route: ConnectionRoute
    ) async throws -> any SecureChannel {
        try await connect(to: device, route: route, connectionID: UUID())
    }

    public func connect(
        to device: DeviceID,
        route: ConnectionRoute,
        transferID: TransferID
    ) async throws -> any SecureChannel {
        try await connect(to: device, route: route, connectionID: transferID.rawValue)
    }

    private func connect(
        to device: DeviceID,
        route: ConnectionRoute,
        connectionID: UUID
    ) async throws -> any SecureChannel {
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
            connectionID: connectionID,
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
public actor WebRTCConnectionListener: IncomingTransferConnectionSource {
    private enum Consumer: Equatable {
        case none
        case legacyChannels
        case transferConnections
    }

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
    private let transferStream: AsyncThrowingStream<IncomingTransferConnection, Error>
    private let transferContinuation:
        AsyncThrowingStream<IncomingTransferConnection, Error>.Continuation
    private var readerTask: Task<Void, Never>?
    private var acceptanceTasks: [UUID: Acceptance] = [:]
    private var stopped = false
    private var consumer = Consumer.none

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
        channelStream = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(32)) {
            continuation = $0
        }
        channelContinuation = continuation
        var transferContinuation:
            AsyncThrowingStream<IncomingTransferConnection, Error>.Continuation!
        transferStream = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(32)) {
            transferContinuation = $0
        }
        self.transferContinuation = transferContinuation
    }

    deinit { readerTask?.cancel() }

    public func channels() async -> AsyncThrowingStream<WebRTCSecureChannel, Error> {
        if consumer == .none { consumer = .legacyChannels }
        await beginReadingIfNeeded()
        return channelStream
    }

    public func connections() async -> AsyncThrowingStream<IncomingTransferConnection, Error> {
        if consumer == .none { consumer = .transferConnections }
        await beginReadingIfNeeded()
        return transferStream
    }

    public func stop() {
        guard !stopped else { return }
        stopped = true
        readerTask?.cancel()
        readerTask = nil
        for acceptance in acceptanceTasks.values { acceptance.task.cancel() }
        acceptanceTasks.removeAll()
        channelContinuation.finish()
        transferContinuation.finish()
    }

    private func beginReadingIfNeeded() async {
        guard !stopped, readerTask == nil else { return }
        let offers = await signaling.incomingOffers()
        readerTask = Task { [weak self] in
            for await offer in offers {
                guard !Task.isCancelled else { return }
                await self?.beginAccepting(offer)
            }
        }
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
        guard let remotePublicKey = await trustRepository.publicKey(for: offer.remoteDevice) else {
            return
        }
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
            switch consumer {
            case .legacyChannels:
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
            case .transferConnections:
                let connection = IncomingTransferConnection(
                    source: offer.remoteDevice,
                    transferID: TransferID(rawValue: offer.connectionID),
                    channel: channel
                )
                switch transferContinuation.yield(connection) {
                case .enqueued:
                    break
                case .dropped(let dropped):
                    await dropped.channel.close()
                    await channel.close()
                case .terminated:
                    await channel.close()
                @unknown default:
                    await channel.close()
                }
            case .none:
                await channel.close()
            }
        } catch {
            // A failed inbound attempt is isolated; later route offers remain usable.
        }
    }
}
