import CryptoKit
import Darwin
import Foundation

public struct TransferReceiveResult: Equatable, Sendable {
    public let transferID: TransferID
    public let receivedURLs: [URL]

}

public struct ReceiveSession: Sendable {
    private let transferID: TransferID
    private let destinationDirectory: URL
    private let control: TransferSessionControl?
    private let onStagingPrepared: (@Sendable (URL) -> Void)?

    public init(
        transferID: TransferID,
        destinationDirectory: URL,
        control: TransferSessionControl? = nil
    ) {
        self.transferID = transferID
        self.destinationDirectory = destinationDirectory
        self.control = control
        onStagingPrepared = nil
    }

    init(
        transferID: TransferID,
        destinationDirectory: URL,
        control: TransferSessionControl? = nil,
        onStagingPrepared: @escaping @Sendable (URL) -> Void
    ) {
        self.transferID = transferID
        self.destinationDirectory = destinationDirectory
        self.control = control
        self.onStagingPrepared = onStagingPrepared
    }

    public func run(on channel: any SecureChannel) async throws -> TransferReceiveResult {
        var outboundSequence: UInt64 = 0
        var terminationCrypto: TransferCryptographicContext?
        do {
            let challenge = TransferReceiverChallenge.fresh(for: transferID)
            try await channel.send(challenge.encode())
            let crypto = try await TransferCryptographicContext.make(
                on: channel,
                transfer: transferID,
                receiverChallenge: challenge.bytes
            )
            terminationCrypto = crypto
            let frameReader = TransferFrameReader(
                stream: channel.frames(),
                transferID: transferID,
                direction: .senderToReceiver,
                cipher: crypto.senderToReceiver
            )
            guard case .frame(let first) = try await frameReader.next() else {
                throw TransferProtocolError.channelEnded
            }
            guard case .offer(let manifest) = first, manifest.id == transferID else {
                throw protocolError(for: first)
            }
            try validateManifest(manifest)
            try manifest.validateDestinationPaths(onVolumeContaining: destinationDirectory)
            var preparation = try ResumePreparation(
                manifest: manifest,
                destinationDirectory: destinationDirectory
            )
            onStagingPrepared?(preparation.stagingDirectory)
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
            var announcedLocalPause = false
            var peerPaused = false
            while true {
                try await applyLocalControl(
                    on: channel,
                    cipher: crypto.receiverToSender,
                    sequence: &outboundSequence,
                    announcedPause: &announcedLocalPause
                )
                var timeout: Duration?
                if chunksSinceAcknowledgement > 0 {
                    let elapsed = lastAcknowledgement.duration(to: clock.now)
                    timeout =
                        elapsed >= .milliseconds(250)
                        ? .zero
                        : .milliseconds(250) - elapsed
                } else {
                    timeout = nil
                }
                if control != nil {
                    timeout = min(timeout ?? .milliseconds(20), .milliseconds(20))
                }
                let event = try await frameReader.next(timeout: timeout)
                if case .timeout = event {
                    if chunksSinceAcknowledgement > 0,
                        lastAcknowledgement.duration(to: clock.now) >= .milliseconds(250)
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
                    continue
                }
                guard case .frame(let frame) = event else {
                    throw TransferProtocolError.channelEnded
                }
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
                    try? await send(
                        terminalFrame,
                        transferID: transferID,
                        direction: .receiverToSender,
                        on: channel,
                        cipher: crypto.receiverToSender,
                        sequence: &outboundSequence
                    )
                }
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
                        transferID: transferID,
                        direction: .receiverToSender,
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
                        transferID: transferID,
                        direction: .receiverToSender,
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

    private func validateManifest(_ manifest: TransferManifest) throws {
        try manifest.validateProtocolLimits()
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
    let tree: DescriptorStagingTree
    let files: [UInt32: StagedFile]
    var resumeStore: ResumeStateStore
    let verified: Set<ChunkCoordinate>

    init(manifest: TransferManifest, destinationDirectory: URL) throws {
        self.destinationDirectory = destinationDirectory.standardizedFileURL
        if !FileManager.default.fileExists(atPath: self.destinationDirectory.path) {
            try FileManager.default.createDirectory(
                at: self.destinationDirectory,
                withIntermediateDirectories: true
            )
        }
        let suffix = manifest.id.rawValue.uuidString.lowercased()
        let rootName = manifest.entries[0].relativePath.components[0]
        let preferredStagingName = ".macchannel-\(suffix).partial"
        let stagingName =
            rootName == preferredStagingName
            ? preferredStagingName + ".metadata" : preferredStagingName
        stagingDirectory = self.destinationDirectory
            .appendingPathComponent(stagingName, isDirectory: true)
        tree = try DescriptorStagingTree(
            destinationDirectory: self.destinationDirectory,
            stagingName: stagingName
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
        let preferredStateName = ".resume-state"
        let stateName =
            rootName == preferredStateName
            ? preferredStateName + ".metadata" : preferredStateName
        let loaded = try ResumeStateStore.load(
            named: stateName,
            fingerprint: fingerprint,
            manifest: manifest,
            tree: tree,
            files: openedFiles
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

    func finalize(_ manifest: TransferManifest) throws -> [URL] {
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
        let rootName = manifest.entries[0].relativePath.components[0]
        let isDirectory = manifest.entries[0].kind == .directory
        let finalRoot = destinationDirectory.appendingPathComponent(
            rootName, isDirectory: isDirectory)
        try tree.finalize(rootName: rootName)
        return [finalRoot]
    }
}

private final class DescriptorStagingTree: @unchecked Sendable {
    let rootDescriptor: Int32
    private let destinationDescriptor: Int32
    private let stagingName: String

    init(destinationDirectory: URL, stagingName: String) throws {
        let destinationDescriptor = Darwin.open(
            destinationDirectory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard destinationDescriptor >= 0 else {
            throw TransferProtocolError.destinationEscape
        }
        self.destinationDescriptor = destinationDescriptor
        self.stagingName = stagingName
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
    }

    deinit {
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
        guard unlinkat(destinationDescriptor, stagingName, AT_REMOVEDIR) == 0 else {
            throw TransferProtocolError.destinationEscape
        }
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

private final class StagedFile: @unchecked Sendable {
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

private final class ResumeStateStore: @unchecked Sendable {
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

    deinit { Darwin.close(descriptor) }

    static func load(
        named name: String,
        fingerprint: Data,
        manifest: TransferManifest,
        tree: DescriptorStagingTree,
        files: [UInt32: StagedFile]
    ) throws -> (store: ResumeStateStore, verified: Set<ChunkCoordinate>) {
        guard fingerprint.count == 32 else { throw TransferProtocolError.invalidResumeMap }
        let descriptor = Darwin.openat(
            tree.rootDescriptor,
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
        guard unlinkat(tree.rootDescriptor, name, 0) == 0 else {
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
            tree.rootDescriptor,
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
                _ = unlinkat(tree.rootDescriptor, temporaryName, 0)
            }
        }
        try writeAll(data, to: temporaryDescriptor, offset: 0)
        guard fsync(temporaryDescriptor) == 0,
            renameat(tree.rootDescriptor, temporaryName, tree.rootDescriptor, name) == 0
        else { throw TransferProtocolError.destinationEscape }
        guard fsync(tree.rootDescriptor) == 0 else {
            throw TransferProtocolError.destinationEscape
        }
        keepTemporary = false
        let replacement = Darwin.openat(
            tree.rootDescriptor,
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

private func manifestFingerprint(_ manifest: TransferManifest) throws -> Data {
    Data(SHA256.hash(data: try TransferFrame.offer(manifest).encode()))
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
    let seconds = floor(date.timeIntervalSince1970)
    let nanoseconds = min(
        999_999_999,
        max(0, Int((date.timeIntervalSince1970 - seconds) * 1_000_000_000))
    )
    var times = [
        timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
        timespec(tv_sec: time_t(seconds), tv_nsec: nanoseconds),
    ]
    guard futimens(descriptor, &times) == 0 else {
        throw TransferProtocolError.destinationEscape
    }
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
