import CryptoKit
import Darwin
import Foundation

public enum ReceiveStoreError: Error, Equatable, Sendable {
    case untrustedSource
    case automaticReceiveDisabled
    case exceedsMaximumSize(limit: UInt64, actual: UInt64)
    case insufficientCapacity(required: UInt64, available: UInt64)
    case destinationNotWritable
    case invalidManifest
    case invalidChunk
    case incompleteTransfer
    case digestMismatch
    case stagingUnavailable
    case atomicPlacementUnavailable
    case databaseFailure
    case alreadyFinished
    case alreadyFinalizing
    case alreadyCancelling
    case transferBusy
}

public protocol ReceiveCapacityProviding: Sendable {
    func availableBytes(at directory: URL) throws -> UInt64
}

public struct VolumeReceiveCapacityProvider: ReceiveCapacityProviding {
    public init() {}

    public func availableBytes(at directory: URL) throws -> UInt64 {
        let values = try directory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        if let important = values.volumeAvailableCapacityForImportantUsage, important >= 0 {
            return UInt64(important)
        }
        if let available = values.volumeAvailableCapacity, available >= 0 {
            return UInt64(available)
        }
        throw ReceiveStoreError.stagingUnavailable
    }
}

final class ReceiveTransferLease: @unchecked Sendable {
    private let incomingDirectory: URL
    private let parentDescriptor: Int32
    private let descriptor: Int32
    private let name: String
    private let parentDevice: dev_t
    private let parentInode: ino_t
    private let device: dev_t
    private let inode: ino_t
    private var removeOnDeinit = true

    private init(
        incomingDirectory: URL,
        parentDescriptor: Int32,
        descriptor: Int32,
        name: String,
        parentStatus: stat,
        status: stat
    ) {
        self.incomingDirectory = incomingDirectory
        self.parentDescriptor = parentDescriptor
        self.descriptor = descriptor
        self.name = name
        parentDevice = parentStatus.st_dev
        parentInode = parentStatus.st_ino
        device = status.st_dev
        inode = status.st_ino
    }

    deinit {
        if removeOnDeinit { try? removeAfterTerminalState() }
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        Darwin.close(parentDescriptor)
    }

