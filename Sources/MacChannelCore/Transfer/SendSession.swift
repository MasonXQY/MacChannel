import Foundation

public struct TransferSendResult: Equatable, Sendable {
    public let transferID: TransferID
    public let sentChunkCount: Int
}

public struct TransferResumeNegotiation: Equatable, Sendable {
    public let transferID: TransferID
    public let resumeMap: ResumeMap
    public let acceptedBytes: UInt64

    public init(transferID: TransferID, resumeMap: ResumeMap, acceptedBytes: UInt64) {
        self.transferID = transferID
        self.resumeMap = resumeMap
        self.acceptedBytes = acceptedBytes
    }
}

public protocol TransferResumeNegotiationObserving: Sendable {
    func recordResumeNegotiation(_ value: TransferResumeNegotiation) async
}

protocol TransferChunkRecording: Sendable {
    func recordSentChunk(_ coordinate: ChunkCoordinate) async
}

public struct SendSession: Sendable {
    private let manifest: TransferManifest
    private let recorder: (any TransferChunkRecording)?
    private let resumeObserver: (any TransferResumeNegotiationObserving)?
    private let control: TransferSessionControl?
    private let resourceOwnership: TransferIOResourceOwnership?

    public init(
        _ manifest: TransferManifest,
        control: TransferSessionControl? = nil,
        resumeObserver: (any TransferResumeNegotiationObserving)? = nil
    ) {
        self.manifest = manifest
        recorder = nil
        self.control = control
        resourceOwnership = nil
        self.resumeObserver = resumeObserver
    }

    init(
        _ manifest: TransferManifest,
        recorder: any TransferChunkRecording,
        control: TransferSessionControl? = nil,
        resourceOwnership: TransferIOResourceOwnership? = nil,
        resumeObserver: (any TransferResumeNegotiationObserving)? = nil
    ) {
        self.manifest = manifest
        self.recorder = recorder
        self.control = control
        self.resourceOwnership = resourceOwnership
        self.resumeObserver = resumeObserver
    }

    public func run(on channel: any SecureChannel) async throws -> TransferSendResult {
        try await TransferIOResourceContext.$ownership.withValue(resourceOwnership) {
            try await runWithResourceOwnership(on: channel)
        }
    }

