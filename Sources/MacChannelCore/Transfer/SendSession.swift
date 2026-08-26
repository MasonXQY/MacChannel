import Foundation

public struct TransferSendResult: Equatable, Sendable {
    public let transferID: TransferID
    public let sentChunkCount: Int
}

protocol TransferChunkRecording: Sendable {
    func recordSentChunk(_ coordinate: ChunkCoordinate) async
}

public struct SendSession: Sendable {
    private let manifest: TransferManifest
    private let recorder: (any TransferChunkRecording)?
    private let control: TransferSessionControl?

    public init(
        _ manifest: TransferManifest,
        control: TransferSessionControl? = nil
    ) {
        self.manifest = manifest
        recorder = nil
        self.control = control
    }

    init(
        _ manifest: TransferManifest,
        recorder: any TransferChunkRecording,
        control: TransferSessionControl? = nil
    ) {
        self.manifest = manifest
        self.recorder = recorder
        self.control = control
    }

    public func run(on channel: any SecureChannel) async throws -> TransferSendResult {
        var outboundSequence: UInt64 = 0
        var terminationCrypto: TransferCryptographicContext?
        do {
            var iterator = channel.frames().makeAsyncIterator()
            guard let challengeWire = try await iterator.next() else {
                throw TransferProtocolError.channelEnded
            }
            let challenge = try TransferReceiverChallenge.decode(
                challengeWire,
                expectedTransferID: manifest.id
            )
            let crypto = try await TransferCryptographicContext.make(
                on: channel,
                transfer: manifest.id,
                receiverChallenge: challenge.bytes
            )
            terminationCrypto = crypto
            try validateSources()
            var inboundSequence: UInt64 = 0
            var announcedLocalPause = false

            try await send(
                .offer(manifest),
                transferID: manifest.id,
                direction: .senderToReceiver,
                on: channel,
                cipher: crypto.senderToReceiver,
                sequence: &outboundSequence
            )
            let acceptedFrame = try await receive(
                from: &iterator,
                transferID: manifest.id,
                direction: .receiverToSender,
                cipher: crypto.receiverToSender,
                sequence: &inboundSequence
            )
            guard case .accept(let resumeMap) = acceptedFrame else {
                throw protocolError(for: acceptedFrame)
            }
            try validate(map: resumeMap)

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
                        announcedPause: &announcedLocalPause
                    )
                    let coordinate = ChunkCoordinate(
                        entryIndex: UInt32(entryOffset),
                        chunkIndex: chunkIndex
                    )
                    guard !resumeMap.contains(coordinate) else { continue }
                    while outstanding.count >= TransferProtocolLimits.maximumUnacknowledgedChunks {
                        try await receiveAcknowledgement(
                            from: &iterator,
                            cipher: crypto.receiverToSender,
                            sequence: &inboundSequence,
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
                        sequence: &outboundSequence
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
                sequence: &outboundSequence
            )
            var receiverCompleted = false
            while !receiverCompleted || !outstanding.isEmpty {
                let frame = try await receive(
                    from: &iterator,
                    transferID: manifest.id,
                    direction: .receiverToSender,
                    cipher: crypto.receiverToSender,
                    sequence: &inboundSequence
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
                        from: &iterator,
                        cipher: crypto.receiverToSender,
                        sequence: &inboundSequence
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
                try? await send(
                    terminalFrame,
                    transferID: manifest.id,
                    direction: .senderToReceiver,
                    on: channel,
                    cipher: crypto.senderToReceiver,
                    sequence: &outboundSequence
                )
            }
            await channel.close()
            if error is CancellationError { throw TransferProtocolError.cancelled }
            throw error
        }
    }

    private func applyLocalControl(
        on channel: any SecureChannel,
        cipher: ChunkCipher,
        sequence: inout UInt64,
        announcedPause: inout Bool
    ) async throws {
        guard let control else { return }
        while true {
            switch await control.state() {
            case .active:
                if announcedPause {
                    try await send(
                        .resume,
                        transferID: manifest.id,
                        direction: .senderToReceiver,
                        on: channel,
                        cipher: cipher,
                        sequence: &sequence
                    )
                    announcedPause = false
                }
                return
            case .paused:
                if !announcedPause {
                    try await send(
                        .pause,
                        transferID: manifest.id,
                        direction: .senderToReceiver,
                        on: channel,
                        cipher: cipher,
                        sequence: &sequence
                    )
                    announcedPause = true
                }
                try await Task.sleep(for: .milliseconds(10))
            case .cancelled:
                throw TransferProtocolError.cancelled
            }
        }
    }

    private func waitForRemoteResume(
        from iterator: inout AsyncThrowingStream<Data, Error>.Iterator,
        cipher: ChunkCipher,
        sequence: inout UInt64
    ) async throws {
        while true {
            let frame = try await receive(
                from: &iterator,
                transferID: manifest.id,
                direction: .receiverToSender,
                cipher: cipher,
                sequence: &sequence
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
        from iterator: inout AsyncThrowingStream<Data, Error>.Iterator,
        cipher: ChunkCipher,
        sequence: inout UInt64,
        resumeMap: ResumeMap,
        sent: ChunkCoverage,
        outstanding: inout Set<ChunkCoordinate>
    ) async throws {
        while true {
            let frame = try await receive(
                from: &iterator,
                transferID: manifest.id,
                direction: .receiverToSender,
                cipher: cipher,
                sequence: &sequence
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
                    from: &iterator,
                    cipher: cipher,
                    sequence: &sequence
                )
            case .error(let remote):
                throw mapRemoteError(remote)
            default:
                throw TransferProtocolError.unexpectedFrame
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
    sequence: inout UInt64
) async throws {
    let sealed = try cipher.seal(
        frame.encode(),
        transfer: transferID,
        sequence: sequence,
        direction: direction
    )
    try await channel.send(sealed.wireData)
    guard sequence < UInt64.max else { throw TransferProtocolError.replayOrOutOfOrder }
    sequence += 1
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
