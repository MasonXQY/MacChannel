import CryptoKit
import Darwin
import Foundation

public struct TransferReceiveResult: Equatable, Sendable {
    public let transferID: TransferID
    public let receivedURLs: [URL]

}

public struct ReceiveSession: Sendable {
    private struct DurableStorage: Sendable {
        let source: DeviceID
        let policy: ReceivePolicy
        let directories: DownloadDirectory
        let database: TransferDatabase
        let incomingDirectory: URL?
        let capacity: any ReceiveCapacityProviding
    }

    private let transferID: TransferID
    private let destinationDirectory: URL
    private let control: TransferSessionControl?
    private let durableStorage: DurableStorage?
    private let initialOfferTimeout: Duration?
    private let inactivityTimeout: Duration?
    private let closeChannelOnExit: Bool
    private let resourceOwnership: TransferIOResourceOwnership?
    private let onStagingPrepared: (@Sendable (URL) -> Void)?
    private let onCheckpointValidated: (@Sendable (String) -> Void)?
    private let onMetadataValidated: (@Sendable (String) -> Void)?

    public init(
        transferID: TransferID,
        destinationDirectory: URL,
        control: TransferSessionControl? = nil,
        initialOfferTimeout: Duration? = nil,
        inactivityTimeout: Duration? = nil,
        closeChannelOnExit: Bool = true
    ) {
        self.transferID = transferID
        self.destinationDirectory = destinationDirectory
        self.control = control
        durableStorage = nil
        self.initialOfferTimeout = initialOfferTimeout
        self.inactivityTimeout = inactivityTimeout
        self.closeChannelOnExit = closeChannelOnExit
        resourceOwnership = nil
        onStagingPrepared = nil
        onCheckpointValidated = nil
        onMetadataValidated = nil
    }

    init(
        transferID: TransferID,
        destinationDirectory: URL,
        control: TransferSessionControl? = nil,
        onStagingPrepared: @escaping @Sendable (URL) -> Void,
        onCheckpointValidated: (@Sendable (String) -> Void)? = nil,
        onMetadataValidated: (@Sendable (String) -> Void)? = nil
    ) {
        self.transferID = transferID
        self.destinationDirectory = destinationDirectory
        self.control = control
        durableStorage = nil
        initialOfferTimeout = nil
        inactivityTimeout = nil
        closeChannelOnExit = true
        resourceOwnership = nil
        self.onStagingPrepared = onStagingPrepared
        self.onCheckpointValidated = onCheckpointValidated
        self.onMetadataValidated = onMetadataValidated
    }

    /// Uses the hardened receive store for policy authorization, durable resume
    /// journals, database history, and atomic final publication.
    public init(
        transferID: TransferID,
        source: DeviceID,
        policy: ReceivePolicy,
        directories: DownloadDirectory = DownloadDirectory(),
        database: TransferDatabase,
        incomingDirectory: URL? = nil,
        capacity: any ReceiveCapacityProviding = VolumeReceiveCapacityProvider(),
        control: TransferSessionControl? = nil,
        initialOfferTimeout: Duration? = nil,
        inactivityTimeout: Duration? = nil,
        closeChannelOnExit: Bool = true
    ) {
        self.transferID = transferID
        destinationDirectory = directories.directory(for: source)
        self.control = control
        durableStorage = DurableStorage(
            source: source,
            policy: policy,
            directories: directories,
            database: database,
            incomingDirectory: incomingDirectory,
            capacity: capacity
        )
        self.initialOfferTimeout = initialOfferTimeout
        self.inactivityTimeout = inactivityTimeout
        self.closeChannelOnExit = closeChannelOnExit
        resourceOwnership = nil
        onStagingPrepared = nil
        onCheckpointValidated = nil
        onMetadataValidated = nil
    }

    init(
        transferID: TransferID,
        source: DeviceID,
        policy: ReceivePolicy,
        directories: DownloadDirectory,
        database: TransferDatabase,
        incomingDirectory: URL?,
        capacity: any ReceiveCapacityProviding,
        control: TransferSessionControl? = nil,
        initialOfferTimeout: Duration?,
        inactivityTimeout: Duration?,
        closeChannelOnExit: Bool,
        resourceOwnership: TransferIOResourceOwnership
    ) {
        self.transferID = transferID
        destinationDirectory = directories.directory(for: source)
        self.control = control
        durableStorage = DurableStorage(
            source: source,
            policy: policy,
            directories: directories,
            database: database,
            incomingDirectory: incomingDirectory,
            capacity: capacity
        )
        self.initialOfferTimeout = initialOfferTimeout
        self.inactivityTimeout = inactivityTimeout
        self.closeChannelOnExit = closeChannelOnExit
        self.resourceOwnership = resourceOwnership
        onStagingPrepared = nil
        onCheckpointValidated = nil
        onMetadataValidated = nil
    }

    public func run(on channel: any SecureChannel) async throws -> TransferReceiveResult {
        try await TransferIOResourceContext.$ownership.withValue(resourceOwnership) {
            try await runWithResourceOwnership(on: channel)
        }
    }

    private func runWithResourceOwnership(
        on channel: any SecureChannel
    ) async throws -> TransferReceiveResult {
        var outboundSequence: UInt64 = 0
        var terminationCrypto: TransferCryptographicContext?
        var receiveStorage: ReceiveSessionStorage?
        let initialClock = ContinuousClock()
        let initialOfferDeadline = initialOfferTimeout.map { initialClock.now + $0 }
        do {
            let crypto = try await prepareReceiverHandshake(
                transferID: transferID,
                on: channel,
                control: control,
                timeout: initialOfferTimeout
            )
            terminationCrypto = crypto
            let frameReader = await TransferFrameReader(
                stream: channel.frames(),
                transferID: transferID,
                direction: .senderToReceiver,
                cipher: crypto.senderToReceiver
            )
            var controlSnapshot = await control?.snapshot()
            if case .cancelled = controlSnapshot?.state {
                throw TransferProtocolError.cancelled
            }
            let first: TransferFrame
            initialOffer: while true {
                let remainingInitialOfferTime = initialOfferDeadline.map { deadline in
                    initialClock.now >= deadline
                        ? Duration.zero
                        : initialClock.now.duration(to: deadline)
                }
                let event = try await waitForTransferSessionEvent(
                    reader: frameReader,
                    control: control,
                    after: controlSnapshot,
                    timeout: remainingInitialOfferTime
                )
                switch event {
                case .frame(let frame):
                    first = frame
                    break initialOffer
                case .control(let changed):
                    controlSnapshot = changed
                    if case .cancelled = changed.state {
                        throw TransferProtocolError.cancelled
                    }
                case .timeout:
                    throw TransferProtocolError.channelEnded
                }
            }
            guard case .offer(let manifest) = first, manifest.id == transferID else {
                throw protocolError(for: first)
            }
            try validateReceivedManifest(manifest)
            try manifest.validateDestinationPaths(onVolumeContaining: destinationDirectory)
            if let durableStorage {
                let store = try await ReceiveStore.prepare(
                    manifest: manifest,
                    source: durableStorage.source,
                    policy: durableStorage.policy,
                    directories: durableStorage.directories,
                    database: durableStorage.database,
                    route: channel.route,
                    incomingDirectory: durableStorage.incomingDirectory,
                    capacity: durableStorage.capacity
                )
                receiveStorage = .durable(store)
            } else {
                let preparation = try ResumePreparation(
                    manifest: manifest,
                    destinationDirectory: destinationDirectory,
                    onCheckpointValidated: onCheckpointValidated
                )
                onStagingPrepared?(preparation.stagingDirectory)
                receiveStorage = .legacy(preparation)
            }
            guard var storage = receiveStorage else {
                throw TransferProtocolError.destinationEscape
            }
            var verified = try VerifiedChunks(await storage.resumeMap())
            try await send(
                .accept(verified.map),
                transferID: transferID,
                direction: .receiverToSender,
                on: channel,
                cipher: crypto.receiverToSender,
                sequence: &outboundSequence,
                control: control
            )

            var expected = nextMissing(in: manifest, verified: verified, after: nil)
            var chunksSinceAcknowledgement = 0
            let clock = ContinuousClock()
            var lastAcknowledgement = clock.now
            var lastInboundActivity = clock.now
            var announcedLocalPause = false
            var peerPaused = false
            while true {
                try await applyLocalControl(
                    on: channel,
                    cipher: crypto.receiverToSender,
                    sequence: &outboundSequence,
                    announcedPause: &announcedLocalPause,
                    snapshot: &controlSnapshot
                )
                var timeout = inactivityTimeout.map { inactivity in
                    let elapsed = lastInboundActivity.duration(to: clock.now)
                    return elapsed >= inactivity ? Duration.zero : inactivity - elapsed
                }
                if chunksSinceAcknowledgement > 0 {
                    let elapsed = lastAcknowledgement.duration(to: clock.now)
                    let acknowledgementTimeout =
                        elapsed >= .milliseconds(250)
                        ? .zero
                        : .milliseconds(250) - elapsed
                    timeout = timeout.map { min($0, acknowledgementTimeout) }
                        ?? acknowledgementTimeout
                }
                let event = try await waitForTransferSessionEvent(
                    reader: frameReader,
                    control: control,
                    after: controlSnapshot,
                    timeout: timeout
                )
                if case .control(let changed) = event {
                    controlSnapshot = changed
                    continue
                }
                if case .timeout = event {
                    if let inactivityTimeout,
                        lastInboundActivity.duration(to: clock.now) >= inactivityTimeout
                    {
                        throw TransferProtocolError.channelEnded
                    }
                    if chunksSinceAcknowledgement > 0,
                        lastAcknowledgement.duration(to: clock.now) >= .milliseconds(250)
                    {
                        try await send(
                            .ackRanges(verified.map),
                            transferID: transferID,
                            direction: .receiverToSender,
                            on: channel,
                            cipher: crypto.receiverToSender,
                            sequence: &outboundSequence,
                            control: control
                        )
                        chunksSinceAcknowledgement = 0
                        lastAcknowledgement = clock.now
                    }
                    continue
                }
                try Task.checkCancellation()
                if let control {
                    let latest = await control.snapshot()
                    if latest.revision != controlSnapshot?.revision {
                        controlSnapshot = latest
                        try await applyLocalControl(
                            on: channel,
                            cipher: crypto.receiverToSender,
                            sequence: &outboundSequence,
                            announcedPause: &announcedLocalPause,
                            snapshot: &controlSnapshot
                        )
                    }
                }
                guard case .frame(let frame) = event else {
                    throw TransferProtocolError.channelEnded
                }
                lastInboundActivity = clock.now
                switch frame {
                case .chunk(let chunk):
                    guard !peerPaused else { throw TransferProtocolError.unexpectedFrame }
                    guard let expectedCoordinate = expected,
                        chunk.coordinate == expectedCoordinate
                    else {
                        if verified.contains(chunk.coordinate) {
                            throw TransferProtocolError.duplicateChunk
                        }
                        throw TransferProtocolError.replayOrOutOfOrder
                    }
                    try validate(chunk: chunk, manifest: manifest)
                    try await storage.write(chunk, manifest: manifest)
                    receiveStorage = storage
                    try verified.insert(chunk.coordinate)
                    chunksSinceAcknowledgement += 1
                    let following = nextMissing(
                        in: manifest,
                        verified: verified,
                        after: chunk.coordinate
                    )
                    if chunksSinceAcknowledgement
                        >= TransferProtocolLimits.acknowledgementChunkInterval
                        || following == nil
                    {
                        try await send(
                            .ackRanges(verified.map),
                            transferID: transferID,
                            direction: .receiverToSender,
                            on: channel,
                            cipher: crypto.receiverToSender,
                            sequence: &outboundSequence,
                            control: control
                        )
                        chunksSinceAcknowledgement = 0
                        lastAcknowledgement = clock.now
                    }
                    expected = following
                case .complete:
                    guard expected == nil else { throw TransferProtocolError.invalidChunk }
                    if chunksSinceAcknowledgement > 0 {
                        try await send(
                            .ackRanges(verified.map),
                            transferID: transferID,
                            direction: .receiverToSender,
                            on: channel,
                            cipher: crypto.receiverToSender,
                            sequence: &outboundSequence,
                            control: control
                        )
                    }
                    let receivedURLs = try await storage.finalize(
                        manifest,
                        onMetadataValidated: onMetadataValidated
                    )
                    receiveStorage = storage
                    // Publication is the session commit point. Completion is a
                    // bounded notification: failure or cancellation here must
                    // not report that committed destination as a failed receive.
                    let notification = await sendTerminalFrameBestEffort(
                        .complete,
                        transferID: transferID,
                        direction: .receiverToSender,
                        on: channel,
                        cipher: crypto.receiverToSender,
                        sequence: outboundSequence
                    )
                    switch notification {
                    case .sent:
                        break
                    case .failed, .timedOut:
                        if closeChannelOnExit { await channel.close() }
                    }
                    return TransferReceiveResult(
                        transferID: transferID,
                        receivedURLs: receivedURLs
                    )
                case .cancel:
                    throw TransferProtocolError.cancelled
                case .pause:
                    guard !peerPaused else { throw TransferProtocolError.unexpectedFrame }
                    peerPaused = true
                case .resume:
                    guard peerPaused else { throw TransferProtocolError.unexpectedFrame }
                    peerPaused = false
                case .error(let remote):
                    throw mapRemoteError(remote)
                case .offer, .accept, .ackRanges:
                    throw TransferProtocolError.unexpectedFrame
                }
            }
        } catch {
            let cancelled =
                error is CancellationError
                || (error as? TransferProtocolError) == .cancelled
            if cancelled {
                await receiveStorage?.cancel()
            } else {
                await receiveStorage?.markFailed()
            }
            if let crypto = terminationCrypto {
                let terminalFrame: TransferFrame?
                if error is CancellationError
                    || (error as? TransferProtocolError) == .cancelled
                {
                    terminalFrame = .cancel
                } else if let code = remoteErrorCode(for: error) {
                    terminalFrame = .error(code)
                } else {
                    terminalFrame = nil
                }
                if let terminalFrame {
                    await sendTerminalFrameBestEffort(
                        terminalFrame,
                        transferID: transferID,
                        direction: .receiverToSender,
                        on: channel,
                        cipher: crypto.receiverToSender,
                        sequence: outboundSequence
                    )
                }
            }
            if closeChannelOnExit { await channel.close() }
            if error is CancellationError { throw TransferProtocolError.cancelled }
            throw error
        }
    }

