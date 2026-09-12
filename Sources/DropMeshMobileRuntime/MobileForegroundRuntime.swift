import Foundation
import MacChannelCore

public enum MobileRuntimeState: Equatable, Sendable {
    case inactive, starting, online, reconnecting, stopping
    case failed(MobileRuntimeFailure)
}

public enum MobileRuntimeFailure: Error, Equatable, Sendable {
    case storage, authentication, network, receive, trustPersistence
}

public enum MobileRuntimeError: Error, Equatable, Sendable {
    case notForeground, notReady, interrupted, sendFailed
}

public struct MobileRuntimeSnapshot: Sendable {
    public let state: MobileRuntimeState
    public let foregroundRequested: Bool
    public let devices: [DeviceSummary]
    public let transfers: [TransferSnapshot]
    /// Bounded process-session completions, not durable history.
    public let received: [TransferReceiveResult]
    public let localNetworkAvailable: Bool
    public let failure: MobileRuntimeFailure?
    public let historyAvailabilityFailure: MobileHistoryAvailabilityFailure?
}

/// Retain exactly one owner after identity bootstrap for the application process.
/// Background interrupts transfers; cancellation never promises remote rollback.
public actor MobileForegroundRuntime {
    typealias NetworkFactory = @Sendable (
        DeviceDirectory,
        @escaping @Sendable (MobilePresenceState) async -> Void,
        @escaping @Sendable (Bool) async -> Void
    ) async throws -> any MobileForegroundNetwork

    private struct SendOperation {
        let epoch: UInt64
        let cancellation: MobileSendCancellation
        let worker: Task<TransferID, Error>
    }

    private let identity: DeviceIdentity
    private let repository: TrustRepository
    private let layout: MobileStorageLayout
    // Neither database nor coordinator is replaced or closed at scene changes.
    private let database: TransferDatabase
    private let transferHistory: MobileTransferHistory
    private var historyAvailabilityFailure: MobileHistoryAvailabilityFailure?
    private let persistence: any TransferSnapshotPersistence
    private let persistTrust: @Sendable () async throws -> Void
    private let makeNetwork: NetworkFactory
    private let onRestored: @Sendable (TransferCoordinator) async -> Void
    private let beforeSendAccounting: @Sendable () async -> Void
    private let connector = MobileForegroundConnector()
    private let directory = DeviceDirectory(trust: DeviceTrust(trustedIDs: []))
    private var coordinator: TransferCoordinator?
    private var transferObserver: Task<Void, Never>?
    private var directoryObserver: Task<Void, Never>?
    private var trustObserver: Task<Void, Never>?
    private var desiredForeground = false
    private var acceptingSends = false
    private var epoch: UInt64 = 0
    private var graphEpoch: UInt64?
    private var network: (any MobileForegroundNetwork)?
    private var networkDrain: Task<Void, Never>?
    private var incoming: IncomingTransferListener?
    private var incomingDrain: Task<Void, Never>?
    private var incomingPolicy: Set<DeviceID>?
    private var transition: Task<Void, Never>?
    private var trustRevision: UInt64 = 0
    private var handledTrustRevision: UInt64 = 0
    private var discoveryEnabled = false
    private var handledDiscoveryEnabled = false
    private var operations: [UUID: SendOperation] = [:]
    private var state: MobileRuntimeState = .inactive
    private var devices: [DeviceSummary] = []
    private var transfers: [TransferSnapshot] = []
    private var received: [TransferReceiveResult] = []
    private var localAvailable = false
    private var failure: MobileRuntimeFailure?
    private var subscribers: [UUID: AsyncStream<MobileRuntimeSnapshot>.Continuation] = [:]

    public init<Secrets: SecretStore & Sendable>(context: MobileIdentityContext<Secrets>) throws {
        identity = context.identity
        repository = context.repository
        layout = context.layout
        do { database = try TransferDatabase(url: context.layout.transferDatabaseFile) }
        catch { throw MobileRuntimeFailure.storage }
        let outputs = MobileReceivedOutputIndex(url: context.layout.receivedOutputIndexFile,
            receiveDirectory: context.layout.receiveDirectory, database: database)
        transferHistory = MobileTransferHistory(database: database, outputs: outputs)
        historyAvailabilityFailure = outputs.initialAvailabilityFailure
        persistence = database
        persistTrust = { try await context.persistTrust() }
        let identity = context.identity
        let repository = context.repository
        makeNetwork = { directory, state, discovery in
            try MobileProductionForegroundNetwork(identity: identity, repository: repository,
                directory: directory, onState: state, onDiscovery: discovery)
        }
        onRestored = { _ in }
        beforeSendAccounting = { }
    }

    init(identity: DeviceIdentity, repository: TrustRepository, layout: MobileStorageLayout,
         database: TransferDatabase, persistence: any TransferSnapshotPersistence,
         persistTrust: @escaping @Sendable () async throws -> Void,
         makeNetwork: @escaping NetworkFactory,
         onRestored: @escaping @Sendable (TransferCoordinator) async -> Void = { _ in },
         beforeSendAccounting: @escaping @Sendable () async -> Void = { }) {
        self.identity = identity; self.repository = repository; self.layout = layout
        self.database = database; self.persistence = persistence; self.persistTrust = persistTrust
        let outputs = MobileReceivedOutputIndex(url: layout.receivedOutputIndexFile,
            receiveDirectory: layout.receiveDirectory, database: database)
        transferHistory = MobileTransferHistory(database: database, outputs: outputs)
        historyAvailabilityFailure = outputs.initialAvailabilityFailure
        self.makeNetwork = makeNetwork; self.onRestored = onRestored
        self.beforeSendAccounting = beforeSendAccounting
    }

    public func currentSnapshot() -> MobileRuntimeSnapshot {
        MobileRuntimeSnapshot(state: state, foregroundRequested: desiredForeground, devices: devices, transfers: transfers,
            received: received, localNetworkAvailable: localAvailable, failure: failure,
            historyAvailabilityFailure: historyAvailabilityFailure)
    }

    public func history(limit: Int = 100) async throws -> [MobileTransferHistoryItem] {
        let items = try await transferHistory.items(limit: limit)
        await refreshHistoryAvailabilityFailure()
        return items
    }

    /// Resolve immediately before presenting an open/share action.
    public func availableReceivedURL(for transferID: TransferID) async -> URL? {
        let url = await transferHistory.availableURL(for: transferID)
        await refreshHistoryAvailabilityFailure()
        return url
    }

    deinit {
        transferObserver?.cancel()
        directoryObserver?.cancel()
        trustObserver?.cancel()
        subscribers.values.forEach { $0.finish() }
    }

    public func snapshots() -> AsyncStream<MobileRuntimeSnapshot> {
        let token = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            subscribers[token] = continuation
            continuation.yield(currentSnapshot())
            continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(token) } }
        }
    }

    public func startForeground() async throws {
        desiredForeground = true
        publish()
        let requestedEpoch = epoch
        await reconcileTask().value
        guard desiredForeground, requestedEpoch == epoch else { throw MobileRuntimeError.interrupted }
        if case let .failed(reason) = state { throw reason }
    }

    public func stopForeground() async {
        // Admission and epoch retirement happen before the first suspension.
        desiredForeground = false
        acceptingSends = false
        epoch &+= 1
        state = .stopping
        localAvailable = false
        publish()
        // Initiate all graph shutdown even when transition is joining a policy drain.
        beginNetworkDrain()
        beginIncomingDrain()
        await reconcileTask().value
    }

    public func retryConnection() async {
        guard desiredForeground else { return }
        guard let network else { await reconcileTask().value; return }
        guard graphEpoch == epoch else { return }
        await network.retryConnection()
    }

    public func refreshTrust() async throws {
        trustRevision &+= 1
        await reconcileTask().value
        if failure == .trustPersistence { throw MobileRuntimeFailure.trustPersistence }
    }

    public func setLocalDiscoveryEnabled(_ enabled: Bool) async {
        discoveryEnabled = enabled
        if !enabled { localAvailable = false; publish() }
        await reconcileTask().value
    }

    public func send(items: [URL], to device: DeviceID) async throws -> TransferID {
        try Task.checkCancellation()
        guard desiredForeground, acceptingSends else { throw MobileRuntimeError.notForeground }
        guard let coordinator else { throw MobileRuntimeError.notReady }
        let token = UUID()
        let admittedEpoch = epoch
        let cancellation = MobileSendCancellation()
        // An unstructured worker owns packaging through accounting independently
        // of its UI waiter. Its record is installed in this actor turn.
        let worker = Task<TransferID, Error> {
            let result: Result<TransferID, Error>
            do { result = .success(try await coordinator.send(items: items, to: device)) }
            catch { result = .failure(error) }
            await beforeSendAccounting()
            return try await accountSend(token, result: result)
        }
        operations[token] = SendOperation(epoch: admittedEpoch, cancellation: cancellation, worker: worker)
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            // The lock defines cancellation's linearization against finalization.
            cancellation.cancel()
        }
    }

    public func pause(_ id: TransferID) async throws {
        guard let coordinator else { throw MobileRuntimeError.notReady }
        do { try await coordinator.pause(id) } catch { throw MobileRuntimeError.interrupted }
    }

    public func resume(_ id: TransferID) async throws {
        guard acceptingSends, let coordinator else { throw MobileRuntimeError.notForeground }
        do { try await coordinator.resume(id) } catch { throw MobileRuntimeError.interrupted }
    }

    public func cancel(_ id: TransferID) async -> TransferCancellationResult {
        guard let coordinator else { return .tooLate }
        return await coordinator.cancel(id)
    }

    private func accountSend(_ token: UUID, result: Result<TransferID, Error>) async throws -> TransferID {
        guard let operation = operations[token] else { throw MobileRuntimeError.interrupted }
        // Keep the record while cancellation crosses the coordinator actor.
        let interrupted = operation.epoch != epoch || !desiredForeground
        let cancelled = operation.cancellation.finish()
        if case let .success(id) = result, interrupted || cancelled {
            _ = await coordinator?.cancel(id)
        }
        operations[token] = nil
        if cancelled { throw CancellationError() }
        if interrupted { throw MobileRuntimeError.interrupted }
        switch result {
        case let .success(id): return id
        case .failure: throw MobileRuntimeError.sendFailed
        }
    }

    private func reconcileTask() -> Task<Void, Never> {
        if let transition { return transition }
        let task = Task { await self.reconcile() }
        transition = task
        return task
    }

    private func reconcile() async {
        defer { transition = nil }
        while true {
            if network != nil, !desiredForeground || graphEpoch != epoch {
                await drainForeground()
                continue
            }
            if !desiredForeground {
                // Hidden sends may be the sole remaining owners after graph drain.
                await connector.disable()
                await cancelDurableTransfers()
                await accountOutstandingSends()
                if desiredForeground { continue }
                if handledTrustRevision != trustRevision { await updateTrust(); continue }
                state = .inactive; publish(); return
            }
            if network == nil {
                await accountOutstandingSends()
                guard desiredForeground else { continue }
                let generation = epoch
                state = .starting; failure = nil; publish()
                do {
                    await startObserversIfNeeded()
                    guard desiredForeground, generation == epoch else { continue }
                    let graph = try await makeNetwork(directory,
                        { [weak self] in await self?.presenceChanged($0, generation: generation) },
                        { [weak self] in await self?.discoveryChanged($0, generation: generation) })
                    network = graph; graphEpoch = generation
                    guard desiredForeground, generation == epoch else { continue }
                    await connector.install(graph.connector)
                    guard desiredForeground, generation == epoch else { continue }
                    if coordinator == nil {
                        do {
                            coordinator = try await TransferCoordinator.restoring(connector: connector,
                                database: persistence, outgoingDirectory: layout.stateDirectory.appendingPathComponent("outgoing"))
                        } catch { throw MobileRuntimeFailure.storage }
                        let owner = coordinator!
                        await onRestored(owner)
                        let stream = await owner.snapshots()
                        transferObserver = Task { [weak self] in
                            for await value in stream {
                                guard !Task.isCancelled else { return }
                                await self?.transfersChanged(value)
                            }
                        }
                    }
                    guard desiredForeground, generation == epoch else { continue }
                    trustRevision &+= 1
                    await updateTrust()
                    guard desiredForeground, generation == epoch else { continue }
                    await graph.start()
                    guard desiredForeground, generation == epoch else { continue }
                    acceptingSends = true
                    let discovery = discoveryEnabled
                    await graph.setLocalDiscoveryEnabled(discovery)
                    handledDiscoveryEnabled = discovery
                } catch {
                    failure = (error as? MobileRuntimeFailure) ?? .network
                    // Failed construction drains any partially installed graph.
                    acceptingSends = false
                    await drainForeground()
                    if generation != epoch { continue }
                    state = .failed(failure ?? .network); publish(); return
                }
                continue
            }
            if handledTrustRevision != trustRevision { await updateTrust(); continue }
            if handledDiscoveryEnabled != discoveryEnabled, let network {
                let value = discoveryEnabled
                await network.setLocalDiscoveryEnabled(value)
                handledDiscoveryEnabled = value
                continue
            }
            return
        }
    }

    private func startObserversIfNeeded() async {
        guard directoryObserver == nil else { return }
        await directory.observeTrust(repository)
        let devices = await directory.devices()
        directoryObserver = Task { [weak self] in
            for await value in devices {
                guard !Task.isCancelled else { return }
                await self?.devicesChanged(value)
            }
        }
        let updates = await repository.updates()
        trustObserver = Task { [weak self] in
            var initial = true
            for await _ in updates {
                guard !Task.isCancelled else { return }
                if initial { initial = false; continue }
                await self?.trustChanged()
            }
        }
    }

    private func updateTrust() async {
        let revision = trustRevision
        do { try await persistTrust(); if failure == .trustPersistence { failure = nil } }
        catch { failure = .trustPersistence; publish() }
        await directory.waitForTrustUpdates()
        if let graph = network, desiredForeground, graphEpoch == epoch {
            // Re-read after the old immutable-policy owner actually drains.
            let latest = await repository.currentTrustStore().trustedDeviceIDs.subtracting([identity.id])
            if incomingPolicy != latest {
                beginIncomingDrain()
                await incomingDrain?.value
                incoming = nil; incomingDrain = nil; incomingPolicy = nil
                guard desiredForeground, graphEpoch == epoch else { handledTrustRevision = revision; return }
                let trusted = await repository.currentTrustStore().trustedDeviceIDs.subtracting([identity.id])
                guard desiredForeground, let generation = graphEpoch, generation == epoch else { handledTrustRevision = revision; return }
                let listener = IncomingTransferListener(source: graph.source,
                    policy: ReceivePolicy(trustedSources: trusted, defaultAutoAccept: true),
                    directories: DownloadDirectory(globalDirectory: layout.receiveDirectory), database: database,
                    incomingDirectory: layout.stateDirectory.appendingPathComponent("incoming", isDirectory: true),
                    onReceiveFinished: { [weak self] result in await self?.receiveFinished(result, generation: generation) },
                    onReceiveFailed: { [weak self] _, _ in await self?.receiveFailed(generation: generation) })
                incoming = listener; incomingPolicy = trusted
                await listener.start()
            }
            if desiredForeground, graphEpoch == epoch { await graph.refreshTrust() }
        }
        handledTrustRevision = revision
    }

    private func beginNetworkDrain() {
        guard networkDrain == nil, let network else { return }
        // Disable before graph cleanup; each graph starts every close before joining.
        networkDrain = Task { [connector] in
            await connector.disable()
            await network.stop()
        }
    }

    private func beginIncomingDrain() {
        guard incomingDrain == nil, let incoming else { return }
        incomingDrain = Task { await incoming.stop() }
    }

    private func drainForeground() async {
        acceptingSends = false; state = .stopping; localAvailable = false; publish()
        await connector.disable()
        beginNetworkDrain()
        // Incoming stop is initiated before joining either network or send workers.
        beginIncomingDrain()
        await cancelDurableTransfers()
        await incomingDrain?.value
        await networkDrain?.value
        incoming = nil; incomingDrain = nil; incomingPolicy = nil
        network = nil; networkDrain = nil; graphEpoch = nil
        handledDiscoveryEnabled = false
        await accountOutstandingSends()
        do { try await persistTrust() } catch { failure = .trustPersistence }
    }

    private func cancelDurableTransfers() async {
        guard let coordinator else { return }
        // A fresh stream's first value is synchronously captured in core, unlike
        // the asynchronously delivered UI cache. Hidden IDs are covered below.
        var iterator = await coordinator.snapshots().makeAsyncIterator()
        for snapshot in await iterator.next() ?? [] {
            switch snapshot.phase {
            case .completed, .cancelled, .failed: break
            default: _ = await coordinator.cancel(snapshot.id)
            }
        }
    }

    private func accountOutstandingSends() async {
        // Admission stays closed, so no new worker can appear during this barrier.
        for operation in Array(operations.values) { _ = try? await operation.worker.value }
    }

    private func presenceChanged(_ value: MobilePresenceState, generation: UInt64) {
        guard desiredForeground, graphEpoch == generation, epoch == generation else { return }
        switch value {
        case .online: state = .online
        case .connecting: state = .starting
        case .reconnecting: state = .reconnecting
        default: break
        }
        publish()
    }
    private func discoveryChanged(_ value: Bool, generation: UInt64) {
        guard desiredForeground, discoveryEnabled, graphEpoch == generation, epoch == generation else { return }
        localAvailable = value; publish()
    }
    private func receiveFinished(_ result: TransferReceiveResult?, generation: UInt64) async {
        // A genuine publication which won the stop race is still a real completion.
        guard graphEpoch == generation, let result, !result.receivedURLs.isEmpty else { return }
        // IncomingTransferListener retains its runner through this awaited call;
        // stop/re-entry therefore cannot retire this graph before indexing ends.
        await transferHistory.recordCompletedReceive(result)
        historyAvailabilityFailure = await transferHistory.availabilityFailure
        guard graphEpoch == generation else { return }
        received.append(result)
        if received.count > 200 { received.removeFirst(received.count - 200) }
        publish()
    }
    private func receiveFailed(generation: UInt64) {
        guard desiredForeground, graphEpoch == generation, epoch == generation else { return }
        failure = .receive; publish()
    }
    private func transfersChanged(_ value: [TransferSnapshot]) { transfers = value; publish() }
    private func devicesChanged(_ value: [DeviceSummary]) { devices = value.filter { $0.id != identity.id }; publish() }
    private func trustChanged() { trustRevision &+= 1; _ = reconcileTask() }
    private func unsubscribe(_ token: UUID) { subscribers[token] = nil }
    private func publish() { let value = currentSnapshot(); subscribers.values.forEach { $0.yield(value) } }

    private func refreshHistoryAvailabilityFailure() async {
        let updated = await transferHistory.availabilityFailure
        guard updated != historyAvailabilityFailure else { return }
        historyAvailabilityFailure = updated
        publish()
    }
}

/// Cancellation wins only if recorded before finalization takes this lock.
private final class MobileSendCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var finished = false
    func cancel() { lock.lock(); defer { lock.unlock() }; if !finished { cancelled = true } }
    func finish() -> Bool { lock.lock(); defer { lock.unlock() }; finished = true; return cancelled }
}
