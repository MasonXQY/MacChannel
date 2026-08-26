import CryptoKit
import Foundation

public struct TransferSendResult: Equatable, Sendable {
    public let transferID: TransferID
    public let chunkCoordinates: [ChunkCoordinate]

    public var chunkIndexes: [UInt32] { chunkCoordinates.map(\.chunkIndex) }

    init(transferID: TransferID, chunkCoordinates: [ChunkCoordinate]) {
        self.transferID = transferID
        self.chunkCoordinates = chunkCoordinates
    }
}

public struct SendSession: Sendable {
    private let manifest: TransferManifest

    public init(_ manifest: TransferManifest) {
        self.manifest = manifest
    }

    public func run(on channel: any SecureChannel) async throws -> TransferSendResult {
        try validateSources()
        let crypto = try await TransferCryptographicContext.make(
            on: channel,
            transfer: manifest.id
        )
        var outboundSequence: UInt64 = 0
        var inboundSequence: UInt64 = 0
        var iterator = channel.frames().makeAsyncIterator()

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

        var sent: [ChunkCoordinate] = []
        var sentCoverage = ChunkCoverage()
        var outstanding: Set<ChunkCoordinate> = []
        for (entryOffset, entry) in manifest.entries.enumerated() where entry.kind == .file {
            guard let sourceURL = entry.sourceURL else { throw TransferProtocolError.sourceChanged }
            let handle = try FileHandle(forReadingFrom: sourceURL)
            defer { try? handle.close() }
            for chunkIndex in 0..<entry.chunkCount {
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
                let offset = UInt64(chunkIndex) * UInt64(TransferProtocolLimits.maximumChunkBytes)
                let expectedLength = Int(
                    min(
                        UInt64(TransferProtocolLimits.maximumChunkBytes),
                        entry.size - offset
                    ))
                try handle.seek(toOffset: offset)
                let data = try handle.read(upToCount: expectedLength) ?? Data()
                guard data.count == expectedLength else {
                    throw TransferProtocolError.sourceChanged
                }
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
                sent.append(coordinate)
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
            case .cancel:
                throw TransferProtocolError.cancelled
            case .error(let remote):
                throw mapRemoteError(remote)
            default:
                throw TransferProtocolError.unexpectedFrame
            }
        }
        return TransferSendResult(transferID: manifest.id, chunkCoordinates: sent)
    }

    private func validateSources() throws {
        for entry in manifest.entries where entry.kind == .file {
            guard let sourceURL = entry.sourceURL else { throw TransferProtocolError.sourceChanged }
            let values = try sourceURL.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ])
            guard let fileSize = values.fileSize, fileSize >= 0 else {
                throw TransferProtocolError.sourceChanged
            }
            guard values.isRegularFile == true,
                values.isSymbolicLink != true,
                UInt64(fileSize) == entry.size,
                try fileDigest(at: sourceURL) == entry.digest
            else { throw TransferProtocolError.sourceChanged }
        }
    }

    private func fileDigest(at url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data =
                try handle.read(upToCount: TransferProtocolLimits.maximumChunkBytes) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return Data(hasher.finalize())
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

private func protocolError(for frame: TransferFrame) -> TransferProtocolError {
    switch frame {
    case .cancel: .cancelled
    case .error(let error): mapRemoteError(error)
    default: .unexpectedFrame
    }
}

private func mapRemoteError(_ error: TransferRemoteError) -> TransferProtocolError {
    switch error {
    case .invalidManifest: .invalidFrame
    case .invalidChunk: .invalidChunk
    case .verificationFailed: .digestMismatch
    case .protocolViolation: .unexpectedFrame
    case .destinationUnavailable: .destinationEscape
    }
}
