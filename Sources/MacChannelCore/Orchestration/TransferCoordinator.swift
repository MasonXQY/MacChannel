import Foundation

public actor TransferCoordinator: TransferCoordinating {
    private struct PersistenceIntent: Sendable {
        let epoch: UInt64
        let snapshot: TransferSnapshot
        let isProgress: Bool
        let completion: PersistenceCompletion
    }

    private struct TransferTask {
        let package: OutgoingTransferPackage
        let peer: DeviceID
        let displayFilename: String
        let totalBytes: Int64
        let control: TransferSessionControl
        var desiredSnapshot: TransferSnapshot
        var durableSnapshot: TransferSnapshot?
        var operationEpoch: UInt64
        var persistenceQueue: [PersistenceIntent]
        var persistenceWorker: Task<Void, Never>?
        var packageCleanupWorker: Task<Void, Never>?
        var runner: Task<Void, Never>?
        var runnerToken: UUID?
        var completedSession: Bool
        var completionClaimed: Bool
        var resourceToken: BoundedChannelResourceRegistry.Token?
        var resourceHasChannel: Bool
        var channel: (any SecureChannel)?
    }

    private struct ConflictPackageCleanup {
        let package: OutgoingTransferPackage
        var worker: Task<Void, Never>?
    }

    private static let maximumConcurrentTransfers = 2
    private static let maximumQueuedTransfers = 200
    private static let maximumPublishedTerminalSnapshots = 200

    private let connector: any PeerConnector
    private let persistence: any TransferSnapshotPersistence
    private let outgoingDirectory: URL
    private let maximumConnectionAttempts: Int
    private let persistenceRetryDelay: Duration
    private let cancellationWatchdogDelay: Duration
    private let connectionAttempts = ConnectionAttemptRegistry()
    private let resources = BoundedChannelResourceRegistry.shared
    private var transfers: [TransferID: TransferTask] = [:]
    private var finishedSnapshots: [TransferSnapshot] = []
    private var pending: [TransferID] = []
    private var active: Set<TransferID> = []
    private var detachedRunners: [UUID: Task<Void, Never>] = [:]
    private var conflictPackageCleanups: [TransferID: ConflictPackageCleanup] = [:]
    private var schedulingWorker: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<[TransferSnapshot]>.Continuation] = [:]
    private var shuttingDown = false

    public init(
        connector: any PeerConnector,
        database: any TransferSnapshotPersistence,
        outgoingDirectory: URL? = nil,
        maximumConnectionAttempts: Int = 3,
        persistenceRetryDelay: Duration = .milliseconds(100),
        cancellationWatchdogDelay: Duration = .seconds(1)
    ) {
        self.connector = connector
        persistence = database
        self.outgoingDirectory = (outgoingDirectory ?? OutgoingTransferPackage.defaultDirectory())
            .standardizedFileURL
        self.maximumConnectionAttempts = max(1, maximumConnectionAttempts)
        self.persistenceRetryDelay = max(.milliseconds(1), persistenceRetryDelay)
        self.cancellationWatchdogDelay = max(.milliseconds(1), cancellationWatchdogDelay)
    }

    /// Reopens private immutable outgoing packages and resumes every runnable
    /// nonterminal task with its original TransferID. Paused tasks remain paused
    /// until the user explicitly resumes them.
    public static func restoring(
        connector: any PeerConnector,
        database: any TransferSnapshotPersistence,
        outgoingDirectory: URL? = nil,
        maximumConnectionAttempts: Int = 3,
        persistenceRetryDelay: Duration = .milliseconds(100),
        cancellationWatchdogDelay: Duration = .seconds(1)
    ) async throws -> TransferCoordinator {
        let coordinator = TransferCoordinator(
            connector: connector,
            database: database,
            outgoingDirectory: outgoingDirectory,
            maximumConnectionAttempts: maximumConnectionAttempts,
            persistenceRetryDelay: persistenceRetryDelay,
            cancellationWatchdogDelay: cancellationWatchdogDelay
        )
        try await coordinator.restoreHistory()
        return coordinator
    }

    deinit {
        for transfer in transfers.values {
            transfer.runner?.cancel()
            transfer.persistenceWorker?.cancel()
            transfer.packageCleanupWorker?.cancel()
        }
        for runner in detachedRunners.values { runner.cancel() }
        for cleanup in conflictPackageCleanups.values { cleanup.worker?.cancel() }
        schedulingWorker?.cancel()
        for subscriber in subscribers.values { subscriber.finish() }
        let attempts = connectionAttempts
        Task { await attempts.cancelAll() }
    }

    public func send(items: [URL], to device: DeviceID) async throws -> TransferID {
        guard !shuttingDown else { throw MacChannelError.transferFailed }
        guard transfers.count + conflictPackageCleanups.count
            < Self.maximumQueuedTransfers + Self.maximumConcurrentTransfers
        else {
            throw MacChannelError.invalidConfiguration("The outbound transfer queue is full.")
        }
        let package = try OutgoingTransferPackage.create(
            items: items,
            peer: device,
            in: outgoingDirectory
        )
        let snapshot = TransferSnapshot(
            id: package.id,
            peer: device,
            phase: .preparing,
            completedBytes: 0,
            totalBytes: package.totalBytes,
            route: .lan
        )
        transfers[package.id] = makeTask(package: package, snapshot: snapshot, durable: nil)
        let receipt = try claimTransition(
            package.id,
            to: .preparing,
            completedBytes: 0,
            route: .lan,
            forceInitialIntent: true
        )
        try await receipt.wait()
        guard transfers[package.id] != nil else { throw MacChannelError.transferFailed }
        pending.append(package.id)
        scheduleTransfers()
        return package.id
    }

    public func pause(_ id: TransferID) async throws {
        guard let transfer = transfers[id], !isTerminal(transfer.desiredSnapshot.phase),
            transfer.desiredSnapshot.phase != .cancelling
        else { throw MacChannelError.transferInvalidState }
        let receipt = try claimTransition(id, to: .paused)
        await transfer.control.pause()
        try await receipt.wait()
        guard transfers[id]?.desiredSnapshot.phase == .paused else {
            throw MacChannelError.transferInvalidState
        }
    }

    public func resume(_ id: TransferID) async throws {
        guard let transfer = transfers[id], transfer.desiredSnapshot.phase == .paused else {
            throw MacChannelError.transferInvalidState
        }
        let resumedPhase: TransferPhase
        if !active.contains(id) {
            resumedPhase = .preparing
        } else if transfer.completedSession {
            resumedPhase = .verifying
        } else if transfer.channel == nil {
            resumedPhase = .connecting
        } else {
            resumedPhase = .transferring
        }
        let receipt = try claimTransition(id, to: resumedPhase)
        try await receipt.wait()
        guard transfers[id]?.desiredSnapshot.phase == resumedPhase else {
            throw MacChannelError.transferInvalidState
        }
        await transfer.control.resume()
        if !active.contains(id), !pending.contains(id) { pending.append(id) }
        scheduleTransfers()
    }

    @discardableResult
    public func cancel(_ id: TransferID) async -> TransferCancellationResult {
        guard let transfer = transfers[id], !isTerminal(transfer.desiredSnapshot.phase) else {
            return .tooLate
        }
        guard !transfer.completionClaimed else { return .tooLate }
        guard (try? claimTransition(id, to: .cancelling)) != nil else { return .tooLate }
        await transfer.control.cancel()
        pending.removeAll { $0 == id }
        guard active.contains(id), let runnerToken = transfer.runnerToken else {
            _ = try? claimTransition(id, to: .cancelled)
            scheduleTransfers()
            return .requested
        }
        transfer.runner?.cancel()
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: cancellationWatchdogDelay)
            await self.forceCancelIfStillRunning(id, runnerToken: runnerToken)
        }
        return .requested
    }

    public func snapshots() -> AsyncStream<[TransferSnapshot]> {
        let token = UUID()
        let current = orderedSnapshots()
        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            subscribers[token] = continuation
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(token) }
            }
        }
    }

    /// Test/process-lifecycle hook: stops in-memory work without mutating durable
    /// phases or deleting packages, matching abrupt process termination.
    public func shutdownForRestart() async {
        guard !shuttingDown else { return }
        shuttingDown = true
        for transfer in transfers.values {
            transfer.runner?.cancel()
            transfer.persistenceWorker?.cancel()
            transfer.packageCleanupWorker?.cancel()
        }
        for cleanup in conflictPackageCleanups.values { cleanup.worker?.cancel() }
        active.removeAll()
        pending.removeAll()
        await connectionAttempts.cancelAll()
        for (id, transfer) in transfers where transfer.channel != nil {
            beginBoundedClose(for: id, channel: transfer.channel!)
        }
    }

    func claimedPhase(for id: TransferID) -> TransferPhase? {
        transfers[id]?.desiredSnapshot.phase
    }

    func activeTransferCount() -> Int { active.count }

    func retainedResourceCount() async -> Int {
        let counts = await resources.counts()
        return counts.outbound
    }

    func detachedRunnerCount() -> Int { detachedRunners.count }

    private func makeTask(
        package: OutgoingTransferPackage,
        snapshot: TransferSnapshot,
        durable: TransferSnapshot?
    ) -> TransferTask {
        TransferTask(
            package: package,
            peer: package.peer,
            displayFilename: package.displayFilename,
            totalBytes: package.totalBytes,
            control: TransferSessionControl(),
            desiredSnapshot: snapshot,
            durableSnapshot: durable,
            operationEpoch: 0,
            persistenceQueue: [],
            persistenceWorker: nil,
            packageCleanupWorker: nil,
            runner: nil,
            runnerToken: nil,
            completedSession: false,
            completionClaimed: false,
            resourceToken: nil,
            resourceHasChannel: false,
            channel: nil
        )
    }

    private func run(_ id: TransferID, runnerToken: UUID) async {
        var attempt = 0
        transferLoop: while attempt < maximumConnectionAttempts {
            var openedResource: (
                channel: any SecureChannel,
                token: BoundedChannelResourceRegistry.Token
            )?
            do {
                try await acquireResourceToken(for: id, runnerToken: runnerToken)
                try Task.checkCancellation()
                try await transitionRespectingPause(id, intendedPhase: .connecting)
                try Task.checkCancellation()
                try await waitForActiveControl(id)
                try Task.checkCancellation()
                guard let lightweight = transfers[id], lightweight.runnerToken == runnerToken else {
                    throw CancellationError()
                }
                guard let resourceToken = lightweight.resourceToken else {
                    throw MacChannelError.transferFailed
                }
                let channel = try await connectionAttempts.connect(
                    connector: connector,
                    peer: lightweight.peer,
                    transferID: id,
                    resourceOwnership: TransferIOResourceOwnership(
                        registry: resources,
                        token: resourceToken
                    )
                )
                // Runner-local ownership is authoritative across the actor
                // handoff. A watchdog may clear the transfer entry while this
                // continuation is resuming, but it cannot erase this cleanup.
                openedResource = (channel, resourceToken)
                transfers[id]?.resourceHasChannel = true
                try Task.checkCancellation()
                guard transfers[id]?.runnerToken == runnerToken else {
                    await beginBoundedClose(channel, token: resourceToken)
                    openedResource = nil
                    throw CancellationError()
                }
                transfers[id]?.channel = channel

                try await performSend(
                    id: id,
                    package: lightweight.package,
                    control: lightweight.control,
                    channel: channel,
                    resourceToken: resourceToken
                )
                // SendSession returns only after the receiver reports .complete,
                // which means publication has succeeded. Claim both durable
                // phases in this actor turn before close or any other await: from
                // here cancellation is irreversibly too late.
                let completions = try claimIrreversibleCompletion(
                    id,
                    runnerToken: runnerToken,
                    completedBytes: lightweight.totalBytes
                )
                transfers[id]?.channel = nil
                await beginBoundedClose(channel, token: resourceToken)
                openedResource = nil
                for completion in completions { try await completion.wait() }
                break transferLoop
            } catch {
                transfers[id]?.channel = nil
                if let openedResource {
                    await beginBoundedClose(
                        openedResource.channel,
                        token: openedResource.token
                    )
                }
                if shuttingDown { break transferLoop }
                if transfers[id]?.completionClaimed == true { break transferLoop }
                let phase = transfers[id]?.desiredSnapshot.phase
                if phase == .cancelling
                    || (error as? TransferProtocolError) == .cancelled
                    || error is CancellationError
                {
                    _ = try? claimTransition(id, to: .cancelled)
                    break transferLoop
                }
                guard isRetryableConnectionLoss(error) else {
                    _ = try? claimTransition(id, to: .failed)
                    break transferLoop
                }
                attempt += 1
                if attempt >= maximumConnectionAttempts {
                    _ = try? claimTransition(id, to: .failed)
                    break transferLoop
                }
                relinquishResourceForRetry(id)
            }
        }
        finishRun(id, runnerToken: runnerToken)
    }

    private func scheduleTransfers() {
        guard !shuttingDown, schedulingWorker == nil else { return }
        schedulingWorker = Task { [weak self] in
            await self?.drainScheduling()
        }
    }

    private func drainScheduling() async {
        defer { schedulingWorker = nil }
        while active.count < Self.maximumConcurrentTransfers,
            let index = pending.firstIndex(where: { id in
                guard let phase = transfers[id]?.desiredSnapshot.phase else { return false }
                return phase != .paused && phase != .cancelling && !isTerminal(phase)
            })
        {
            let candidateID = pending[index]
            guard let resourceToken = await resources.reserve(.outbound, onReleased: {
                [weak self] in
                await self?.resourceCapacityReleased()
            }) else { return }
            guard let currentIndex = pending.firstIndex(of: candidateID) else {
                await resources.finishWithoutClose(resourceToken)
                continue
            }
            let id = pending.remove(at: currentIndex)
            guard var transfer = transfers[id], !isTerminal(transfer.desiredSnapshot.phase),
                transfer.desiredSnapshot.phase != .paused,
                transfer.desiredSnapshot.phase != .cancelling
            else {
                await resources.finishWithoutClose(resourceToken)
                continue
            }
            active.insert(id)
            let runnerToken = UUID()
            let runner = Task { [weak self, resources] in
                guard let self else {
                    await resources.finishWithoutClose(resourceToken)
                    return
                }
                await self.run(id, runnerToken: runnerToken)
            }
            transfer.runner = runner
            transfer.runnerToken = runnerToken
            transfer.resourceToken = resourceToken
            transfer.resourceHasChannel = false
            transfers[id] = transfer
        }
    }

    private func resourceCapacityReleased() {
        scheduleTransfers()
    }

    private func acquireResourceToken(
        for id: TransferID,
        runnerToken: UUID
    ) async throws {
        while transfers[id]?.resourceToken == nil {
            try Task.checkCancellation()
            guard transfers[id]?.runnerToken == runnerToken else { throw CancellationError() }
            if let token = await resources.reserve(.outbound, onReleased: { [weak self] in
                await self?.resourceCapacityReleased()
            }) {
                guard var transfer = transfers[id], transfer.runnerToken == runnerToken else {
                    await resources.finishWithoutClose(token)
                    throw CancellationError()
                }
                transfer.resourceToken = token
                transfer.resourceHasChannel = false
                transfers[id] = transfer
                return
            }
            try await Task.sleep(for: persistenceRetryDelay)
        }
    }

    private func beginBoundedClose(
        for id: TransferID,
        channel: any SecureChannel
    ) {
        guard let token = transfers[id]?.resourceToken else { return }
        transfers[id]?.resourceHasChannel = true
        let timeout = cancellationWatchdogDelay
        Task { [resources] in
            await resources.beginClose(channel, token: token, timeout: timeout)
        }
    }

    private func beginBoundedClose(
        _ channel: any SecureChannel,
        token: BoundedChannelResourceRegistry.Token
    ) async {
        await resources.beginClose(
            channel,
            token: token,
            timeout: cancellationWatchdogDelay
        )
    }

    private func relinquishResourceForRetry(_ id: TransferID) {
        guard let token = transfers[id]?.resourceToken else { return }
        if transfers[id]?.resourceHasChannel == true {
            Task { [resources] in await resources.runnerReturned(token) }
        } else {
            Task { [resources] in await resources.finishWithoutClose(token) }
        }
        transfers[id]?.resourceToken = nil
        transfers[id]?.resourceHasChannel = false
    }

    private func finishRun(_ id: TransferID, runnerToken: UUID) {
        guard transfers[id]?.runnerToken == runnerToken else { return }
        active.remove(id)
        transfers[id]?.runner = nil
        transfers[id]?.runnerToken = nil
        transfers[id]?.completedSession = false
        transfers[id]?.channel = nil
        if let resourceToken = transfers[id]?.resourceToken {
            if transfers[id]?.resourceHasChannel == true {
                Task { await resources.runnerReturned(resourceToken) }
            } else {
                Task { await resources.finishWithoutClose(resourceToken) }
            }
            transfers[id]?.resourceToken = nil
            transfers[id]?.resourceHasChannel = false
        }
        archiveIfDurablyTerminal(id)
        scheduleTransfers()
    }

    /// Claims an operation epoch synchronously, before any database await. All
    /// writes then flow through the per-transfer FIFO persistence worker.
    private func claimTransition(
        _ id: TransferID,
        to phase: TransferPhase,
        completedBytes: Int64? = nil,
        route: ConnectionRoute? = nil,
        isProgress: Bool = false,
        forceInitialIntent: Bool = false
    ) throws -> PersistenceCompletion {
        guard var transfer = transfers[id] else { throw MacChannelError.transferFailed }
        let current = transfer.desiredSnapshot
        if isTerminal(current.phase), phase != current.phase {
            throw MacChannelError.transferFailed
        }
        if current.phase == .cancelling, phase != .cancelling, phase != .cancelled {
            throw CancellationError()
        }
        let monotonicCompleted = min(
            transfer.totalBytes,
            max(current.completedBytes, completedBytes ?? current.completedBytes)
        )
        transfer.operationEpoch &+= 1
        let epoch = transfer.operationEpoch
        let snapshot = TransferSnapshot(
            id: id,
            peer: transfer.peer,
            phase: phase,
            completedBytes: monotonicCompleted,
            totalBytes: transfer.totalBytes,
            route: route ?? current.route
        )
        transfer.desiredSnapshot = snapshot
        let completion = PersistenceCompletion()
        let intent = PersistenceIntent(
            epoch: epoch,
            snapshot: snapshot,
            isProgress: isProgress,
            completion: completion
        )
        if isProgress, transfer.persistenceQueue.count > 1,
            transfer.persistenceQueue.last?.isProgress == true
        {
            transfer.persistenceQueue[transfer.persistenceQueue.count - 1] = intent
        } else {
            transfer.persistenceQueue.append(intent)
        }
        if forceInitialIntent { transfer.durableSnapshot = nil }
        if transfer.persistenceWorker == nil {
            transfer.persistenceWorker = Task { [weak self] in
                await self?.drainPersistence(for: id)
            }
        }
        transfers[id] = transfer
        return completion
    }

    private func performSend(
        id: TransferID,
        package: OutgoingTransferPackage,
        control: TransferSessionControl,
        channel: any SecureChannel,
        resourceToken: BoundedChannelResourceRegistry.Token
    ) async throws {
        // The manifest and its pinned source descriptors are scoped entirely to
        // the protocol session. No later close task can capture them.
        let manifest = try package.openManifest()
        let progress = CoordinatorProgressRecorder(entries: manifest.entries) {
            [weak self] completedBytes in
            await self?.recordProgress(completedBytes, for: id)
        }
        try await transitionRespectingPause(
            id,
            intendedPhase: .transferring,
            route: channel.route
        )
        _ = try await SendSession(
            manifest,
            recorder: progress,
            control: control,
            resourceOwnership: TransferIOResourceOwnership(
                registry: resources,
                token: resourceToken
            )
        ).run(on: channel)
    }

    private func claimIrreversibleCompletion(
        _ id: TransferID,
        runnerToken: UUID,
        completedBytes: Int64
    ) throws -> [PersistenceCompletion] {
        guard var transfer = transfers[id], transfer.runnerToken == runnerToken else {
            throw CancellationError()
        }
        guard transfer.desiredSnapshot.phase != .cancelling,
            !isTerminal(transfer.desiredSnapshot.phase)
        else {
            throw CancellationError()
        }
        transfer.completedSession = true
        transfer.completionClaimed = true
        transfers[id] = transfer
        let verifying = try claimTransition(id, to: .verifying, completedBytes: completedBytes)
        let completed = try claimTransition(id, to: .completed, completedBytes: completedBytes)
        return [verifying, completed]
    }

    private func drainPersistence(for id: TransferID) async {
        var consecutiveFailures = 0
        while !Task.isCancelled {
            guard let transfer = transfers[id], let intent = transfer.persistenceQueue.first else {
                transfers[id]?.persistenceWorker = nil
                return
            }
            let expectedPhase = transfer.durableSnapshot?.phase
            do {
                try await persistence.persist(
                    intent.snapshot,
                    displayFilename: transfer.displayFilename,
                    expectedPhase: expectedPhase
                )
            } catch {
                if Task.isCancelled || shuttingDown { return }
                if isPermanentPersistenceConflict(error) {
                    await failPermanently(id, intent: intent, error: error)
                    return
                }
                if (error as? TransferPersistenceError) == .conditionalConflict {
                    if await reconcileConditionalConflict(id, intent: intent) { continue }
                    return
                }
                let backoffSteps = 1 << min(consecutiveFailures, 4)
                for _ in 0..<backoffSteps {
                    try? await Task.sleep(for: persistenceRetryDelay)
                    if Task.isCancelled || shuttingDown { return }
                }
                consecutiveFailures += 1
                continue
            }
            consecutiveFailures = 0
            guard var current = transfers[id],
                current.persistenceQueue.first?.epoch == intent.epoch
            else {
                await intent.completion.resolve(.failure(MacChannelError.transferFailed))
                continue
            }
            current.persistenceQueue.removeFirst()
            let durableCompleted = max(
                current.durableSnapshot?.completedBytes ?? 0,
                intent.snapshot.completedBytes
            )
            current.durableSnapshot = TransferSnapshot(
                id: intent.snapshot.id,
                peer: intent.snapshot.peer,
                phase: intent.snapshot.phase,
                completedBytes: durableCompleted,
                totalBytes: intent.snapshot.totalBytes,
                route: intent.snapshot.route
            )
            transfers[id] = current
            await intent.completion.resolve(.success(()))
            if transfers[id]?.operationEpoch == intent.epoch,
                !isTerminal(intent.snapshot.phase)
            {
                publishSnapshots()
            }
            archiveIfDurablyTerminal(id)
        }
    }

    /// A conditional conflict means blind retry can never make progress. Adopt
    /// an already-committed compatible row, or atomically quarantine the exact
    /// outbound row as failed so the runner and its resource token can drain.
    private func reconcileConditionalConflict(
        _ id: TransferID,
        intent: PersistenceIntent
    ) async -> Bool {
        do {
            let existing = try await persistence.persistedTransfer(id: id)
            let displayFilename = transfers[id]?.displayFilename ?? ""
            var record: TransferHistoryRecord
            if let existing {
                guard existing.direction == .outbound else {
                    throw TransferPersistenceError.directionConflict
                }
                guard existing.peer == intent.snapshot.peer,
                    existing.displayFilename == displayFilename,
                    existing.aggregateSize == UInt64(intent.snapshot.totalBytes)
                else { throw TransferPersistenceError.identityConflict }
                record = existing
            } else {
                record = try await persistence.quarantineOutboundTransfer(
                    intent.snapshot,
                    displayFilename: displayFilename
                )
            }
            if record.phase == .verifying {
                record = try await completePublishedRecord(record)
            }
            let compatibleCommit =
                record.completedBytes >= UInt64(intent.snapshot.completedBytes)
                && (record.phase == intent.snapshot.phase
                    ? record.route == intent.snapshot.route
                    : isCompatibleNewerPhase(
                        record.phase,
                        than: intent.snapshot.phase
                    ))
            if !compatibleCommit && !isTerminal(record.phase) {
                record = try await persistence.quarantineOutboundTransfer(
                    intent.snapshot,
                    displayFilename: displayFilename
                )
            }
            guard compatibleCommit || isTerminal(record.phase) else {
                throw TransferPersistenceError.conditionalConflict
            }
            await adoptPersistedRecord(record, for: id, intent: intent)
            return true
        } catch {
            if isPermanentPersistenceConflict(error) {
                await failPermanently(id, intent: intent, error: error)
                return false
            }
            guard (error as? TransferPersistenceError) == .conditionalConflict else {
                try? await Task.sleep(for: persistenceRetryDelay)
                return true
            }
            // One last read handles a concurrent writer that completed while the
            // quarantine transaction was racing. No conditional write is retried.
            do {
                if let record = try await persistence.persistedTransfer(id: id),
                    record.direction == .outbound,
                    record.peer == intent.snapshot.peer,
                    record.displayFilename == transfers[id]?.displayFilename,
                    record.aggregateSize == UInt64(intent.snapshot.totalBytes)
                {
                    if record.phase == .verifying {
                        try? await Task.sleep(for: persistenceRetryDelay)
                        return true
                    }
                    if isTerminal(record.phase) {
                        await adoptPersistedRecord(record, for: id, intent: intent)
                        return true
                    }
                }
            } catch {
                guard (error as? TransferPersistenceError) == .conditionalConflict else {
                    try? await Task.sleep(for: persistenceRetryDelay)
                    return true
                }
            }
            await failClosedAfterConflict(id, intent: intent)
            return false
        }
    }

    private func failPermanently(
        _ id: TransferID,
        intent: PersistenceIntent,
        error: Error
    ) async {
        guard var current = transfers[id],
            current.persistenceQueue.first?.epoch == intent.epoch
        else {
            await intent.completion.resolve(.failure(error))
            return
        }
        let completions = current.persistenceQueue.map(\.completion)
        current.persistenceQueue.removeAll()
        current.persistenceWorker = nil
        pending.removeAll { $0 == id }
        current.runner?.cancel()
        if let channel = current.channel {
            transfers[id] = current
            beginBoundedClose(for: id, channel: channel)
            current = transfers[id] ?? current
        }
        active.remove(id)
        if let runner = current.runner, let runnerToken = current.runnerToken {
            detachedRunners[runnerToken] = runner
            let resourceToken = current.resourceToken
            let resourceHasChannel = current.resourceHasChannel
            Task { [weak self] in
                await runner.value
                await self?.detachedRunnerFinished(
                    runnerToken,
                    resourceToken: resourceToken,
                    resourceHasChannel: resourceHasChannel
                )
            }
        } else if let resourceToken = current.resourceToken {
            if current.resourceHasChannel {
                await resources.runnerReturned(resourceToken)
            } else {
                await resources.finishWithoutClose(resourceToken)
            }
        }
        transfers.removeValue(forKey: id)
        conflictPackageCleanups[id] = ConflictPackageCleanup(
            package: current.package,
            worker: nil
        )
        retryConflictPackageCleanup(id)
        for completion in completions { await completion.resolve(.failure(error)) }
        scheduleTransfers()
    }

    private func retryConflictPackageCleanup(_ id: TransferID) {
        guard let cleanup = conflictPackageCleanups[id], cleanup.worker == nil else { return }
        do {
            try cleanup.package.removeAfterPersistenceConflict()
            conflictPackageCleanups.removeValue(forKey: id)
        } catch {
            let retryDelay = persistenceRetryDelay
            let worker = Task { [weak self] in
                do {
                    try await Task.sleep(for: retryDelay)
                } catch { return }
                await self?.conflictPackageCleanupTimerFired(id)
            }
            conflictPackageCleanups[id]?.worker = worker
        }
    }

    private func conflictPackageCleanupTimerFired(_ id: TransferID) {
        conflictPackageCleanups[id]?.worker = nil
        retryConflictPackageCleanup(id)
    }

    private func isPermanentPersistenceConflict(_ error: Error) -> Bool {
        switch error as? TransferPersistenceError {
        case .identityConflict, .directionConflict:
            return true
        case .conditionalConflict, nil:
            return false
        }
    }

    private func completePublishedRecord(
        _ record: TransferHistoryRecord
    ) async throws -> TransferHistoryRecord {
        let completed = TransferSnapshot(
            id: record.id,
            peer: record.peer,
            phase: .completed,
            completedBytes: Int64(record.aggregateSize),
            totalBytes: Int64(record.aggregateSize),
            route: record.route
        )
        do {
            try await persistence.persist(
                completed,
                displayFilename: record.displayFilename,
                expectedPhase: .verifying
            )
        } catch {
            guard (error as? TransferPersistenceError) == .conditionalConflict,
                let current = try await persistence.persistedTransfer(id: record.id),
                current.direction == .outbound,
                current.peer == record.peer,
                current.displayFilename == record.displayFilename,
                current.aggregateSize == record.aggregateSize,
                current.phase == .completed
            else { throw error }
            return current
        }
        guard let current = try await persistence.persistedTransfer(id: record.id),
            current.direction == .outbound,
            current.peer == record.peer,
            current.displayFilename == record.displayFilename,
            current.aggregateSize == record.aggregateSize,
            current.phase == .completed
        else { throw TransferPersistenceError.conditionalConflict }
        return current
    }

    private func adoptPersistedRecord(
        _ record: TransferHistoryRecord,
        for id: TransferID,
        intent: PersistenceIntent
    ) async {
        guard var current = transfers[id],
            current.persistenceQueue.first?.epoch == intent.epoch
        else {
            await intent.completion.resolve(.failure(MacChannelError.transferFailed))
            return
        }
        let snapshot = TransferSnapshot(
            id: record.id,
            peer: record.peer,
            phase: record.phase,
            completedBytes: Int64(record.completedBytes),
            totalBytes: Int64(record.aggregateSize),
            route: record.route
        )
        if isTerminal(record.phase) {
            let completions = current.persistenceQueue.map(\.completion)
            current.persistenceQueue.removeAll()
            current.desiredSnapshot = snapshot
            current.durableSnapshot = snapshot
            transfers[id] = current
            for completion in completions { await completion.resolve(.success(())) }
            terminateRunnerAfterDurableConflict(id)
        } else {
            current.persistenceQueue.removeFirst()
            current.durableSnapshot = snapshot
            transfers[id] = current
            await intent.completion.resolve(.success(()))
            publishSnapshots()
        }
    }

    private func failClosedAfterConflict(_ id: TransferID, intent: PersistenceIntent) async {
        guard var current = transfers[id] else { return }
        let completions = current.persistenceQueue.map(\.completion)
        for completion in completions {
            await completion.resolve(.failure(TransferPersistenceError.conditionalConflict))
        }
        current.persistenceQueue.removeAll()
        current.persistenceWorker = nil
        transfers[id] = current
        current.runner?.cancel()
        terminateRunnerAfterDurableConflict(id)
    }

    private func isCompatibleNewerPhase(
        _ persisted: TransferPhase,
        than intended: TransferPhase
    ) -> Bool {
        switch intended {
        case .preparing:
            return persisted == .connecting
        case .connecting:
            return persisted == .transferring
        case .transferring, .paused, .cancelling, .verifying, .completed, .failed,
            .cancelled:
            return false
        }
    }

    private func terminateRunnerAfterDurableConflict(_ id: TransferID) {
        pending.removeAll { $0 == id }
        guard let transfer = transfers[id], let token = transfer.runnerToken else {
            archiveIfDurablyTerminal(id)
            scheduleTransfers()
            return
        }
        transfer.runner?.cancel()
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: cancellationWatchdogDelay)
            await self.forceReleaseConflictedRunner(id, runnerToken: token)
        }
    }

    private func forceReleaseConflictedRunner(_ id: TransferID, runnerToken: UUID) {
        guard var current = transfers[id], current.runnerToken == runnerToken else { return }
        if let channel = current.channel { beginBoundedClose(for: id, channel: channel) }
        active.remove(id)
        if let runner = current.runner {
            detachedRunners[runnerToken] = runner
            let resourceToken = current.resourceToken
            let resourceHasChannel = current.resourceHasChannel
            Task { [weak self] in
                await runner.value
                await self?.detachedRunnerFinished(
                    runnerToken,
                    resourceToken: resourceToken,
                    resourceHasChannel: resourceHasChannel
                )
            }
        }
        current.runner = nil
        current.runnerToken = nil
        current.resourceToken = nil
        current.resourceHasChannel = false
        current.channel = nil
        transfers[id] = current
        archiveIfDurablyTerminal(id)
        scheduleTransfers()
    }

    private func transitionRespectingPause(
        _ id: TransferID,
        intendedPhase: TransferPhase,
        route: ConnectionRoute? = nil
    ) async throws {
        guard let current = transfers[id]?.desiredSnapshot.phase else {
            throw MacChannelError.transferFailed
        }
        if current == .cancelling || isTerminal(current) { throw CancellationError() }
        let receipt = try claimTransition(
            id,
            to: current == .paused ? .paused : intendedPhase,
            route: route
        )
        try await receipt.wait()
    }

    private func waitForActiveControl(_ id: TransferID) async throws {
        guard let control = transfers[id]?.control else { throw MacChannelError.transferFailed }
        var snapshot = await control.snapshot()
        while true {
            try Task.checkCancellation()
            switch snapshot.state {
            case .active:
                return
            case .cancelled:
                throw CancellationError()
            case .paused:
                snapshot = await control.waitForChange(after: snapshot.revision)
            }
        }
    }

    private func recordProgress(_ completedBytes: Int64, for id: TransferID) async {
        guard let transfer = transfers[id],
            !isTerminal(transfer.desiredSnapshot.phase),
            transfer.desiredSnapshot.phase != .cancelling,
            completedBytes > transfer.desiredSnapshot.completedBytes
        else { return }
        _ = try? claimTransition(
            id,
            to: transfer.desiredSnapshot.phase,
            completedBytes: completedBytes,
            isProgress: true
        )
    }

    private func publishSnapshots() {
        let value = orderedSnapshots()
        var terminated: [UUID] = []
        for (token, subscriber) in subscribers {
            if case .terminated = subscriber.yield(value) { terminated.append(token) }
        }
        for token in terminated { subscribers.removeValue(forKey: token) }
    }

    private func orderedSnapshots() -> [TransferSnapshot] {
        let live = transfers.values.compactMap { transfer -> TransferSnapshot? in
            guard let snapshot = transfer.durableSnapshot,
                snapshot.phase != .completed,
                snapshot.phase != .failed,
                snapshot.phase != .cancelled
            else { return nil }
            return snapshot
        }.sorted {
            $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
        }
        let liveIDs = Set(live.map(\.id))
        return live + finishedSnapshots.filter { !liveIDs.contains($0.id) }
    }

    private func archiveIfDurablyTerminal(_ id: TransferID) {
        guard !active.contains(id), let transfer = transfers[id],
            transfer.persistenceQueue.isEmpty,
            let durable = transfer.durableSnapshot,
            isTerminal(durable.phase)
        else { return }
        // Terminal sends are not resumable. Removing every terminal package
        // bounds private source retention during normal operation as well as
        // across restart.
        guard transfer.packageCleanupWorker == nil else { return }
        do {
            try transfer.package.remove()
        } catch {
            let retryDelay = persistenceRetryDelay
            let cleanupWorker = Task { [weak self] in
                try? await Task.sleep(for: retryDelay)
                await self?.retryPackageCleanup(id)
            }
            transfers[id]?.packageCleanupWorker = cleanupWorker
            return
        }
        finishedSnapshots.removeAll { $0.id == id }
        finishedSnapshots.insert(durable, at: 0)
        if finishedSnapshots.count > Self.maximumPublishedTerminalSnapshots {
            finishedSnapshots.removeLast(
                finishedSnapshots.count - Self.maximumPublishedTerminalSnapshots
            )
        }
        transfers.removeValue(forKey: id)
        publishSnapshots()
    }

    private func retryPackageCleanup(_ id: TransferID) {
        transfers[id]?.packageCleanupWorker = nil
        archiveIfDurablyTerminal(id)
    }

    private func restoreHistory() async throws {
        let recovery = try OutgoingTransferPackage.recoverAll(from: outgoingDirectory)
        let packages = recovery.packages
        let completedConflictCleanupIDs = recovery.completedConflictCleanupIDs
        var packageByID = Dictionary(uniqueKeysWithValues: packages.map { ($0.id, $0) })
        var history = try await persistence.persistedHistory(limit: 10_000)
        var historyIDs = Set(history.map(\.id))
        // The bounded recent-history publication window is not an authority for
        // package identity. Resolve every durable package by exact TransferID so
        // a long-paused send cannot be mistaken for a new orphan.
        for package in packages where !historyIDs.contains(package.id) {
            if let record = try await persistence.persistedTransfer(id: package.id) {
                history.append(record)
                historyIDs.insert(record.id)
            }
        }
        for record in history {
            // ReceiveStore exclusively owns inbound reconciliation. Legacy rows
            // migrate to unknown and are intentionally left untouched.
            guard record.direction == .outbound else { continue }
            guard record.aggregateSize <= UInt64(Int64.max),
                record.completedBytes <= UInt64(Int64.max)
            else { throw ReceiveStoreError.databaseFailure }
            let snapshot = TransferSnapshot(
                id: record.id,
                peer: record.peer,
                phase: record.phase,
                completedBytes: Int64(record.completedBytes),
                totalBytes: Int64(record.aggregateSize),
                route: record.route
            )
            if record.phase == .verifying {
                if let package = packageByID.removeValue(forKey: record.id) {
                    try package.remove()
                }
                let completed = try await completePublishedRecord(record)
                appendRestoredTerminal(
                    TransferSnapshot(
                        id: completed.id,
                        peer: completed.peer,
                        phase: .completed,
                        completedBytes: Int64(completed.aggregateSize),
                        totalBytes: Int64(completed.aggregateSize),
                        route: completed.route
                    )
                )
                continue
            }
            if completedConflictCleanupIDs.contains(record.id) {
                if let package = packageByID.removeValue(forKey: record.id) {
                    try package.removeAfterPersistenceConflict()
                }
                if isTerminal(record.phase) { appendRestoredTerminal(snapshot) }
                continue
            }
            guard let package = packageByID.removeValue(forKey: record.id) else {
                if isTerminal(record.phase) {
                    appendRestoredTerminal(snapshot)
                } else {
                    let failed = TransferSnapshot(
                        id: record.id,
                        peer: record.peer,
                        phase: .failed,
                        completedBytes: Int64(record.completedBytes),
                        totalBytes: Int64(record.aggregateSize),
                        route: record.route
                    )
                    try await persistence.persist(
                        failed,
                        displayFilename: record.displayFilename,
                        expectedPhase: record.phase
                    )
                    appendRestoredTerminal(failed)
                }
                continue
            }
            guard package.peer == record.peer,
                package.displayFilename == record.displayFilename,
                package.totalBytes == Int64(record.aggregateSize)
            else {
                try package.removeAfterPersistenceConflict()
                if isTerminal(record.phase) { appendRestoredTerminal(snapshot) }
                continue
            }
            if isTerminal(record.phase) {
                try package.remove()
                appendRestoredTerminal(snapshot)
                continue
            }
            let task = makeTask(package: package, snapshot: snapshot, durable: snapshot)
            if record.phase == .paused { await task.control.pause() }
            transfers[record.id] = task
            if record.phase != .paused && record.phase != .cancelling {
                pending.append(record.id)
            } else if record.phase == .cancelling {
                _ = try claimTransition(record.id, to: .cancelled)
            }
        }
        // A package is runnable only when SQLite contains its durable preparing
        // (or later) phase. Package creation that never reached that commit is
        // unacknowledged/ineligible and must never become an automatic send on
        // restart, including after a post-rename cleanup failure.
        for package in packageByID.values { try package.remove() }
        packageByID.removeAll()
        guard transfers.count <= Self.maximumQueuedTransfers + Self.maximumConcurrentTransfers else {
            throw MacChannelError.invalidConfiguration(
                "The durable outbound transfer queue exceeds its bounded capacity."
            )
        }
        publishSnapshots()
        scheduleTransfers()
    }

    private func appendRestoredTerminal(_ snapshot: TransferSnapshot) {
        guard finishedSnapshots.count < Self.maximumPublishedTerminalSnapshots else { return }
        finishedSnapshots.append(snapshot)
    }

    private func removeSubscriber(_ token: UUID) {
        subscribers.removeValue(forKey: token)
    }

    private func isTerminal(_ phase: TransferPhase) -> Bool {
        phase == .completed || phase == .failed || phase == .cancelled
    }

    private func isRetryableConnectionLoss(_ error: Error) -> Bool {
        if (error as? TransferProtocolError) == .channelEnded { return true }
        if (error as? MacChannelError) == .connectionFailed { return true }
        if error is ConnectionCoordinatorError { return true }
        if let attempt = error as? ConnectionAttemptError {
            return attempt != .authenticationFailed
        }
        if let channel = error as? WebRTCSecureChannelError {
            switch channel {
            case .transportClosed, .sendFailed:
                return true
            default:
                return false
            }
        }
        return false
    }

    private func forceCancelIfStillRunning(_ id: TransferID, runnerToken: UUID) async {
        guard let transfer = transfers[id], transfer.runnerToken == runnerToken,
            transfer.desiredSnapshot.phase == .cancelling
        else { return }
        if let channel = transfer.channel { beginBoundedClose(for: id, channel: channel) }
        _ = try? claimTransition(id, to: .cancelled)
        guard var current = transfers[id], current.runnerToken == runnerToken else { return }
        active.remove(id)
        if let runner = current.runner {
            detachedRunners[runnerToken] = runner
            let resourceToken = current.resourceToken
            let resourceHasChannel = current.resourceHasChannel
            Task { [weak self] in
                await runner.value
                await self?.detachedRunnerFinished(
                    runnerToken,
                    resourceToken: resourceToken,
                    resourceHasChannel: resourceHasChannel
                )
            }
        }
        current.runner = nil
        current.runnerToken = nil
        current.channel = nil
        current.resourceToken = nil
        current.resourceHasChannel = false
        transfers[id] = current
        archiveIfDurablyTerminal(id)
        scheduleTransfers()
    }

    private func detachedRunnerFinished(
        _ token: UUID,
        resourceToken: BoundedChannelResourceRegistry.Token?,
        resourceHasChannel: Bool
    ) {
        if let resourceToken {
            if resourceHasChannel {
                Task { await resources.runnerReturned(resourceToken) }
            } else {
                Task { await resources.finishWithoutClose(resourceToken) }
            }
        }
        detachedRunners.removeValue(forKey: token)
        scheduleTransfers()
    }
}