    private func runWithResourceOwnership(
        on channel: any SecureChannel
    ) async throws -> TransferSendResult {
        var outboundSequence: UInt64 = 0
        var terminationCrypto: TransferCryptographicContext?
        do {
            let initial = try await receiveInitialWire(
                from: channel.frames(),
                control: control
            )
            let challengeWire = initial.wire
            let challenge = try TransferReceiverChallenge.decode(
                challengeWire,
                expectedTransferID: manifest.id
            )
            let crypto = try await TransferCryptographicContext.make(
                on: channel,
                transfer: manifest.id,
                receiverChallenge: challenge.bytes
            )
            let frameReader = await TransferFrameReader(
                iterator: initial.iterator,
                transferID: manifest.id,
                direction: .receiverToSender,
                cipher: crypto.receiverToSender
            )
            terminationCrypto = crypto
            try validateSources()
            var announcedLocalPause = false
            var controlSnapshot = await control?.snapshot()

            try await send(
                .offer(manifest),
                transferID: manifest.id,
                direction: .senderToReceiver,
                on: channel,
                cipher: crypto.senderToReceiver,
                sequence: &outboundSequence,
                control: control
            )
            try await applyLocalControl(
                on: channel,
                cipher: crypto.senderToReceiver,
                sequence: &outboundSequence,
                announcedPause: &announcedLocalPause,
                snapshot: &controlSnapshot
            )
            let acceptedFrame = try await nextFrame(
                from: frameReader,
                controlSnapshot: &controlSnapshot,
                on: channel,
                outboundCipher: crypto.senderToReceiver,
                outboundSequence: &outboundSequence,
                announcedPause: &announcedLocalPause
            )
            guard case .accept(let resumeMap) = acceptedFrame else {
                throw protocolError(for: acceptedFrame)
            }
            try validate(map: resumeMap)
            await resumeObserver?.recordResumeNegotiation(
                TransferResumeNegotiation(
                    transferID: manifest.id,
                    resumeMap: resumeMap,
                    acceptedBytes: acceptedBytes(in: resumeMap)
                )
            )

            var sentCount = 0
            var sentCoverage = ChunkCoverage()
            var outstanding: Set<ChunkCoordinate> = []
            for (entryOffset, entry) in manifest.entries.enumerated() where entry.kind == .file {
                guard let source = entry.pinnedSource else {
                    throw TransferProtocolError.sourceChanged
                }
                for chunkIndex in 0..<entry.chunkCount {
                    try await applyLocalControl(
                        on: channel,
                        cipher: crypto.senderToReceiver,
                        sequence: &outboundSequence,
                        announcedPause: &announcedLocalPause,
                        snapshot: &controlSnapshot
                    )
                    let coordinate = ChunkCoordinate(
                        entryIndex: UInt32(entryOffset),
                        chunkIndex: chunkIndex
                    )
                    guard !resumeMap.contains(coordinate) else { continue }
                    while outstanding.count >= TransferProtocolLimits.maximumUnacknowledgedChunks {
                        try await receiveAcknowledgement(
                            from: frameReader,
                            controlSnapshot: &controlSnapshot,
                            on: channel,
                            outboundCipher: crypto.senderToReceiver,
                            outboundSequence: &outboundSequence,
                            announcedPause: &announcedLocalPause,
                            resumeMap: resumeMap,
                            sent: sentCoverage,
                            outstanding: &outstanding
                        )
                    }
                    let offset =
                        UInt64(chunkIndex) * UInt64(TransferProtocolLimits.maximumChunkBytes)
                    let expectedLength = Int(
                        min(
                            UInt64(TransferProtocolLimits.maximumChunkBytes),
                            entry.size - offset
                        ))
                    let data = try source.read(offset: offset, length: expectedLength)
                    try await send(
                        .chunk(
                            try TransferChunk(
                                coordinate: coordinate,
                                offset: offset,
                                data: data
                            )),
                        transferID: manifest.id,
                        direction: .senderToReceiver,
                        on: channel,
                        cipher: crypto.senderToReceiver,
                        sequence: &outboundSequence,
                        control: control
                    )
                    sentCount += 1
                    await recorder?.recordSentChunk(coordinate)
                    sentCoverage.insert(coordinate)
                    outstanding.insert(coordinate)
                }
            }

            // Complete also acts as an immediate ACK flush for transfers whose
            // final batch contains fewer than 16 chunks.
            try await send(
                .complete,
                transferID: manifest.id,
                direction: .senderToReceiver,
                on: channel,
                cipher: crypto.senderToReceiver,
                sequence: &outboundSequence,
                control: control
            )
            var receiverCompleted = false
            while !receiverCompleted || !outstanding.isEmpty {
                let frame = try await nextFrame(
                    from: frameReader,
                    controlSnapshot: &controlSnapshot,
                    on: channel,
                    outboundCipher: crypto.senderToReceiver,
                    outboundSequence: &outboundSequence,
                    announcedPause: &announcedLocalPause
                )
                switch frame {
                case .ackRanges(let map):
                    try applyAcknowledgement(
                        map,
                        resumeMap: resumeMap,
                        sent: sentCoverage,
                        outstanding: &outstanding
                    )
                case .complete:
                    receiverCompleted = true
                case .pause:
                    try await waitForRemoteResume(
                        from: frameReader,
                        controlSnapshot: &controlSnapshot,
                        on: channel,
                        outboundCipher: crypto.senderToReceiver,
                        outboundSequence: &outboundSequence,
                        announcedPause: &announcedLocalPause
                    )
                case .cancel:
                    throw TransferProtocolError.cancelled
                case .error(let remote):
                    throw mapRemoteError(remote)
                default:
                    throw TransferProtocolError.unexpectedFrame
                }
            }
            return TransferSendResult(transferID: manifest.id, sentChunkCount: sentCount)
        } catch {
            if let crypto = terminationCrypto {
                let terminalFrame: TransferFrame =
                    error is CancellationError
                        || (error as? TransferProtocolError) == .cancelled
                    ? .cancel
                    : .error(senderRemoteErrorCode(for: error))
                await sendTerminalFrameBestEffort(
                    terminalFrame,
                    transferID: manifest.id,
                    direction: .senderToReceiver,
                    on: channel,
                    cipher: crypto.senderToReceiver,
                    sequence: outboundSequence
                )
            }
            await channel.close()
            if error is CancellationError { throw TransferProtocolError.cancelled }
            throw error
        }
    }

