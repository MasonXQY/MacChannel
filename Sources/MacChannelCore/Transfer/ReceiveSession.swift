import CryptoKit
import Foundation

public struct TransferReceiveResult: Equatable, Sendable {
    public let transferID: TransferID
    public let receivedURLs: [URL]

}

public struct ReceiveSession: Sendable {
    private let transferID: TransferID
    private let destinationDirectory: URL

    public init(transferID: TransferID, destinationDirectory: URL) {
        self.transferID = transferID
        self.destinationDirectory = destinationDirectory
    }

    public func run(on channel: any SecureChannel) async throws -> TransferReceiveResult {
        let crypto = try await TransferCryptographicContext.make(on: channel, transfer: transferID)
        var outboundSequence: UInt64 = 0
        let frameReader = TransferFrameReader(
            stream: channel.frames(),
            transferID: transferID,
            direction: .senderToReceiver,
            cipher: crypto.senderToReceiver
        )

        do {
            guard case .frame(let first) = try await frameReader.next() else {
                throw TransferProtocolError.channelEnded
            }
            guard case .offer(let manifest) = first, manifest.id == transferID else {
                throw TransferProtocolError.unexpectedFrame
            }
            try validateManifest(manifest)
            var preparation = try ResumePreparation(
                manifest: manifest,
                destinationDirectory: destinationDirectory
            )
            var verified = try VerifiedChunks(preparation.verified)
            try await send(
                .accept(verified.map),
                transferID: transferID,
                direction: .receiverToSender,
                on: channel,
                cipher: crypto.receiverToSender,
                sequence: &outboundSequence
            )

            var expected = nextMissing(in: manifest, verified: verified, after: nil)
            var chunksSinceAcknowledgement = 0
            let clock = ContinuousClock()
            var lastAcknowledgement = clock.now
            while true {
                let timeout: Duration?
                if chunksSinceAcknowledgement > 0 {
                    let elapsed = lastAcknowledgement.duration(to: clock.now)
                    timeout =
                        elapsed >= .milliseconds(250)
                        ? .zero
                        : .milliseconds(250) - elapsed
                } else {
                    timeout = nil
                }
                let event = try await frameReader.next(timeout: timeout)
                if case .timeout = event {
                    try await send(
                        .ackRanges(verified.map),
                        transferID: transferID,
                        direction: .receiverToSender,
                        on: channel,
                        cipher: crypto.receiverToSender,
                        sequence: &outboundSequence
                    )
                    chunksSinceAcknowledgement = 0
                    lastAcknowledgement = clock.now
                    continue
                }
                guard case .frame(let frame) = event else {
                    throw TransferProtocolError.channelEnded
                }
                switch frame {
                case .chunk(let chunk):
                    guard let expectedCoordinate = expected,
                        chunk.coordinate == expectedCoordinate
                    else {
                        if verified.contains(chunk.coordinate) {
                            throw TransferProtocolError.duplicateChunk
                        }
                        throw TransferProtocolError.replayOrOutOfOrder
                    }
                    try validate(chunk: chunk, manifest: manifest)
                    let digest = try preparation.writeAndVerify(chunk, manifest: manifest)
                    try preparation.resumeStore.append(chunk.coordinate, digest: digest)
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
                            sequence: &outboundSequence
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
                            sequence: &outboundSequence
                        )
                    }
                    try preparation.verifyCompletedFiles(manifest)
                    let receivedURLs = try preparation.finalize(manifest)
                    try await send(
                        .complete,
                        transferID: transferID,
                        direction: .receiverToSender,
                        on: channel,
                        cipher: crypto.receiverToSender,
                        sequence: &outboundSequence
                    )
                    return TransferReceiveResult(
                        transferID: transferID,
                        receivedURLs: receivedURLs
                    )
                case .cancel:
                    throw TransferProtocolError.cancelled
                case .pause:
                    continue
                case .resume:
                    continue
                default:
                    throw TransferProtocolError.unexpectedFrame
                }
            }
        } catch {
            if let code = remoteErrorCode(for: error) {
                try? await send(
                    .error(code),
                    transferID: transferID,
                    direction: .receiverToSender,
                    on: channel,
                    cipher: crypto.receiverToSender,
                    sequence: &outboundSequence
                )
            }
            throw error
        }
    }

    private func validateManifest(_ manifest: TransferManifest) throws {
        guard !manifest.entries.isEmpty else { throw TransferProtocolError.invalidFrame }
        let root = manifest.entries[0].relativePath.components[0]
        var directories: Set<RelativePath> = []
        var seen: Set<RelativePath> = []
        for entry in manifest.entries {
            guard entry.relativePath.components[0] == root,
                seen.insert(entry.relativePath).inserted
            else { throw TransferProtocolError.invalidFrame }
            if entry.relativePath.components.count > 1 {
                let parent = try RelativePath(
                    components: Array(entry.relativePath.components.dropLast()))
                guard directories.contains(parent) else { throw TransferProtocolError.invalidFrame }
            }
            if entry.kind == .directory { directories.insert(entry.relativePath) }
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

private enum TransferReadEvent: Sendable {
    case frame(TransferFrame)
    case timeout
}

private final class TransferFrameReader: @unchecked Sendable {
    private let inbox: TransferFrameInbox
    private let readerTask: Task<Void, Never>

    init(
        stream: AsyncThrowingStream<Data, Error>,
        transferID: TransferID,
        direction: TransferDirection,
        cipher: ChunkCipher
    ) {
        let inbox = TransferFrameInbox()
        self.inbox = inbox
        readerTask = Task {
            var sequence: UInt64 = 0
            var iterator = stream.makeAsyncIterator()
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
                    guard await inbox.push(frame) else { return }
                }
                await inbox.finish(TransferProtocolError.channelEnded)
            } catch {
                await inbox.finish(error)
            }
        }
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

private struct ResumePreparation {
    let destinationDirectory: URL
    let stagingDirectory: URL
    var resumeStore: ResumeStateStore
    let verified: Set<ChunkCoordinate>

    init(manifest: TransferManifest, destinationDirectory: URL) throws {
        self.destinationDirectory = destinationDirectory.standardizedFileURL
        try Self.prepareDestination(self.destinationDirectory)
        let suffix = manifest.id.rawValue.uuidString.lowercased()
        let rootName = manifest.entries[0].relativePath.components[0]
        let preferredStagingName = ".macchannel-\(suffix).partial"
        let stagingName =
            rootName == preferredStagingName
            ? preferredStagingName + ".metadata" : preferredStagingName
        stagingDirectory = self.destinationDirectory
            .appendingPathComponent(stagingName, isDirectory: true)
        try Self.ensureDirectory(stagingDirectory)

        let finalRoot = self.destinationDirectory.appendingPathComponent(
            rootName,
            isDirectory: manifest.entries[0].kind == .directory
        )
        guard !FileManager.default.fileExists(atPath: finalRoot.path) else {
            throw TransferProtocolError.destinationExists
        }
        for entry in manifest.entries {
            let url = try safeURL(for: entry.relativePath, under: stagingDirectory)
            switch entry.kind {
            case .directory:
                try Self.ensureDirectory(url)
            case .file:
                let parent = url.deletingLastPathComponent()
                try Self.ensureDirectory(parent)
                if !FileManager.default.fileExists(atPath: url.path) {
                    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                        throw TransferProtocolError.destinationEscape
                    }
                }
                let values = try url.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey,
                ])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw TransferProtocolError.destinationEscape
                }
            }
        }
        let fingerprint = try manifestFingerprint(manifest)
        let preferredStateName = ".resume-state"
        let stateName =
            rootName == preferredStateName
            ? preferredStateName + ".metadata" : preferredStateName
        let stateURL = stagingDirectory.appendingPathComponent(stateName)
        let loaded = try ResumeStateStore.load(
            from: stateURL,
            fingerprint: fingerprint,
            manifest: manifest,
            stagingDirectory: stagingDirectory
        )
        resumeStore = loaded.store
        verified = loaded.verified
    }

    mutating func writeAndVerify(
        _ chunk: TransferChunk,
        manifest: TransferManifest
    ) throws -> Data {
        let entry = manifest.entries[Int(chunk.coordinate.entryIndex)]
        let url = try safeURL(for: entry.relativePath, under: stagingDirectory)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: chunk.offset)
        try handle.write(contentsOf: chunk.data)
        try handle.synchronize()

        let readHandle = try FileHandle(forReadingFrom: url)
        defer { try? readHandle.close() }
        try readHandle.seek(toOffset: chunk.offset)
        let written = try readHandle.read(upToCount: chunk.data.count) ?? Data()
        guard written == chunk.data else { throw TransferProtocolError.digestMismatch }
        return Data(SHA256.hash(data: written))
    }

    func verifyCompletedFiles(_ manifest: TransferManifest) throws {
        for entry in manifest.entries where entry.kind == .file {
            let url = try safeURL(for: entry.relativePath, under: stagingDirectory)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber,
                size.uint64Value == entry.size,
                try digestFile(at: url) == entry.digest
            else { throw TransferProtocolError.digestMismatch }
        }
    }

    func finalize(_ manifest: TransferManifest) throws -> [URL] {
        for entry in manifest.entries.reversed() {
            let url = try safeURL(for: entry.relativePath, under: stagingDirectory)
            try FileManager.default.setAttributes(
                [.modificationDate: entry.modificationDate],
                ofItemAtPath: url.path
            )
        }
        try FileManager.default.removeItem(at: resumeStore.url)
        let rootName = manifest.entries[0].relativePath.components[0]
        let isDirectory = manifest.entries[0].kind == .directory
        let stagedRoot = stagingDirectory.appendingPathComponent(rootName, isDirectory: isDirectory)
        let finalRoot = destinationDirectory.appendingPathComponent(
            rootName, isDirectory: isDirectory)
        guard !FileManager.default.fileExists(atPath: finalRoot.path) else {
            throw TransferProtocolError.destinationExists
        }
        try FileManager.default.moveItem(at: stagedRoot, to: finalRoot)
        try FileManager.default.removeItem(at: stagingDirectory)
        return [finalRoot]
    }

    private static func prepareDestination(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw TransferProtocolError.destinationEscape
            }
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private static func ensureDirectory(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw TransferProtocolError.destinationEscape
            }
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
    }
}

