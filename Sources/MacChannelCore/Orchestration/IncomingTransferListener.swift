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
    /// rejected by that stream. Production uses a zero-element handoff buffer;
    /// the listener itself owns the 34 established-channel capacity below.
    func connections() async -> AsyncThrowingStream<IncomingTransferConnection, Error>
}

public enum IncomingTransferCapacity {
    public static let maximumActiveTransfers = 2
    public static let maximumQueuedConnections = 32
    public static let maximumEstablishedConnections =
        maximumActiveTransfers + maximumQueuedConnections

    // WebRTC can additionally have eight authenticated acceptances in flight,
    // but retains no second established-channel queue before this listener.
    public static let maximumUpstreamAcceptances = 8
    public static let maximumDetachedHandshakeOperations = 8
    public static let maximumEndToEndConnections =
        maximumEstablishedConnections + maximumUpstreamAcceptances
    public static let maximumRetainedConnectionsAndOperations =
        maximumEndToEndConnections + maximumDetachedHandshakeOperations
}

/// Runs trusted inbound transfers through `ReceiveSession` and its hardened
/// `ReceiveStore` configuration. The listener owns no alternate staging path.
public actor IncomingTransferListener {
    private struct ActiveReceive {
        let transferID: TransferID
        let channel: any SecureChannel
        let resourceToken: BoundedChannelResourceRegistry.Token
        let task: Task<Void, Never>
    }

    private let source: any IncomingTransferConnectionSource
    private let policy: ReceivePolicy
    private let directories: DownloadDirectory
    private let database: TransferDatabase
    private let incomingDirectory: URL?
    private let capacity: any ReceiveCapacityProviding
    private let inactivityTimeout: Duration
    private let resources = BoundedChannelResourceRegistry.shared

    private var readerTask: Task<Void, Never>?
    private var pending: [IncomingTransferConnection] = []
    private var active: [UUID: ActiveReceive] = [:]
    private var activeTransferIDs: Set<TransferID> = []
    private var schedulingWorker: Task<Void, Never>?
    private var closingBacklog: [any SecureChannel] = []
    private var closingBacklogWorker: Task<Void, Never>?
    private var stopped = false

    public init(
        source: any IncomingTransferConnectionSource,
        policy: ReceivePolicy,
        directories: DownloadDirectory = DownloadDirectory(),
        database: TransferDatabase,
        incomingDirectory: URL? = nil,
        capacity: any ReceiveCapacityProviding = VolumeReceiveCapacityProvider(),
        inactivityTimeout: Duration = .seconds(30)
    ) {
        self.source = source
        self.policy = policy
        self.directories = directories
        self.database = database
        self.incomingDirectory = incomingDirectory
        self.capacity = capacity
        self.inactivityTimeout = max(.milliseconds(1), inactivityTimeout)
    }

    deinit {
        readerTask?.cancel()
        schedulingWorker?.cancel()
        closingBacklogWorker?.cancel()
        for receive in active.values { receive.task.cancel() }
    }

    public func start() {
        guard !stopped, readerTask == nil else { return }
        readerTask = Task { [weak self, source] in
            do {
                let connections = await source.connections()
                for try await connection in connections {
                    guard !Task.isCancelled, let self else {
                        await connection.channel.close()
                        return
                    }
                    await self.enqueue(connection)
                }
            } catch {
                await self?.sourceEnded()
            }
        }
    }

    public func stop() async {
        guard !stopped else { return }
        stopped = true
        readerTask?.cancel()
        readerTask = nil
        let queued = pending
        pending.removeAll()
        let receives = Array(active.values)
        active.removeAll()
        activeTransferIDs.removeAll()
        for receive in receives { receive.task.cancel() }
        closingBacklog.append(contentsOf: queued.map(\.channel))
        for receive in receives {
            await resources.beginClose(
                receive.channel,
                token: receive.resourceToken,
                timeout: inactivityTimeout
            )
        }
        drainClosingBacklog()
    }

    private func enqueue(_ connection: IncomingTransferConnection) async {
        guard !stopped,
            !activeTransferIDs.contains(connection.transferID),
            !pending.contains(where: { $0.transferID == connection.transferID })
        else {
            await closeRejected(connection.channel)
            return
        }
        guard pending.count < IncomingTransferCapacity.maximumQueuedConnections else {
            await closeRejected(connection.channel)
            return
        }
        pending.append(connection)
        schedule()
    }

    private func schedule() {
        guard schedulingWorker == nil else { return }
        schedulingWorker = Task { [weak self] in
            await self?.drainSchedule()
        }
    }

    private func drainSchedule() async {
        defer { schedulingWorker = nil }
        while active.count < IncomingTransferCapacity.maximumActiveTransfers, !pending.isEmpty {
            guard let resourceToken = await resources.reserve(.inbound, onReleased: {
                [weak self] in
                await self?.resourceCapacityReleased()
            }) else { return }
            guard !pending.isEmpty else {
                await resources.finishWithoutClose(resourceToken)
                continue
            }
            let connection = pending.removeFirst()
            guard !stopped else {
                closingBacklog.append(connection.channel)
                await resources.finishWithoutClose(resourceToken)
                drainClosingBacklog()
                continue
            }
            let token = UUID()
            activeTransferIDs.insert(connection.transferID)
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
            _ = try await ReceiveSession(
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
        } catch {}
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
        drainClosingBacklog()
    }

    private func closeRejected(_ channel: any SecureChannel) async {
        while !Task.isCancelled {
            if let token = await resources.reserve(.inbound, onReleased: { [weak self] in
                await self?.resourceCapacityReleased()
            }) {
                await resources.beginClose(channel, token: token, timeout: inactivityTimeout)
                await resources.runnerReturned(token)
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        closingBacklog.append(channel)
        drainClosingBacklog()
    }

    private func drainClosingBacklog() {
        guard closingBacklogWorker == nil, !closingBacklog.isEmpty else { return }
        closingBacklogWorker = Task { [weak self] in
            await self?.drainClosures()
        }
    }

    private func drainClosures() async {
        defer { closingBacklogWorker = nil }
        while !closingBacklog.isEmpty {
            guard let token = await resources.reserve(.inbound, onReleased: { [weak self] in
                await self?.resourceCapacityReleased()
            }) else { return }
            let channel = closingBacklog.removeFirst()
            await resources.beginClose(channel, token: token, timeout: inactivityTimeout)
            await resources.runnerReturned(token)
        }
    }

    func retainedResourceCount() async -> Int {
        let counts = await resources.counts()
        return counts.inbound
    }

    private func sourceEnded() {
        readerTask = nil
    }
}