    private func acceptedBytes(in map: ResumeMap) -> UInt64 {
        map.ranges.reduce(into: UInt64(0)) { total, range in
            guard Int(range.entryIndex) < manifest.entries.count else { return }
            let entry = manifest.entries[Int(range.entryIndex)]
            guard entry.kind == .file else { return }
            let chunkBytes = UInt64(TransferProtocolLimits.maximumChunkBytes)
            let lower = min(entry.size, UInt64(range.lowerBound) * chunkBytes)
            let upper = min(entry.size, UInt64(range.upperBound) * chunkBytes)
            total += upper - lower
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
                        transferID: manifest.id,
                        direction: .senderToReceiver,
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
                        transferID: manifest.id,
                        direction: .senderToReceiver,
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

    private func waitForRemoteResume(
        from reader: TransferFrameReader,
        controlSnapshot: inout TransferSessionControl.Snapshot?,
        on channel: any SecureChannel,
        outboundCipher: ChunkCipher,
        outboundSequence: inout UInt64,
        announcedPause: inout Bool
    ) async throws {
        while true {
            let frame = try await nextFrame(
                from: reader,
                controlSnapshot: &controlSnapshot,
                on: channel,
                outboundCipher: outboundCipher,
                outboundSequence: &outboundSequence,
                announcedPause: &announcedPause
            )
            switch frame {
            case .resume: return
            case .cancel: throw TransferProtocolError.cancelled
            case .error(let remote): throw mapRemoteError(remote)
            default: throw TransferProtocolError.unexpectedFrame
            }
        }
    }

    private func validateSources() throws {
        for entry in manifest.entries where entry.kind == .file {
            guard let source = entry.pinnedSource,
                source.size == entry.size,
                try source.digest() == entry.digest
            else { throw TransferProtocolError.sourceChanged }
        }
    }

    private func validate(map: ResumeMap) throws {
        for range in map.ranges {
            guard Int(range.entryIndex) < manifest.entries.count else {
                throw TransferProtocolError.invalidResumeMap
            }
            let entry = manifest.entries[Int(range.entryIndex)]
            guard entry.kind == .file, range.upperBound <= entry.chunkCount else {
                throw TransferProtocolError.invalidResumeMap
            }
        }
    }

    private func receiveAcknowledgement(
        from reader: TransferFrameReader,
        controlSnapshot: inout TransferSessionControl.Snapshot?,
        on channel: any SecureChannel,
        outboundCipher: ChunkCipher,
        outboundSequence: inout UInt64,
        announcedPause: inout Bool,
        resumeMap: ResumeMap,
        sent: ChunkCoverage,
        outstanding: inout Set<ChunkCoordinate>
    ) async throws {
        while true {
            let frame = try await nextFrame(
                from: reader,
                controlSnapshot: &controlSnapshot,
                on: channel,
                outboundCipher: outboundCipher,
                outboundSequence: &outboundSequence,
                announcedPause: &announcedPause
            )
            switch frame {
            case .ackRanges(let map):
                try applyAcknowledgement(
                    map,
                    resumeMap: resumeMap,
                    sent: sent,
                    outstanding: &outstanding
                )
                return
            case .cancel:
                throw TransferProtocolError.cancelled
            case .pause:
                try await waitForRemoteResume(
                    from: reader,
                    controlSnapshot: &controlSnapshot,
                    on: channel,
                    outboundCipher: outboundCipher,
                    outboundSequence: &outboundSequence,
                    announcedPause: &announcedPause
                )
            case .error(let remote):
                throw mapRemoteError(remote)
            default:
                throw TransferProtocolError.unexpectedFrame
            }
        }
    }

    private func nextFrame(
        from reader: TransferFrameReader,
        controlSnapshot: inout TransferSessionControl.Snapshot?,
        on channel: any SecureChannel,
        outboundCipher: ChunkCipher,
        outboundSequence: inout UInt64,
        announcedPause: inout Bool
    ) async throws -> TransferFrame {
        while true {
            let event = try await waitForTransferSessionEvent(
                reader: reader,
                control: control,
                after: controlSnapshot
            )
            switch event {
            case .frame(let frame):
                try Task.checkCancellation()
                if let control {
                    let latest = await control.snapshot()
                    if latest.revision != controlSnapshot?.revision {
                        controlSnapshot = latest
                        try await applyLocalControl(
                            on: channel,
                            cipher: outboundCipher,
                            sequence: &outboundSequence,
                            announcedPause: &announcedPause,
                            snapshot: &controlSnapshot
                        )
                    }
                }
                return frame
            case .timeout:
                continue
            case .control(let changed):
                controlSnapshot = changed
                try await applyLocalControl(
                    on: channel,
                    cipher: outboundCipher,
                    sequence: &outboundSequence,
                    announcedPause: &announcedPause,
                    snapshot: &controlSnapshot
                )
            }
        }
    }

    private func applyAcknowledgement(
        _ map: ResumeMap,
        resumeMap: ResumeMap,
        sent: ChunkCoverage,
        outstanding: inout Set<ChunkCoordinate>
    ) throws {
        try validate(map: map)
        for range in map.ranges {
            guard sent.covers(range, additionally: resumeMap) else {
                throw TransferProtocolError.invalidResumeMap
            }
        }
        outstanding = outstanding.filter { !map.contains($0) }
    }
}

private struct ChunkCoverage {
    private var rangesByEntry: [UInt32: [ChunkRange]] = [:]

    mutating func insert(_ coordinate: ChunkCoordinate) {
        var ranges = rangesByEntry[coordinate.entryIndex] ?? []
        if let last = ranges.last, last.upperBound == coordinate.chunkIndex,
            let merged = try? ChunkRange(
                entryIndex: coordinate.entryIndex,
                lowerBound: last.lowerBound,
                upperBound: coordinate.chunkIndex + 1
            )
        {
            ranges[ranges.count - 1] = merged
        } else if let range = try? ChunkRange(
            entryIndex: coordinate.entryIndex,
            lowerBound: coordinate.chunkIndex,
            upperBound: coordinate.chunkIndex + 1
        ) {
            ranges.append(range)
        }
        rangesByEntry[coordinate.entryIndex] = ranges
    }

    func covers(_ requested: ChunkRange, additionally resumeMap: ResumeMap) -> Bool {
        let candidates =
            ((rangesByEntry[requested.entryIndex] ?? [])
            + resumeMap.ranges.filter { $0.entryIndex == requested.entryIndex }).sorted {
                $0.lowerBound < $1.lowerBound
            }
        var cursor = requested.lowerBound
        for range in candidates where range.upperBound > cursor {
            guard range.lowerBound <= cursor else { return false }
            cursor = max(cursor, range.upperBound)
            if cursor >= requested.upperBound { return true }
        }
        return false
    }
}

func send(
    _ frame: TransferFrame,
    transferID: TransferID,
    direction: TransferDirection,
    on channel: any SecureChannel,
    cipher: ChunkCipher,
    sequence: inout UInt64,
    control: TransferSessionControl? = nil
) async throws {
    guard sequence < UInt64.max else { throw TransferProtocolError.replayOrOutOfOrder }
    let reservedSequence = sequence
    let sealed = try cipher.seal(
        frame.encode(),
        transfer: transferID,
        sequence: reservedSequence,
        direction: direction
    )
    // Once ciphertext exists, transport delivery is inherently ambiguous until
    // the send returns. Burn the nonce before awaiting I/O so cancellation can
    // never reuse it for a terminal frame that races a delivered send.
    sequence += 1
    try await sendWireRespectingCancellation(
        sealed.wireData,
        on: channel,
        control: control
    )
}

func sendWireRespectingCancellation(
    _ wire: Data,
    on channel: any SecureChannel,
    control: TransferSessionControl?
) async throws {
    guard let control else {
        try await channel.send(wire)
        return
    }
    let completion = TransferIOCompletion()
    let sendTask = Task {
        do {
            try await channel.send(wire)
            await completion.finish(.completed)
        } catch {
            await completion.finish(.failed(error))
        }
    }
    let cancellationTask = Task {
        do {
            try await control.waitUntilCancelled()
            await completion.finish(.cancelled)
        } catch {}
    }
    let outcome = await withTaskCancellationHandler {
        await completion.wait()
    } onCancel: {
        Task { await completion.finish(.cancelled) }
    }
    cancellationTask.cancel()
    switch outcome {
    case .completed:
        return
    case .failed(let error):
        throw error
    case .cancelled:
        try? await Task.sleep(for: .milliseconds(20))
        if let completed = await completion.completedIOOutcome() {
            switch completed {
            case .completed:
                return
            case .failed(let error):
                throw error
            case .cancelled:
                break
            }
        }
        sendTask.cancel()
        if let ownership = TransferIOResourceContext.ownership,
            await ownership.registry.retainOperation(ownership.token)
        {
            Task {
                await sendTask.value
                await ownership.registry.operationReturned(ownership.token)
            }
        }
        throw TransferProtocolError.cancelled
    }
}

private final class InitialWireResult: @unchecked Sendable {
    let wire: Data
    let iterator: AsyncThrowingStream<Data, Error>.Iterator

    init(wire: Data, iterator: AsyncThrowingStream<Data, Error>.Iterator) {
        self.wire = wire
        self.iterator = iterator
    }
}

private enum InitialWireOutcome: @unchecked Sendable {
    case received(InitialWireResult)
    case failed(Error)
    case cancelled
}

private actor InitialWireCompletion {
    private var outcome: InitialWireOutcome?
    private var received: InitialWireResult?
    private var waiter: CheckedContinuation<InitialWireOutcome, Never>?

    func wait() async -> InitialWireOutcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation in
            if let outcome {
                continuation.resume(returning: outcome)
            } else {
                waiter = continuation
            }
        }
    }