private struct ResumeStateStore {
    private static let magic = Data([0x4d, 0x43, 0x52, 0x53])  // MCRS
    private static let version: UInt8 = 1
    private static let headerBytes = 37
    private static let recordBytes = 40
    private static let maximumRecords = 1_000_000

    let url: URL

    static func load(
        from url: URL,
        fingerprint: Data,
        manifest: TransferManifest,
        stagingDirectory: URL
    ) throws -> (store: ResumeStateStore, verified: Set<ChunkCoordinate>) {
        guard fingerprint.count == 32 else { throw TransferProtocolError.invalidResumeMap }
        var candidates: [(ChunkCoordinate, Data)] = []
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey,
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw TransferProtocolError.destinationEscape
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber,
                size.uint64Value <= UInt64(headerBytes + recordBytes * maximumRecords)
            else { throw TransferProtocolError.invalidResumeMap }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count >= headerBytes,
                data.prefix(4) == magic,
                data[4] == version,
                data.subdata(in: 5..<37) == fingerprint,
                (data.count - headerBytes).isMultiple(of: recordBytes)
            else { throw TransferProtocolError.invalidResumeMap }
            var offset = headerBytes
            var seen: Set<ChunkCoordinate> = []
            while offset < data.count {
                let entry = readUInt32(data, at: offset)
                let chunk = readUInt32(data, at: offset + 4)
                let digest = data.subdata(in: (offset + 8)..<(offset + recordBytes))
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
            let fileURL = try safeURL(for: entry.relativePath, under: stagingDirectory)
            guard let digest = try? digestChunk(at: fileURL, offset: offset, length: length),
                digest == expectedDigest
            else { continue }
            verified.insert(coordinate)
            verifiedRecords.append((coordinate, digest))
        }
        try writeState(
            to: url,
            fingerprint: fingerprint,
            records: verifiedRecords
        )
        return (ResumeStateStore(url: url), verified)
    }

