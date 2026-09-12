import Darwin
import Foundation

public actor MobileImportStager {
    private let directory: URL
    private let rootDescriptor: Int32
    private let rootOpenError: Int32
    private let didCopyFirstChunk: (@Sendable () -> Void)?

    public init(directory: URL) {
        self.directory = directory.standardizedFileURL
        rootDescriptor = open(self.directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        rootOpenError = rootDescriptor < 0 ? errno : 0
        didCopyFirstChunk = nil
    }

    init(directory: URL, didCopyFirstChunk: @escaping @Sendable () -> Void) {
        self.directory = directory.standardizedFileURL
        rootDescriptor = open(self.directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        rootOpenError = rootDescriptor < 0 ? errno : 0
        self.didCopyFirstChunk = didCopyFirstChunk
    }

    deinit {
        if rootDescriptor >= 0 { close(rootDescriptor) }
    }

    public func stage(file source: URL) async throws -> URL {
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

        try Task.checkCancellation()
        let importName = UUID().uuidString
        guard mkdirat(rootDescriptor, importName, 0o700) == 0 else { throw currentPOSIXError() }
        let importDirectory = directory.appendingPathComponent(importName, isDirectory: true)
        let importDescriptor = openat(rootDescriptor, importName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard importDescriptor >= 0 else {
            _ = unlinkat(rootDescriptor, importName, AT_REMOVEDIR)
            throw currentPOSIXError()
        }
        defer { close(importDescriptor) }
        let destinationName = source.lastPathComponent
        let partialName = ".\(UUID().uuidString).partial"
        do {
            guard fchmod(importDescriptor, 0o700) == 0 else { throw currentPOSIXError() }
            try copy(sourceDescriptor: sourceDescriptor, to: partialName, in: importDescriptor)
            try Task.checkCancellation()
            guard renameat(importDescriptor, partialName, importDescriptor, destinationName) == 0 else {
                throw currentPOSIXError()
            }
            return importDirectory.appendingPathComponent(destinationName, isDirectory: false)
        } catch {
            _ = unlinkat(importDescriptor, partialName, 0)
            _ = unlinkat(importDescriptor, destinationName, 0)
            _ = unlinkat(rootDescriptor, importName, AT_REMOVEDIR)
            throw error
        }
    }

    public func discard(_ stagedFile: URL) throws {
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
    }

    private func copy(sourceDescriptor: Int32, to destinationName: String, in importDescriptor: Int32) throws {
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
        while true {
            try Task.checkCancellation()
            let count = read(sourceDescriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
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
            try Task.checkCancellation()
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