    func finish(_ outcome: InitialWireOutcome) {
        if case .received(let result) = outcome {
            received = result
        }
        guard self.outcome == nil else { return }
        self.outcome = outcome
        waiter?.resume(returning: outcome)
        waiter = nil
    }

    func receivedResult() -> InitialWireResult? { received }
}

private func receiveInitialWire(
    from stream: AsyncThrowingStream<Data, Error>,
    control: TransferSessionControl?
) async throws -> InitialWireResult {
    guard let control else {
        var iterator = stream.makeAsyncIterator()
        guard let wire = try await iterator.next() else {
            throw TransferProtocolError.channelEnded
        }
        return InitialWireResult(wire: wire, iterator: iterator)
    }
    let completion = InitialWireCompletion()
    let readTask = Task {
        var iterator = stream.makeAsyncIterator()
        do {
            guard let wire = try await iterator.next() else {
                await completion.finish(.failed(TransferProtocolError.channelEnded))
                return
            }
            await completion.finish(
                .received(InitialWireResult(wire: wire, iterator: iterator))
            )
        } catch {
            await completion.finish(.failed(error))
        }
    }
    let cancellationTask = Task {
        do {
            try await control.waitUntilCancelled()
            await completion.finish(.cancelled)
        } catch {}
    }
    let outcome = await withTaskCancellationHandler {
        await completion.wait()
    } onCancel: {
        Task { await completion.finish(.cancelled) }
    }
    cancellationTask.cancel()
    switch outcome {
    case .received(let result):
        return result
    case .failed(let error):
        throw error
    case .cancelled:
        try? await Task.sleep(for: .milliseconds(20))
        if let received = await completion.receivedResult() {
            return received
        }
        readTask.cancel()
        if let ownership = TransferIOResourceContext.ownership,
            await ownership.registry.retainOperation(ownership.token)
        {
            Task {
                await readTask.value
                await ownership.registry.operationReturned(ownership.token)
            }
        }
        throw TransferProtocolError.cancelled
    }
}

