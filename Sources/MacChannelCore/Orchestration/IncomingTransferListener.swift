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
    func connections() async -> AsyncThrowingStream<IncomingTransferConnection, Error>
}

/// Runs trusted inbound transfers through `ReceiveSession` and its hardened
/// `ReceiveStore` configuration. The listener owns no alternate staging path.
public actor IncomingTransferListener {
    private struct ActiveReceive {
        let transferID: TransferID
        let channel: any SecureChannel
        let task: Task<Void, Never>
    }

    private static let maximumConcurrentTransfers = 2
    private static let maximumQueuedConnections = 32

    private let source: any IncomingTransferConnectionSource
    private let policy: ReceivePolicy
    private let directories: DownloadDirectory
    private let database: TransferDatabase
    private let incomingDirectory: URL?
    private let capacity: any ReceiveCapacityProviding

    private var readerTask: Task<Void, Never>?
    private var pending: [IncomingTransferConnection] = []
    private var active: [UUID: ActiveReceive] = [:]
    private var activeTransferIDs: Set<TransferID> = []
    private var stopped = false

    public init(
        source: any IncomingTransferConnectionSource,
        policy: ReceivePolicy,
        directories: DownloadDirectory = DownloadDirectory(),
        database: TransferDatabase,
        incomingDirectory: URL? = nil,
        capacity: any ReceiveCapacityProviding = VolumeReceiveCapacityProvider()
    ) {
        self.source = source
        self.policy = policy
        self.directories = directories
        self.database = database
        self.incomingDirectory = incomingDirectory
        self.capacity = capacity
    }

    deinit {
        readerTask?.cancel()
        for receive in active.values { receive.task.cancel() }
    }

    public func start() {
        guard !stopped, readerTask == nil else { return }
        readerTask = Task { [weak self, source] in
            do {
                let connections = await source.connections()
                for try await connection in connections {
                    guard !Task.isCancelled else { return }
                    await self?.enqueue(connection)
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
        for connection in queued { await connection.channel.close() }
        for receive in receives { await receive.channel.close() }
        for receive in receives { await receive.task.value }
    }

    private func enqueue(_ connection: IncomingTransferConnection) async {
        guard !stopped,
            !activeTransferIDs.contains(connection.transferID),
            !pending.contains(where: { $0.transferID == connection.transferID })
        else {
            await connection.channel.close()
            return
        }
        guard pending.count < Self.maximumQueuedConnections else {
            await connection.channel.close()
            return
        }
        pending.append(connection)
        schedule()
    }

    private func schedule() {
        while active.count < Self.maximumConcurrentTransfers, !pending.isEmpty {
            let connection = pending.removeFirst()
            let token = UUID()
            activeTransferIDs.insert(connection.transferID)
            let task = Task { [weak self] in
                guard let self else { return }
                await self.receive(connection, token: token)
            }
            active[token] = ActiveReceive(
                transferID: connection.transferID,
                channel: connection.channel,
                task: task
            )
        }
    }

    private func receive(_ connection: IncomingTransferConnection, token: UUID) async {
        do {
            _ = try await ReceiveSession(
                transferID: connection.transferID,
                source: connection.source,
                policy: policy,
                directories: directories,
                database: database,
                incomingDirectory: incomingDirectory,
                capacity: capacity
            ).run(on: connection.channel)
        } catch {
            await connection.channel.close()
        }
        receiveFinished(token)
    }

    private func receiveFinished(_ token: UUID) {
        guard let finished = active.removeValue(forKey: token) else { return }
        activeTransferIDs.remove(finished.transferID)
        schedule()
    }

    private func sourceEnded() {
        readerTask = nil
    }
}