    static func acquire(
        transferID: TransferID,
        incomingDirectory: URL,
        onLocked: @Sendable (URL) throws -> Void = { _ in }
    ) throws -> ReceiveTransferLease {
        let parent = Darwin.open(
            incomingDirectory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard parent >= 0 else { throw ReceiveStoreError.stagingUnavailable }
        var parentStatus = stat()
        guard fstat(parent, &parentStatus) == 0,
            parentStatus.st_mode & S_IFMT == S_IFDIR,
            parentStatus.st_uid == geteuid(),
            parentStatus.st_mode & 0o077 == 0
        else {
            Darwin.close(parent)
            throw ReceiveStoreError.stagingUnavailable
        }
        let name = ".macchannel-lease-\(transferID.rawValue.uuidString.lowercased())"
        let descriptor = Darwin.openat(
            parent,
            name,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            Darwin.close(parent)
            throw ReceiveStoreError.stagingUnavailable
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
            status.st_mode & S_IFMT == S_IFREG,
            status.st_uid == geteuid(),
            status.st_nlink == 1,
            fchmod(descriptor, S_IRUSR | S_IWUSR) == 0
        else {
            Darwin.close(descriptor)
            Darwin.close(parent)
            throw ReceiveStoreError.stagingUnavailable
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let busy = errno == EWOULDBLOCK || errno == EAGAIN
            Darwin.close(descriptor)
            Darwin.close(parent)
            throw busy ? ReceiveStoreError.transferBusy : ReceiveStoreError.stagingUnavailable
        }
        do {
            try onLocked(incomingDirectory.appendingPathComponent(name))
        } catch {
            _ = flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
            Darwin.close(parent)
            throw error
        }
        var named = stat()
        guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
            named.st_mode & S_IFMT == S_IFREG,
            named.st_uid == geteuid(),
            named.st_nlink == 1,
            named.st_dev == status.st_dev,
            named.st_ino == status.st_ino
        else {
            _ = flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
            Darwin.close(parent)
            throw ReceiveStoreError.stagingUnavailable
        }
        let lease = ReceiveTransferLease(
            incomingDirectory: incomingDirectory.standardizedFileURL,
            parentDescriptor: parent,
            descriptor: descriptor,
            name: name,
            parentStatus: parentStatus,
            status: status
        )
        try lease.requireHeld(error: .stagingUnavailable)
        return lease
    }

    func requireHeld() throws {
        try requireHeld(error: .transferBusy)
    }

    private func requireHeld(error: ReceiveStoreError) throws {
        var parent = stat()
        var path = stat()
        var status = stat()
        var named = stat()
        guard fstat(parentDescriptor, &parent) == 0,
            parent.st_mode & S_IFMT == S_IFDIR,
            parent.st_dev == parentDevice,
            parent.st_ino == parentInode,
            lstat(incomingDirectory.path, &path) == 0,
            path.st_mode & S_IFMT == S_IFDIR,
            path.st_dev == parentDevice,
            path.st_ino == parentInode,
            fstat(descriptor, &status) == 0,
            status.st_mode & S_IFMT == S_IFREG,
            status.st_dev == device,
            status.st_ino == inode,
            status.st_nlink == 1,
            fstatat(parentDescriptor, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
            named.st_mode & S_IFMT == S_IFREG,
            named.st_uid == geteuid(),
            named.st_nlink == 1,
            named.st_dev == device,
            named.st_ino == inode
        else { throw error }
    }

    func stagingDirectoryExists(transferID: TransferID) throws -> Bool {
        try requireHeld()
        let name = transferID.rawValue.uuidString.lowercased()
        var status = stat()
        if fstatat(parentDescriptor, name, &status, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw ReceiveStoreError.stagingUnavailable }
            try requireHeld()
            return false
        }
        guard status.st_mode & S_IFMT == S_IFDIR,
            status.st_uid == geteuid(),
            status.st_mode & 0o077 == 0
        else { throw ReceiveStoreError.stagingUnavailable }
        try requireHeld()
        return true
    }

    func makeStagingTree(
        stagingName: String,
        metadataName: String,
        onStagingDirectoryCreated: () throws -> Void = {}
    ) throws
        -> DescriptorStagingTree
    {
        try requireHeld()
        let tree = try DescriptorStagingTree(
            destinationDescriptor: parentDescriptor,
            stagingName: stagingName,
            metadataName: metadataName,
            onStagingDirectoryCreated: onStagingDirectoryCreated
        )
        try requireHeld()
        return tree
    }

    func removeExpiredQuarantines() throws {
        try requireHeld()
        try secureRemoveExpiredQuarantines(incomingDescriptor: parentDescriptor)
        try requireHeld()
    }

    func removeStagingDirectory(transferID: TransferID) throws -> Bool {
        try requireHeld()
        let removed = try secureRemoveStagingDirectory(
            transferID: transferID,
            incomingDescriptor: parentDescriptor
        )
        try requireHeld()
        return removed
    }

    func preserveForTransfer() {
        removeOnDeinit = false
    }

    func removeAfterTerminalState() throws {
        var current = stat()
        if fstatat(parentDescriptor, name, &current, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT, fsync(parentDescriptor) == 0 else {
                throw ReceiveStoreError.stagingUnavailable
            }
            removeOnDeinit = false
            return
        }
        guard
            current.st_mode & S_IFMT == S_IFREG,
            current.st_dev == device,
            current.st_ino == inode,
            unlinkat(parentDescriptor, name, 0) == 0,
            fsync(parentDescriptor) == 0
        else { throw ReceiveStoreError.stagingUnavailable }
        removeOnDeinit = false
    }
}

private struct PublicationIntent: Sendable {
    private static let magic = Data([0x4d, 0x43, 0x50, 0x49])  // MCPI
    private static let version: UInt8 = 1
    private static let name = ".publication-intent"
    private static let temporaryName = ".publication-intent.tmp"
    private static let fixedBytes = 4 + 1 + 32 + 2 + 32

    let candidate: String

    static func load(fingerprint: Data, tree: DescriptorStagingTree) throws -> PublicationIntent? {
        guard fingerprint.count == 32 else { throw ReceiveStoreError.invalidManifest }
        try removeFileIfPresent(named: temporaryName, tree: tree)
        let descriptor = Darwin.openat(
            tree.metadataDescriptor,
            name,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        if descriptor < 0 {
            guard errno == ENOENT else { throw ReceiveStoreError.stagingUnavailable }
            return nil
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
            status.st_mode & S_IFMT == S_IFREG,
            status.st_uid == geteuid(),
            status.st_nlink == 1,
            status.st_size >= fixedBytes,
            status.st_size <= fixedBytes + Int(MAXNAMLEN)
        else { throw ReceiveStoreError.stagingUnavailable }
        let data = try readPublicationData(descriptor, length: Int(status.st_size))
        let body = data.dropLast(32)
        guard data.prefix(4) == magic,
            data[4] == version,
            data.subdata(in: 5..<37) == fingerprint,
            Data(SHA256.hash(data: body)) == data.suffix(32)
        else { throw ReceiveStoreError.stagingUnavailable }
        let length = Int(data[37]) << 8 | Int(data[38])
        guard length > 0, fixedBytes + length == data.count,
            let candidate = String(data: data.subdata(in: 39..<(39 + length)), encoding: .utf8),
            isSafePublicationName(candidate)
        else { throw ReceiveStoreError.stagingUnavailable }
        return PublicationIntent(candidate: candidate)
    }

    static func record(
        candidate: String,
        fingerprint: Data,
        tree: DescriptorStagingTree
    ) throws {
        guard fingerprint.count == 32, isSafePublicationName(candidate) else {
            throw ReceiveStoreError.invalidManifest
        }
        let encoded = Data(candidate.utf8)
        guard encoded.count <= Int(UInt16.max), encoded.count <= Int(MAXNAMLEN) else {
            throw ReceiveStoreError.invalidManifest
        }
        var body = magic
        body.append(version)
        body.append(fingerprint)
        body.append(UInt8(encoded.count >> 8))
        body.append(UInt8(encoded.count & 0xff))
        body.append(encoded)
        var data = body
        data.append(Data(SHA256.hash(data: body)))

        try removeFileIfPresent(named: temporaryName, tree: tree)
        let descriptor = Darwin.openat(
            tree.metadataDescriptor,
            temporaryName,
            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw ReceiveStoreError.stagingUnavailable }
        var keepTemporary = true
        defer {
            Darwin.close(descriptor)
            if keepTemporary {
                _ = unlinkat(tree.metadataDescriptor, temporaryName, 0)
            }
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
            status.st_mode & S_IFMT == S_IFREG,
            status.st_uid == geteuid(),
            status.st_nlink == 1
        else { throw ReceiveStoreError.stagingUnavailable }
        try writePublicationData(data, descriptor: descriptor)
        guard fsync(descriptor) == 0,
            renameat(
                tree.metadataDescriptor,
                temporaryName,
                tree.metadataDescriptor,
                name
            ) == 0,
            fsync(tree.metadataDescriptor) == 0
        else { throw ReceiveStoreError.stagingUnavailable }
        keepTemporary = false
    }

    static func remove(tree: DescriptorStagingTree) throws {
        try removeFileIfPresent(named: name, tree: tree)
        guard fsync(tree.metadataDescriptor) == 0 else {
            throw ReceiveStoreError.stagingUnavailable
        }
    }

    private static func removeFileIfPresent(
        named name: String,
        tree: DescriptorStagingTree
    ) throws {
        var status = stat()
        if fstatat(tree.metadataDescriptor, name, &status, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw ReceiveStoreError.stagingUnavailable }
            return
        }
        guard status.st_mode & S_IFMT == S_IFREG,
            status.st_uid == geteuid(),
            status.st_nlink == 1,
            unlinkat(tree.metadataDescriptor, name, 0) == 0
        else { throw ReceiveStoreError.stagingUnavailable }
    }

    private static func isSafePublicationName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/")
            && !value.contains("\0") && value.utf8.count <= Int(MAXNAMLEN)
    }
}

private enum SourceBindingStore {
    private static let magic = Data([0x4d, 0x43, 0x53, 0x42])  // MCSB
    private static let version: UInt8 = 1
    private static let name = ".source-binding"
    private static let temporaryName = ".source-binding.tmp"
    private static let bodyBytes = 4 + 1 + 36
    private static let totalBytes = bodyBytes + 32

    static func ensure(
        source: DeviceID,
        resuming: Bool,
        tree: DescriptorStagingTree
    ) throws {
        try removeIfPresent(named: temporaryName, tree: tree)
        let descriptor = Darwin.openat(
            tree.metadataDescriptor,
            name,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        if descriptor < 0 {
            guard errno == ENOENT else { throw ReceiveStoreError.stagingUnavailable }
            guard !resuming else { throw ReceiveStoreError.invalidManifest }
            try record(source: source, tree: tree)
            return
        }
        try validate(descriptor: descriptor, source: source)
    }

    static func validateIfPresent(
        source: DeviceID,
        tree: DescriptorStagingTree
    ) throws {
        let descriptor = Darwin.openat(
            tree.metadataDescriptor,
            name,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        if descriptor < 0 {
            guard errno == ENOENT else { throw ReceiveStoreError.stagingUnavailable }
            return
        }
        try validate(descriptor: descriptor, source: source)
    }

    private static func validate(descriptor: Int32, source: DeviceID) throws {
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
            status.st_mode & S_IFMT == S_IFREG,
            status.st_uid == geteuid(),
            status.st_nlink == 1,
            status.st_size == totalBytes
        else { throw ReceiveStoreError.stagingUnavailable }
        let data = try readPublicationData(descriptor, length: totalBytes)
        let body = data.prefix(bodyBytes)
        guard body.prefix(4) == magic,
            body[4] == version,
            String(data: Data(body.dropFirst(5)), encoding: .utf8)
                == source.rawValue.uuidString.lowercased(),
            Data(SHA256.hash(data: body)) == data.suffix(32)
        else { throw ReceiveStoreError.invalidManifest }
    }

    static func remove(tree: DescriptorStagingTree) throws {
        try removeIfPresent(named: name, tree: tree)
        guard fsync(tree.metadataDescriptor) == 0 else {
            throw ReceiveStoreError.stagingUnavailable
        }
    }

    private static func record(source: DeviceID, tree: DescriptorStagingTree) throws {
        var body = magic
        body.append(version)
        body.append(Data(source.rawValue.uuidString.lowercased().utf8))
        guard body.count == bodyBytes else { throw ReceiveStoreError.invalidManifest }
        var data = body
        data.append(Data(SHA256.hash(data: body)))
        let descriptor = Darwin.openat(
            tree.metadataDescriptor,
            temporaryName,
            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw ReceiveStoreError.stagingUnavailable }
        var keepTemporary = true
        defer {
            Darwin.close(descriptor)
            if keepTemporary {
                _ = unlinkat(tree.metadataDescriptor, temporaryName, 0)
            }
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
            status.st_mode & S_IFMT == S_IFREG,
            status.st_uid == geteuid(),
            status.st_nlink == 1
        else { throw ReceiveStoreError.stagingUnavailable }
        try writePublicationData(data, descriptor: descriptor)
        guard fsync(descriptor) == 0,
            renameat(
                tree.metadataDescriptor,
                temporaryName,
                tree.metadataDescriptor,
                name
            ) == 0,
            fsync(tree.metadataDescriptor) == 0
        else { throw ReceiveStoreError.stagingUnavailable }
        keepTemporary = false
    }

    private static func removeIfPresent(
        named name: String,
        tree: DescriptorStagingTree
    ) throws {
        var status = stat()
        if fstatat(tree.metadataDescriptor, name, &status, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw ReceiveStoreError.stagingUnavailable }
            return
        }
        guard status.st_mode & S_IFMT == S_IFREG,
            status.st_uid == geteuid(),
            status.st_nlink == 1,
            unlinkat(tree.metadataDescriptor, name, 0) == 0
        else { throw ReceiveStoreError.stagingUnavailable }
    }
}

private enum CancellationIntentStore {
    private static let magic = Data([0x4d, 0x43, 0x43, 0x49])  // MCCI
    private static let version: UInt8 = 1
    private static let name = ".cancellation-intent"
    private static let temporaryName = ".cancellation-intent.tmp"
    private static let bodyBytes = 4 + 1 + 32
    private static let totalBytes = bodyBytes + 32

    static func exists(fingerprint: Data, tree: DescriptorStagingTree) throws -> Bool {
        guard fingerprint.count == 32 else { throw ReceiveStoreError.invalidManifest }
        try removeIfPresent(named: temporaryName, tree: tree)
        let descriptor = Darwin.openat(
            tree.metadataDescriptor,
            name,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        if descriptor < 0 {
            guard errno == ENOENT else { throw ReceiveStoreError.stagingUnavailable }
            return false
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
            status.st_mode & S_IFMT == S_IFREG,
            status.st_uid == geteuid(),
            status.st_nlink == 1,
            status.st_size == totalBytes
        else { throw ReceiveStoreError.stagingUnavailable }
        let data = try readPublicationData(descriptor, length: totalBytes)
        let body = data.prefix(bodyBytes)
        guard body.prefix(4) == magic,
            body[4] == version,
            Data(body.dropFirst(5)) == fingerprint,
            Data(SHA256.hash(data: body)) == data.suffix(32)
        else { throw ReceiveStoreError.stagingUnavailable }
        return true
    }

    static func record(fingerprint: Data, tree: DescriptorStagingTree) throws {
        guard fingerprint.count == 32 else { throw ReceiveStoreError.invalidManifest }
        try removeIfPresent(named: temporaryName, tree: tree)
        var body = magic
        body.append(version)
        body.append(fingerprint)
        var data = body
        data.append(Data(SHA256.hash(data: body)))
        let descriptor = Darwin.openat(
            tree.metadataDescriptor,
            temporaryName,
            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw ReceiveStoreError.stagingUnavailable }
        var keepTemporary = true
        defer {
            Darwin.close(descriptor)
            if keepTemporary { _ = unlinkat(tree.metadataDescriptor, temporaryName, 0) }
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
            status.st_mode & S_IFMT == S_IFREG,
            status.st_uid == geteuid(),
            status.st_nlink == 1
        else { throw ReceiveStoreError.stagingUnavailable }
        try writePublicationData(data, descriptor: descriptor)
        guard fsync(descriptor) == 0,
            renameat(
                tree.metadataDescriptor,
                temporaryName,
                tree.metadataDescriptor,
                name
            ) == 0,
            fsync(tree.metadataDescriptor) == 0
        else { throw ReceiveStoreError.stagingUnavailable }
        keepTemporary = false
    }

    private static func removeIfPresent(
        named name: String,
        tree: DescriptorStagingTree
    ) throws {
        var status = stat()
        if fstatat(tree.metadataDescriptor, name, &status, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw ReceiveStoreError.stagingUnavailable }
            return
        }
        guard status.st_mode & S_IFMT == S_IFREG,
            status.st_uid == geteuid(),
            status.st_nlink == 1,
            unlinkat(tree.metadataDescriptor, name, 0) == 0,
            fsync(tree.metadataDescriptor) == 0
        else { throw ReceiveStoreError.stagingUnavailable }
    }
}

private func readPublicationData(_ descriptor: Int32, length: Int) throws -> Data {
    var data = Data(count: length)
    var consumed = 0
    while consumed < length {
        let count = data.withUnsafeMutableBytes { rawBuffer in
            pread(
                descriptor,
                rawBuffer.baseAddress!.advanced(by: consumed),
                length - consumed,
                off_t(consumed)
            )
        }
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw ReceiveStoreError.stagingUnavailable }
        consumed += count
    }
    return data
}

private func writePublicationData(_ data: Data, descriptor: Int32) throws {
    var consumed = 0
    while consumed < data.count {
        let count = data.withUnsafeBytes { rawBuffer in
            pwrite(
                descriptor,
                rawBuffer.baseAddress!.advanced(by: consumed),
                data.count - consumed,
                off_t(consumed)
            )
        }
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw ReceiveStoreError.stagingUnavailable }
        consumed += count
    }
}

enum PublicationCleanupStep: CaseIterable, Sendable {
    case historyCommitted
    case resumeRemoved
    case sourceBindingRemoved
    case intentRemoved
    case metadataRetired
    case metadataRemoved
    case stagingRemoved
}

enum CancellationCleanupStep: Sendable {
    case intentRecorded
    case stagingDiscarded
}

enum ReceivePreparationStep: CaseIterable, Sendable {
    case treeCreated
    case sourceBindingWritten
    case manifestRootCreated
    case journalReady
    case beforeDatabaseReady
}

public actor ReceiveStore {
    private enum State {
        case receiving
        case finalizing(epoch: UInt64, published: URL?)
        case cancelling(epoch: UInt64, stagingDiscarded: Bool)
        case cancellationPendingDiscard
        case discardedPendingCommit
        case published(URL)
        case reconciled(URL)
        case finished
    }

    private let manifest: TransferManifest
    private let source: DeviceID
    private let destinationDirectory: URL
    private let destinationHandle: PinnedReceiveDirectory
    private let incomingDirectory: URL
    private let capacity: any ReceiveCapacityProviding
    private let database: TransferDatabase
    private let lease: ReceiveTransferLease
    private let tree: DescriptorStagingTree
    private let files: [UInt32: StagedFile]
    private var resumeStore: ResumeStateStore?
    private var verified: Set<ChunkCoordinate>
    private let preparedFingerprint: Data
    private var state = State.receiving
    private var operationEpoch: UInt64 = 0

    private init(
        manifest: TransferManifest,
        source: DeviceID,
        destinationDirectory: URL,
        destinationHandle: PinnedReceiveDirectory,
        incomingDirectory: URL,
        capacity: any ReceiveCapacityProviding,
        database: TransferDatabase,
        lease: ReceiveTransferLease,
        tree: DescriptorStagingTree,
        files: [UInt32: StagedFile],
        resumeStore: ResumeStateStore?,
        verified: Set<ChunkCoordinate>,
        preparedFingerprint: Data,
        state: State = .receiving
    ) {
        self.manifest = manifest
        self.source = source
        self.destinationDirectory = destinationDirectory
        self.destinationHandle = destinationHandle
        self.incomingDirectory = incomingDirectory
        self.capacity = capacity
        self.database = database
        self.lease = lease
        self.tree = tree
        self.files = files
        self.resumeStore = resumeStore
        self.verified = verified
        self.preparedFingerprint = preparedFingerprint
        self.state = state
    }

    public static func prepare(
        manifest: TransferManifest,
        source: DeviceID,
        policy: ReceivePolicy,
        directories: DownloadDirectory = DownloadDirectory(),
        database suppliedDatabase: TransferDatabase? = nil,
        route: ConnectionRoute = .lan,
        incomingDirectory suppliedIncoming: URL? = nil,
        capacity: any ReceiveCapacityProviding = VolumeReceiveCapacityProvider()
    ) async throws -> ReceiveStore {
        try await prepareImpl(
            manifest: manifest,
            source: source,
            policy: policy,
            directories: directories,
            database: suppliedDatabase,
            route: route,
            incomingDirectory: suppliedIncoming,
            capacity: capacity,
            onPreparationStep: { _ in }
        )
    }

    static func prepare(
        manifest: TransferManifest,
        source: DeviceID,
        policy: ReceivePolicy,
        directories: DownloadDirectory = DownloadDirectory(),
        database suppliedDatabase: TransferDatabase? = nil,
        route: ConnectionRoute = .lan,
        incomingDirectory suppliedIncoming: URL? = nil,
        capacity: any ReceiveCapacityProviding = VolumeReceiveCapacityProvider(),
        onPreparationStep: @escaping @Sendable (ReceivePreparationStep) throws -> Void
    ) async throws -> ReceiveStore {
        try await prepareImpl(
            manifest: manifest,
            source: source,
            policy: policy,
            directories: directories,
            database: suppliedDatabase,
            route: route,
            incomingDirectory: suppliedIncoming,
            capacity: capacity,
            onPreparationStep: onPreparationStep
        )
    }

    private static func prepareImpl(
        manifest: TransferManifest,
        source: DeviceID,
        policy: ReceivePolicy,
        directories: DownloadDirectory = DownloadDirectory(),
        database suppliedDatabase: TransferDatabase? = nil,
        route: ConnectionRoute = .lan,
        incomingDirectory suppliedIncoming: URL? = nil,
        capacity: any ReceiveCapacityProviding,
        onPreparationStep: @escaping @Sendable (ReceivePreparationStep) throws -> Void
    ) async throws -> ReceiveStore {
        do {
            try validateReceivedManifest(manifest)
        } catch {
            throw ReceiveStoreError.invalidManifest
        }
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("MacChannel", isDirectory: true)
        let incoming =
            (suppliedIncoming
            ?? applicationSupport.appendingPathComponent("Incoming", isDirectory: true))
            .standardizedFileURL
        try preparePrivateIncomingDirectory(incoming)
        let database: TransferDatabase
        if let suppliedDatabase {
            database = suppliedDatabase
        } else {
            database = try TransferDatabase(
                url: applicationSupport.appendingPathComponent("transfers.sqlite3")
            )
        }
        let lease = try ReceiveTransferLease.acquire(
            transferID: manifest.id,
            incomingDirectory: incoming
        )
        var resuming = try lease.stagingDirectoryExists(transferID: manifest.id)
        let knownPhase = try await database.phase(for: manifest.id)
        if knownPhase == .cancelling || knownPhase == .cancelled || knownPhase == .completed {
            do {
                try lease.removeExpiredQuarantines()
                if resuming {
                    _ = try lease.removeStagingDirectory(transferID: manifest.id)
                }
                if knownPhase == .cancelling {
                    try await database.markPhase(.cancelled, for: manifest.id, at: Date())
                }
                try lease.removeAfterTerminalState()
            } catch let error as ReceiveStoreError {
                throw error
            } catch {
                throw ReceiveStoreError.stagingUnavailable
            }
            throw ReceiveStoreError.alreadyFinished
        }

        let aggregate = try manifestAggregateBytes(manifest)
        try policy.authorize(source: source, aggregateBytes: aggregate)
        let destination = directories.directory(for: source).standardizedFileURL
        let destinationHandle = try prepareWritableDestination(destination)
        do {
            try manifest.validateDestinationPaths(onVolumeContaining: destination)
        } catch {
            throw ReceiveStoreError.invalidManifest
        }
        guard try directoriesShareVolume(incoming, destination) else {
            throw ReceiveStoreError.atomicPlacementUnavailable
        }
        try lease.requireHeld()
        if !resuming {
            try requireCapacity(
                remaining: aggregate,
                at: incoming,
                provider: capacity
            )
        }

        let rootName = manifest.entries[0].relativePath.components[0]
        let suffix = manifest.id.rawValue.uuidString.lowercased()
        let caseSensitive = try destinationVolumeSupportsCaseSensitiveNames(destination)
        let rootKey = destinationFilesystemKey([rootName], caseSensitive: caseSensitive)
        let preferredMetadata = ".macchannel-storage-metadata"
        let metadataName =
            rootKey
                == destinationFilesystemKey(
                    [preferredMetadata],
                    caseSensitive: caseSensitive
                ) ? preferredMetadata + ".private" : preferredMetadata
        let fingerprint = try manifestFingerprint(manifest)
        let initialPreparation: TransferPreparationRecord?
        var recordedPhase: TransferPhase
        var creationIntentDurable: Bool
        if resuming {
            initialPreparation = try await database.preparationRecord(
                manifest: manifest,
                source: source
            )
            recordedPhase = initialPreparation?.phase ?? .preparing
            creationIntentDurable = initialPreparation?.isCreating == true
        } else {
            recordedPhase = try await database.recordPreparationIntent(
                manifest: manifest,
                source: source,
                route: route,
                at: Date()
            )
            initialPreparation = TransferPreparationRecord(
                phase: recordedPhase,
                isCreating: true
            )
            creationIntentDurable = true
        }

        if resuming, creationIntentDurable {
            do {
                let interruptedTree = try lease.makeStagingTree(
                    stagingName: suffix,
                    metadataName: metadataName
                )
                try interruptedTree.requireSafeCreationSubset(
                    manifestRootName: rootName,
                    entries: manifest.entries,
                    allowedMetadataEntries: [
                        ".source-binding", ".source-binding.tmp", ".resume-state",
                    ],
                    caseSensitive: caseSensitive
                )
                try SourceBindingStore.validateIfPresent(source: source, tree: interruptedTree)
                try interruptedTree.discard()
                resuming = false
            } catch let error as ReceiveStoreError {
                _ = try? await database.markPhase(.failed, for: manifest.id, at: Date())
                lease.preserveForTransfer()
                throw error
            } catch {
                _ = try? await database.markPhase(.failed, for: manifest.id, at: Date())
                lease.preserveForTransfer()
                throw ReceiveStoreError.stagingUnavailable
            }
        }

        var preparationInterrupted = false
        func checkpoint(_ step: ReceivePreparationStep) throws {
            do {
                try onPreparationStep(step)
            } catch {
                preparationInterrupted = true
                throw error
            }
        }
        let tree: DescriptorStagingTree
        do {
            tree = try lease.makeStagingTree(
                stagingName: suffix,
                metadataName: metadataName,
                onStagingDirectoryCreated: {
                    try checkpoint(.treeCreated)
                }
            )
        } catch {
            if preparationInterrupted {
                lease.preserveForTransfer()
                throw error
            }
            if creationIntentDurable {
                _ = try? await database.markPhase(.failed, for: manifest.id, at: Date())
            }
            throw ReceiveStoreError.stagingUnavailable
        }
        var files: [UInt32: StagedFile] = [:]
        var publicationCommitted = knownPhase == .completed
        var cancellationRecovery = false
        var databasePrepared = initialPreparation != nil || creationIntentDurable
        do {
            try ResumeStateStore.requireCompatible(
                named: ".resume-state",
                fingerprint: fingerprint,
                tree: tree
            )
            let intent = try PublicationIntent.load(fingerprint: fingerprint, tree: tree)
            let rootExists = try tree.containsRootEntry(rootName)
            if knownPhase != .completed {
                try SourceBindingStore.ensure(source: source, resuming: resuming, tree: tree)
            }
            if !resuming { try checkpoint(.sourceBindingWritten) }
            let hasCancellationIntent = try CancellationIntentStore.exists(
                fingerprint: fingerprint,
                tree: tree
            )
            if resuming, rootExists {
                try tree.requireExactEntries(
                    manifest.entries,
                    caseSensitive: caseSensitive
                )
            } else if resuming, intent == nil, knownPhase != .completed {
                throw ReceiveStoreError.stagingUnavailable
            }
            if rootExists {
                for (index, entry) in manifest.entries.enumerated() {
                    switch entry.kind {
                    case .directory:
                        if !resuming {
                            try tree.ensureDirectory(entry.relativePath.components)
                        }
                    case .file:
                        files[UInt32(index)] = try tree.openFile(
                            entry.relativePath.components,
                            create: !resuming
                        )
                    }
                }
            } else if !resuming {
                let rootEntry = manifest.entries[0]
                switch rootEntry.kind {
                case .directory:
                    try tree.ensureDirectory(rootEntry.relativePath.components)
                case .file:
                    files[0] = try tree.openFile(
                        rootEntry.relativePath.components,
                        create: true
                    )
                }
                try checkpoint(.manifestRootCreated)
                for (index, entry) in manifest.entries.enumerated().dropFirst() {
                    switch entry.kind {
                    case .directory:
                        try tree.ensureDirectory(entry.relativePath.components)
                    case .file:
                        files[UInt32(index)] = try tree.openFile(
                            entry.relativePath.components,
                            create: true
                        )
                    }
                }
            }
            let loaded: (store: ResumeStateStore, verified: Set<ChunkCoordinate>)?
            if rootExists || !resuming {
                loaded = try ResumeStateStore.load(
                    named: ".resume-state",
                    fingerprint: fingerprint,
                    manifest: manifest,
                    tree: tree,
                    files: files,
                    onCheckpointValidated: nil
                )
            } else {
                loaded = nil
            }
            if !resuming { try checkpoint(.journalReady) }
            if loaded != nil {
                var metadataEntries: Set<String> = [".resume-state", ".source-binding"]
                if intent != nil { metadataEntries.insert(".publication-intent") }
                if hasCancellationIntent { metadataEntries.insert(".cancellation-intent") }
                try tree.requireExactStagingRoot(
                    manifestRootName: rootName,
                    metadataEntries: metadataEntries
                )
            }

            if resuming, initialPreparation == nil {
                recordedPhase = try await database.recordPreparationIntent(
                    manifest: manifest,
                    source: source,
                    route: route,
                    at: Date()
                )
                creationIntentDurable = true
                databasePrepared = true
            }
            if creationIntentDurable {
                try checkpoint(.beforeDatabaseReady)
                recordedPhase = try await database.finishPreparation(
                    manifest: manifest,
                    source: source,
                    route: route,
                    at: Date()
                )
                creationIntentDurable = false
            }
            if recordedPhase == .cancelling {
                cancellationRecovery = true
                try tree.discard()
                try await database.markPhase(.cancelled, for: manifest.id, at: Date())
                try lease.removeAfterTerminalState()
                throw ReceiveStoreError.alreadyFinished
            }
            if hasCancellationIntent {
                cancellationRecovery = true
                if recordedPhase != .cancelling {
                    try await database.markPhase(.cancelling, for: manifest.id, at: Date())
                }
                try tree.discard()
                try await database.markPhase(.cancelled, for: manifest.id, at: Date())
                try lease.removeAfterTerminalState()
                throw ReceiveStoreError.alreadyFinished
            }
            if let intent {
                let published = try recoverPublishedCandidate(
                    intent.candidate,
                    manifest: manifest,
                    destination: destination,
                    destinationHandle: destinationHandle,
                    required: !rootExists || recordedPhase == .completed
                )
                if published {
                    if recordedPhase != .completed {
                        try await database.markPhase(.completed, for: manifest.id, at: Date())
                        publicationCommitted = true
                    }
                    try tree.discard()
                    try lease.removeAfterTerminalState()
                    return ReceiveStore(
                        manifest: manifest,
                        source: source,
                        destinationDirectory: destination,
                        destinationHandle: destinationHandle,
                        incomingDirectory: incoming,
                        capacity: capacity,
                        database: database,
                        lease: lease,
                        tree: tree,
                        files: [:],
                        resumeStore: nil,
                        verified: try allManifestCoordinates(manifest),
                        preparedFingerprint: fingerprint,
                        state: .reconciled(
                            destination.appendingPathComponent(
                                intent.candidate,
                                isDirectory: manifest.entries[0].kind == .directory
                            )
                        )
                    )
                }
            }
            if recordedPhase == .completed {
                guard !rootExists else { throw ReceiveStoreError.stagingUnavailable }
                try tree.discard()
                try lease.removeAfterTerminalState()
                throw ReceiveStoreError.alreadyFinished
            }
            guard let loaded else { throw ReceiveStoreError.stagingUnavailable }
            let store = ReceiveStore(
                manifest: manifest,
                source: source,
                destinationDirectory: destination,
                destinationHandle: destinationHandle,
                incomingDirectory: incoming,
                capacity: capacity,
                database: database,
                lease: lease,
                tree: tree,
                files: files,
                resumeStore: loaded.store,
                verified: loaded.verified,
                preparedFingerprint: fingerprint
            )
            let revalidated = try await store.resumeMap()
            if resuming {
                try requireCapacity(
                    remaining: try await store.remainingBytes(),
                    at: incoming,
                    provider: capacity
                )
            }
            try await database.activatePrepared(manifest.id, route: route, at: Date())
            try await database.replaceVerifiedRanges(for: manifest.id, with: revalidated)
            try await database.updateProgress(
                try await store.completedBytes(),
                for: manifest.id,
                at: Date()
            )
            lease.preserveForTransfer()
            return store
        } catch let error as ReceiveStoreError {
            if preparationInterrupted {
                lease.preserveForTransfer()
                throw error
            }
            if databasePrepared, !publicationCommitted, !cancellationRecovery {
                _ = try? await database.markPhase(.failed, for: manifest.id, at: Date())
            } else if !resuming, !databasePrepared {
                try? tree.discard()
            }
            throw error
        } catch {
            if preparationInterrupted {
                lease.preserveForTransfer()
                throw error
            }
            if databasePrepared, !publicationCommitted, !cancellationRecovery {
                _ = try? await database.markPhase(.failed, for: manifest.id, at: Date())
            } else if !resuming, !databasePrepared {
                try? tree.discard()
            }
            throw ReceiveStoreError.stagingUnavailable
        }
    }

    public func write(_ data: Data, index: UInt32, entry: UInt32) async throws {
        guard case .receiving = state else { throw ReceiveStoreError.alreadyFinished }
        try lease.requireHeld()
        do {
            try tree.requireStagingPathIdentity()
        } catch {
            throw ReceiveStoreError.stagingUnavailable
        }
        let coordinate = ChunkCoordinate(entryIndex: entry, chunkIndex: index)
        guard !verified.contains(coordinate), Int(entry) < manifest.entries.count else {
            throw ReceiveStoreError.invalidChunk
        }
        let manifestEntry = manifest.entries[Int(entry)]
        guard manifestEntry.kind == .file,
            index < manifestEntry.chunkCount,
            let file = files[entry]
        else { throw ReceiveStoreError.invalidChunk }
        let offset = UInt64(index) * UInt64(TransferProtocolLimits.maximumChunkBytes)
        let expectedLength = Int(
            min(
                UInt64(TransferProtocolLimits.maximumChunkBytes),
                manifestEntry.size - offset
            )
        )
        guard data.count == expectedLength else { throw ReceiveStoreError.invalidChunk }
        try requireCapacity(
            remaining: try remainingBytes(),
            at: incomingDirectory,
            provider: capacity
        )
        do {
            let digest = try file.writeAndVerify(data, offset: offset)
            guard let resumeStore else { throw ReceiveStoreError.stagingUnavailable }
            try resumeStore.append(coordinate, digest: digest)
            verified.insert(coordinate)
            try await database.recordVerified(coordinate, for: manifest.id)
            try await database.updateProgress(
                try completedBytes(),
                for: manifest.id,
                at: Date()
            )
        } catch let error as ReceiveStoreError {
            throw error
        } catch let error as TransferProtocolError {
            if error == .digestMismatch { throw ReceiveStoreError.digestMismatch }
            throw ReceiveStoreError.stagingUnavailable
        } catch {
            throw ReceiveStoreError.stagingUnavailable
        }
    }

    public func resumeMap() throws -> ResumeMap {
        var ranges: [ChunkRange] = []
        for (entryIndex, entry) in manifest.entries.enumerated() where entry.kind == .file {
            var start: UInt32?
            var previous: UInt32?
            for chunk in 0..<entry.chunkCount {
                let present = verified.contains(
                    ChunkCoordinate(entryIndex: UInt32(entryIndex), chunkIndex: chunk)
                )
                if present, start == nil { start = chunk }
                if !present, let lower = start, let upper = previous {
                    ranges.append(
                        try ChunkRange(
                            entryIndex: UInt32(entryIndex),
                            lowerBound: lower,
                            upperBound: upper + 1
                        )
                    )
                    break
                }
                if present { previous = chunk }
            }
            if let lower = start, let upper = previous,
                !ranges.contains(where: { $0.entryIndex == UInt32(entryIndex) })
            {
                ranges.append(
                    try ChunkRange(
                        entryIndex: UInt32(entryIndex),
                        lowerBound: lower,
                        upperBound: upper + 1
                    )
                )
            }
        }
        return try ResumeMap(ranges: ranges)
    }

    public func finalize() async throws -> URL {
        try await finalize(
            onOperationClaimed: {},
            onPublishedBeforeHistory: {},
            onCleanupStep: { _ in }
        )
    }

    func finalize(
        onPublishedBeforeHistory: @Sendable () throws -> Void
    ) async throws -> URL {
        try await finalize(
            onOperationClaimed: {},
            onPublishedBeforeHistory: onPublishedBeforeHistory,
            onCleanupStep: { _ in }
        )
    }

    func finalize(
        onOperationClaimed: @escaping @Sendable () async -> Void = {},
        onPublishedBeforeHistory: @Sendable () throws -> Void,
        onPublicationIntentRecorded: @Sendable () throws -> Void = {},
        onCleanupStep: @escaping @Sendable (PublicationCleanupStep) throws -> Void
    ) async throws -> URL {
        let epoch = claimOperationEpoch()
        let previouslyPublished: URL?
        switch state {
        case .reconciled(let output):
            state = .finished
            return output
        case .published(let output):
            previouslyPublished = output
            state = .finalizing(epoch: epoch, published: output)
        case .finished:
            throw ReceiveStoreError.alreadyFinished
        case .finalizing:
            throw ReceiveStoreError.alreadyFinalizing
        case .cancelling, .cancellationPendingDiscard:
            throw ReceiveStoreError.alreadyFinished
        case .discardedPendingCommit:
            throw ReceiveStoreError.alreadyFinished
        case .receiving:
            previouslyPublished = nil
            state = .finalizing(epoch: epoch, published: nil)
        }

        if let output = previouslyPublished {
            await onOperationClaimed()
            guard ownsFinalization(epoch: epoch, published: output) else {
                throw ReceiveStoreError.alreadyFinalizing
            }
            do {
                try await finishPublished(
                    output,
                    epoch: epoch,
                    onCleanupStep: onCleanupStep
                )
                return output
            } catch {
                restorePublished(output, for: epoch)
                throw error
            }
        }

        do {
            try lease.requireHeld()
            for (index, entry) in manifest.entries.enumerated() where entry.kind == .file {
                guard let file = files[UInt32(index)] else {
                    throw ReceiveStoreError.invalidManifest
                }
                for chunk in 0..<entry.chunkCount
                where !verified.contains(
                    ChunkCoordinate(entryIndex: UInt32(index), chunkIndex: chunk)
                ) {
                    _ = chunk
                    throw ReceiveStoreError.incompleteTransfer
                }
                do {
                    guard try file.currentSize() == entry.size,
                        try file.digest(size: entry.size) == entry.digest
                    else { throw ReceiveStoreError.digestMismatch }
                    try tree.requireIdentity(file, at: entry.relativePath.components)
                } catch let error as ReceiveStoreError {
                    throw error
                } catch {
                    throw ReceiveStoreError.digestMismatch
                }
            }
            guard (try? manifestFingerprint(manifest)) == preparedFingerprint else {
                throw ReceiveStoreError.invalidManifest
            }
        } catch {
            restoreReceiving(for: epoch)
            throw error
        }

        await onOperationClaimed()
        guard ownsFinalization(epoch: epoch, published: nil) else {
            throw ReceiveStoreError.alreadyFinalizing
        }
        do {
            try await database.markPhase(.verifying, for: manifest.id, at: Date())
        } catch {
            restoreReceiving(for: epoch)
            throw error
        }
        guard ownsFinalization(epoch: epoch, published: nil) else {
            throw ReceiveStoreError.alreadyFinalizing
        }
        do {
            try destinationHandle.requirePathIdentity()
            try tree.requireStagingPathIdentity()
            let intent = try PublicationIntent.load(
                fingerprint: preparedFingerprint,
                tree: tree
            )
            guard
                try !CancellationIntentStore.exists(
                    fingerprint: preparedFingerprint,
                    tree: tree
                )
            else { throw TransferProtocolError.destinationEscape }
            var metadataEntries: Set<String> = [".resume-state", ".source-binding"]
            if intent != nil { metadataEntries.insert(".publication-intent") }
            try tree.requireExactStagingRoot(
                manifestRootName: manifest.entries[0].relativePath.components[0],
                metadataEntries: metadataEntries
            )
            try tree.requireExactEntries(
                manifest.entries,
                caseSensitive: try destinationVolumeSupportsCaseSensitiveNames(incomingDirectory)
            )
            for (index, entry) in manifest.entries.enumerated() where entry.kind == .file {
                try files[UInt32(index)]?.setModificationDate(entry.modificationDate)
            }
            for entry in manifest.entries.reversed() where entry.kind == .directory {
                try tree.setDirectoryModificationDate(
                    entry.modificationDate,
                    components: entry.relativePath.components
                )
            }
            let root = manifest.entries[0]
            try destinationHandle.lockForPublication()
            let output: URL
            do {
                output = try tree.finalize(
                    rootName: root.relativePath.components[0],
                    isDirectory: root.kind == .directory,
                    destinationDirectory: destinationDirectory,
                    destinationDescriptor: destinationHandle.descriptor,
                    onCandidate: { candidate in
                        try PublicationIntent.record(
                            candidate: candidate,
                            fingerprint: self.preparedFingerprint,
                            tree: self.tree
                        )
                        try onPublicationIntentRecorded()
                        try self.lease.requireHeld()
                        try self.destinationHandle.requirePathIdentity()
                    }
                )
                destinationHandle.unlockPublication()
            } catch {
                destinationHandle.unlockPublication()
                if let intent = try? PublicationIntent.load(
                    fingerprint: preparedFingerprint,
                    tree: tree
                ), (try? tree.containsRootEntry(root.relativePath.components[0])) == false {
                    let recoveredOutput = destinationDirectory.appendingPathComponent(
                        intent.candidate,
                        isDirectory: root.kind == .directory
                    )
                    if ownsFinalization(epoch: epoch, published: nil) {
                        state = .finalizing(epoch: epoch, published: recoveredOutput)
                    }
                }
                throw error
            }
            guard ownsFinalization(epoch: epoch, published: nil) else {
                throw ReceiveStoreError.alreadyFinalizing
            }
            state = .finalizing(epoch: epoch, published: output)
            try onPublishedBeforeHistory()
            try await finishPublished(
                output,
                epoch: epoch,
                onCleanupStep: onCleanupStep
            )
            return output
        } catch {
            if let output = finalizingPublishedOutput(for: epoch) {
                restorePublished(output, for: epoch)
            } else {
                _ = try? await database.markPhase(.failed, for: manifest.id, at: Date())
                restoreReceiving(for: epoch)
            }
            if let storage = error as? ReceiveStoreError { throw storage }
            throw ReceiveStoreError.atomicPlacementUnavailable
        }
    }

    private func claimOperationEpoch() -> UInt64 {
        operationEpoch &+= 1
        return operationEpoch
    }

    private func ownsFinalization(epoch: UInt64, published: URL?) -> Bool {
        guard case .finalizing(let current, let currentPublished) = state else { return false }
        return current == epoch && currentPublished == published
    }

    private func finalizingPublishedOutput(for epoch: UInt64) -> URL? {
        guard case .finalizing(let current, let output?) = state, current == epoch else {
            return nil
        }
        return output
    }

    private func restoreReceiving(for epoch: UInt64) {
        if ownsFinalization(epoch: epoch, published: nil) { state = .receiving }
    }

    private func restorePublished(_ output: URL, for epoch: UInt64) {
        if ownsFinalization(epoch: epoch, published: output) { state = .published(output) }
    }

    public func cancel() async throws {
        try await cancel(onOperationClaimed: {}, onCleanupStep: { _ in })
    }

    func cancel(
        onCleanupStep: @escaping @Sendable (CancellationCleanupStep) throws -> Void
    ) async throws {
        try await cancel(onOperationClaimed: {}, onCleanupStep: onCleanupStep)
    }

    func cancel(
        onOperationClaimed: @escaping @Sendable () async -> Void,
        onCleanupStep: @escaping @Sendable (CancellationCleanupStep) throws -> Void
    ) async throws {
        let epoch = claimOperationEpoch()
        let fallback: State
        var durableCancellation = false
        var stagingDiscarded = false
        switch state {
        case .receiving:
            fallback = .receiving
            state = .cancelling(epoch: epoch, stagingDiscarded: false)
        case .cancellationPendingDiscard:
            fallback = .cancellationPendingDiscard
            durableCancellation = true
            state = .cancelling(epoch: epoch, stagingDiscarded: false)
        case .discardedPendingCommit:
            fallback = .discardedPendingCommit
            durableCancellation = true
            stagingDiscarded = true
            state = .cancelling(epoch: epoch, stagingDiscarded: true)
        case .cancelling:
            throw ReceiveStoreError.alreadyCancelling
        case .finalizing:
            throw ReceiveStoreError.alreadyFinalizing
        case .published, .reconciled, .finished:
            return
        }

        do {
            try lease.requireHeld()
            await onOperationClaimed()
            guard ownsCancellation(epoch: epoch, stagingDiscarded: stagingDiscarded) else {
                throw ReceiveStoreError.alreadyCancelling
            }
            if !stagingDiscarded {
                try await database.markPhase(.cancelling, for: manifest.id, at: Date())
                durableCancellation = true
                guard ownsCancellation(epoch: epoch, stagingDiscarded: false) else {
                    throw ReceiveStoreError.alreadyCancelling
                }
                if try !CancellationIntentStore.exists(
                    fingerprint: preparedFingerprint,
                    tree: tree
                ) {
                    try CancellationIntentStore.record(
                        fingerprint: preparedFingerprint,
                        tree: tree
                    )
                    try onCleanupStep(.intentRecorded)
                }
                do {
                    try tree.discard()
                } catch {
                    do {
                        guard try !lease.stagingDirectoryExists(transferID: manifest.id) else {
                            throw ReceiveStoreError.stagingUnavailable
                        }
                    } catch let storage as ReceiveStoreError {
                        throw storage
                    } catch {
                        throw ReceiveStoreError.stagingUnavailable
                    }
                }
                stagingDiscarded = true
                state = .cancelling(epoch: epoch, stagingDiscarded: true)
                try onCleanupStep(.stagingDiscarded)
            }
            try lease.requireHeld()
            guard try !lease.stagingDirectoryExists(transferID: manifest.id) else {
                throw ReceiveStoreError.stagingUnavailable
            }
            try await database.markPhase(.cancelled, for: manifest.id, at: Date())
            guard ownsCancellation(epoch: epoch, stagingDiscarded: true) else {
                throw ReceiveStoreError.alreadyCancelling
            }
            try lease.removeAfterTerminalState()
            state = .finished
        } catch {
            if ownsCancellation(epoch: epoch, stagingDiscarded: stagingDiscarded) {
                if stagingDiscarded {
                    state = .discardedPendingCommit
                } else if durableCancellation {
                    state = .cancellationPendingDiscard
                } else {
                    state = fallback
                }
            }
            throw error
        }
    }

    private func ownsCancellation(epoch: UInt64, stagingDiscarded: Bool) -> Bool {
        guard case .cancelling(let current, let currentDiscarded) = state else { return false }
        return current == epoch && currentDiscarded == stagingDiscarded
    }

    public func markFailed(at date: Date = Date()) async throws {
        guard case .receiving = state else { throw ReceiveStoreError.alreadyFinished }
        try await database.markPhase(.failed, for: manifest.id, at: date)
    }

    private func finishPublished(
        _ output: URL,
        epoch: UInt64,
        onCleanupStep: @escaping @Sendable (PublicationCleanupStep) throws -> Void
    ) async throws {
        guard ownsFinalization(epoch: epoch, published: output) else {
            throw ReceiveStoreError.alreadyFinalizing
        }
        try destinationHandle.requirePathIdentity()
        try verifyPublishedManifest(
            parentDescriptor: destinationHandle.descriptor,
            candidate: output.lastPathComponent,
            manifest: manifest,
            caseSensitive: try destinationVolumeSupportsCaseSensitiveNames(destinationDirectory)
        )
        try destinationHandle.synchronize()
        try await database.markPhase(.completed, for: manifest.id, at: Date())
        guard ownsFinalization(epoch: epoch, published: output) else {
            throw ReceiveStoreError.alreadyFinalizing
        }
        try onCleanupStep(.historyCommitted)
        try performPublicationCleanup {
            try ResumeStateStore.remove(named: ".resume-state", tree: tree)
        }
        resumeStore = nil
        try onCleanupStep(.resumeRemoved)
        try performPublicationCleanup {
            try SourceBindingStore.remove(tree: tree)
        }
        try onCleanupStep(.sourceBindingRemoved)
        try performPublicationCleanup {
            try PublicationIntent.remove(tree: tree)
        }
        try onCleanupStep(.intentRemoved)
        try performPublicationCleanup {
            try tree.removeMetadataDirectory(onValidated: { _ in
                try onCleanupStep(.metadataRetired)
            })
        }
        try onCleanupStep(.metadataRemoved)
        try performPublicationCleanup {
            try tree.removeEmptyStagingDirectory()
        }
        try onCleanupStep(.stagingRemoved)
        try performPublicationCleanup {
            try lease.removeAfterTerminalState()
        }
        state = .finished
    }

    public static func expireFailedStaging(
        database: TransferDatabase,
        incomingDirectory: URL? = nil,
        now: Date = Date()
    ) async throws -> [TransferID] {
        let incoming =
            (incomingDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacChannel/Incoming", isDirectory: true))
            .standardizedFileURL
        guard FileManager.default.fileExists(atPath: incoming.path) else { return [] }
        let threshold = now.addingTimeInterval(-7 * 86_400)
        let candidates = try await database.failedTransfers(updatedBefore: threshold)
        var removed: [TransferID] = []
        for id in candidates {
            do {
                let lease: ReceiveTransferLease
                do {
                    lease = try ReceiveTransferLease.acquire(
                        transferID: id,
                        incomingDirectory: incoming
                    )
                } catch ReceiveStoreError.transferBusy {
                    continue
                }
                try lease.requireHeld()
                try lease.removeExpiredQuarantines()
                if try lease.removeStagingDirectory(transferID: id) {
                    removed.append(id)
                }
                try? lease.removeAfterTerminalState()
            } catch {
                throw ReceiveStoreError.stagingUnavailable
            }
        }
        return removed
    }

    private func remainingBytes() throws -> UInt64 {
        let total = try manifestAggregateBytes(manifest)
        let completed = try completedBytes()
        guard completed <= total else { throw ReceiveStoreError.invalidManifest }
        return total - completed
    }

    private func completedBytes() throws -> UInt64 {
        var total: UInt64 = 0
        for coordinate in verified {
            guard Int(coordinate.entryIndex) < manifest.entries.count else {
                throw ReceiveStoreError.invalidManifest
            }
            let entry = manifest.entries[Int(coordinate.entryIndex)]
            let offset =
                UInt64(coordinate.chunkIndex)
                * UInt64(TransferProtocolLimits.maximumChunkBytes)
            guard offset < entry.size || entry.size == 0 else {
                throw ReceiveStoreError.invalidManifest
            }
            let length = min(
                UInt64(TransferProtocolLimits.maximumChunkBytes),
                entry.size - offset
            )
            guard total <= UInt64.max - length else {
                throw ReceiveStoreError.invalidManifest
            }
            total += length
        }
        return total
    }
}

func manifestAggregateBytes(_ manifest: TransferManifest) throws -> UInt64 {
    var aggregate: UInt64 = 0
    for entry in manifest.entries {
        guard aggregate <= UInt64.max - entry.size else {
            throw ReceiveStoreError.invalidManifest
        }
        aggregate += entry.size
    }
    return aggregate
}

private func recoverPublishedCandidate(
    _ candidate: String,
    manifest: TransferManifest,
    destination: URL,
    destinationHandle: PinnedReceiveDirectory,
    required: Bool
) throws -> Bool {
    try destinationHandle.requirePathIdentity()
    try destinationHandle.lockForPublication()
    defer { destinationHandle.unlockPublication() }
    do {
        try verifyPublishedManifest(
            parentDescriptor: destinationHandle.descriptor,
            candidate: candidate,
            manifest: manifest,
            caseSensitive: try destinationVolumeSupportsCaseSensitiveNames(destination)
        )
        try destinationHandle.synchronize()
        return true
    } catch {
        if required { throw error }
        return false
    }
}

private func performPublicationCleanup(_ operation: () throws -> Void) throws {
    do {
        try operation()
    } catch let error as ReceiveStoreError {
        throw error
    } catch {
        throw ReceiveStoreError.stagingUnavailable
    }
}

private func allManifestCoordinates(_ manifest: TransferManifest) throws -> Set<ChunkCoordinate> {
    var result: Set<ChunkCoordinate> = []
    for (entryIndex, entry) in manifest.entries.enumerated() where entry.kind == .file {
        guard entryIndex <= Int(UInt32.max) else { throw ReceiveStoreError.invalidManifest }
        for chunkIndex in 0..<entry.chunkCount {
            result.insert(
                ChunkCoordinate(
                    entryIndex: UInt32(entryIndex),
                    chunkIndex: chunkIndex
                )
            )
        }
    }
    return result
}

private func requiredCapacity(for remaining: UInt64) -> UInt64 {
    let reserve = remaining / 20 + (remaining.isMultiple(of: 20) ? 0 : 1)
    return remaining > UInt64.max - reserve ? UInt64.max : remaining + reserve
}

private func requireCapacity(
    remaining: UInt64,
    at directory: URL,
    provider: any ReceiveCapacityProviding
) throws {
    let available = try provider.availableBytes(at: directory)
    let required = requiredCapacity(for: remaining)
    guard available >= required else {
        throw ReceiveStoreError.insufficientCapacity(required: required, available: available)
    }
}

private final class PinnedReceiveDirectory: @unchecked Sendable {
    let descriptor: Int32
    private let url: URL
    private let device: dev_t
    private let inode: ino_t

    init(url: URL, descriptor: Int32, status: stat) {
        self.url = url
        self.descriptor = descriptor
        device = status.st_dev
        inode = status.st_ino
    }

    deinit { Darwin.close(descriptor) }

    func requirePathIdentity() throws {
        var current = stat()
        guard stat(url.path, &current) == 0,
            current.st_mode & S_IFMT == S_IFDIR,
            current.st_dev == device,
            current.st_ino == inode
        else { throw ReceiveStoreError.atomicPlacementUnavailable }
    }

    func lockForPublication() throws {
        while flock(descriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw ReceiveStoreError.atomicPlacementUnavailable
        }
    }

    func unlockPublication() {
        _ = flock(descriptor, LOCK_UN)
    }

    func synchronize() throws {
        guard fsync(descriptor) == 0 else {
            throw ReceiveStoreError.atomicPlacementUnavailable
        }
    }
}

private func prepareWritableDestination(_ directory: URL) throws -> PinnedReceiveDirectory {
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
        throw ReceiveStoreError.destinationNotWritable
    }
    let descriptor = Darwin.open(
        directory.path,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else { throw ReceiveStoreError.destinationNotWritable }
    var status = stat()
    guard fstat(descriptor, &status) == 0,
        status.st_mode & S_IFMT == S_IFDIR,
        status.st_uid == geteuid(),
        status.st_mode & S_IWUSR != 0
    else {
        Darwin.close(descriptor)
        throw ReceiveStoreError.destinationNotWritable
    }
    return PinnedReceiveDirectory(url: directory, descriptor: descriptor, status: status)
}

private func preparePrivateIncomingDirectory(_ directory: URL) throws {
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
        throw ReceiveStoreError.stagingUnavailable
    }
    let descriptor = Darwin.open(
        directory.path,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else { throw ReceiveStoreError.stagingUnavailable }
    defer { Darwin.close(descriptor) }
    var status = stat()
    guard fstat(descriptor, &status) == 0,
        status.st_mode & S_IFMT == S_IFDIR,
        status.st_uid == geteuid(),
        fchmod(descriptor, S_IRWXU) == 0,
        fstat(descriptor, &status) == 0,
        status.st_mode & 0o077 == 0
    else { throw ReceiveStoreError.stagingUnavailable }
}

private func directoriesShareVolume(_ first: URL, _ second: URL) throws -> Bool {
    var firstStatus = stat()
    var secondStatus = stat()
    guard stat(first.path, &firstStatus) == 0, stat(second.path, &secondStatus) == 0 else {
        throw ReceiveStoreError.atomicPlacementUnavailable
    }
    return firstStatus.st_dev == secondStatus.st_dev
}
