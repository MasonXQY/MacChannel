import Foundation

public actor TransferCoordinator: TransferCoordinating {
    private struct TransferTask {
        let manifest: TransferManifest
        let peer: DeviceID
        let displayFilename: String
        let totalBytes: Int64
        let control: TransferSessionControl
        var snapshot: TransferSnapshot
        var runner: Task<Void, Never>?
        var runnerToken: UUID?
        var channel: (any SecureChannel)?
    }

    private let connector: any PeerConnector
    private let database: TransferDatabase
    private let maximumConnectionAttempts: Int
    private var transfers: [TransferID: TransferTask] = [:]
    private var finishedSnapshots: [TransferID: TransferSnapshot] = [:]
    private var pending: [TransferID] = []
    private var active: Set<TransferID> = []
    private var subscribers: [UUID: AsyncStream<[TransferSnapshot]>.Continuation] = [:]

    public init(
        connector: any PeerConnector,
        database: TransferDatabase,
        maximumConnectionAttempts: Int = 3
    ) {
        self.connector = connector
        self.database = database
        self.maximumConnectionAttempts = max(1, maximumConnectionAttempts)
    }

    /// Restores privacy-limited history for UI snapshots. Since source paths and
    /// pinned descriptors are intentionally never persisted, an interrupted
    /// outbound process is durably marked failed; an inbound reconnect can still
    /// reactivate the same ID from `ReceiveStore`'s verified journal.
    public static func restoring(
        connector: any PeerConnector,
        database: TransferDatabase,
        maximumConnectionAttempts: Int = 3
    ) async throws -> TransferCoordinator {
        let coordinator = TransferCoordinator(
            connector: connector,
            database: database,
            maximumConnectionAttempts: maximumConnectionAttempts
        )
        try await coordinator.restoreHistory()
        return coordinator
    }

    deinit {
        for transfer in transfers.values {
            transfer.runner?.cancel()
        }
        for subscriber in subscribers.values {
            subscriber.finish()
        }
    }

    public func send(items: [URL], to device: DeviceID) async throws -> TransferID {
        guard items.count == 1, let item = items.first else {
            throw MacChannelError.invalidConfiguration(
                "A transfer currently requires exactly one file or folder root."
            )
        }
        let manifest = try TransferManifest.build(from: item)
        let totalBytes = try aggregateBytes(in: manifest)
        let id = manifest.id
        let snapshot = TransferSnapshot(
            id: id,
            peer: device,
            phase: .preparing,
            completedBytes: 0,
            totalBytes: totalBytes,
            route: .lan
        )
        let task = TransferTask(
            manifest: manifest,
            peer: device,
            displayFilename: item.lastPathComponent,
            totalBytes: totalBytes,
            control: TransferSessionControl(),
            snapshot: snapshot,
            runner: nil,
            runnerToken: nil,
            channel: nil
        )
        transfers[id] = task
        do {
            try await database.record(snapshot, displayFilename: task.displayFilename)
        } catch {
            transfers.removeValue(forKey: id)
            throw error
        }
        publishSnapshots()
        pending.append(id)
        scheduleTransfers()
        return id
    }

    public func pause(_ id: TransferID) async {
        guard let transfer = transfers[id], !isTerminal(transfer.snapshot.phase) else { return }
        do {
            try await transition(id, to: .paused)
        } catch {
            return
        }
        await transfer.control.pause()
    }

    public func resume(_ id: TransferID) async throws {
        guard let transfer = transfers[id] else { throw MacChannelError.transferFailed }
        guard transfer.snapshot.phase == .paused else { return }
        let resumedPhase: TransferPhase
        if !active.contains(id) {
            resumedPhase = .preparing
        } else if transfer.channel == nil {
            resumedPhase = .connecting
        } else {
            resumedPhase = .transferring
        }
        try await transition(id, to: resumedPhase)
        await transfer.control.resume()
        scheduleTransfers()
    }

    public func cancel(_ id: TransferID) async {
        guard let transfer = transfers[id], !isTerminal(transfer.snapshot.phase) else { return }
        do {
            try await transition(id, to: .cancelling)
        } catch {
            return
        }
        await transfer.control.cancel()
        if !active.contains(id) {
            pending.removeAll { $0 == id }
            transfer.runner?.cancel()
            try? await transition(id, to: .cancelled)
            scheduleTransfers()
            return
        }
        transfer.runner?.cancel()
        if let runnerToken = transfer.runnerToken {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                await self?.forceCancelIfStillRunning(id, runnerToken: runnerToken)
            }
        }
    }

    public func snapshots() -> AsyncStream<[TransferSnapshot]> {
        let token = UUID()
        let current = orderedSnapshots()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            subscribers[token] = continuation
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(token) }
            }
        }
    }

    private func run(_ id: TransferID) async {
        guard let transfer = transfers[id] else {
            finishRun(id)
            return
        }
        let progress = CoordinatorProgressRecorder(entries: transfer.manifest.entries) {
            [weak self] completedBytes in
            await self?.recordProgress(completedBytes, for: id)
        }
        var attempt = 0
        transferLoop: while attempt < maximumConnectionAttempts {
            var openedChannel: (any SecureChannel)?
            do {
                try Task.checkCancellation()
                try await transitionRespectingPause(id, intendedPhase: .connecting)
                let channel: any SecureChannel
                if let transferConnector = connector as? any TransferAwarePeerConnector {
                    channel = try await transferConnector.connect(
                        to: transfer.peer,
                        transferID: transfer.manifest.id
                    )
                } else {
                    channel = try await connector.connect(to: transfer.peer)
                }
                openedChannel = channel
                try Task.checkCancellation()
                guard transfers[id] != nil else {
                    await channel.close()
                    break transferLoop
                }
                transfers[id]?.channel = channel
                try await transitionRespectingPause(
                    id,
                    intendedPhase: .transferring,
                    route: channel.route
                )
                _ = try await SendSession(
                    transfer.manifest,
                    recorder: progress,
                    control: transfer.control
                ).run(on: channel)
                transfers[id]?.channel = nil
                await channel.close()
                try await transition(id, to: .verifying)
                try await transition(id, to: .completed, completedBytes: transfer.totalBytes)
                break transferLoop
            } catch {
                transfers[id]?.channel = nil
                if let openedChannel { await openedChannel.close() }
                if transfers[id]?.snapshot.phase == .cancelling
                    || (error as? TransferProtocolError) == .cancelled
                    || error is CancellationError
                {
                    try? await transition(id, to: .cancelled)
                    break transferLoop
                }
                guard isRetryableConnectionLoss(error) else {
                    try? await transition(id, to: .failed)
                    break transferLoop
                }
                attempt += 1
                if attempt >= maximumConnectionAttempts {
                    try? await transition(id, to: .failed)
                    break transferLoop
                }
            }
        }
        finishRun(id)
    }

    private func scheduleTransfers() {
        while active.count < 2,
            let index = pending.firstIndex(where: { id in
                guard let phase = transfers[id]?.snapshot.phase else { return false }
                return phase != .paused && phase != .cancelling && !isTerminal(phase)
            })
        {
            let id = pending.remove(at: index)
            active.insert(id)
            let runnerToken = UUID()
            let runner = Task { [weak self] in
                guard let self else { return }
                await self.run(id)
            }
            transfers[id]?.runner = runner
            transfers[id]?.runnerToken = runnerToken
        }
    }

    private func finishRun(_ id: TransferID) {
        active.remove(id)
        if let transfer = transfers[id], isTerminal(transfer.snapshot.phase) {
            finishedSnapshots[id] = transfer.snapshot
            transfers.removeValue(forKey: id)
            publishSnapshots()
        } else {
            transfers[id]?.runner = nil
            transfers[id]?.runnerToken = nil
        }
        scheduleTransfers()
    }

    private func transition(
        _ id: TransferID,
        to phase: TransferPhase,
        completedBytes: Int64? = nil,
        route: ConnectionRoute? = nil
    ) async throws {
        guard var transfer = transfers[id] else { throw MacChannelError.transferFailed }
        let snapshot = TransferSnapshot(
            id: id,
            peer: transfer.peer,
            phase: phase,
            completedBytes: completedBytes ?? transfer.snapshot.completedBytes,
            totalBytes: transfer.totalBytes,
            route: route ?? transfer.snapshot.route
        )
        try await database.record(snapshot, displayFilename: transfer.displayFilename)
        transfer.snapshot = snapshot
        transfers[id] = transfer
        publishSnapshots()
    }

    private func transitionRespectingPause(
        _ id: TransferID,
        intendedPhase: TransferPhase,
        route: ConnectionRoute? = nil
    ) async throws {
        guard let current = transfers[id]?.snapshot.phase else {
            throw MacChannelError.transferFailed
        }
        try await transition(
            id,
            to: current == .paused ? .paused : intendedPhase,
            route: route
        )
    }

    private func recordProgress(_ completedBytes: Int64, for id: TransferID) async {
        guard let transfer = transfers[id],
            !isTerminal(transfer.snapshot.phase),
            transfer.snapshot.phase != .cancelling,
            completedBytes > transfer.snapshot.completedBytes
        else { return }
        try? await transition(
            id,
            to: transfer.snapshot.phase,
            completedBytes: min(completedBytes, transfer.totalBytes)
        )
    }

    private func publishSnapshots() {
        let value = orderedSnapshots()
        var terminated: [UUID] = []
        for (token, subscriber) in subscribers {
            if case .terminated = subscriber.yield(value) {
                terminated.append(token)
            }
        }
        for token in terminated { subscribers.removeValue(forKey: token) }
    }

    private func orderedSnapshots() -> [TransferSnapshot] {
        var snapshots = finishedSnapshots
        for (id, transfer) in transfers { snapshots[id] = transfer.snapshot }
        return snapshots.values.sorted {
            $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
        }
    }

    private func restoreHistory() async throws {
        for record in try await database.history(limit: 10_000) {
            guard record.aggregateSize <= UInt64(Int64.max),
                record.completedBytes <= UInt64(Int64.max)
            else { throw ReceiveStoreError.databaseFailure }
            let recoveredPhase: TransferPhase
            switch record.phase {
            case .completed, .cancelled, .failed, .cancelling:
                recoveredPhase = record.phase
            default:
                recoveredPhase = .failed
            }
            let snapshot = TransferSnapshot(
                id: record.id,
                peer: record.peer,
                phase: recoveredPhase,
                completedBytes: Int64(record.completedBytes),
                totalBytes: Int64(record.aggregateSize),
                route: record.route
            )
            if recoveredPhase != record.phase {
                try await database.record(
                    snapshot,
                    displayFilename: record.displayFilename
                )
            }
            finishedSnapshots[record.id] = snapshot
        }
        publishSnapshots()
    }

    private func removeSubscriber(_ token: UUID) {
        subscribers.removeValue(forKey: token)
    }

    private func aggregateBytes(in manifest: TransferManifest) throws -> Int64 {
        var total: UInt64 = 0
        for entry in manifest.entries {
            guard total <= UInt64(Int64.max) - entry.size else {
                throw MacChannelError.transferFailed
            }
            total += entry.size
        }
        return Int64(total)
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

    private func forceCancelIfStillRunning(
        _ id: TransferID,
        runnerToken: UUID
    ) async {
        guard let transfer = transfers[id],
            transfer.runnerToken == runnerToken,
            transfer.snapshot.phase == .cancelling
        else { return }
        if let channel = transfer.channel { await channel.close() }
        try? await transition(id, to: .cancelled)
        finishRun(id)
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
        let offset =
            UInt64(coordinate.chunkIndex)
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
