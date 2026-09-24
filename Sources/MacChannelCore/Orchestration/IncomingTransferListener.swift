import Foundation

public struct IncomingTransferConnection: Sendable {
    public let source: DeviceID
    public let transferID: TransferID
    public let channel: any SecureChannel

    public init(
        source: DeviceID,
        transferID: TransferID,
        channel: any SecureChannel
    ) {
        self.source = source
        self.transferID = transferID
        self.channel = channel
    }
}

public protocol IncomingTransferConnectionSource: Sendable {
    /// Implementations must use a bounded source stream and close every channel
    /// rejected by that stream. Production uses a zero-element handoff buffer.
    /// The listener requests the stream and each next element only after it has
    /// reserved process-wide retained-channel ownership.
    func connections() async -> AsyncThrowingStream<IncomingTransferConnection, Error>
}

public enum IncomingTransferCapacity {
    public static let maximumActiveTransfers = 2
    public static let maximumQueuedConnections = 32
    public static let maximumEstablishedConnections =
        maximumActiveTransfers + maximumQueuedConnections
    public static let maximumAdmittedChannels = maximumEstablishedConnections
    public static let maximumConcurrentCloseOperations = 4

    // WebRTC can additionally have eight authenticated acceptances in flight,
    // but retains no second established-channel queue before this listener. A
    // retained-channel admission is backpressured before the source is pulled.
    public static let maximumUpstreamAcceptances = 8
    public static let maximumAdmissionWaiters = 4
    public static let maximumDetachedHandshakeOperations = 8
    public static let maximumEndToEndConnections =
        maximumEstablishedConnections + maximumUpstreamAcceptances
    public static let maximumRetainedConnectionsAndOperations =
        maximumEndToEndConnections + maximumDetachedHandshakeOperations
        + maximumAdmissionWaiters
}

public enum IncomingTransferFailure: Equatable, Sendable {
    case receiveStore(ReceiveStoreError)
    case transferProtocol(TransferProtocolError)
    case other

    init(_ error: any Error) {
        if let error = error as? ReceiveStoreError {
            self = .receiveStore(error)
        } else if let error = error as? TransferProtocolError {
            self = .transferProtocol(error)
        } else {
            self = .other
        }
    }
}

