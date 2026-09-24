import Darwin
import Foundation

// Pure payload copy owner; safe to compile without Core or identity dependencies.
final class MobileImportCopy: @unchecked Sendable {
    // Leases survive a stager's deinit: a returned URL can still have borrowers.
    // Only exact successful discard retires a lease; process death clears them.
    private static let leases = MobileImportLeases()
    private let lock = NSLock()
    private let directory: URL
    private let rootDescriptor: Int32
    private let rootOpenError: Int32
    private let didCopyFirstChunk: (@Sendable () -> Void)?
    private let didFinalize: (@Sendable () -> Void)?

    init(directory: URL, didCopyFirstChunk: (@Sendable () -> Void)? = nil,
         didFinalize: (@Sendable () -> Void)? = nil) {
        self.directory = directory.standardizedFileURL
        rootDescriptor = open(self.directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        rootOpenError = rootDescriptor < 0 ? errno : 0
        self.didCopyFirstChunk = didCopyFirstChunk
        self.didFinalize = didFinalize
    }

    deinit {
        if rootDescriptor >= 0 { close(rootDescriptor) }
    }

    func stage(file source: URL, cancellation: MobileImportCancellation, maximumBytes: Int64? = nil) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        try cancellation.check()
        guard source.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }

        try requireRootDescriptor()
        let sourceDescriptor = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard sourceDescriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(sourceDescriptor) }

        var sourceInfo = stat()
        guard fstat(sourceDescriptor, &sourceInfo) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard (sourceInfo.st_mode & S_IFMT) == S_IFREG else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        if let maximumBytes {
            guard maximumBytes >= 0, sourceInfo.st_size >= 0, sourceInfo.st_size <= maximumBytes
            else { throw POSIXError(.EFBIG) }
        }

        try cancellation.check()
        let importName = UUID().uuidString
        try Self.leases.withLock {
            guard mkdirat(rootDescriptor, importName, 0o700) == 0 else { throw currentPOSIXError() }
            Self.leases.names.insert(try leaseKey(importName))
        }
        let importDirectory = directory.appendingPathComponent(importName, isDirectory: true)
        let importDescriptor = openat(rootDescriptor, importName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard importDescriptor >= 0 else {
            let error = currentPOSIXError()
            if unlinkat(rootDescriptor, importName, AT_REMOVEDIR) == 0 { retireLease(importName) }
            throw error
        }
        defer { close(importDescriptor) }
        let destinationName = source.lastPathComponent
        let partialName = ".\(UUID().uuidString).partial"
        do {
            guard fchmod(importDescriptor, 0o700) == 0 else { throw currentPOSIXError() }
            try copy(sourceDescriptor: sourceDescriptor, to: partialName, in: importDescriptor,
                     cancellation: cancellation, maximumBytes: maximumBytes)
            try cancellation.check()
            guard renameat(importDescriptor, partialName, importDescriptor, destinationName) == 0 else {
                throw currentPOSIXError()
            }
            // Publication wins later cancellation; caller owns the returned URL.
            didFinalize?()
            return importDirectory.appendingPathComponent(destinationName, isDirectory: false)
        } catch {
            _ = unlinkat(importDescriptor, partialName, 0)
            _ = unlinkat(importDescriptor, destinationName, 0)
            if unlinkat(rootDescriptor, importName, AT_REMOVEDIR) == 0 { retireLease(importName) }
            throw error
        }
    }

    public func discard(_ stagedFile: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard stagedFile.isFileURL else { throw CocoaError(.fileNoSuchFile) }
        let candidate = stagedFile.standardizedFileURL
        let importDirectory = candidate.deletingLastPathComponent()
        guard UUID(uuidString: importDirectory.lastPathComponent) != nil,
              importDirectory.deletingLastPathComponent().standardizedFileURL == directory,
              candidate.lastPathComponent != ".",
              candidate.lastPathComponent != ".."
        else {
            throw CocoaError(.fileNoSuchFile)
        }
        try requireRootDescriptor()
        let importName = importDirectory.lastPathComponent
        let importDescriptor = openat(rootDescriptor, importName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard importDescriptor >= 0 else { throw CocoaError(.fileNoSuchFile) }
        defer { close(importDescriptor) }

        let children = try directoryEntryNames(descriptor: importDescriptor)
        guard children == [candidate.lastPathComponent] else {
            throw CocoaError(.fileNoSuchFile)
        }
        let fileDescriptor = openat(
            importDescriptor,
            candidate.lastPathComponent,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard fileDescriptor >= 0 else { throw CocoaError(.fileNoSuchFile) }
        defer { close(fileDescriptor) }
        var fileInfo = stat()
        guard fstat(fileDescriptor, &fileInfo) == 0, (fileInfo.st_mode & S_IFMT) == S_IFREG else {
            throw CocoaError(.fileNoSuchFile)
        }

        guard unlinkat(importDescriptor, candidate.lastPathComponent, 0) == 0 else { throw currentPOSIXError() }
        guard unlinkat(rootDescriptor, importName, AT_REMOVEDIR) == 0 else { throw currentPOSIXError() }
        retireLease(importName)
    }

    /// Invoked by main-app composition before import admission. The private root
    /// descriptor and process leases prevent another service from reclaiming live work.
    func recoverAbandonedImports() throws {
        lock.lock(); defer { lock.unlock() }
        try requireRootDescriptor()
        try Self.leases.withLock {
            for name in try directoryEntryNames(descriptor: rootDescriptor) {
                guard UUID(uuidString: name)?.uuidString == name else { throw POSIXError(.EINVAL) }
                if Self.leases.names.contains(try leaseKey(name)) { continue }
                let child = openat(rootDescriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw currentPOSIXError() }
                defer { close(child) }
                var info = stat()
                guard fstat(child, &info) == 0, info.st_uid == getuid() else { throw POSIXError(.EPERM) }
                let files = try directoryEntryNames(descriptor: child)
                guard files.count <= 1 else { throw POSIXError(.EINVAL) }
                for file in files {
                    let descriptor = openat(child, file, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                    guard descriptor >= 0 else { throw currentPOSIXError() }
                    defer { close(descriptor) }
                    var payload = stat()
                    guard fstat(descriptor, &payload) == 0,
                          payload.st_mode & S_IFMT == S_IFREG, payload.st_nlink == 1,
                          payload.st_uid == getuid() else { throw POSIXError(.EINVAL) }
                    try requireSameEntry(parent: child, name: file, expected: payload)
                    guard unlinkat(child, file, 0) == 0 else { throw currentPOSIXError() }
                }
                try requireSameEntry(parent: rootDescriptor, name: name, expected: info)
                guard unlinkat(rootDescriptor, name, AT_REMOVEDIR) == 0 else { throw currentPOSIXError() }
            }
        }
    }

    private func leaseKey(_ name: String) throws -> String {
        var info = stat()
        guard fstat(rootDescriptor, &info) == 0 else { throw currentPOSIXError() }
        return "\(info.st_dev):\(info.st_ino):\(name)"
    }

    private func retireLease(_ name: String) {
        if let key = try? leaseKey(name) { Self.leases.withLock { _ = Self.leases.names.remove(key) } }
    }

    private func requireSameEntry(parent: Int32, name: String, expected: stat) throws {
        var current = stat()
        guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == expected.st_dev, current.st_ino == expected.st_ino,
              current.st_mode == expected.st_mode else { throw POSIXError(.ESTALE) }
    }

    private func copy(sourceDescriptor: Int32, to destinationName: String, in importDescriptor: Int32,
                      cancellation: MobileImportCancellation, maximumBytes: Int64?) throws {
        let destinationDescriptor = openat(
            importDescriptor,
            destinationName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard destinationDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(destinationDescriptor) }

        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var copiedFirstChunk = false
        var remaining = maximumBytes
        while true {
            try cancellation.check()
            let count = read(sourceDescriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            // Enforce on the opened source, before any excess byte is written.
            // A final read at the exact boundary distinguishes EOF from growth.
            if let allowance = remaining {
                guard Int64(count) <= allowance else { throw POSIXError(.EFBIG) }
                remaining = allowance - Int64(count)
            }
            var written = 0
            while written < count {
                let result = buffer.withUnsafeBytes { bytes in
                    write(destinationDescriptor, bytes.baseAddress!.advanced(by: written), count - written)
                }
                guard result > 0 else {
                    if result < 0, errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                written += result
            }
            if !copiedFirstChunk {
                copiedFirstChunk = true
                didCopyFirstChunk?()
            }
            try cancellation.check()
        }
        guard fchmod(destinationDescriptor, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func requireRootDescriptor() throws {
        guard rootDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: rootOpenError) ?? .EIO)
        }
    }

    private func directoryEntryNames(descriptor: Int32) throws -> [String] {
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else { throw currentPOSIXError() }
        guard let stream = fdopendir(duplicate) else {
            close(duplicate)
            throw currentPOSIXError()
        }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." { names.append(name) }
            errno = 0
        }
        guard errno == 0 else { throw currentPOSIXError() }
        return names
    }

    private func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

private final class MobileImportLeases: @unchecked Sendable {
    private let lock = NSLock()
    var names: Set<String> = []
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}