    func append(_ coordinate: ChunkCoordinate, digest: Data) throws {
        guard digest.count == 32 else { throw TransferProtocolError.invalidResumeMap }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let offset = try handle.seekToEnd()
        guard offset <= UInt64(Self.headerBytes + Self.recordBytes * (Self.maximumRecords - 1))
        else {
            throw TransferProtocolError.invalidResumeMap
        }
        var record = Data()
        appendUInt32(coordinate.entryIndex, to: &record)
        appendUInt32(coordinate.chunkIndex, to: &record)
        record.append(digest)
        try handle.write(contentsOf: record)
        try handle.synchronize()
    }

    private static func writeState(
        to url: URL,
        fingerprint: Data,
        records: [(ChunkCoordinate, Data)]
    ) throws {
        var data = magic
        data.append(version)
        data.append(fingerprint)
        for (coordinate, digest) in records.sorted(by: { $0.0 < $1.0 }) {
            appendUInt32(coordinate.entryIndex, to: &data)
            appendUInt32(coordinate.chunkIndex, to: &data)
            data.append(digest)
        }
        try data.write(to: url, options: .atomic)
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

private struct VerifiedChunks {
    private var coordinates: Set<ChunkCoordinate>
    private(set) var map: ResumeMap

    init(_ coordinates: Set<ChunkCoordinate>) throws {
        self.coordinates = coordinates
        map = try Self.makeMap(from: coordinates)
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

private func safeURL(for path: RelativePath, under root: URL) throws -> URL {
    let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
    var current = root.standardizedFileURL
    for component in path.components {
        current.appendPathComponent(component)
        if FileManager.default.fileExists(atPath: current.path) {
            let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw TransferProtocolError.destinationEscape
            }
        }
        let resolved = current.resolvingSymlinksInPath().standardizedFileURL
        let prefix =
            canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        guard resolved.path.hasPrefix(prefix) else {
            throw TransferProtocolError.destinationEscape
        }
    }
    return current
}

private func manifestFingerprint(_ manifest: TransferManifest) throws -> Data {
    Data(SHA256.hash(data: try TransferFrame.offer(manifest).encode()))
}

private func digestFile(at url: URL) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
        let data = try handle.read(upToCount: TransferProtocolLimits.maximumChunkBytes) ?? Data()
        if data.isEmpty { break }
        hasher.update(data: data)
    }
    return Data(hasher.finalize())
}

private func digestChunk(at url: URL, offset: UInt64, length: Int) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    try handle.seek(toOffset: offset)
    let data = try handle.read(upToCount: length) ?? Data()
    guard data.count == length else { throw TransferProtocolError.digestMismatch }
    return Data(SHA256.hash(data: data))
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
