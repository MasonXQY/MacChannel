import CryptoKit
import Darwin
import Foundation

public enum TransferProtocolError: Error, Equatable, Sendable {
    case invalidRelativePath
    case unsupportedSource
    case symlinkEscape
    case sourceChanged
    case manifestTooLarge
    case invalidFrame
    case unsupportedVersion
    case frameTooLarge
    case authenticationFailed
    case replayOrOutOfOrder
    case unexpectedFrame
    case invalidResumeMap
    case invalidChunk
    case duplicateChunk
    case digestMismatch
    case destinationEscape
    case destinationExists
    case destinationPathCollision
    case cancelled
    case channelEnded
}

public enum TransferProtocolLimits {
    public static let maximumWireFrameBytes = 64 * 1024
    public static let maximumUnacknowledgedChunks = 64
    public static let acknowledgementChunkInterval = 16
    public static let maximumFramePlaintextBytes = maximumWireFrameBytes - 62
    public static let maximumManifestEntries = 4_096
    public static let maximumResumeRanges = maximumManifestEntries
    public static let maximumTransferChunks = 1_000_000

    // A chunk frame uses 22 bytes of versioned metadata. The authenticated
    // envelope uses 62 bytes (magic, version, direction, transfer ID,
    // sequence, reconnect nonce epoch, and tag). File bytes are therefore within the
    // SecureChannel's inclusive 64 KiB cap.
    public static let maximumChunkBytes = maximumWireFrameBytes - 84
    public static let maximumTransferBytes =
        UInt64(maximumChunkBytes) * UInt64(maximumTransferChunks)
}

public struct RelativePath: Hashable, Sendable {
    public let components: [String]

    public init(_ string: String) throws {
        guard !string.isEmpty,
            !string.contains("\0"),
            !NSString(string: string).isAbsolutePath,
            !string.hasPrefix("/")
        else { throw TransferProtocolError.invalidRelativePath }
        let raw = string.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !raw.isEmpty,
            raw.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
            raw.allSatisfy({ component in
                Data(component.precomposedStringWithCanonicalMapping.utf8) == Data(component.utf8)
            })
        else { throw TransferProtocolError.invalidRelativePath }
        components = raw
    }

    init(components: [String]) throws {
        try self.init(components.joined(separator: "/"))
    }

    public var string: String { components.joined(separator: "/") }
}

public enum TransferEntryKind: UInt8, Sendable {
    case file = 1
    case directory = 2
}

public struct TransferManifestEntry: Sendable {
    public let relativePath: RelativePath
    public let kind: TransferEntryKind
    public let size: UInt64
    public let modificationDate: Date
    public let chunkCount: UInt32
    public let digest: Data
    let pinnedSource: PinnedSource?

    init(
        relativePath: RelativePath,
        kind: TransferEntryKind,
        size: UInt64,
        modificationDate: Date,
        chunkCount: UInt32,
        digest: Data,
        pinnedSource: PinnedSource? = nil
    ) {
        self.relativePath = relativePath
        self.kind = kind
        self.size = size
        self.modificationDate = modificationDate
        self.chunkCount = chunkCount
        self.digest = digest
        self.pinnedSource = pinnedSource
    }
}

final class PinnedSource: @unchecked Sendable {
    private let descriptor: Int32
    let size: UInt64

    private init(descriptor: Int32, size: UInt64) {
        self.descriptor = descriptor
        self.size = size
    }

    deinit { Darwin.close(descriptor) }