private enum TransferIOOutcome: @unchecked Sendable {
    case completed
    case failed(Error)
    case cancelled
}

private actor TransferIOCompletion {
    private var outcome: TransferIOOutcome?
    private var completedIO: TransferIOOutcome?
    private var waiter: CheckedContinuation<TransferIOOutcome, Never>?

    func wait() async -> TransferIOOutcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation in
            if let outcome {
                continuation.resume(returning: outcome)
            } else {
                waiter = continuation
            }
        }
    }

    func finish(_ outcome: TransferIOOutcome) {
        switch outcome {
        case .completed, .failed:
            completedIO = outcome
        case .cancelled:
            break
        }
        guard self.outcome == nil else { return }
        self.outcome = outcome
        waiter?.resume(returning: outcome)
        waiter = nil
    }

    func completedIOOutcome() -> TransferIOOutcome? { completedIO }
}

enum TerminalSendOutcome: Sendable {
    case sent
    case failed
    case timedOut
}

@discardableResult
func sendTerminalFrameBestEffort(
    _ frame: TransferFrame,
    transferID: TransferID,
    direction: TransferDirection,
    on channel: any SecureChannel,
    cipher: ChunkCipher,
    sequence: UInt64
) async -> TerminalSendOutcome {
    guard
        let sealed = try? cipher.seal(
            frame.encode(),
            transfer: transferID,
            sequence: sequence,
            direction: direction
        )
    else { return .failed }
    let completion = TerminalSendCompletion()
    let sendTask = Task {
        do {
            try await channel.send(sealed.wireData)
            await completion.finish(.sent)
        } catch {
            await completion.finish(.failed)
        }
    }
    let timeoutTask = Task {
        try? await Task.sleep(for: .milliseconds(100))
        await completion.finish(.timedOut)
    }
    let outcome = await completion.wait()
    if case .sent = outcome {
        await channel.flush()
    }
    sendTask.cancel()
    if case .timedOut = outcome,
        let ownership = TransferIOResourceContext.ownership,
        await ownership.registry.retainOperation(ownership.token)
    {
        Task {
            await sendTask.value
            await ownership.registry.operationReturned(ownership.token)
        }
    }
    // Let the bounded timer finish naturally. Cancelling a sleeping task after
    // the send wins can surface an otherwise irrelevant CancellationError to a
    // caller's task-local test/error machinery.
    _ = timeoutTask
    return outcome
}

