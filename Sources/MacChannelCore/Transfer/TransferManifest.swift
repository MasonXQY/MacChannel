import CryptoKit
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
    case cancelled
    case channelEnded
}

public enum TransferProtocolLimits {
    public static let maximumWireFrameBytes = 64 * 1024
    public static let maximumUnacknowledgedChunks = 64
    public static let acknowledgementChunkInterval = 16

    // A chunk frame uses 22 bytes of versioned metadata. The authenticated
    // envelope uses 62 bytes (magic, version, direction, transfer ID,
    // sequence, reconnect nonce epoch, and tag). File bytes are therefore within the
    // SecureChannel's inclusive 64 KiB cap.
    public static let maximumChunkBytes = maximumWireFrameBytes - 84
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
            raw.allSatisfy({ $0.precomposedStringWithCanonicalMapping == $0 })
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
    let sourceURL: URL?

}

public struct TransferManifest: Sendable {
    public let id: TransferID
    public let entries: [TransferManifestEntry]

    public static func build(from sourceURL: URL) throws -> TransferManifest {
        let source = sourceURL.standardizedFileURL
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .fileSizeKey, .contentModificationDateKey,
        ]
        let rootValues = try source.resourceValues(forKeys: keys)
        guard rootValues.isSymbolicLink != true else { throw TransferProtocolError.symlinkEscape }

        var urls: [URL] = []
        var pending = [source]
        var pendingIndex = 0
        while pendingIndex < pending.count {
            let url = pending[pendingIndex]
            pendingIndex += 1
            urls.append(url)
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { throw TransferProtocolError.symlinkEscape }
            if values.isDirectory == true {
                let children = try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: Array(keys),
                    options: []
                ).map(\.standardizedFileURL).sorted { $0.path < $1.path }
                pending.append(contentsOf: children)
            } else if values.isRegularFile != true {
                throw TransferProtocolError.unsupportedSource
            }
        }
        if rootValues.isDirectory != true, rootValues.isRegularFile != true {
            throw TransferProtocolError.unsupportedSource
        }

        let parent = source.deletingLastPathComponent()
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
            if kind == .file {
                guard let fileSize = values.fileSize, fileSize >= 0 else {
                    throw TransferProtocolError.unsupportedSource
                }
                size = UInt64(fileSize)
            } else {
                size = 0
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
                        ? try digestFile(at: url) : Data(SHA256.hash(data: Data())),
                    sourceURL: url
                ))
        }
        entries.sort { lhs, rhs in
            if lhs.relativePath.components.count != rhs.relativePath.components.count {
                return lhs.relativePath.components.count < rhs.relativePath.components.count
            }
            return lhs.relativePath.string < rhs.relativePath.string
        }
        return TransferManifest(id: TransferID(rawValue: UUID()), entries: entries)
    }

    private static func chunkCount(for size: UInt64) throws -> UInt32 {
        guard size > 0 else { return 0 }
        let chunkSize = UInt64(TransferProtocolLimits.maximumChunkBytes)
        let count = size / chunkSize + (size.isMultiple(of: chunkSize) ? 0 : 1)
        guard count <= UInt64(UInt32.max) else { throw TransferProtocolError.unsupportedSource }
        return UInt32(count)
    }

    private static func digestFile(at url: URL) throws -> Data {
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
}