/// Runs trusted inbound transfers through `ReceiveSession` and its hardened
/// `ReceiveStore` configuration. The listener owns no alternate staging path.
public actor IncomingTransferListener {
    private struct AdmittedConnection: Sendable {
        let connection: IncomingTransferConnection
        let permit: IncomingChannelCloseRegistry.Permit
    }

    private struct ActiveReceive {
        let transferID: TransferID
        let channel: any SecureChannel
        let permit: IncomingChannelCloseRegistry.Permit
        let resourceToken: BoundedChannelResourceRegistry.Token
        let task: Task<Void, Never>
    }

    private let sources: [any IncomingTransferConnectionSource]
    private let policy: ReceivePolicy
    private let directories: DownloadDirectory
    private let database: TransferDatabase
    private let incomingDirectory: URL?
    private let capacity: any ReceiveCapacityProviding
    private let inactivityTimeout: Duration
    private let onReceiveFinished: @Sendable (TransferReceiveResult?) async -> Void
    private let onReceiveFailed: @Sendable (TransferID, IncomingTransferFailure) async -> Void
    private let resources = BoundedChannelResourceRegistry.shared
    private let closeRegistry = IncomingChannelCloseRegistry.shared
    private let resourceOwner = UUID()

    private var readerTask: Task<Void, Never>?
    private var pending: [AdmittedConnection] = []
    private var active: [UUID: ActiveReceive] = [:]
    private var activeTransferIDs: Set<TransferID> = []
    private var schedulingWorker: Task<Void, Never>?
    private var stopped = false
    private var stopTask: Task<Void, Never>?

    public init(
        source: any IncomingTransferConnectionSource,
        policy: ReceivePolicy,
        directories: DownloadDirectory = DownloadDirectory(),
        database: TransferDatabase,
        incomingDirectory: URL? = nil,
        capacity: any ReceiveCapacityProviding = VolumeReceiveCapacityProvider(),
        inactivityTimeout: Duration = .seconds(30),
        onReceiveFinished: @escaping @Sendable (TransferReceiveResult?) async -> Void = { _ in },
        onReceiveFailed: @escaping @Sendable (TransferID, IncomingTransferFailure) async -> Void = { _, _ in }
    ) {
        self.init(sources: [source], policy: policy, directories: directories, database: database,
            incomingDirectory: incomingDirectory, capacity: capacity, inactivityTimeout: inactivityTimeout,
            onReceiveFinished: onReceiveFinished, onReceiveFailed: onReceiveFailed)
    }

    public init(
        sources: [any IncomingTransferConnectionSource],
        policy: ReceivePolicy,
        directories: DownloadDirectory = DownloadDirectory(),
        database: TransferDatabase,
        incomingDirectory: URL? = nil,
        capacity: any ReceiveCapacityProviding = VolumeReceiveCapacityProvider(),
        inactivityTimeout: Duration = .seconds(30),
        onReceiveFinished: @escaping @Sendable (TransferReceiveResult?) async -> Void = { _ in },
        onReceiveFailed: @escaping @Sendable (TransferID, IncomingTransferFailure) async -> Void = { _, _ in }
    ) {
        precondition((1...2).contains(sources.count), "One or two inbound planes are supported")
        self.sources = sources
        self.policy = policy
        self.directories = directories
        self.database = database
        self.incomingDirectory = incomingDirectory
        self.capacity = capacity
        self.inactivityTimeout = max(.milliseconds(1), inactivityTimeout)
        self.onReceiveFinished = onReceiveFinished
        self.onReceiveFailed = onReceiveFailed
    }

    deinit {
        readerTask?.cancel()
        schedulingWorker?.cancel()
        for receive in active.values { receive.task.cancel() }
    }

    public func start() {
        guard !stopped, readerTask == nil else { return }
        readerTask = Task { [weak self, sources, closeRegistry, resourceOwner, timeout = inactivityTimeout] in
            await withTaskGroup(of: Void.self) { group in
                for source in sources {
                    group.addTask { [weak self] in
                        do {
                            guard let initialPermit = await closeRegistry.acquire(owner: resourceOwner) else {
                                return
                            }
                            guard !Task.isCancelled else {
                                await closeRegistry.releaseUnused(initialPermit)
                                return
                            }
                            let connections = await source.connections()
                            var iterator = connections.makeAsyncIterator()
                            var permit: IncomingChannelCloseRegistry.Permit? = initialPermit
                            while let currentPermit = permit {
                                let connection: IncomingTransferConnection?
                                do {
                                    connection = try await iterator.next()
                                } catch {
                                    await closeRegistry.releaseUnused(currentPermit)
                                    throw error
                                }
                                guard let connection else {
                                    await closeRegistry.releaseUnused(currentPermit)
                                    break
                                }
                                guard !Task.isCancelled, let self else {
                                    await closeRegistry.close(
                                        connection.channel,
                                        permit: currentPermit,
                                        timeout: timeout
                                    )
                                    return
                                }
                                await self.enqueue(
                                    AdmittedConnection(connection: connection, permit: currentPermit)
                                )
                                guard !Task.isCancelled else { return }
                                permit = await closeRegistry.acquire(owner: resourceOwner)
                            }
                        } catch {
                            // This plane ending does not stop the other admitted reader.
                        }
                    }
                }
                await group.waitForAll()
            }
            await self?.sourceEnded()
        }
    }

    public func stop() async {
        if let stopTask { await stopTask.value; return }
        stopped = true
        let reader = readerTask
        readerTask?.cancel()
        readerTask = nil
        let scheduler = schedulingWorker
        schedulingWorker?.cancel()
        let queued = pending
        pending.removeAll()
        let receives = Array(active.values)
        active.removeAll()
        activeTransferIDs.removeAll()
        for receive in receives { receive.task.cancel() }
        let task = Task {
            // Start close before joining runners: close can unblock their I/O.
            for receive in receives {
                await resources.beginClose(receive.channel, token: receive.resourceToken,
                                           timeout: inactivityTimeout)
            }
            for connection in queued {
                await closeRegistry.close(connection.connection.channel, permit: connection.permit,
                                          timeout: inactivityTimeout)
            }
            await reader?.value
            await scheduler?.value
            for receive in receives { await receive.task.value }
            // Permits survive runner return until close and every detached I/O
            // operation return. Drain only this listener, not the shared pool.
            await closeRegistry.waitForDrain(owner: resourceOwner)
        }
        stopTask = task
        await task.value
    }

    private func enqueue(_ admitted: AdmittedConnection) async {
        let connection = admitted.connection
#if DEBUG
        print("DropMeshTransfer inbound stage=enqueued")
#endif
        guard !stopped,
            !activeTransferIDs.contains(connection.transferID),
            !pending.contains(where: { $0.connection.transferID == connection.transferID })
        else {
            await closeRejected(admitted)
            return
        }
        guard pending.count < IncomingTransferCapacity.maximumQueuedConnections else {
            await closeRejected(admitted)
            return
        }
        pending.append(admitted)
        schedule()
    }

    private func schedule() {
        guard !stopped, schedulingWorker == nil else { return }
        schedulingWorker = Task { [weak self] in
            await self?.drainSchedule()
        }
    }

    private func drainSchedule() async {
        defer { schedulingWorker = nil }
        while !stopped, active.count < IncomingTransferCapacity.maximumActiveTransfers, !pending.isEmpty {
            let admitted = pending.removeFirst()
            let connection = admitted.connection
            let permit = admitted.permit
            // Keep the identity reserved while waiting for a process-wide slot;
            // the other plane must not enqueue it in this suspension window.
            activeTransferIDs.insert(connection.transferID)
            let resourceToken = await resources.reserveWhenAvailable(
                .inbound,
                onReleased: { [weak self, closeRegistry, permit] in
                    await closeRegistry.activeResourceReleased(permit)
                    await self?.resourceCapacityReleased()
                }
            )
            guard let resourceToken else {
                activeTransferIDs.remove(connection.transferID)
                await closeRegistry.close(
                    connection.channel,
                    permit: permit,
                    timeout: inactivityTimeout
                )
                continue
            }
            guard !stopped else {
                await resources.beginClose(
                    connection.channel,
                    token: resourceToken,
                    timeout: inactivityTimeout
                )
                await resources.runnerReturned(resourceToken)
                continue
            }
            let token = UUID()
            let timeout = inactivityTimeout
            let task = Task { [weak self, resources] in
                guard let self else {
                    await resources.beginClose(
                        connection.channel,
                        token: resourceToken,
                        timeout: timeout
                    )
                    await resources.runnerReturned(resourceToken)
                    return
                }
                await self.receive(
                    connection,
                    token: token,
                    resourceToken: resourceToken
                )
                await self.receiveRunnerReturned(resourceToken)
            }
            active[token] = ActiveReceive(
                transferID: connection.transferID,
                channel: connection.channel,
                permit: permit,
                resourceToken: resourceToken,
                task: task
            )
        }
    }

    private func receive(
        _ connection: IncomingTransferConnection,
        token: UUID,
        resourceToken: BoundedChannelResourceRegistry.Token
    ) async {
        defer { receiveFinished(token) }
        do {
#if DEBUG
            print("DropMeshTransfer inbound stage=receiving")
#endif
            let result = try await ReceiveSession(
                transferID: connection.transferID,
                source: connection.source,
                policy: policy,
                directories: directories,
                database: database,
                incomingDirectory: incomingDirectory,
                capacity: capacity,
                initialOfferTimeout: inactivityTimeout,
                inactivityTimeout: inactivityTimeout,
                closeChannelOnExit: false,
                resourceOwnership: TransferIOResourceOwnership(
                    registry: resources,
                    token: resourceToken
                )
            ).run(on: connection.channel)
#if DEBUG
            print("DropMeshTransfer inbound stage=completed")
#endif
            await onReceiveFinished(result)
        } catch {
#if DEBUG
            print("DropMeshTransfer inbound stage=failed category=\(String(describing: IncomingTransferFailure(error)))")
#endif
            await onReceiveFinished(nil)
            await onReceiveFailed(connection.transferID, IncomingTransferFailure(error))
        }
    }

    private func receiveFinished(_ token: UUID) {
        guard let finished = active.removeValue(forKey: token) else { return }
        activeTransferIDs.remove(finished.transferID)
        // Release the logical receive slot before initiating bounded close. The
        // global resource token remains occupied until both close and the
        // ReceiveSession runner have actually returned.
        Task { [resources, timeout = inactivityTimeout] in
            await resources.beginClose(
                finished.channel,
                token: finished.resourceToken,
                timeout: timeout
            )
        }
        schedule()
    }

    private func receiveRunnerReturned(_ token: BoundedChannelResourceRegistry.Token) async {
        await resources.runnerReturned(token)
    }

    private func resourceCapacityReleased() {
        schedule()
    }

    private func closeRejected(_ admitted: AdmittedConnection) async {
        await closeRegistry.close(
            admitted.connection.channel,
            permit: admitted.permit,
            timeout: inactivityTimeout
        )
    }

    func retainedResourceCount() async -> Int {
        let counts = await resources.counts()
        return counts.inbound
    }

    func activeReceiveCount() -> Int { active.count }
    func queuedConnectionCount() -> Int { pending.count }

    private func sourceEnded() {
        readerTask = nil
    }
}
