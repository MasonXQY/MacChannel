import Darwin
import Foundation

public actor MobileImportStager {
    private let directory: URL
    private let canonicalDirectory: URL

    public init(directory: URL) {
        self.directory = directory.standardizedFileURL
        canonicalDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
    }

    public func stage(file source: URL) async throws -> URL {
        guard source.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }

        let sourceDescriptor = open(source.path, O_RDONLY | O_NOFOLLOW)
        guard sourceDescriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(sourceDescriptor) }

        var sourceInfo = stat()
        guard fstat(sourceDescriptor, &sourceInfo) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard (sourceInfo.st_mode & S_IFMT) == S_IFREG else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }

        let importDirectory = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: importDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: importDirectory.path)
            let destination = importDirectory.appendingPathComponent(source.lastPathComponent, isDirectory: false)
            let partial = importDirectory.appendingPathComponent(".\(UUID().uuidString).partial", isDirectory: false)
            try copy(sourceDescriptor: sourceDescriptor, to: partial)
            guard rename(partial.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: importDirectory)
            throw error
        }
    }

    public func discard(_ stagedFile: URL) throws {
        guard stagedFile.isFileURL else { throw CocoaError(.fileNoSuchFile) }
        let candidate = stagedFile.standardizedFileURL
        let importDirectory = candidate.deletingLastPathComponent()
        guard UUID(uuidString: importDirectory.lastPathComponent) != nil,
              importDirectory.deletingLastPathComponent().standardizedFileURL == directory,
              candidate.resolvingSymlinksInPath().deletingLastPathComponent() == canonicalDirectory
                .appendingPathComponent(importDirectory.lastPathComponent, isDirectory: true)
                .resolvingSymlinksInPath()
        else {
            throw CocoaError(.fileNoSuchFile)
        }

        let children = try FileManager.default.contentsOfDirectory(
            at: importDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        )
        guard children.count == 1, children[0].standardizedFileURL == candidate else {
            throw CocoaError(.fileNoSuchFile)
        }
        let values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileNoSuchFile)
        }

        guard unlink(candidate.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard rmdir(importDirectory.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func copy(sourceDescriptor: Int32, to destination: URL) throws {
        let destinationDescriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard destinationDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(destinationDescriptor) }

        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
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
        }
        guard fchmod(destinationDescriptor, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