private actor TerminalSendCompletion {
    private var outcome: TerminalSendOutcome?
    private var waiter: CheckedContinuation<TerminalSendOutcome, Never>?

    func wait() async -> TerminalSendOutcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation in
            if let outcome {
                continuation.resume(returning: outcome)
            } else {
                waiter = continuation
            }
        }
    }

    func finish(_ outcome: TerminalSendOutcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        waiter?.resume(returning: outcome)
        waiter = nil
    }
}

func receive(
    from iterator: inout AsyncThrowingStream<Data, Error>.Iterator,
    transferID: TransferID,
    direction: TransferDirection,
    cipher: ChunkCipher,
    sequence: inout UInt64
) async throws -> TransferFrame {
    guard let wire = try await iterator.next() else { throw TransferProtocolError.channelEnded }
    let plaintext = try cipher.openWire(
        wire,
        expectedTransfer: transferID,
        expectedSequence: sequence,
        expectedDirection: direction
    )
    let frame = try TransferFrame.decode(plaintext)
    guard sequence < UInt64.max else { throw TransferProtocolError.replayOrOutOfOrder }
    sequence += 1
    return frame
}

func protocolError(for frame: TransferFrame) -> TransferProtocolError {
    switch frame {
    case .cancel: .cancelled
    case .error(let error): mapRemoteError(error)
    default: .unexpectedFrame
    }
}

func mapRemoteError(_ error: TransferRemoteError) -> TransferProtocolError {
    switch error {
    case .invalidManifest: .invalidFrame
    case .invalidChunk: .invalidChunk
    case .verificationFailed: .digestMismatch
    case .protocolViolation: .unexpectedFrame
    case .destinationUnavailable: .destinationEscape
    case .sourceUnavailable: .sourceChanged
    }
}

private func senderRemoteErrorCode(for error: Error) -> TransferRemoteError {
    switch error as? TransferProtocolError {
    case .sourceChanged, .unsupportedSource, .symlinkEscape: .sourceUnavailable
    case .invalidChunk, .duplicateChunk: .invalidChunk
    case .digestMismatch: .verificationFailed
    default: .protocolViolation
    }
}
