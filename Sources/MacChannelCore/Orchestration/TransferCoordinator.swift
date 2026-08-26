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
        var channel: (any SecureChannel)?
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
    private var transfers: [TransferID: TransferTask] = [:]
    private var finishedSnapshots: [TransferSnapshot] = []
    private var pending: [TransferID] = []
    private var active: Set<TransferID> = []
    private var detachedRunners: [UUID: Task<Void, Never>] = [:]
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
        for subscriber in subscribers.values { subscriber.finish() }
        let attempts = connectionAttempts
        Task { await attempts.cancelAll() }
    }

    public func send(items: [URL], to device: DeviceID) async throws -> TransferID {
        guard !shuttingDown else { throw MacChannelError.transferFailed }
        guard transfers.count < Self.maximumQueuedTransfers + Self.maximumConcurrentTransfers else {
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

    public func pause(_ id: TransferID) async {
        guard let transfer = transfers[id], !isTerminal(transfer.desiredSnapshot.phase),
            transfer.desiredSnapshot.phase != .cancelling
        else { return }
        guard let receipt = try? claimTransition(id, to: .paused) else { return }
        await transfer.control.pause()
        try? await receipt.wait()
    }

    public func resume(_ id: TransferID) async throws {
        guard let transfer = transfers[id] else { throw MacChannelError.transferFailed }
        guard transfer.desiredSnapshot.phase == .paused else { return }
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
        guard transfers[id]?.desiredSnapshot.phase == resumedPhase else { return }
        await transfer.control.resume()
        if !active.contains(id), !pending.contains(id) { pending.append(id) }
        scheduleTransfers()
    }

    public func cancel(_ id: TransferID) async {
        guard let transfer = transfers[id], !isTerminal(transfer.desiredSnapshot.phase) else {
            return
        }
        guard (try? claimTransition(id, to: .cancelling)) != nil else { return }
        await transfer.control.cancel()
        pending.removeAll { $0 == id }
        guard active.contains(id), let runnerToken = transfer.runnerToken else {
            _ = try? claimTransition(id, to: .cancelled)
            scheduleTransfers()
            return
        }
        transfer.runner?.cancel()
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: cancellationWatchdogDelay)
            await self.forceCancelIfStillRunning(id, runnerToken: runnerToken)
        }
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
    func shutdownForRestart() async {
        guard !shuttingDown else { return }
        shuttingDown = true
        let channels = transfers.values.compactMap(\.channel)
        for transfer in transfers.values {
            transfer.runner?.cancel()
            transfer.persistenceWorker?.cancel()
            transfer.packageCleanupWorker?.cancel()
        }
        active.removeAll()
        pending.removeAll()
        await connectionAttempts.cancelAll()
        for channel in channels { await channel.close() }
    }

    func claimedPhase(for id: TransferID) -> TransferPhase? {
        transfers[id]?.desiredSnapshot.phase
    }

    func activeTransferCount() -> Int { active.count }

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
            channel: nil
        )
    }

    private func run(_ id: TransferID, runnerToken: UUID) async {
        var attempt = 0
        transferLoop: while attempt < maximumConnectionAttempts {
            var openedChannel: (any SecureChannel)?
            do {
                try Task.checkCancellation()
                try await transitionRespectingPause(id, intendedPhase: .connecting)
                try await waitForActiveControl(id)
                guard let lightweight = transfers[id], lightweight.runnerToken == runnerToken else {
                    throw CancellationError()
                }
                let channel = try await connectionAttempts.connect(
                    connector: connector,
                    peer: lightweight.peer,
                    transferID: id
                )
                openedChannel = channel
                try Task.checkCancellation()
                guard transfers[id]?.runnerToken == runnerToken else {
                    await channel.close()
                    throw CancellationError()
                }
                transfers[id]?.channel = channel

                // No PinnedSource exists before this point. A cancelled or stuck
                // connector therefore owns only peer/transfer identifiers.
                let manifest = try lightweight.package.openManifest()
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
                    control: lightweight.control
                ).run(on: channel)
                transfers[id]?.completedSession = true
                transfers[id]?.channel = nil
                await channel.close()
                try await transitionRespectingPause(id, intendedPhase: .verifying)
                try await waitForActiveControl(id)
                let completion = try claimCompletionIfStillVerifying(
                    id,
                    runnerToken: runnerToken,
                    completedBytes: lightweight.totalBytes
                )
                try await completion.wait()
                break transferLoop
            } catch {
                transfers[id]?.channel = nil
                if let openedChannel { await openedChannel.close() }
                if shuttingDown { break transferLoop }
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
            }
        }
        finishRun(id, runnerToken: runnerToken)
    }

    private func scheduleTransfers() {
        guard !shuttingDown else { return }
        while active.count < Self.maximumConcurrentTransfers,
            let index = pending.firstIndex(where: { id in
                guard let phase = transfers[id]?.desiredSnapshot.phase else { return false }
                return phase != .paused && phase != .cancelling && !isTerminal(phase)
            })
        {
            let id = pending.remove(at: index)
            active.insert(id)
            let runnerToken = UUID()
            let runner = Task { [weak self] in
                guard let self else { return }
                await self.run(id, runnerToken: runnerToken)
            }
            transfers[id]?.runner = runner
            transfers[id]?.runnerToken = runnerToken
        }
    }

    private func finishRun(_ id: TransferID, runnerToken: UUID) {
        guard transfers[id]?.runnerToken == runnerToken else { return }
        active.remove(id)
        transfers[id]?.runner = nil
        transfers[id]?.runnerToken = nil
        transfers[id]?.completedSession = false
        transfers[id]?.channel = nil
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

    /// The phase check and completion claim are one actor-isolated operation.
    /// A pause or cancellation that already claimed a newer epoch therefore
    /// wins; the continuation that persisted verification cannot overwrite it.
    private func claimCompletionIfStillVerifying(
        _ id: TransferID,
        runnerToken: UUID,
        completedBytes: Int64
    ) throws -> PersistenceCompletion {
        guard let transfer = transfers[id], transfer.runnerToken == runnerToken else {
            throw CancellationError()
        }
        guard transfer.desiredSnapshot.phase == .verifying else {
            if transfer.desiredSnapshot.phase == .cancelling
                || transfer.desiredSnapshot.phase == .cancelled
            {
                throw CancellationError()
            }
            throw MacChannelError.transferFailed
        }
        return try claimTransition(id, to: .completed, completedBytes: completedBytes)
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
        let packages = try OutgoingTransferPackage.loadAll(from: outgoingDirectory)
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
            else { throw TransferProtocolError.sourceChanged }
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
        if let channel = transfer.channel { await channel.close() }
        _ = try? claimTransition(id, to: .cancelled)
        guard var current = transfers[id], current.runnerToken == runnerToken else { return }
        active.remove(id)
        if let runner = current.runner {
            detachedRunners[runnerToken] = runner
            Task { [weak self] in
                await runner.value
                await self?.detachedRunnerFinished(runnerToken)
            }
        }
        current.runner = nil
        current.runnerToken = nil
        current.channel = nil
        transfers[id] = current
        archiveIfDurablyTerminal(id)
        scheduleTransfers()
    }

    private func detachedRunnerFinished(_ token: UUID) {
        detachedRunners.removeValue(forKey: token)
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
        transferID: TransferID
    ) async throws -> any SecureChannel {
        guard attempts.count < maximumRetainedAttempts else {
            throw MacChannelError.connectionFailed
        }
        let token = UUID()
        let gate = ConnectionAttemptGate()
        let task = Task { [weak self, connector, gate] in
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