    static func clone(from url: URL) throws -> PinnedSource {
        var pathStatus = stat()
        guard lstat(url.path, &pathStatus) == 0,
            pathStatus.st_mode & S_IFMT == S_IFREG
        else { throw TransferProtocolError.sourceChanged }
        let sourceDescriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard sourceDescriptor >= 0 else { throw TransferProtocolError.sourceChanged }
        defer { Darwin.close(sourceDescriptor) }
        var sourceStatus = stat()
        guard fstat(sourceDescriptor, &sourceStatus) == 0,
            sourceStatus.st_mode & S_IFMT == S_IFREG,
            sourceStatus.st_dev == pathStatus.st_dev,
            sourceStatus.st_ino == pathStatus.st_ino,
            sourceStatus.st_size >= 0
        else { throw TransferProtocolError.sourceChanged }

        let parent = url.deletingLastPathComponent()
        let parentDescriptor = Darwin.open(
            parent.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard parentDescriptor >= 0 else { throw TransferProtocolError.unsupportedSource }
        defer { Darwin.close(parentDescriptor) }
        let directoryName = ".macchannel-source-\(UUID().uuidString.lowercased())"
        guard mkdirat(parentDescriptor, directoryName, S_IRWXU) == 0 else {
            throw TransferProtocolError.unsupportedSource
        }
        defer { _ = unlinkat(parentDescriptor, directoryName, AT_REMOVEDIR) }
        let directoryDescriptor = Darwin.openat(
            parentDescriptor,
            directoryName,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directoryDescriptor >= 0 else {
            throw TransferProtocolError.unsupportedSource
        }
        defer { Darwin.close(directoryDescriptor) }
        let cloneName = "snapshot"
        guard fclonefileat(sourceDescriptor, directoryDescriptor, cloneName, 0) == 0 else {
            throw TransferProtocolError.unsupportedSource
        }
        defer { _ = unlinkat(directoryDescriptor, cloneName, 0) }
        let cloneDescriptor = Darwin.openat(
            directoryDescriptor,
            cloneName,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard cloneDescriptor >= 0 else { throw TransferProtocolError.unsupportedSource }
        var cloneStatus = stat()
        guard fstat(cloneDescriptor, &cloneStatus) == 0,
            cloneStatus.st_mode & S_IFMT == S_IFREG,
            cloneStatus.st_nlink == 1,
            cloneStatus.st_size >= 0
        else {
            Darwin.close(cloneDescriptor)
            throw TransferProtocolError.unsupportedSource
        }
        return PinnedSource(descriptor: cloneDescriptor, size: UInt64(cloneStatus.st_size))
    }

    /// Opens an immutable file in a private outgoing package. Unlike arbitrary
    /// user-selected input, this file is already an APFS clone protected by an
    /// owner-only package and has no write bits, so pinning its descriptor does
    /// not require another temporary clone.
    static func openImmutablePackageFile(from url: URL) throws -> PinnedSource {
        var before = stat()
        guard lstat(url.path, &before) == 0,
            before.st_mode & S_IFMT == S_IFREG,
            before.st_uid == geteuid(),
            before.st_nlink == 1,
            before.st_mode & (S_IWUSR | S_IWGRP | S_IWOTH) == 0,
            before.st_size >= 0
        else { throw TransferProtocolError.sourceChanged }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw TransferProtocolError.sourceChanged }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
            after.st_mode & S_IFMT == S_IFREG,
            after.st_dev == before.st_dev,
            after.st_ino == before.st_ino,
            after.st_uid == before.st_uid,
            after.st_nlink == 1,
            after.st_size == before.st_size,
            after.st_mode & (S_IWUSR | S_IWGRP | S_IWOTH) == 0
        else {
            Darwin.close(descriptor)
            throw TransferProtocolError.sourceChanged
        }
        return PinnedSource(descriptor: descriptor, size: UInt64(after.st_size))
    }

    func clonePersistently(to destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        let parentDescriptor = Darwin.open(
            parent.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard parentDescriptor >= 0 else { throw TransferProtocolError.unsupportedSource }
        defer { Darwin.close(parentDescriptor) }
        let name = destination.lastPathComponent
        guard !name.isEmpty, !name.contains("/") else {
            throw TransferProtocolError.invalidRelativePath
        }
        guard fclonefileat(descriptor, parentDescriptor, name, 0) == 0 else {
            throw TransferProtocolError.unsupportedSource
        }
        var status = stat()
        guard fstatat(parentDescriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0,
            status.st_mode & S_IFMT == S_IFREG,
            status.st_uid == geteuid(),
            status.st_nlink == 1,
            status.st_size >= 0,
            UInt64(status.st_size) == size,
            fchmodat(parentDescriptor, name, S_IRUSR, 0) == 0
        else {
            _ = unlinkat(parentDescriptor, name, 0)
            throw TransferProtocolError.sourceChanged
        }
    }

    func read(offset: UInt64, length: Int) throws -> Data {
        guard length >= 0, offset <= size, UInt64(length) <= size - offset else {
            throw TransferProtocolError.sourceChanged
        }
        var output = Data(count: length)
        var total = 0
        while total < length {
            let count = output.withUnsafeMutableBytes { bytes in
                pread(
                    descriptor,
                    bytes.baseAddress!.advanced(by: total),
                    length - total,
                    off_t(offset) + off_t(total)
                )
            }
            guard count > 0 else { throw TransferProtocolError.sourceChanged }
            total += count
        }
        return output
    }

    func digest() throws -> Data {
        var hasher = SHA256()
        var offset: UInt64 = 0
        while offset < size {
            let length = Int(
                min(
                    UInt64(TransferProtocolLimits.maximumChunkBytes),
                    size - offset
                ))
            hasher.update(data: try read(offset: offset, length: length))
            offset += UInt64(length)
        }
        return Data(hasher.finalize())
    }
}

public struct TransferManifest: Sendable {
    public let id: TransferID
    public let entries: [TransferManifestEntry]

    func validateProtocolLimits() throws {
        guard !entries.isEmpty,
            entries.count <= TransferProtocolLimits.maximumManifestEntries
        else { throw TransferProtocolError.manifestTooLarge }
        var aggregateBytes: UInt64 = 0
        var aggregateChunks: UInt64 = 0
        var offerBytes = 22
        for entry in entries {
            let pathBytes = entry.relativePath.string.utf8.count
            guard pathBytes <= 4_096,
                offerBytes <= TransferProtocolLimits.maximumFramePlaintextBytes - 55 - pathBytes
            else { throw TransferProtocolError.manifestTooLarge }
            offerBytes += 55 + pathBytes
            guard entry.size <= TransferProtocolLimits.maximumTransferBytes - aggregateBytes,
                UInt64(entry.chunkCount)
                    <= UInt64(TransferProtocolLimits.maximumTransferChunks) - aggregateChunks
            else { throw TransferProtocolError.manifestTooLarge }
            aggregateBytes += entry.size
            aggregateChunks += UInt64(entry.chunkCount)
        }
    }

    func validateDestinationPaths(onVolumeContaining destination: URL) throws {
        let caseSensitive = try destinationVolumeSupportsCaseSensitiveNames(destination)
        var seen: Set<String> = []
        for entry in entries {
            let key = destinationFilesystemKey(
                entry.relativePath.components,
                caseSensitive: caseSensitive
            )
            guard seen.insert(key).inserted else {
                throw TransferProtocolError.destinationPathCollision
            }
        }
    }

    public static func build(from sourceURL: URL) throws -> TransferManifest {
        try build(
            from: sourceURL,
            transferID: TransferID(rawValue: UUID()),
            immutablePackageSource: false
        )
    }

    static func build(
        from sourceURL: URL,
        transferID: TransferID,
        immutablePackageSource: Bool
    ) throws -> TransferManifest {
        let source = sourceURL.standardizedFileURL
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .fileSizeKey, .contentModificationDateKey,
        ]
        let rootValues = try source.resourceValues(forKeys: keys)
        guard rootValues.isSymbolicLink != true else { throw TransferProtocolError.symlinkEscape }

        if rootValues.isDirectory != true, rootValues.isRegularFile != true {
            throw TransferProtocolError.unsupportedSource
        }
        var urls = [source]
        if rootValues.isDirectory == true {
            var enumerationError: Error?
            guard
                let enumerator = FileManager.default.enumerator(
                    at: source,
                    includingPropertiesForKeys: Array(keys),
                    options: [],
                    errorHandler: { _, error in
                        enumerationError = error
                        return false
                    }
                )
            else { throw TransferProtocolError.unsupportedSource }
            while let item = enumerator.nextObject() {
                guard let url = item as? URL else {
                    throw TransferProtocolError.unsupportedSource
                }
                urls.append(url.standardizedFileURL)
                guard urls.count <= TransferProtocolLimits.maximumManifestEntries else {
                    throw TransferProtocolError.manifestTooLarge
                }
                let values = try url.resourceValues(forKeys: keys)
                guard values.isSymbolicLink != true else {
                    enumerator.skipDescendants()
                    throw TransferProtocolError.symlinkEscape
                }
                guard values.isDirectory == true || values.isRegularFile == true else {
                    enumerator.skipDescendants()
                    throw TransferProtocolError.unsupportedSource
                }
            }
            if enumerationError != nil { throw TransferProtocolError.unsupportedSource }
        }

        let parent = source.deletingLastPathComponent()
        var preflightBytes: UInt64 = 0
        var preflightChunks: UInt64 = 0
        var preflightOfferBytes = 22
        for url in urls {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { throw TransferProtocolError.symlinkEscape }
            if values.isRegularFile == true {
                guard let fileSize = values.fileSize, fileSize >= 0 else {
                    throw TransferProtocolError.unsupportedSource
                }
                let size = UInt64(fileSize)
                let chunks = UInt64(try chunkCount(for: size))
                guard size <= TransferProtocolLimits.maximumTransferBytes - preflightBytes,
                    chunks <= UInt64(TransferProtocolLimits.maximumTransferChunks) - preflightChunks
                else { throw TransferProtocolError.manifestTooLarge }
                preflightBytes += size
                preflightChunks += chunks
            }
            let parentPath = parent.path.hasSuffix("/") ? parent.path : parent.path + "/"
            guard url.path.hasPrefix(parentPath) else {
                throw TransferProtocolError.symlinkEscape
            }
            let relativeBytes = String(url.path.dropFirst(parentPath.count))
                .precomposedStringWithCanonicalMapping.utf8.count
            guard relativeBytes <= 4_096,
                preflightOfferBytes
                    <= TransferProtocolLimits.maximumFramePlaintextBytes - 55 - relativeBytes
            else { throw TransferProtocolError.manifestTooLarge }
            preflightOfferBytes += 55 + relativeBytes
        }

        var entries: [TransferManifestEntry] = []
        var seenPaths: Set<RelativePath> = []
        for url in urls {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { throw TransferProtocolError.symlinkEscape }
            let kind: TransferEntryKind
            if values.isDirectory == true {
                kind = .directory
            } else if values.isRegularFile == true {
                kind = .file
            } else {
                throw TransferProtocolError.unsupportedSource
            }
            let parentPath = parent.path.hasSuffix("/") ? parent.path : parent.path + "/"
            guard url.path.hasPrefix(parentPath) else { throw TransferProtocolError.symlinkEscape }
            let relativeString = String(url.path.dropFirst(parentPath.count))
                .precomposedStringWithCanonicalMapping
            let size: UInt64
            let pinnedSource: PinnedSource?
            if kind == .file {
                let pinned = try immutablePackageSource
                    ? PinnedSource.openImmutablePackageFile(from: url)
                    : PinnedSource.clone(from: url)
                size = pinned.size
                pinnedSource = pinned
            } else {
                size = 0
                pinnedSource = nil
            }
            let relativePath = try RelativePath(relativeString)
            guard seenPaths.insert(relativePath).inserted else {
                throw TransferProtocolError.invalidRelativePath
            }
            entries.append(
                TransferManifestEntry(
                    relativePath: relativePath,
                    kind: kind,
                    size: size,
                    modificationDate: values.contentModificationDate ?? .distantPast,
                    chunkCount: kind == .file ? try chunkCount(for: size) : 0,
                    digest: kind == .file
                        ? try pinnedSource!.digest() : Data(SHA256.hash(data: Data())),
                    pinnedSource: pinnedSource
                ))
        }
        entries.sort { lhs, rhs in
            if lhs.relativePath.components.count != rhs.relativePath.components.count {
                return lhs.relativePath.components.count < rhs.relativePath.components.count
            }
            return lhs.relativePath.string < rhs.relativePath.string
        }
        let manifest = TransferManifest(id: transferID, entries: entries)
        try manifest.validateProtocolLimits()
        return manifest
    }

    private static func chunkCount(for size: UInt64) throws -> UInt32 {
        guard size > 0 else { return 0 }
        let chunkSize = UInt64(TransferProtocolLimits.maximumChunkBytes)
        let count = size / chunkSize + (size.isMultiple(of: chunkSize) ? 0 : 1)
        guard count <= UInt64(UInt32.max) else { throw TransferProtocolError.unsupportedSource }
        return UInt32(count)
    }

}

func destinationVolumeSupportsCaseSensitiveNames(_ destination: URL) throws -> Bool {
    var volumeURL = destination.standardizedFileURL
    while !FileManager.default.fileExists(atPath: volumeURL.path) {
        let parent = volumeURL.deletingLastPathComponent()
        guard parent.path != volumeURL.path else {
            throw TransferProtocolError.destinationEscape
        }
        volumeURL = parent
    }
    let values = try volumeURL.resourceValues(forKeys: [
        .volumeSupportsCaseSensitiveNamesKey
    ])
    guard let caseSensitive = values.volumeSupportsCaseSensitiveNames else {
        throw TransferProtocolError.destinationEscape
    }
    return caseSensitive
}

func destinationFilesystemKey(_ components: [String], caseSensitive: Bool) -> String {
    let locale = Locale(identifier: "en_US_POSIX")
    return components.map { component in
        let normalized = component.decomposedStringWithCanonicalMapping
        return caseSensitive
            ? normalized
            : normalized.folding(options: [.caseInsensitive], locale: locale)
    }.joined(separator: "/")
}