    private func applyLocalControl(
        on channel: any SecureChannel,
        cipher: ChunkCipher,
        sequence: inout UInt64,
        announcedPause: inout Bool,
        snapshot: inout TransferSessionControl.Snapshot?
    ) async throws {
        guard let control else { return }
        var current: TransferSessionControl.Snapshot
        if let snapshot {
            current = snapshot
        } else {
            current = await control.snapshot()
        }
        while true {
            try Task.checkCancellation()
            switch current.state {
            case .active:
                if announcedPause {
                    try await send(
                        .resume,
                        transferID: transferID,
                        direction: .receiverToSender,
                        on: channel,
                        cipher: cipher,
                        sequence: &sequence,
                        control: control
                    )
                    announcedPause = false
                }
                snapshot = current
                return
            case .paused:
                if !announcedPause {
                    try await send(
                        .pause,
                        transferID: transferID,
                        direction: .receiverToSender,
                        on: channel,
                        cipher: cipher,
                        sequence: &sequence,
                        control: control
                    )
                    announcedPause = true
                }
                current = await control.waitForChange(after: current.revision)
            case .cancelled:
                throw TransferProtocolError.cancelled
            }
        }
    }

    private func validate(chunk: TransferChunk, manifest: TransferManifest) throws {
        guard Int(chunk.coordinate.entryIndex) < manifest.entries.count else {
            throw TransferProtocolError.invalidChunk
        }
        let entry = manifest.entries[Int(chunk.coordinate.entryIndex)]
        guard entry.kind == .file,
            chunk.coordinate.chunkIndex < entry.chunkCount
        else { throw TransferProtocolError.invalidChunk }
        let expectedOffset =
            UInt64(chunk.coordinate.chunkIndex)
            * UInt64(TransferProtocolLimits.maximumChunkBytes)
        let expectedLength = Int(
            min(
                UInt64(TransferProtocolLimits.maximumChunkBytes),
                entry.size - expectedOffset
            ))
        guard chunk.offset == expectedOffset, chunk.data.count == expectedLength else {
            throw TransferProtocolError.invalidChunk
        }
    }
}

private enum ReceiveSessionStorage: Sendable {
    case legacy(ResumePreparation)
    case durable(ReceiveStore)

    func resumeMap() async throws -> ResumeMap {
        switch self {
        case .legacy(let preparation):
            return try VerifiedChunks(preparation.verified).map
        case .durable(let store):
            return try await store.resumeMap()
        }
    }

    mutating func write(_ chunk: TransferChunk, manifest: TransferManifest) async throws {
        switch self {
        case .legacy(var preparation):
            let digest = try preparation.writeAndVerify(chunk, manifest: manifest)
            try preparation.resumeStore.append(chunk.coordinate, digest: digest)
            self = .legacy(preparation)
        case .durable(let store):
            try await store.write(
                chunk.data,
                index: chunk.coordinate.chunkIndex,
                entry: chunk.coordinate.entryIndex
            )
        }
    }

    mutating func finalize(
        _ manifest: TransferManifest,
        onMetadataValidated: (@Sendable (String) -> Void)?
    ) async throws -> [URL] {
        switch self {
        case .legacy(let preparation):
            try preparation.verifyCompletedFiles(manifest)
            let urls = try preparation.finalize(
                manifest,
                onMetadataValidated: onMetadataValidated
            )
            return urls
        case .durable(let store):
            return [try await store.finalize()]
        }
    }

    func cancel() async {
        if case .durable(let store) = self { try? await store.cancel() }
    }

    func markFailed() async {
        if case .durable(let store) = self { try? await store.markFailed() }
    }
}

enum TransferReadEvent: Sendable {
    case frame(TransferFrame)
    case timeout
}

final class TransferFrameReader: @unchecked Sendable {
    private let inbox: TransferFrameInbox
    private let readerTask: Task<Void, Never>

    init(
        stream: AsyncThrowingStream<Data, Error>,
        transferID: TransferID,
        direction: TransferDirection,
        cipher: ChunkCipher
    ) async {
        let inbox = TransferFrameInbox()
        let retainedOwnership = await Self.retainResourceOwnership()
        self.inbox = inbox
        readerTask = Self.startReader(
            iterator: stream.makeAsyncIterator(),
            inbox: inbox,
            transferID: transferID,
            direction: direction,
            cipher: cipher,
            retainedOwnership: retainedOwnership
        )
    }

    init(
        iterator: sending AsyncThrowingStream<Data, Error>.Iterator,
        transferID: TransferID,
        direction: TransferDirection,
        cipher: ChunkCipher
    ) async {
        let inbox = TransferFrameInbox()
        let retainedOwnership = await Self.retainResourceOwnership()
        self.inbox = inbox
        readerTask = Self.startReader(
            iterator: iterator,
            inbox: inbox,
            transferID: transferID,
            direction: direction,
            cipher: cipher,
            retainedOwnership: retainedOwnership
        )
    }

    init(bufferedFrames: [TransferFrame]) {
        inbox = TransferFrameInbox(frames: bufferedFrames)
        readerTask = Task {}
    }

    private static func startReader(
        iterator initialIterator: sending AsyncThrowingStream<Data, Error>.Iterator,
        inbox: TransferFrameInbox,
        transferID: TransferID,
        direction: TransferDirection,
        cipher: ChunkCipher,
        retainedOwnership: TransferIOResourceOwnership?
    ) -> Task<Void, Never> {
        Task {
            var sequence: UInt64 = 0
            var iterator = initialIterator
            do {
                while let wire = try await iterator.next() {
                    let plaintext = try cipher.openWire(
                        wire,
                        expectedTransfer: transferID,
                        expectedSequence: sequence,
                        expectedDirection: direction
                    )
                    let frame = try TransferFrame.decode(plaintext)
                    guard sequence < UInt64.max else {
                        throw TransferProtocolError.replayOrOutOfOrder
                    }
                    sequence += 1
                    guard await inbox.push(frame) else { break }
                }
                await inbox.finish(TransferProtocolError.channelEnded)
            } catch {
                await inbox.finish(error)
            }
            if let retainedOwnership {
                await retainedOwnership.registry.operationReturned(retainedOwnership.token)
            }
        }
    }

    private static func retainResourceOwnership() async -> TransferIOResourceOwnership? {
        guard let ownership = TransferIOResourceContext.ownership,
            await ownership.registry.retainOperation(ownership.token)
        else { return nil }
        return ownership
    }

    deinit { readerTask.cancel() }

    func next(timeout: Duration? = nil) async throws -> TransferReadEvent {
        try await inbox.next(timeout: timeout)
    }
}

private actor TransferFrameInbox {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<TransferReadEvent, Error>
        let timer: Task<Void, Never>?
    }

    private var frames: [TransferFrame] = []
    private var terminalError: Error?
    private var waiter: Waiter?

    init(frames: [TransferFrame] = []) {
        self.frames = frames
    }

    func push(_ frame: TransferFrame) -> Bool {
        guard terminalError == nil else { return false }
        if let waiter {
            self.waiter = nil
            waiter.timer?.cancel()
            waiter.continuation.resume(returning: .frame(frame))
        } else {
            guard frames.count < 128 else {
                frames.removeAll(keepingCapacity: false)
                terminalError = TransferProtocolError.invalidFrame
                return false
            }
            frames.append(frame)
        }
        return true
    }

    func finish(_ error: Error) {
        guard terminalError == nil else { return }
        terminalError = error
        if let waiter {
            self.waiter = nil
            waiter.timer?.cancel()
            waiter.continuation.resume(throwing: error)
        }
    }

    func next(timeout: Duration?) async throws -> TransferReadEvent {
        if !frames.isEmpty { return .frame(frames.removeFirst()) }
        if let terminalError { throw terminalError }
        guard waiter == nil else { throw TransferProtocolError.unexpectedFrame }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timer = timeout.map { timeout in
                    Task { [weak self] in
                        do {
                            try await Task.sleep(for: timeout)
                            await self?.timeout(id)
                        } catch {}
                    }
                }
                waiter = Waiter(id: id, continuation: continuation, timer: timer)
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func timeout(_ id: UUID) {
        guard let waiter, waiter.id == id else { return }
        self.waiter = nil
        waiter.continuation.resume(returning: .timeout)
    }

    private func cancel(_ id: UUID) {
        guard let waiter, waiter.id == id else { return }
        self.waiter = nil
        waiter.timer?.cancel()
        waiter.continuation.resume(throwing: CancellationError())
    }
}

