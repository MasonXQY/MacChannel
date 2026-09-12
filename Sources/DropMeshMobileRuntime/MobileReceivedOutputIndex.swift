import Darwin
import Foundation
import MacChannelCore

public enum MobileHistoryAvailabilityFailure: Error, Equatable, Sendable {
    case receivedOutputIndexUnavailable
}

/// Private association store. Registration is confined to the receive owner;
/// callers must resolve again at action time, since URLs are not capabilities.
public actor MobileReceivedOutputIndex {
    private enum Kind: String, Codable { case regularFile, directory }
    private struct Identity: Codable, Equatable {
        let device: UInt64
        let inode: UInt64
        let kind: Kind
    }
    private struct Entry: Codable {
        let transferID: UUID
        let leafName: String
        let device: UInt64
        let inode: UInt64
        let kind: Kind
        let recordedAt: Date
        var identity: Identity { Identity(device: device, inode: inode, kind: kind) }
    }
    private struct Envelope: Codable { let version: Int; let entries: [Entry] }
    private let database: TransferDatabase
    private let receiveDirectory: URL
    private let indexURL: URL
    private let maximum: Int
    private var rootIdentity: Identity?
    private var parentIdentity: Identity?
    private var fileIdentity: Identity?
    private var entries: [UUID: Entry] = [:]
    public private(set) var availabilityFailure: MobileHistoryAvailabilityFailure?
    nonisolated let initialAvailabilityFailure: MobileHistoryAvailabilityFailure?
    private static let byteLimit = 1_048_576
    private static let unavailable = MobileHistoryAvailabilityFailure.receivedOutputIndexUnavailable

    /// Failure is isolated from database history and network startup. Invalid
    /// stores remain untouched and unavailable for this owner's lifetime.
    public init(url: URL, receiveDirectory: URL, database: TransferDatabase, maximumEntryCount: Int = 1_000) {
        self.database = database
        self.receiveDirectory = receiveDirectory.standardizedFileURL
        indexURL = url.standardizedFileURL
        maximum = min(1_000, max(1, maximumEntryCount))
        do {
            guard url.isFileURL, receiveDirectory.isFileURL, Self.validLeaf(url.lastPathComponent) else { throw Self.unavailable }
            let root = try Self.openDirectory(self.receiveDirectory)
            defer { close(root) }
            rootIdentity = try Self.identity(root)
            let parent = try Self.openDirectory(indexURL.deletingLastPathComponent(), privateDirectory: true)
            defer { close(parent) }
            parentIdentity = try Self.identity(parent)
            let leaf = indexURL.lastPathComponent
            let existing = try Self.status(parent, leaf: leaf, allowMissing: true)
            if let existing {
                try Self.validatePrivateFile(existing)
                let fd = openat(parent, leaf, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
                guard fd >= 0 else { throw Self.unavailable }
                defer { close(fd) }
                let opened = try Self.fileStatus(fd)
                guard try Self.identity(opened) == Self.identity(existing) else { throw Self.unavailable }
                try Self.validatePrivateFile(opened)
                guard opened.st_size >= 0, opened.st_size <= Self.byteLimit else { throw Self.unavailable }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = read(fd, &buffer, buffer.count)
                    if count < 0, errno == EINTR { continue }
                    guard count >= 0, data.count + count <= Self.byteLimit else { throw Self.unavailable }
                    if count == 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
                let envelope = try JSONDecoder().decode(Envelope.self, from: data)
                guard envelope.version == 1, envelope.entries.count <= maximum else { throw Self.unavailable }
                var decoded: [UUID: Entry] = [:]
                for entry in envelope.entries {
                    guard Self.validLeaf(entry.leafName), entry.device <= UInt64(UInt32.max), entry.inode > 0,
                          entry.recordedAt.timeIntervalSince1970.isFinite,
                          decoded[entry.transferID] == nil else { throw Self.unavailable }
                    decoded[entry.transferID] = entry
                }
                entries = decoded
                fileIdentity = try Self.identity(opened)
            }
        } catch { availabilityFailure = Self.unavailable }
        initialAvailabilityFailure = availabilityFailure
    }

    public func availableURL(for transferID: TransferID) async -> URL? {
        guard availabilityFailure == nil, let entry = entries[transferID.rawValue] else { return nil }
        let row: TransferHistoryRecord
        do { guard let persisted = try await database.persistedTransfer(id: transferID) else { return nil }; row = persisted }
        catch { return nil }
        guard Self.completedInbound(row) else { return nil }
        do {
            let parent = try checkedParent(); defer { close(parent) }
            try checkIndex(parent)
            let root = try checkedRoot(); defer { close(root) }
            guard let status = try Self.status(root, leaf: entry.leafName, allowMissing: true) else { return nil }
            // A missing, moved, replaced, or type-changed user file is a
            // per-item availability result, not corruption of the index.
            guard (try? Self.identity(status)) == entry.identity else { return nil }
            return receiveDirectory.appendingPathComponent(entry.leafName, isDirectory: entry.kind == .directory)
        } catch { markUnavailable(); return nil }
    }

    func recordCompletedReceive(_ result: TransferReceiveResult) async throws {
        guard availabilityFailure == nil else { throw Self.unavailable }
        guard result.receivedURLs.count == 1, let url = result.receivedURLs.first,
              url.isFileURL, url.standardizedFileURL.deletingLastPathComponent() == receiveDirectory,
              url.pathComponents == receiveDirectory.pathComponents + [url.lastPathComponent],
              Self.validLeaf(url.lastPathComponent),
              let row = try await database.persistedTransfer(id: result.transferID),
              Self.completedInbound(row), result.source == row.peer else { throw Self.unavailable }
        guard availabilityFailure == nil else { throw Self.unavailable }
        let root: Int32
        do { root = try checkedRoot() }
        catch { markUnavailable(); throw Self.unavailable }
        defer { close(root) }
        let status: stat?
        do { status = try Self.status(root, leaf: url.lastPathComponent, allowMissing: true) }
        catch { markUnavailable(); throw Self.unavailable }
        guard let status else { throw Self.unavailable }
        let identity = try Self.identity(status)
        if let existing = entries[result.transferID.rawValue] {
            // A duplicate callback cannot repin a replacement to a completed ID.
            guard existing.leafName == url.lastPathComponent, existing.identity == identity else { throw Self.unavailable }
            do {
                let parent = try checkedParent(); defer { close(parent) }
                try checkIndex(parent)
            } catch { markUnavailable(); throw Self.unavailable }
            return
        }
        var updated = entries
        updated[result.transferID.rawValue] = Entry(transferID: result.transferID.rawValue,
            leafName: url.lastPathComponent, device: identity.device, inode: identity.inode,
            kind: identity.kind, recordedAt: Date())
        let retained = updated.values.sorted {
            $0.recordedAt == $1.recordedAt ? $0.transferID.uuidString < $1.transferID.uuidString : $0.recordedAt > $1.recordedAt
        }.prefix(maximum)
        do {
            try persist(Array(retained))
            entries = Dictionary(uniqueKeysWithValues: retained.map { ($0.transferID, $0) })
        } catch {
            markUnavailable()
            entries = [:]
            throw Self.unavailable
        }
    }

    private func markUnavailable() { availabilityFailure = Self.unavailable }

    private static func completedInbound(_ row: TransferHistoryRecord) -> Bool {
        row.direction == .inbound && row.phase == .completed && row.completedBytes == row.aggregateSize
    }

    private func persist(_ entries: [Entry]) throws {
        let data = try JSONEncoder().encode(Envelope(version: 1, entries: entries))
        guard data.count <= Self.byteLimit else { throw Self.unavailable }
        let parent = try checkedParent(); defer { close(parent) }
        try checkIndex(parent)
        let temporary = ".received-output-\(UUID().uuidString).tmp"
        let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.unavailable }
        defer { close(fd); unlinkat(parent, temporary, 0) }
        guard fchmod(fd, 0o600) == 0 else { throw Self.unavailable }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Self.unavailable }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw Self.unavailable }
        try checkIndex(parent)
        // Revalidate named parent immediately before publication. All mutations
        // are descriptor relative; a changed ancestor never redirects writes.
        let currentParent = try checkedParent(); close(currentParent)
        guard renameat(parent, temporary, parent, indexURL.lastPathComponent) == 0,
              fsync(parent) == 0 else { throw Self.unavailable }
        fileIdentity = try Self.identity(fd)
    }

    private func checkedRoot() throws -> Int32 {
        let fd = try Self.openDirectory(receiveDirectory)
        do { guard try Self.identity(fd) == rootIdentity else { throw Self.unavailable }; return fd }
        catch { close(fd); throw Self.unavailable }
    }
    private func checkedParent() throws -> Int32 {
        let fd = try Self.openDirectory(indexURL.deletingLastPathComponent(), privateDirectory: true)
        do { guard try Self.identity(fd) == parentIdentity else { throw Self.unavailable }; return fd }
        catch { close(fd); throw Self.unavailable }
    }
    private func checkIndex(_ parent: Int32) throws {
        let status = try Self.status(parent, leaf: indexURL.lastPathComponent, allowMissing: true)
        if let status {
            try Self.validatePrivateFile(status)
            guard try Self.identity(status) == fileIdentity else { throw Self.unavailable }
        } else if fileIdentity != nil { throw Self.unavailable }
    }
    private static func validLeaf(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != "..", value.utf8.count <= 255,
              !value.contains("/"), !value.contains("\0") else { return false }
        if let decoded = value.removingPercentEncoding, decoded.contains("/") || decoded.contains("\0") || decoded == "." || decoded == ".." { return false }
        return URL(fileURLWithPath: "/").appendingPathComponent(value).lastPathComponent == value
    }
    private static func openDirectory(_ url: URL, privateDirectory: Bool = false) throws -> Int32 {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw unavailable }
        do {
            let status = try fileStatus(fd)
            guard status.st_mode & S_IFMT == S_IFDIR, status.st_uid == geteuid(),
                  !privateDirectory || status.st_mode & 0o777 == 0o700 else { throw unavailable }
            return fd
        } catch { close(fd); throw unavailable }
    }
    private static func fileStatus(_ fd: Int32) throws -> stat {
        var value = stat(); guard fstat(fd, &value) == 0 else { throw unavailable }; return value
    }
    private static func status(_ fd: Int32, leaf: String, allowMissing: Bool = false) throws -> stat? {
        var value = stat()
        if fstatat(fd, leaf, &value, AT_SYMLINK_NOFOLLOW) == 0 { return value }
        if allowMissing, errno == ENOENT { return nil }
        throw unavailable
    }
    private static func identity(_ fd: Int32) throws -> Identity { try identity(fileStatus(fd)) }
    private static func identity(_ status: stat) throws -> Identity {
        let kind: Kind
        switch status.st_mode & S_IFMT {
        case S_IFREG: kind = .regularFile
        case S_IFDIR: kind = .directory
        default: throw unavailable
        }
        return Identity(device: UInt64(UInt32(bitPattern: status.st_dev)), inode: UInt64(status.st_ino), kind: kind)
    }
    private static func validatePrivateFile(_ status: stat) throws {
        guard status.st_mode & S_IFMT == S_IFREG, status.st_uid == geteuid(), status.st_nlink == 1,
              status.st_mode & 0o777 == 0o600 else { throw unavailable }
    }
}