private actor PersistenceCompletion {
    private enum State {
        case pending([CheckedContinuation<Void, Error>])
        case resolved(Result<Void, Error>)
    }

    private var state: State = .pending([])

    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            switch state {
            case .pending(var continuations):
                continuations.append(continuation)
                state = .pending(continuations)
            case .resolved(let result):
                continuation.resume(with: result)
            }
        }
    }

    func resolve(_ result: Result<Void, Error>) {
        guard case .pending(let continuations) = state else { return }
        state = .resolved(result)
        for continuation in continuations { continuation.resume(with: result) }
    }
}

private actor ConnectionAttemptGate {
    private enum State {
        case pending([CheckedContinuation<any SecureChannel, Error>])
        case resolved(Result<any SecureChannel, Error>)
    }

    private var state: State = .pending([])

    func wait() async throws -> any SecureChannel {
        try await withCheckedThrowingContinuation { continuation in
            switch state {
            case .pending(var continuations):
                continuations.append(continuation)
                state = .pending(continuations)
            case .resolved(let result):
                continuation.resume(with: result)
            }
        }
    }

    @discardableResult
    func resolve(_ result: Result<any SecureChannel, Error>) -> Bool {
        guard case .pending(let continuations) = state else { return false }
        state = .resolved(result)
        for continuation in continuations { continuation.resume(with: result) }
        return true
    }
}