private enum ReceiverHandshakeOutcome: @unchecked Sendable {
    case ready(TransferCryptographicContext)
    case failed(Error)
    case timedOut
    case cancelled
}

private actor ReceiverHandshakeCompletion {
    private var outcome: ReceiverHandshakeOutcome?
    private var waiter: CheckedContinuation<ReceiverHandshakeOutcome, Never>?

    func wait() async -> ReceiverHandshakeOutcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation in
            if let outcome {
                continuation.resume(returning: outcome)
            } else {
                waiter = continuation
            }
        }
    }

    func finish(_ outcome: ReceiverHandshakeOutcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        waiter?.resume(returning: outcome)
        waiter = nil
    }
}

/// Retains cancellation-insensitive pre-offer work until it actually exits and
/// refuses to create more once the explicit detached-operation bound is full.
/// Well-behaved channels are reaped immediately after close/cancellation.
actor ReceiverHandshakeOperationRegistry {
    static let shared = ReceiverHandshakeOperationRegistry()

    private var operations: [UUID: Task<Void, Never>] = [:]

    func start(_ operation: @escaping @Sendable () async -> Void) -> UUID? {
        guard operations.count < IncomingTransferCapacity.maximumDetachedHandshakeOperations else {
            return nil
        }
        let token = UUID()
        operations[token] = Task { [weak self] in
            await operation()
            await self?.finished(token)
        }
        return token
    }

    func cancel(_ token: UUID) {
        operations[token]?.cancel()
    }

    func activeCount() -> Int { operations.count }

    private func finished(_ token: UUID) {
        operations.removeValue(forKey: token)
    }
}

/// Bounds the entire pre-offer exchange, including a transport that ignores
/// cancellation while sending the receiver challenge or exporting keying
/// material. The listener can close the owned channel and release its slot
/// without awaiting that non-cooperative operation.
private func prepareReceiverHandshake(
    transferID: TransferID,
    on channel: any SecureChannel,
    control: TransferSessionControl?,
    timeout: Duration?
) async throws -> TransferCryptographicContext {
    let completion = ReceiverHandshakeCompletion()
    let retainedOwnership: TransferIOResourceOwnership?
    if let ownership = TransferIOResourceContext.ownership {
        guard await ownership.registry.retainOperation(ownership.token) else {
            throw TransferProtocolError.channelEnded
        }
        retainedOwnership = ownership
    } else {
        retainedOwnership = nil
    }
    guard let operationToken = await ReceiverHandshakeOperationRegistry.shared.start({
        do {
            let challenge = TransferReceiverChallenge.fresh(for: transferID)
            try await sendWireRespectingCancellation(
                challenge.encode(),
                on: channel,
                control: control
            )
            let crypto = try await TransferCryptographicContext.make(
                on: channel,
                transfer: transferID,
                receiverChallenge: challenge.bytes
            )
            await completion.finish(.ready(crypto))
        } catch {
            await completion.finish(.failed(error))
        }
        if let retainedOwnership {
            await retainedOwnership.registry.operationReturned(retainedOwnership.token)
        }
    }) else {
        if let retainedOwnership {
            await retainedOwnership.registry.operationReturned(retainedOwnership.token)
        }
        throw TransferProtocolError.channelEnded
    }
    let watchdog = timeout.map { timeout in
        Task {
            do {
                try await Task.sleep(for: timeout)
                await completion.finish(.timedOut)
            } catch {}
        }
    }
    let outcome = await withTaskCancellationHandler {
        await completion.wait()
    } onCancel: {
        Task { await completion.finish(.cancelled) }
    }
    await ReceiverHandshakeOperationRegistry.shared.cancel(operationToken)
    watchdog?.cancel()
    switch outcome {
    case .ready(let crypto):
        return crypto
    case .failed(let error):
        throw error
    case .timedOut:
        throw TransferProtocolError.channelEnded
    case .cancelled:
        throw TransferProtocolError.cancelled
    }
}

enum TransferSessionEvent: Sendable {
    case frame(TransferFrame)
    case timeout
    case control(TransferSessionControl.Snapshot)
}

func waitForTransferSessionEvent(
    reader: TransferFrameReader,
    control: TransferSessionControl?,
    after snapshot: TransferSessionControl.Snapshot?,
    timeout: Duration? = nil
) async throws -> TransferSessionEvent {
    guard let control, let snapshot else {
        return try await mapReadEvent(reader.next(timeout: timeout))
    }
    return try await withThrowingTaskGroup(of: TransferSessionEvent.self) { group in
        group.addTask {
            try await mapReadEvent(reader.next(timeout: timeout))
        }
        group.addTask {
            .control(await control.waitForChange(after: snapshot.revision))
        }
        guard var selected = try await group.next() else {
            throw TransferProtocolError.channelEnded
        }
        group.cancelAll()
        do {
            while let event = try await group.next() {
                selected = preferredTransferSessionEvent(selected, event)
            }
        } catch is CancellationError {
            // The losing pending read/control waiter was cancelled. If it had
            // already consumed a frame, it returns that frame before observing
            // cancellation and the preference below preserves it.
        } catch {
            if case .frame = selected { return selected }
            throw error
        }
        try Task.checkCancellation()
        if case .control(let unchanged) = selected,
            unchanged.revision == snapshot.revision
        {
            return .timeout
        }
        return selected
    }
}

private func preferredTransferSessionEvent(
    _ first: TransferSessionEvent,
    _ second: TransferSessionEvent
) -> TransferSessionEvent {
    if case .frame = first { return first }
    if case .frame = second { return second }
    if case .control = first { return first }
    if case .control = second { return second }
    return first
}

private func mapReadEvent(_ event: TransferReadEvent) -> TransferSessionEvent {
    switch event {
    case .frame(let frame): .frame(frame)
    case .timeout: .timeout
    }
}

private struct ResumePreparation {
    let destinationDirectory: URL
    let stagingDirectory: URL
    let tree: DescriptorStagingTree
    let files: [UInt32: StagedFile]
    var resumeStore: ResumeStateStore
    let verified: Set<ChunkCoordinate>

    init(
        manifest: TransferManifest,
        destinationDirectory: URL,
        onCheckpointValidated: (@Sendable (String) -> Void)?
    ) throws {
        self.destinationDirectory = destinationDirectory.standardizedFileURL
        if !FileManager.default.fileExists(atPath: self.destinationDirectory.path) {
            try FileManager.default.createDirectory(
                at: self.destinationDirectory,
                withIntermediateDirectories: true
            )
        }
        let suffix = manifest.id.rawValue.uuidString.lowercased()
        let rootName = manifest.entries[0].relativePath.components[0]
        let caseSensitive = try destinationVolumeSupportsCaseSensitiveNames(
            self.destinationDirectory
        )
        let rootKey = destinationFilesystemKey([rootName], caseSensitive: caseSensitive)
        let preferredStagingName = ".macchannel-\(suffix).partial"
        let stagingName =
            rootKey
                == destinationFilesystemKey(
                    [preferredStagingName], caseSensitive: caseSensitive)
            ? preferredStagingName + ".metadata" : preferredStagingName
        let preferredMetadataName = ".macchannel-protocol-\(suffix)"
        let metadataName =
            rootKey
                == destinationFilesystemKey(
                    [preferredMetadataName], caseSensitive: caseSensitive)
            ? preferredMetadataName + ".metadata" : preferredMetadataName
        stagingDirectory = self.destinationDirectory
            .appendingPathComponent(stagingName, isDirectory: true)
        tree = try DescriptorStagingTree(
            destinationDirectory: self.destinationDirectory,
            stagingName: stagingName,
            metadataName: metadataName
        )
        try tree.requireAbsentInDestination(rootName)
        var openedFiles: [UInt32: StagedFile] = [:]
        for (index, entry) in manifest.entries.enumerated() {
            switch entry.kind {
            case .directory:
                try tree.ensureDirectory(entry.relativePath.components)
            case .file:
                openedFiles[UInt32(index)] = try tree.openFile(
                    entry.relativePath.components,
                    create: true
                )
            }
        }
        files = openedFiles
        let fingerprint = try manifestFingerprint(manifest)
        let loaded = try ResumeStateStore.load(
            named: ".resume-state",
            fingerprint: fingerprint,
            manifest: manifest,
            tree: tree,
            files: openedFiles,
            onCheckpointValidated: onCheckpointValidated
        )
        resumeStore = loaded.store
        verified = loaded.verified
    }

    mutating func writeAndVerify(
        _ chunk: TransferChunk,
        manifest: TransferManifest
    ) throws -> Data {
        guard let file = files[chunk.coordinate.entryIndex] else {
            throw TransferProtocolError.destinationEscape
        }
        return try file.writeAndVerify(chunk.data, offset: chunk.offset)
    }

    func verifyCompletedFiles(_ manifest: TransferManifest) throws {
        for (index, entry) in manifest.entries.enumerated() where entry.kind == .file {
            guard let file = files[UInt32(index)],
                try file.currentSize() == entry.size,
                try file.digest(size: entry.size) == entry.digest
            else { throw TransferProtocolError.digestMismatch }
        }
    }

    func finalize(
        _ manifest: TransferManifest,
        onMetadataValidated: (@Sendable (String) -> Void)?
    ) throws -> [URL] {
        for (index, entry) in manifest.entries.enumerated() where entry.kind == .file {
            guard let file = files[UInt32(index)] else {
                throw TransferProtocolError.destinationEscape
            }
            try tree.requireIdentity(file, at: entry.relativePath.components)
            try file.setModificationDate(entry.modificationDate)
        }
        for entry in manifest.entries.reversed() where entry.kind == .directory {
            try tree.setDirectoryModificationDate(
                entry.modificationDate,
                components: entry.relativePath.components
            )
        }
        try resumeStore.remove()
        try tree.removeMetadataDirectory(onValidated: onMetadataValidated)
        let rootName = manifest.entries[0].relativePath.components[0]
        let isDirectory = manifest.entries[0].kind == .directory
        let finalRoot = destinationDirectory.appendingPathComponent(
            rootName, isDirectory: isDirectory)
        try tree.finalize(rootName: rootName)
        return [finalRoot]
    }
}

final class DescriptorStagingTree: @unchecked Sendable {
    let rootDescriptor: Int32
    let metadataDescriptor: Int32
    private let destinationDescriptor: Int32
    private let stagingName: String
    private let metadataName: String
    private let metadataDevice: dev_t
    private let metadataInode: ino_t
    private let stagingDevice: dev_t
    private let stagingInode: ino_t