/// Owns unstructured connector attempts so cancellation-insensitive connectors
/// can be detached without retaining a coordinator, package, manifest, or file
/// descriptor. Late channels are closed and completed attempts are removed.
private actor ConnectionAttemptRegistry {
    private struct Attempt {
        let task: Task<Void, Never>
        let gate: ConnectionAttemptGate
    }

    private var attempts: [UUID: Attempt] = [:]
    private let maximumRetainedAttempts = 8

    func connect(
        connector: any PeerConnector,
        peer: DeviceID,
        transferID: TransferID,
        resourceOwnership: TransferIOResourceOwnership
    ) async throws -> any SecureChannel {
        guard attempts.count < maximumRetainedAttempts else {
            throw MacChannelError.connectionFailed
        }
        guard await resourceOwnership.registry.retainOperation(resourceOwnership.token) else {
            throw MacChannelError.connectionFailed
        }
        let token = UUID()
        let gate = ConnectionAttemptGate()
        let task = Task { [weak self, connector, gate, resourceOwnership] in
            do {
                let channel: any SecureChannel
                if let aware = connector as? any TransferAwarePeerConnector {
                    channel = try await aware.connect(to: peer, transferID: transferID)
                } else {
                    channel = try await connector.connect(to: peer)
                }
                if !(await gate.resolve(.success(channel))) { await channel.close() }
            } catch {
                _ = await gate.resolve(.failure(error))
            }
            await resourceOwnership.registry.operationReturned(resourceOwnership.token)
            await self?.attemptFinished(token)
        }
        attempts[token] = Attempt(task: task, gate: gate)
        return try await withTaskCancellationHandler {
            try await gate.wait()
        } onCancel: {
            task.cancel()
            Task { await gate.resolve(.failure(CancellationError())) }
        }
    }

    func cancelAll() async {
        let current = Array(attempts.values)
        for attempt in current {
            attempt.task.cancel()
            _ = await attempt.gate.resolve(.failure(CancellationError()))
        }
    }

    private func attemptFinished(_ token: UUID) {
        attempts.removeValue(forKey: token)
    }
}

private actor CoordinatorProgressRecorder: TransferChunkRecording {
    private let entries: [TransferManifestEntry]
    private let onProgress: @Sendable (Int64) async -> Void
    private var recorded: Set<ChunkCoordinate> = []
    private var completedBytes: Int64 = 0

    init(
        entries: [TransferManifestEntry],
        onProgress: @escaping @Sendable (Int64) async -> Void
    ) {
        self.entries = entries
        self.onProgress = onProgress
    }

    func recordSentChunk(_ coordinate: ChunkCoordinate) async {
        guard recorded.insert(coordinate).inserted,
            Int(coordinate.entryIndex) < entries.count
        else { return }
        let entry = entries[Int(coordinate.entryIndex)]
        let offset = UInt64(coordinate.chunkIndex)
            * UInt64(TransferProtocolLimits.maximumChunkBytes)
        guard entry.kind == .file, offset < entry.size else { return }
        let bytes = min(
            UInt64(TransferProtocolLimits.maximumChunkBytes),
            entry.size - offset
        )
        guard bytes <= UInt64(Int64.max), completedBytes <= Int64.max - Int64(bytes) else {
            return
        }
        completedBytes += Int64(bytes)
        await onProgress(completedBytes)
    }
}