    convenience init(destinationDirectory: URL, stagingName: String, metadataName: String) throws {
        let destinationDescriptor = Darwin.open(
            destinationDirectory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard destinationDescriptor >= 0 else {
            throw TransferProtocolError.destinationEscape
        }
        defer { Darwin.close(destinationDescriptor) }
        try self.init(
            destinationDescriptor: destinationDescriptor,
            stagingName: stagingName,
            metadataName: metadataName
        )
    }

    init(
        destinationDescriptor sourceDescriptor: Int32,
        stagingName: String,
        metadataName: String,
        onStagingDirectoryCreated: () throws -> Void = {}
    ) throws {
        let destinationDescriptor = Darwin.openat(
            sourceDescriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard destinationDescriptor >= 0 else {
            throw TransferProtocolError.destinationEscape
        }
        self.destinationDescriptor = destinationDescriptor
        self.stagingName = stagingName
        self.metadataName = metadataName
        if mkdirat(destinationDescriptor, stagingName, S_IRWXU) != 0, errno != EEXIST {
            Darwin.close(destinationDescriptor)
            throw TransferProtocolError.destinationEscape
        }
        rootDescriptor = Darwin.openat(
            destinationDescriptor,
            stagingName,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard rootDescriptor >= 0 else {
            Darwin.close(destinationDescriptor)
            throw TransferProtocolError.destinationEscape
        }
        var status = stat()
        guard fstat(rootDescriptor, &status) == 0,
            status.st_mode & S_IFMT == S_IFDIR,
            status.st_uid == geteuid(),
            status.st_mode & 0o077 == 0
        else {
            Darwin.close(rootDescriptor)
            Darwin.close(destinationDescriptor)
            throw TransferProtocolError.destinationEscape
        }
        stagingDevice = status.st_dev
        stagingInode = status.st_ino
        do {
            try onStagingDirectoryCreated()
        } catch {
            Darwin.close(rootDescriptor)
            Darwin.close(destinationDescriptor)
            throw error
        }
        do {
            try removeStaleMetadataRetirements(rootDescriptor: rootDescriptor)
        } catch {
            Darwin.close(rootDescriptor)
            Darwin.close(destinationDescriptor)
            throw error
        }
        if mkdirat(rootDescriptor, metadataName, S_IRWXU) != 0, errno != EEXIST {
            Darwin.close(rootDescriptor)
            Darwin.close(destinationDescriptor)
            throw TransferProtocolError.destinationEscape
        }
        metadataDescriptor = Darwin.openat(
            rootDescriptor,
            metadataName,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard metadataDescriptor >= 0 else {
            Darwin.close(rootDescriptor)
            Darwin.close(destinationDescriptor)
            throw TransferProtocolError.destinationEscape
        }
        var metadataStatus = stat()
        guard fstat(metadataDescriptor, &metadataStatus) == 0,
            metadataStatus.st_mode & S_IFMT == S_IFDIR,
            metadataStatus.st_uid == geteuid(),
            metadataStatus.st_mode & 0o077 == 0
        else {
            Darwin.close(metadataDescriptor)
            Darwin.close(rootDescriptor)
            Darwin.close(destinationDescriptor)
            throw TransferProtocolError.destinationEscape
        }
        metadataDevice = metadataStatus.st_dev
        metadataInode = metadataStatus.st_ino
    }

    deinit {
        Darwin.close(metadataDescriptor)
        Darwin.close(rootDescriptor)
        Darwin.close(destinationDescriptor)
    }

    func requireAbsentInDestination(_ name: String) throws {
        var status = stat()
        if fstatat(destinationDescriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 {
            throw TransferProtocolError.destinationExists
        }
        guard errno == ENOENT else { throw TransferProtocolError.destinationEscape }
    }

    func containsRootEntry(_ name: String) throws -> Bool {
        var status = stat()
        if fstatat(rootDescriptor, name, &status, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw TransferProtocolError.destinationEscape }
            return false
        }
        guard status.st_uid == geteuid(),
            status.st_mode & S_IFMT == S_IFREG || status.st_mode & S_IFMT == S_IFDIR
        else { throw TransferProtocolError.destinationEscape }
        return true
    }

    func ensureDirectory(_ components: [String]) throws {
        let descriptor = try openDirectory(components, create: true)
        Darwin.close(descriptor)
    }

    func openFile(_ components: [String], create: Bool) throws -> StagedFile {
        guard let name = components.last else { throw TransferProtocolError.destinationEscape }
        let parent = try openDirectory(Array(components.dropLast()), create: create)
        defer { Darwin.close(parent) }
        var flags = O_RDWR | O_CLOEXEC | O_NOFOLLOW
        if create { flags |= O_CREAT }
        let descriptor = Darwin.openat(parent, name, flags, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw TransferProtocolError.destinationEscape }
        do {
            return try StagedFile(descriptor: descriptor)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    func requireIdentity(_ file: StagedFile, at components: [String]) throws {
        let current = try openFile(components, create: false)
        guard try file.hasSameIdentity(as: current) else {
            throw TransferProtocolError.destinationEscape
        }
    }

    func setDirectoryModificationDate(_ date: Date, components: [String]) throws {
        let descriptor = try openDirectory(components, create: false)
        defer { Darwin.close(descriptor) }
        try setDescriptorModificationDate(descriptor, date: date)
    }

    func removeMetadataDirectory(
        onValidated: (@Sendable (String) throws -> Void)?
    ) throws {
        try requireMetadataDirectoryEmpty()
        guard fsync(metadataDescriptor) == 0 else {
            throw TransferProtocolError.destinationEscape
        }
        let quarantineName = ".macchannel-metadata-retired-\(UUID().uuidString.lowercased())"
        guard
            renameatx_np(
                rootDescriptor,
                metadataName,
                rootDescriptor,
                quarantineName,
                UInt32(RENAME_EXCL)
            ) == 0
        else { throw TransferProtocolError.destinationEscape }
        let quarantineDescriptor = Darwin.openat(
            rootDescriptor,
            quarantineName,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard quarantineDescriptor >= 0 else {
            throw TransferProtocolError.destinationEscape
        }
        defer { Darwin.close(quarantineDescriptor) }
        var quarantinedStatus = stat()
        guard
            fstat(quarantineDescriptor, &quarantinedStatus) == 0,
            quarantinedStatus.st_mode & S_IFMT == S_IFDIR,
            quarantinedStatus.st_dev == metadataDevice,
            quarantinedStatus.st_ino == metadataInode
        else { throw TransferProtocolError.destinationEscape }
        try onValidated?(quarantineName)
        var namedStatus = stat()
        guard
            fstatat(
                rootDescriptor,
                quarantineName,
                &namedStatus,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            namedStatus.st_mode & S_IFMT == S_IFDIR,
            namedStatus.st_dev == metadataDevice,
            namedStatus.st_ino == metadataInode,
            unlinkat(rootDescriptor, quarantineName, AT_REMOVEDIR) == 0
        else { throw TransferProtocolError.destinationEscape }
        var replacement = stat()
        guard
            fstatat(
                rootDescriptor,
                quarantineName,
                &replacement,
                AT_SYMLINK_NOFOLLOW
            ) != 0,
            errno == ENOENT
        else { throw TransferProtocolError.destinationEscape }
    }

    private func requireMetadataDirectoryEmpty() throws {
        let independentDescriptor = Darwin.openat(
            metadataDescriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard independentDescriptor >= 0,
            let directory = fdopendir(independentDescriptor)
        else {
            if independentDescriptor >= 0 { Darwin.close(independentDescriptor) }
            throw TransferProtocolError.destinationEscape
        }
        errno = 0
        var foundEntry = false
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." {
                foundEntry = true
                break
            }
        }
        let readError = errno
        guard closedir(directory) == 0, readError == 0, !foundEntry else {
            throw TransferProtocolError.destinationEscape
        }
    }

    func finalize(rootName: String) throws {
        guard
            renameatx_np(
                rootDescriptor,
                rootName,
                destinationDescriptor,
                rootName,
                UInt32(RENAME_EXCL)
            ) == 0
        else {
            if errno == EEXIST { throw TransferProtocolError.destinationExists }
            throw TransferProtocolError.destinationEscape
        }
        // Publication is the commit point. A same-owner process may add an
        // unrelated staging entry after the verified metadata directory was
        // removed. That can leave an empty/private staging remnant, but must not
        // turn an already-published verified transfer into a reported failure.
        _ = fsync(destinationDescriptor)
        _ = unlinkat(destinationDescriptor, stagingName, AT_REMOVEDIR)
    }

    func finalize(
        rootName: String,
        isDirectory: Bool,
        destinationDirectory: URL,
        destinationDescriptor descriptor: Int32,
        onCandidate: (String) throws -> Void = { _ in }
    ) throws -> URL {
        let destination = destinationDirectory.standardizedFileURL
        var status = stat()
        guard fstat(descriptor, &status) == 0,
            status.st_mode & S_IFMT == S_IFDIR,
            status.st_uid == geteuid(),
            status.st_mode & S_IWUSR != 0
        else { throw TransferProtocolError.destinationEscape }
        try requireStagingPathIdentity()

        var number = 1
        let configuredNameMaximum = fpathconf(descriptor, _PC_NAME_MAX)
        guard configuredNameMaximum > 0 else { throw TransferProtocolError.destinationEscape }
        let nameMaximum = Int(configuredNameMaximum)
        while number <= 10_000 {
            let candidate = numberedReceiveName(
                rootName,
                number: number,
                maximumBytes: nameMaximum
            )
            if try directoryContainsEquivalentName(descriptor, candidate: candidate) {
                number += 1
                continue
            }
            try onCandidate(candidate)
            if renameatx_np(
                rootDescriptor,
                rootName,
                descriptor,
                candidate,
                UInt32(RENAME_EXCL)
            ) == 0 {
                guard fsync(rootDescriptor) == 0, fsync(descriptor) == 0 else {
                    throw TransferProtocolError.destinationEscape
                }
                return destination.appendingPathComponent(candidate, isDirectory: isDirectory)
            }
            if errno == EEXIST {
                number += 1
                continue
            }
            throw TransferProtocolError.destinationEscape
        }
        throw TransferProtocolError.destinationExists
    }

    func removeEmptyStagingDirectory() throws {
        var current = stat()
        if fstatat(destinationDescriptor, stagingName, &current, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw TransferProtocolError.destinationEscape }
            return
        }
        guard current.st_mode & S_IFMT == S_IFDIR,
            current.st_dev == stagingDevice,
            current.st_ino == stagingInode,
            unlinkat(destinationDescriptor, stagingName, AT_REMOVEDIR) == 0,
            fsync(destinationDescriptor) == 0
        else { throw TransferProtocolError.destinationEscape }
    }

    func discard() throws {
        try requireStagingPathIdentity()
        try removeDirectoryContents(descriptor: rootDescriptor)
        var current = stat()
        guard fstatat(destinationDescriptor, stagingName, &current, AT_SYMLINK_NOFOLLOW) == 0,
            current.st_mode & S_IFMT == S_IFDIR,
            current.st_dev == stagingDevice,
            current.st_ino == stagingInode,
            unlinkat(destinationDescriptor, stagingName, AT_REMOVEDIR) == 0
        else { throw TransferProtocolError.destinationEscape }
        guard fsync(destinationDescriptor) == 0 else {
            throw TransferProtocolError.destinationEscape
        }
    }

    func requireStagingPathIdentity() throws {
        var current = stat()
        guard fstatat(destinationDescriptor, stagingName, &current, AT_SYMLINK_NOFOLLOW) == 0,
            current.st_mode & S_IFMT == S_IFDIR,
            current.st_dev == stagingDevice,
            current.st_ino == stagingInode
        else { throw TransferProtocolError.destinationEscape }
    }

    func requireExactEntries(
        _ entries: [TransferManifestEntry],
        caseSensitive: Bool
    ) throws {
        var actual: [String: TransferEntryKind] = [:]
        let root = entries[0].relativePath.components[0]
        try collectStagedEntries(
            parentDescriptor: rootDescriptor,
            name: root,
            components: [root],
            caseSensitive: caseSensitive,
            result: &actual
        )
        var expected: [String: TransferEntryKind] = [:]
        for entry in entries {
            let key = destinationFilesystemKey(
                entry.relativePath.components,
                caseSensitive: caseSensitive
            )
            guard expected.updateValue(entry.kind, forKey: key) == nil else {
                throw TransferProtocolError.destinationPathCollision
            }
        }
        guard actual == expected else { throw TransferProtocolError.destinationEscape }
    }

    func requireSafeCreationSubset(
        manifestRootName: String,
        entries: [TransferManifestEntry],
        allowedMetadataEntries: Set<String>,
        caseSensitive: Bool
    ) throws {
        try requireStagingPathIdentity()
        let rootNames = try exactDirectoryNames(rootDescriptor)
        guard rootNames.contains(metadataName),
            rootNames.isSubset(of: [manifestRootName, metadataName])
        else { throw TransferProtocolError.destinationEscape }

        var metadata = stat()
        guard fstatat(rootDescriptor, metadataName, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
            metadata.st_mode & S_IFMT == S_IFDIR,
            metadata.st_uid == geteuid(),
            metadata.st_dev == metadataDevice,
            metadata.st_ino == metadataInode
        else { throw TransferProtocolError.destinationEscape }
        let metadataNames = try exactDirectoryNames(metadataDescriptor)
        guard metadataNames.isSubset(of: allowedMetadataEntries) else {
            throw TransferProtocolError.destinationEscape
        }
        for name in metadataNames {
            var item = stat()
            guard fstatat(metadataDescriptor, name, &item, AT_SYMLINK_NOFOLLOW) == 0,
                item.st_mode & S_IFMT == S_IFREG,
                item.st_uid == geteuid(),
                item.st_nlink == 1
            else { throw TransferProtocolError.destinationEscape }
        }

        guard rootNames.contains(manifestRootName) else { return }
        var actual: [String: TransferEntryKind] = [:]
        try collectStagedEntries(
            parentDescriptor: rootDescriptor,
            name: manifestRootName,
            components: [manifestRootName],
            caseSensitive: caseSensitive,
            result: &actual
        )
        var expected: [String: TransferEntryKind] = [:]
        for entry in entries {
            let key = destinationFilesystemKey(
                entry.relativePath.components,
                caseSensitive: caseSensitive
            )
            guard expected.updateValue(entry.kind, forKey: key) == nil else {
                throw TransferProtocolError.destinationPathCollision
            }
        }
        for (key, kind) in actual where expected[key] != kind {
            throw TransferProtocolError.destinationEscape
        }
    }

    func requireExactStagingRoot(
        manifestRootName: String,
        metadataEntries expectedMetadataEntries: Set<String>
    ) throws {
        try requireStagingPathIdentity()
        guard try exactDirectoryNames(rootDescriptor) == Set([manifestRootName, metadataName])
        else { throw TransferProtocolError.destinationEscape }

        var metadata = stat()
        guard fstatat(rootDescriptor, metadataName, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
            metadata.st_mode & S_IFMT == S_IFDIR,
            metadata.st_uid == geteuid(),
            metadata.st_dev == metadataDevice,
            metadata.st_ino == metadataInode,
            try exactDirectoryNames(metadataDescriptor) == expectedMetadataEntries
        else { throw TransferProtocolError.destinationEscape }
    }

    private func exactDirectoryNames(_ descriptor: Int32) throws -> Set<String> {
        let independent = Darwin.openat(
            descriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard independent >= 0, let directory = fdopendir(independent) else {
            if independent >= 0 { Darwin.close(independent) }
            throw TransferProtocolError.destinationEscape
        }
        var names: Set<String> = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != ".", name != "..", !names.insert(name).inserted {
                _ = closedir(directory)
                throw TransferProtocolError.destinationEscape
            }
        }
        let readError = errno
        guard closedir(directory) == 0, readError == 0 else {
            throw TransferProtocolError.destinationEscape
        }
        return names
    }

    private func openDirectory(_ components: [String], create: Bool) throws -> Int32 {
        var current = dup(rootDescriptor)
        guard current >= 0 else { throw TransferProtocolError.destinationEscape }
        for component in components {
            if create, mkdirat(current, component, S_IRWXU) != 0, errno != EEXIST {
                Darwin.close(current)
                throw TransferProtocolError.destinationEscape
            }
            let next = Darwin.openat(
                current,
                component,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            Darwin.close(current)
            guard next >= 0 else { throw TransferProtocolError.destinationEscape }
            current = next
        }
        return current
    }
}

final class StagedFile: @unchecked Sendable {
    let descriptor: Int32
    private let device: dev_t
    private let inode: ino_t

    init(descriptor: Int32) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
            status.st_mode & S_IFMT == S_IFREG,
            status.st_nlink == 1
        else { throw TransferProtocolError.destinationEscape }
        self.descriptor = descriptor
        device = status.st_dev
        inode = status.st_ino
    }

    deinit { Darwin.close(descriptor) }

    func hasSameIdentity(as other: StagedFile) throws -> Bool {
        var status = stat()
        guard fstat(other.descriptor, &status) == 0,
            status.st_mode & S_IFMT == S_IFREG,
            status.st_nlink == 1
        else { throw TransferProtocolError.destinationEscape }
        return status.st_dev == device && status.st_ino == inode
    }

    func writeAndVerify(_ data: Data, offset: UInt64) throws -> Data {
        try writeAll(data, to: descriptor, offset: offset)
        guard fsync(descriptor) == 0 else { throw TransferProtocolError.destinationEscape }
        let written = try readExact(from: descriptor, offset: offset, length: data.count)
        guard written == data else { throw TransferProtocolError.digestMismatch }
        return Data(SHA256.hash(data: written))
    }

    func currentSize() throws -> UInt64 {
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_size >= 0 else {
            throw TransferProtocolError.destinationEscape
        }
        return UInt64(status.st_size)
    }

    func digest(size: UInt64) throws -> Data {
        var hasher = SHA256()
        var offset: UInt64 = 0
        while offset < size {
            let length = Int(
                min(
                    UInt64(TransferProtocolLimits.maximumChunkBytes),
                    size - offset
                ))
            hasher.update(
                data: try readExact(
                    from: descriptor,
                    offset: offset,
                    length: length
                ))
            offset += UInt64(length)
        }
        return Data(hasher.finalize())
    }

    func digest(offset: UInt64, length: Int) throws -> Data {
        Data(
            SHA256.hash(
                data: try readExact(
                    from: descriptor,
                    offset: offset,
                    length: length
                )))
    }

    func setModificationDate(_ date: Date) throws {
        try setDescriptorModificationDate(descriptor, date: date)
    }
}

final class ResumeStateStore: @unchecked Sendable {
    private static let magic = Data([0x4d, 0x43, 0x52, 0x53])  // MCRS
    private static let version: UInt8 = 2
    private static let headerBytes = 37
    private static let recordBodyBytes = 40
    private static let recordBytes = 72
    private static let maximumRecords = 1_000_000

    private let descriptor: Int32
    private let name: String
    private let tree: DescriptorStagingTree
    let fingerprint: Data

    private init(
        descriptor: Int32,
        name: String,
        tree: DescriptorStagingTree,
        fingerprint: Data
    ) {
        self.descriptor = descriptor
        self.name = name
        self.tree = tree
        self.fingerprint = fingerprint
    }

    static func requireCompatible(
        named name: String,
        fingerprint: Data,
        tree: DescriptorStagingTree
    ) throws {
        guard fingerprint.count == 32 else { throw TransferProtocolError.invalidResumeMap }
        let descriptor = Darwin.openat(
            tree.metadataDescriptor,
            name,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        if descriptor < 0 {
            guard errno == ENOENT else { throw TransferProtocolError.destinationEscape }
            return
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
            status.st_mode & S_IFMT == S_IFREG,
            status.st_uid == geteuid(),
            status.st_nlink == 1,
            status.st_size >= headerBytes
        else { throw TransferProtocolError.invalidResumeMap }
        let header = try readExact(from: descriptor, offset: 0, length: headerBytes)
        guard header.prefix(4) == magic,
            header[4] == version,
            header.subdata(in: 5..<headerBytes) == fingerprint
        else { throw TransferProtocolError.invalidResumeMap }
    }

    deinit { Darwin.close(descriptor) }

    static func load(
        named name: String,
        fingerprint: Data,
        manifest: TransferManifest,
        tree: DescriptorStagingTree,
        files: [UInt32: StagedFile],
        onCheckpointValidated: (@Sendable (String) -> Void)?
    ) throws -> (store: ResumeStateStore, verified: Set<ChunkCoordinate>) {
        guard fingerprint.count == 32 else { throw TransferProtocolError.invalidResumeMap }
        try removeStaleCheckpoints(
            from: tree,
            onCheckpointValidated: onCheckpointValidated
        )
        let descriptor = Darwin.openat(
            tree.metadataDescriptor,
            name,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw TransferProtocolError.destinationEscape }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
            status.st_mode & S_IFMT == S_IFREG,
            status.st_nlink == 1,
            status.st_size >= 0,
            UInt64(status.st_size) <= UInt64(headerBytes + recordBytes * maximumRecords)
        else { throw TransferProtocolError.destinationEscape }
        var candidates: [(ChunkCoordinate, Data)] = []
        if status.st_size > 0 {
            let data = try readExact(
                from: descriptor,
                offset: 0,
                length: Int(status.st_size)
            )
            guard data.count >= headerBytes,
                data.prefix(4) == magic,
                data[4] == version,
                data.subdata(in: 5..<37) == fingerprint
            else { throw TransferProtocolError.invalidResumeMap }
            var offset = headerBytes
            var seen: Set<ChunkCoordinate> = []
            let completeRecordBytes = (data.count - headerBytes) / recordBytes * recordBytes
            let validEnd = headerBytes + completeRecordBytes
            while offset < validEnd {
                let body = data.subdata(in: offset..<(offset + recordBodyBytes))
                let checksum = data.subdata(
                    in: (offset + recordBodyBytes)..<(offset + recordBytes)
                )
                guard checksum == recordChecksum(fingerprint: fingerprint, body: body) else {
                    throw TransferProtocolError.invalidResumeMap
                }
                let entry = readUInt32(data, at: offset)
                let chunk = readUInt32(data, at: offset + 4)
                let digest = data.subdata(in: (offset + 8)..<(offset + recordBodyBytes))
                let coordinate = ChunkCoordinate(entryIndex: entry, chunkIndex: chunk)
                guard seen.insert(coordinate).inserted else {
                    throw TransferProtocolError.invalidResumeMap
                }
                candidates.append((coordinate, digest))
                offset += recordBytes
            }
        }

        var verified: Set<ChunkCoordinate> = []
        var verifiedRecords: [(ChunkCoordinate, Data)] = []
        for (coordinate, expectedDigest) in candidates {
            guard Int(coordinate.entryIndex) < manifest.entries.count else { continue }
            let entry = manifest.entries[Int(coordinate.entryIndex)]
            guard entry.kind == .file, coordinate.chunkIndex < entry.chunkCount else { continue }
            let offset =
                UInt64(coordinate.chunkIndex)
                * UInt64(TransferProtocolLimits.maximumChunkBytes)
            let length = Int(
                min(
                    UInt64(TransferProtocolLimits.maximumChunkBytes),
                    entry.size - offset
                ))
            guard let file = files[coordinate.entryIndex],
                let digest = try? file.digest(offset: offset, length: length),
                digest == expectedDigest
            else { continue }
            verified.insert(coordinate)
            verifiedRecords.append((coordinate, digest))
        }
        let boundedVerified = boundedResumeCoordinates(verified)
        verifiedRecords = verifiedRecords.filter { boundedVerified.contains($0.0) }
        let compactedDescriptor = try writeState(
            named: name,
            tree: tree,
            fingerprint: fingerprint,
            records: verifiedRecords
        )
        return (
            ResumeStateStore(
                descriptor: compactedDescriptor,
                name: name,
                tree: tree,
                fingerprint: fingerprint
            ),
            boundedVerified
        )
    }

    func append(_ coordinate: ChunkCoordinate, digest: Data) throws {
        guard digest.count == 32 else { throw TransferProtocolError.invalidResumeMap }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_size >= 0 else {
            throw TransferProtocolError.invalidResumeMap
        }
        let offset = UInt64(status.st_size)
        guard offset <= UInt64(Self.headerBytes + Self.recordBytes * (Self.maximumRecords - 1))
        else {
            throw TransferProtocolError.invalidResumeMap
        }
        var record = Data()
        appendUInt32(coordinate.entryIndex, to: &record)
        appendUInt32(coordinate.chunkIndex, to: &record)
        record.append(digest)
        record.append(Self.recordChecksum(fingerprint: fingerprint, body: record))
        try writeAll(record, to: descriptor, offset: offset)
        guard fsync(descriptor) == 0 else { throw TransferProtocolError.destinationEscape }
    }

    func remove() throws {
        try Self.remove(named: name, tree: tree)
    }

    static func remove(named name: String, tree: DescriptorStagingTree) throws {
        var status = stat()
        if fstatat(tree.metadataDescriptor, name, &status, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw TransferProtocolError.destinationEscape }
            return
        }
        guard status.st_mode & S_IFMT == S_IFREG,
            status.st_uid == geteuid(),
            status.st_nlink == 1,
            unlinkat(tree.metadataDescriptor, name, 0) == 0,
            fsync(tree.metadataDescriptor) == 0
        else {
            throw TransferProtocolError.destinationEscape
        }
    }

    private static func writeState(
        named name: String,
        tree: DescriptorStagingTree,
        fingerprint: Data,
        records: [(ChunkCoordinate, Data)]
    ) throws -> Int32 {
        var data = magic
        data.append(version)
        data.append(fingerprint)
        for (coordinate, digest) in records.sorted(by: { $0.0 < $1.0 }) {
            var record = Data()
            appendUInt32(coordinate.entryIndex, to: &record)
            appendUInt32(coordinate.chunkIndex, to: &record)
            record.append(digest)
            data.append(record)
            data.append(recordChecksum(fingerprint: fingerprint, body: record))
        }
        let temporaryName = ".resume-checkpoint-\(UUID().uuidString.lowercased())"
        let temporaryDescriptor = Darwin.openat(
            tree.metadataDescriptor,
            temporaryName,
            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard temporaryDescriptor >= 0 else {
            throw TransferProtocolError.destinationEscape
        }
        var keepTemporary = true
        defer {
            Darwin.close(temporaryDescriptor)
            if keepTemporary {
                _ = unlinkat(tree.metadataDescriptor, temporaryName, 0)
            }
        }
        try writeAll(data, to: temporaryDescriptor, offset: 0)
        guard fsync(temporaryDescriptor) == 0,
            renameat(
                tree.metadataDescriptor,
                temporaryName,
                tree.metadataDescriptor,
                name
            ) == 0
        else { throw TransferProtocolError.destinationEscape }
        guard fsync(tree.metadataDescriptor) == 0 else {
            throw TransferProtocolError.destinationEscape
        }
        keepTemporary = false
        let replacement = Darwin.openat(
            tree.metadataDescriptor,
            name,
            O_RDWR | O_CLOEXEC | O_NOFOLLOW
        )
        guard replacement >= 0 else { throw TransferProtocolError.destinationEscape }
        var status = stat()
        guard fstat(replacement, &status) == 0,
            status.st_mode & S_IFMT == S_IFREG,
            status.st_nlink == 1
        else {
            Darwin.close(replacement)
            throw TransferProtocolError.destinationEscape
        }
        return replacement
    }

    private static func removeStaleCheckpoints(
        from tree: DescriptorStagingTree,
        onCheckpointValidated: (@Sendable (String) -> Void)?
    ) throws {
        let independentDescriptor = Darwin.openat(
            tree.metadataDescriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard independentDescriptor >= 0,
            let directory = fdopendir(independentDescriptor)
        else {
            if independentDescriptor >= 0 { Darwin.close(independentDescriptor) }
            throw TransferProtocolError.destinationEscape
        }
        var names: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if isRecognizedCheckpointName(name) { names.append(name) }
        }
        let readError = errno
        guard closedir(directory) == 0, readError == 0 else {
            throw TransferProtocolError.destinationEscape
        }
        guard names.count <= TransferProtocolLimits.maximumManifestEntries else {
            throw TransferProtocolError.manifestTooLarge
        }
        for name in names {
            try removeStaleCheckpoint(
                named: name,
                from: tree,
                onCheckpointValidated: onCheckpointValidated
            )
        }
        guard fsync(tree.metadataDescriptor) == 0 else {
            throw TransferProtocolError.destinationEscape
        }
    }

    private static func removeStaleCheckpoint(
        named name: String,
        from tree: DescriptorStagingTree,
        onCheckpointValidated: (@Sendable (String) -> Void)?
    ) throws {
        let quarantineName = ".resume-retired-\(UUID().uuidString.lowercased())"
        guard
            renameatx_np(
                tree.metadataDescriptor,
                name,
                tree.metadataDescriptor,
                quarantineName,
                UInt32(RENAME_EXCL)
            ) == 0
        else { throw TransferProtocolError.destinationEscape }
        let checkpoint = Darwin.openat(
            tree.metadataDescriptor,
            quarantineName,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard checkpoint >= 0 else {
            throw TransferProtocolError.destinationEscape
        }
        defer { Darwin.close(checkpoint) }
        var status = stat()
        var namedStatus = stat()
        guard
            fstat(checkpoint, &status) == 0,
            status.st_mode & S_IFMT == S_IFREG,
            status.st_uid == geteuid(),
            status.st_nlink == 1
        else { throw TransferProtocolError.destinationEscape }
        onCheckpointValidated?(quarantineName)
        guard
            fstatat(
                tree.metadataDescriptor,
                quarantineName,
                &namedStatus,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            namedStatus.st_mode & S_IFMT == S_IFREG,
            namedStatus.st_dev == status.st_dev,
            namedStatus.st_ino == status.st_ino,
            unlinkat(tree.metadataDescriptor, quarantineName, 0) == 0,
            fstat(checkpoint, &status) == 0,
            status.st_nlink == 0
        else { throw TransferProtocolError.destinationEscape }
    }

    private static func isRecognizedCheckpointName(_ name: String) -> Bool {
        for prefix in [".resume-checkpoint-", ".resume-retired-"] {
            guard name.hasPrefix(prefix) else { continue }
            let suffix = String(name.dropFirst(prefix.count))
            guard let identifier = UUID(uuidString: suffix) else { return false }
            return suffix == identifier.uuidString.lowercased()
        }
        return false
    }

    private static func recordChecksum(fingerprint: Data, body: Data) -> Data {
        var material = fingerprint
        material.append(body)
        return Data(SHA256.hash(data: material))
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data.subdata(in: offset..<(offset + 4)).withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self).bigEndian
        }
    }
}

private func nextMissing(
    in manifest: TransferManifest,
    verified: VerifiedChunks,
    after previous: ChunkCoordinate?
) -> ChunkCoordinate? {
    var entryIndex = previous.map { Int($0.entryIndex) } ?? 0
    var chunkIndex = previous.map { $0.chunkIndex + 1 } ?? 0
    while entryIndex < manifest.entries.count {
        let entry = manifest.entries[entryIndex]
        while entry.kind == .file, chunkIndex < entry.chunkCount {
            let candidate = ChunkCoordinate(
                entryIndex: UInt32(entryIndex),
                chunkIndex: chunkIndex
            )
            if !verified.contains(candidate) { return candidate }
            chunkIndex += 1
        }
        entryIndex += 1
        chunkIndex = 0
    }
    return nil
}

// Resume advertisements are intentionally limited to one verified contiguous
// run per manifest entry. This bounds the map to the manifest entry cap and
// conservatively causes any other verified chunks to be resent.
private func boundedResumeCoordinates(
    _ coordinates: Set<ChunkCoordinate>
) -> Set<ChunkCoordinate> {
    var result: Set<ChunkCoordinate> = []
    var activeEntry: UInt32?
    var lastIncludedChunk: UInt32?
    for coordinate in coordinates.sorted() {
        if activeEntry != coordinate.entryIndex {
            activeEntry = coordinate.entryIndex
            lastIncludedChunk = coordinate.chunkIndex
            result.insert(coordinate)
        } else if lastIncludedChunk != nil,
            coordinate.chunkIndex == lastIncludedChunk! + 1
        {
            result.insert(coordinate)
            lastIncludedChunk = coordinate.chunkIndex
        }
    }
    return result
}

private struct VerifiedChunks {
    private var coordinates: Set<ChunkCoordinate>
    private(set) var map: ResumeMap

    init(_ coordinates: Set<ChunkCoordinate>) throws {
        self.coordinates = coordinates
        map = try Self.makeMap(from: coordinates)
    }

    init(_ map: ResumeMap) throws {
        var coordinates: Set<ChunkCoordinate> = []
        for range in map.ranges {
            for chunkIndex in range.lowerBound..<range.upperBound {
                coordinates.insert(
                    ChunkCoordinate(
                        entryIndex: range.entryIndex,
                        chunkIndex: chunkIndex
                    )
                )
            }
        }
        self.coordinates = coordinates
        self.map = try Self.makeMap(from: coordinates)
    }

    func contains(_ coordinate: ChunkCoordinate) -> Bool {
        coordinates.contains(coordinate)
    }

    mutating func insert(_ coordinate: ChunkCoordinate) throws {
        guard coordinates.insert(coordinate).inserted else {
            throw TransferProtocolError.duplicateChunk
        }
        map = try ResumeMap(
            ranges: map.ranges + [
                try ChunkRange(
                    entryIndex: coordinate.entryIndex,
                    lowerBound: coordinate.chunkIndex,
                    upperBound: coordinate.chunkIndex + 1
                )
            ])
    }

    private static func makeMap(from coordinates: Set<ChunkCoordinate>) throws -> ResumeMap {
        let sorted = coordinates.sorted()
        var ranges: [ChunkRange] = []
        var start: ChunkCoordinate?
        var previous: ChunkCoordinate?
        for coordinate in sorted {
            if start != nil, let previousValue = previous,
                coordinate.entryIndex == previousValue.entryIndex,
                coordinate.chunkIndex == previousValue.chunkIndex + 1
            {
                previous = coordinate
            } else {
                if let startValue = start, let previousValue = previous {
                    ranges.append(
                        try ChunkRange(
                            entryIndex: startValue.entryIndex,
                            lowerBound: startValue.chunkIndex,
                            upperBound: previousValue.chunkIndex + 1
                        ))
                }
                start = coordinate
                previous = coordinate
            }
        }
        if let start, let previous {
            ranges.append(
                try ChunkRange(
                    entryIndex: start.entryIndex,
                    lowerBound: start.chunkIndex,
                    upperBound: previous.chunkIndex + 1
                ))
        }
        return try ResumeMap(ranges: ranges)
    }
}

func validateReceivedManifest(_ manifest: TransferManifest) throws {
    try manifest.validateProtocolLimits()
    let root = manifest.entries[0].relativePath.components[0]
    let foldedRoot = root.lowercased()
    guard !foldedRoot.hasPrefix(".macchannel-metadata-retired-"),
        !foldedRoot.hasPrefix(".macchannel-metadata-reaping-")
    else { throw TransferProtocolError.invalidFrame }
    if manifest.entries.count > 1, manifest.entries[0].kind != .directory {
        throw TransferProtocolError.invalidFrame
    }
    var directories: Set<RelativePath> = []
    var seen: Set<RelativePath> = []
    for entry in manifest.entries {
        _ = try validatedModificationTimespec(entry.modificationDate)
        guard entry.relativePath.components[0] == root,
            seen.insert(entry.relativePath).inserted,
            entry.digest.count == 32
        else { throw TransferProtocolError.invalidFrame }
        switch entry.kind {
        case .directory:
            guard entry.size == 0,
                entry.chunkCount == 0,
                entry.digest == Data(SHA256.hash(data: Data()))
            else { throw TransferProtocolError.invalidFrame }
        case .file:
            let chunkSize = UInt64(TransferProtocolLimits.maximumChunkBytes)
            let expectedChunks =
                entry.size == 0
                ? 0
                : entry.size / chunkSize + (entry.size.isMultiple(of: chunkSize) ? 0 : 1)
            guard expectedChunks == UInt64(entry.chunkCount) else {
                throw TransferProtocolError.invalidFrame
            }
        }
        if entry.relativePath.components.count > 1 {
            let parent = try RelativePath(
                components: Array(entry.relativePath.components.dropLast()))
            guard directories.contains(parent) else { throw TransferProtocolError.invalidFrame }
        }
        if entry.kind == .directory { directories.insert(entry.relativePath) }
    }
}

func manifestFingerprint(_ manifest: TransferManifest) throws -> Data {
    Data(SHA256.hash(data: try TransferFrame.offer(manifest).encode()))
}

private func numberedReceiveName(
    _ original: String,
    number: Int,
    maximumBytes: Int
) -> String {
    guard number > 1 else { return original }
    let value = original as NSString
    let pathExtension = value.pathExtension
    let suffix = " \(number)"
    let extensionSuffix = pathExtension.isEmpty ? "" : ".\(pathExtension)"
    var stem = pathExtension.isEmpty ? original : value.deletingPathExtension
    if suffix.utf8.count + extensionSuffix.utf8.count >= maximumBytes {
        stem = original
    }
    let retainedExtension = stem == original ? "" : extensionSuffix
    let available = max(0, maximumBytes - suffix.utf8.count - retainedExtension.utf8.count)
    return prefixFittingUTF8(stem, maximumBytes: available) + suffix + retainedExtension
}

private func prefixFittingUTF8(_ value: String, maximumBytes: Int) -> String {
    var result = ""
    var bytes = 0
    for character in value {
        let addition = String(character)
        guard bytes + addition.utf8.count <= maximumBytes else { break }
        result.append(character)
        bytes += addition.utf8.count
    }
    return result
}

func directoryContainsEquivalentName(_ descriptor: Int32, candidate: String) throws -> Bool {
    let independent = Darwin.openat(
        descriptor,
        ".",
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard independent >= 0, let directory = fdopendir(independent) else {
        if independent >= 0 { Darwin.close(independent) }
        throw TransferProtocolError.destinationEscape
    }
    defer { closedir(directory) }
    let candidateKey = destinationFilesystemKey([candidate], caseSensitive: false)
    errno = 0
    while let entry = readdir(directory) {
        let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                String(cString: $0)
            }
        }
        if name != ".", name != "..",
            destinationFilesystemKey([name], caseSensitive: false) == candidateKey
        {
            return true
        }
    }
    guard errno == 0 else { throw TransferProtocolError.destinationEscape }
    return false
}

private func collectStagedEntries(
    parentDescriptor: Int32,
    name: String,
    components: [String],
    caseSensitive: Bool,
    result: inout [String: TransferEntryKind]
) throws {
    var status = stat()
    guard fstatat(parentDescriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0,
        status.st_uid == geteuid()
    else { throw TransferProtocolError.destinationEscape }
    let kind: TransferEntryKind
    switch status.st_mode & S_IFMT {
    case S_IFREG:
        kind = .file
    case S_IFDIR:
        kind = .directory
    default:
        throw TransferProtocolError.destinationEscape
    }
    let key = destinationFilesystemKey(components, caseSensitive: caseSensitive)
    guard result.updateValue(kind, forKey: key) == nil else {
        throw TransferProtocolError.destinationPathCollision
    }
    guard kind == .directory else { return }

    let descriptor = Darwin.openat(
        parentDescriptor,
        name,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else { throw TransferProtocolError.destinationEscape }
    defer { Darwin.close(descriptor) }
    let independent = Darwin.openat(
        descriptor,
        ".",
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard independent >= 0, let directory = fdopendir(independent) else {
        if independent >= 0 { Darwin.close(independent) }
        throw TransferProtocolError.destinationEscape
    }
    var names: [String] = []
    errno = 0
    while let entry = readdir(directory) {
        let child = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                String(cString: $0)
            }
        }
        if child != ".", child != ".." { names.append(child) }
    }
    let readError = errno
    guard closedir(directory) == 0, readError == 0 else {
        throw TransferProtocolError.destinationEscape
    }
    for child in names {
        try collectStagedEntries(
            parentDescriptor: descriptor,
            name: child,
            components: components + [child],
            caseSensitive: caseSensitive,
            result: &result
        )
    }
}

private func removeStaleMetadataRetirements(rootDescriptor: Int32) throws {
    let independent = Darwin.openat(
        rootDescriptor,
        ".",
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard independent >= 0, let directory = fdopendir(independent) else {
        if independent >= 0 { Darwin.close(independent) }
        throw TransferProtocolError.destinationEscape
    }
    var names: [String] = []
    errno = 0
    while let entry = readdir(directory) {
        let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                String(cString: $0)
            }
        }
        if isRecognizedMetadataRetirement(name) { names.append(name) }
    }
    let readError = errno
    guard closedir(directory) == 0, readError == 0,
        names.count <= TransferProtocolLimits.maximumManifestEntries
    else { throw TransferProtocolError.destinationEscape }

    for name in names {
        var named = stat()
        guard fstatat(rootDescriptor, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
            named.st_mode & S_IFMT == S_IFDIR,
            named.st_uid == geteuid(),
            named.st_mode & 0o077 == 0
        else { throw TransferProtocolError.destinationEscape }
        let quarantine = ".macchannel-metadata-reaping-\(UUID().uuidString.lowercased())"
        guard
            renameatx_np(
                rootDescriptor,
                name,
                rootDescriptor,
                quarantine,
                UInt32(RENAME_EXCL)
            ) == 0
        else { throw TransferProtocolError.destinationEscape }
        let retired = Darwin.openat(
            rootDescriptor,
            quarantine,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard retired >= 0 else { throw TransferProtocolError.destinationEscape }
        do {
            var opened = stat()
            guard fstat(retired, &opened) == 0,
                opened.st_mode & S_IFMT == S_IFDIR,
                opened.st_dev == named.st_dev,
                opened.st_ino == named.st_ino,
                opened.st_uid == geteuid(),
                opened.st_mode & 0o077 == 0
            else { throw TransferProtocolError.destinationEscape }
            try requireEmptyDirectory(retired)
            var current = stat()
            guard fstatat(rootDescriptor, quarantine, &current, AT_SYMLINK_NOFOLLOW) == 0,
                current.st_mode & S_IFMT == S_IFDIR,
                current.st_dev == named.st_dev,
                current.st_ino == named.st_ino,
                unlinkat(rootDescriptor, quarantine, AT_REMOVEDIR) == 0
            else { throw TransferProtocolError.destinationEscape }
            Darwin.close(retired)
        } catch {
            Darwin.close(retired)
            throw error
        }
    }
    guard fsync(rootDescriptor) == 0 else {
        throw TransferProtocolError.destinationEscape
    }
}

private func isRecognizedMetadataRetirement(_ name: String) -> Bool {
    for prefix in [".macchannel-metadata-retired-", ".macchannel-metadata-reaping-"] {
        guard name.hasPrefix(prefix) else { continue }
        let suffix = String(name.dropFirst(prefix.count))
        guard suffix == suffix.lowercased(), let identifier = UUID(uuidString: suffix) else {
            return false
        }
        return identifier.uuidString.lowercased() == suffix
    }
    return false
}

private func requireEmptyDirectory(_ descriptor: Int32) throws {
    let independent = Darwin.openat(
        descriptor,
        ".",
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard independent >= 0, let directory = fdopendir(independent) else {
        if independent >= 0 { Darwin.close(independent) }
        throw TransferProtocolError.destinationEscape
    }
    errno = 0
    var foundEntry = false
    while let entry = readdir(directory) {
        let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                String(cString: $0)
            }
        }
        if name != ".", name != ".." {
            foundEntry = true
            break
        }
    }
    let readError = errno
    guard closedir(directory) == 0, readError == 0, !foundEntry else {
        throw TransferProtocolError.destinationEscape
    }
}

func verifyPublishedManifest(
    parentDescriptor: Int32,
    candidate: String,
    manifest: TransferManifest,
    caseSensitive: Bool
) throws {
    let root = manifest.entries[0].relativePath.components[0]
    var actual: [String: TransferEntryKind] = [:]
    try collectStagedEntries(
        parentDescriptor: parentDescriptor,
        name: candidate,
        components: [root],
        caseSensitive: caseSensitive,
        result: &actual
    )
    var expected: [String: TransferEntryKind] = [:]
    for entry in manifest.entries {
        let key = destinationFilesystemKey(
            entry.relativePath.components,
            caseSensitive: caseSensitive
        )
        guard expected.updateValue(entry.kind, forKey: key) == nil else {
            throw TransferProtocolError.destinationPathCollision
        }
    }
    guard actual == expected else { throw TransferProtocolError.destinationEscape }

    for entry in manifest.entries where entry.kind == .file {
        let descriptor = try openPublishedFile(
            parentDescriptor: parentDescriptor,
            candidate: candidate,
            relativeComponents: Array(entry.relativePath.components.dropFirst())
        )
        var status = stat()
        guard fstat(descriptor, &status) == 0,
            status.st_mode & S_IFMT == S_IFREG,
            status.st_uid == geteuid(),
            status.st_nlink == 1,
            status.st_size >= 0,
            UInt64(status.st_size) == entry.size
        else {
            Darwin.close(descriptor)
            throw TransferProtocolError.destinationEscape
        }
        let file: StagedFile
        do {
            file = try StagedFile(descriptor: descriptor)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        guard try file.digest(size: entry.size) == entry.digest else {
            throw TransferProtocolError.digestMismatch
        }
    }
}

private func openPublishedFile(
    parentDescriptor: Int32,
    candidate: String,
    relativeComponents: [String]
) throws -> Int32 {
    if relativeComponents.isEmpty {
        let descriptor = Darwin.openat(
            parentDescriptor,
            candidate,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw TransferProtocolError.destinationEscape }
        return descriptor
    }
    var current = Darwin.openat(
        parentDescriptor,
        candidate,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard current >= 0 else { throw TransferProtocolError.destinationEscape }
    for component in relativeComponents.dropLast() {
        let next = Darwin.openat(
            current,
            component,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        Darwin.close(current)
        guard next >= 0 else { throw TransferProtocolError.destinationEscape }
        current = next
    }
    let descriptor = Darwin.openat(
        current,
        relativeComponents.last!,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW
    )
    Darwin.close(current)
    guard descriptor >= 0 else { throw TransferProtocolError.destinationEscape }
    return descriptor
}

private func removeDirectoryContents(descriptor: Int32) throws {
    let independent = Darwin.openat(
        descriptor,
        ".",
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard independent >= 0, let directory = fdopendir(independent) else {
        if independent >= 0 { Darwin.close(independent) }
        throw TransferProtocolError.destinationEscape
    }
    var names: [String] = []
    errno = 0
    while let entry = readdir(directory) {
        let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                String(cString: $0)
            }
        }
        if name != ".", name != ".." { names.append(name) }
    }
    let readError = errno
    guard closedir(directory) == 0, readError == 0 else {
        throw TransferProtocolError.destinationEscape
    }
    for name in names {
        var status = stat()
        guard fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0,
            status.st_uid == geteuid()
        else { throw TransferProtocolError.destinationEscape }
        if status.st_mode & S_IFMT == S_IFDIR {
            let child = Darwin.openat(
                descriptor,
                name,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            guard child >= 0 else { throw TransferProtocolError.destinationEscape }
            do {
                try removeDirectoryContents(descriptor: child)
                Darwin.close(child)
            } catch {
                Darwin.close(child)
                throw error
            }
            guard unlinkat(descriptor, name, AT_REMOVEDIR) == 0 else {
                throw TransferProtocolError.destinationEscape
            }
        } else {
            guard unlinkat(descriptor, name, 0) == 0 else {
                throw TransferProtocolError.destinationEscape
            }
        }
    }
    guard fsync(descriptor) == 0 else { throw TransferProtocolError.destinationEscape }
}

func secureRemoveStagingDirectory(
    transferID: TransferID,
    incomingDescriptor parent: Int32
) throws -> Bool {
    let name = transferID.rawValue.uuidString.lowercased()
    var named = stat()
    if fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) != 0 {
        guard errno == ENOENT else { throw TransferProtocolError.destinationEscape }
        return false
    }
    guard named.st_mode & S_IFMT == S_IFDIR,
        named.st_uid == geteuid(),
        named.st_mode & 0o077 == 0
    else { throw TransferProtocolError.destinationEscape }
    let quarantine = ".macchannel-expired-\(UUID().uuidString.lowercased())"
    guard renameatx_np(parent, name, parent, quarantine, UInt32(RENAME_EXCL)) == 0 else {
        throw TransferProtocolError.destinationEscape
    }
    guard fsync(parent) == 0 else { throw TransferProtocolError.destinationEscape }
    let directory = Darwin.openat(
        parent,
        quarantine,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard directory >= 0 else { throw TransferProtocolError.destinationEscape }
    defer { Darwin.close(directory) }
    var moved = stat()
    guard fstat(directory, &moved) == 0,
        moved.st_mode & S_IFMT == S_IFDIR,
        moved.st_dev == named.st_dev,
        moved.st_ino == named.st_ino
    else { throw TransferProtocolError.destinationEscape }
    try removeDirectoryContents(descriptor: directory)
    var current = stat()
    guard fstatat(parent, quarantine, &current, AT_SYMLINK_NOFOLLOW) == 0,
        current.st_mode & S_IFMT == S_IFDIR,
        current.st_dev == named.st_dev,
        current.st_ino == named.st_ino,
        unlinkat(parent, quarantine, AT_REMOVEDIR) == 0
    else { throw TransferProtocolError.destinationEscape }
    guard fsync(parent) == 0 else { throw TransferProtocolError.destinationEscape }
    return true
}

func secureRemoveExpiredQuarantines(incomingDescriptor parent: Int32) throws {
    let independent = Darwin.openat(
        parent,
        ".",
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard independent >= 0, let directory = fdopendir(independent) else {
        if independent >= 0 { Darwin.close(independent) }
        throw TransferProtocolError.destinationEscape
    }
    var names: [String] = []
    errno = 0
    while let entry = readdir(directory) {
        let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                String(cString: $0)
            }
        }
        if isRecognizedExpiredQuarantine(name) { names.append(name) }
    }
    let readError = errno
    guard closedir(directory) == 0, readError == 0 else {
        throw TransferProtocolError.destinationEscape
    }
    for name in names {
        var named = stat()
        guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
            named.st_mode & S_IFMT == S_IFDIR,
            named.st_uid == geteuid(),
            named.st_mode & 0o077 == 0
        else { throw TransferProtocolError.destinationEscape }
        let child = Darwin.openat(
            parent,
            name,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard child >= 0 else { throw TransferProtocolError.destinationEscape }
        do {
            var opened = stat()
            guard fstat(child, &opened) == 0,
                opened.st_dev == named.st_dev,
                opened.st_ino == named.st_ino
            else { throw TransferProtocolError.destinationEscape }
            try removeDirectoryContents(descriptor: child)
            Darwin.close(child)
        } catch {
            Darwin.close(child)
            throw error
        }
        var current = stat()
        guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
            current.st_dev == named.st_dev,
            current.st_ino == named.st_ino,
            unlinkat(parent, name, AT_REMOVEDIR) == 0
        else { throw TransferProtocolError.destinationEscape }
    }
    guard fsync(parent) == 0 else { throw TransferProtocolError.destinationEscape }
}

private func isRecognizedExpiredQuarantine(_ name: String) -> Bool {
    let prefix = ".macchannel-expired-"
    guard name.hasPrefix(prefix) else { return false }
    let suffix = String(name.dropFirst(prefix.count))
    guard suffix == suffix.lowercased(),
        let uuid = UUID(uuidString: suffix)
    else { return false }
    return uuid.uuidString.lowercased() == suffix
}

private func readExact(from descriptor: Int32, offset: UInt64, length: Int) throws -> Data {
    guard length >= 0, offset <= UInt64(Int64.max) else {
        throw TransferProtocolError.destinationEscape
    }
    var output = Data(count: length)
    try output.withUnsafeMutableBytes { bytes in
        var total = 0
        while total < length {
            let count = pread(
                descriptor,
                bytes.baseAddress!.advanced(by: total),
                length - total,
                off_t(offset) + off_t(total)
            )
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw TransferProtocolError.digestMismatch }
            total += count
        }
    }
    return output
}

private func writeAll(_ data: Data, to descriptor: Int32, offset: UInt64) throws {
    guard offset <= UInt64(Int64.max) else { throw TransferProtocolError.destinationEscape }
    try data.withUnsafeBytes { bytes in
        var total = 0
        while total < data.count {
            let count = pwrite(
                descriptor,
                bytes.baseAddress!.advanced(by: total),
                data.count - total,
                off_t(offset) + off_t(total)
            )
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw TransferProtocolError.destinationEscape }
            total += count
        }
    }
}

private func setDescriptorModificationDate(_ descriptor: Int32, date: Date) throws {
    let modification = try validatedModificationTimespec(date)
    var times = [
        timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
        modification,
    ]
    guard futimens(descriptor, &times) == 0 else {
        throw TransferProtocolError.destinationEscape
    }
}

private func validatedModificationTimespec(_ date: Date) throws -> timespec {
    let interval = date.timeIntervalSince1970
    guard interval.isFinite else { throw TransferProtocolError.invalidFrame }
    let seconds = floor(interval)
    let minimum = Double(time_t.min)
    let maximumExclusive = Double(time_t.max) + 1
    guard seconds >= minimum, seconds < maximumExclusive else {
        throw TransferProtocolError.invalidFrame
    }
    let fractional = interval - seconds
    let scaledNanoseconds = floor(fractional * 1_000_000_000)
    guard fractional >= 0, fractional < 1,
        scaledNanoseconds >= 0, scaledNanoseconds < 1_000_000_000
    else { throw TransferProtocolError.invalidFrame }
    return timespec(
        tv_sec: time_t(seconds),
        tv_nsec: Int(scaledNanoseconds)
    )
}

private func appendUInt32(_ value: UInt32, to data: inout Data) {
    var big = value.bigEndian
    withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
}

private func remoteErrorCode(for error: Error) -> TransferRemoteError? {
    guard let error = error as? TransferProtocolError else { return .destinationUnavailable }
    switch error {
    case .channelEnded, .cancelled:
        return nil
    case .invalidChunk, .duplicateChunk:
        return .invalidChunk
    case .digestMismatch:
        return .verificationFailed
    case .destinationEscape, .destinationExists:
        return .destinationUnavailable
    case .invalidRelativePath, .manifestTooLarge, .unsupportedSource, .symlinkEscape:
        return .invalidManifest
    default:
        return .protocolViolation
    }
}
