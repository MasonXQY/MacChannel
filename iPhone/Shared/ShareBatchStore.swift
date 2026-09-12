import Darwin
import Foundation
import UniformTypeIdentifiers
#if !SHARE_EXTENSION
import DropMeshMobileRuntime
#endif

enum SharePayloadError: Error { case unavailable, unsupported, limit, malformed, busy, cleanup }

/// Payload only. No identity, recipient, authorization or absolute path is persisted.
struct ShareManifest: Codable, Sendable {
    struct Item: Codable, Sendable {
        let directory: String
        let name: String
        let contentType: String
        let size: Int64
    }
    let version: Int
    let id: UUID
    let created: Date
    let items: [Item]
}

actor ShareBatchStore {
    static let group = "group.com.zensystech.dropmesh.iphone.dev"
    static let maximumItems = 10
    static let maximumBatches = 20
    static let maximumFileBytes: Int64 = 2 * 1024 * 1024 * 1024
    static let maximumBatchBytes: Int64 = 4 * 1024 * 1024 * 1024
    static let retention: TimeInterval = 24 * 3600
    private let root: URL

    init(root: URL) { self.root = root.standardizedFileURL }

    static func applicationGroup() throws -> ShareBatchStore {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { throw SharePayloadError.unavailable }
        return ShareBatchStore(root: container.appendingPathComponent("SharePayload-v1", isDirectory: true))
    }

    private func openRoot() throws -> Int32 {
        let parent = try ShareFS.directory(root.deletingLastPathComponent().path)
        defer { close(parent) }
        if mkdirat(parent, root.lastPathComponent, 0o700) != 0, errno != EEXIST { throw ShareFS.error() }
        let fd = try ShareFS.directory(root.lastPathComponent, parent: parent)
        do {
            try ShareFS.protect(fd)
            var url = root
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            return fd
        } catch { close(fd); throw error }
    }

    func begin() throws -> ShareBatch {
        let fd = try openRoot(); defer { close(fd) }
        guard try ShareFS.names(fd).count < Self.maximumBatches else { throw SharePayloadError.limit }
        let id = UUID()
        guard mkdirat(fd, id.uuidString, 0o700) == 0 else { throw ShareFS.error() }
        return try ShareBatch(root: root, rootFD: fd, id: id, creating: true)
    }

    func pending() throws -> [UUID] {
        let fd = try openRoot(); defer { close(fd) }
        return try ShareFS.names(fd).prefix(Self.maximumBatches).compactMap { name in
            guard let id = UUID(uuidString: name), id.uuidString == name,
                  let batch = try? ShareBatch(root: root, rootFD: fd, id: id, creating: false)
            else { return nil }
            // A live writer/claimant is omitted, never consumed twice.
            return batch.hasReady ? id : nil
        }.sorted { $0.uuidString < $1.uuidString }
    }

    func claim(_ id: UUID) async throws -> ShareBatch? {
        let fd = try openRoot(); defer { close(fd) }
        let batch: ShareBatch
        do { batch = try ShareBatch(root: root, rootFD: fd, id: id, creating: false) }
        catch SharePayloadError.busy { return nil }
        guard batch.hasReady else { return nil }
        _ = try await batch.files() // fresh bounded manifest and every file validation
        return batch
    }

    /// At most 20 exact UUID batches per foreground/extension entry. Locks survive
    /// provider awaits; kernel release after process death makes old work reclaimable.
    func cleanup(now: Date = Date()) async throws {
        let fd = try openRoot(); defer { close(fd) }
        for name in try ShareFS.names(fd).prefix(Self.maximumBatches) {
            guard let id = UUID(uuidString: name), id.uuidString == name,
                  let batch = try? ShareBatch(root: root, rootFD: fd, id: id, creating: false)
            else { continue }
            if now.timeIntervalSince(batch.modified) > Self.retention {
                try await batch.discard()
            }
        }
    }
}

/// One cross-process exclusive flock owns a batch from creation through publish,
/// or from claim through private import and acknowledgement. Never a send receipt.
actor ShareBatch {
    nonisolated let id: UUID
    nonisolated let hasReady: Bool
    nonisolated let modified: Date
    private let rootFD: Int32
    private let directoryFD: Int32
    private let lockFD: Int32
    private let directory: URL
    private let stager: MobileImportStager
    private var items: [ShareManifest.Item] = []
    private var published: Bool
    private var released = false
    private var retired = false

    init(root: URL, rootFD: Int32, id: UUID, creating: Bool) throws {
        let fd = try ShareFS.directory(id.uuidString, parent: rootFD)
        let lock = openat(fd, ".lock", O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (creating ? O_CREAT | O_EXCL : 0), 0o600)
        guard lock >= 0 else { close(fd); throw ShareFS.error() }
        do {
            _ = try ShareFS.regular(lock)
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw SharePayloadError.busy }
            try ShareFS.protect(fd); try ShareFS.protect(lock)
        } catch { close(lock); close(fd); throw error }
        self.rootFD = dup(rootFD)
        guard self.rootFD >= 0 else { close(lock); close(fd); throw ShareFS.error() }
        self.id = id; directoryFD = fd; lockFD = lock
        directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        stager = MobileImportStager(directory: directory)
        var info = stat(); fstat(fd, &info)
        modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
        var ready = stat()
        hasReady = fstatat(fd, ".ready", &ready, AT_SYMLINK_NOFOLLOW) == 0 && (ready.st_mode & S_IFMT) == S_IFREG
        published = hasReady
    }
    deinit { close(lockFD); close(directoryFD); close(rootFD) }

    func append(_ source: URL, contentType: String) async throws {
        guard !released, !published, !retired else { throw SharePayloadError.busy }
        guard items.count < ShareBatchStore.maximumItems,
              let type = UTType(contentType), type.conforms(to: .data),
              !type.conforms(to: .directory) else { throw SharePayloadError.unsupported }
        let sourceFD = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard source.isFileURL, sourceFD >= 0 else { if sourceFD >= 0 { close(sourceFD) }; throw SharePayloadError.unsupported }
        let size: Int64
        do { size = try ShareFS.regular(sourceFD).st_size; close(sourceFD) }
        catch { close(sourceFD); throw error }
        guard size >= 0, size <= ShareBatchStore.maximumFileBytes,
              items.reduce(Int64(0), { $0 + $1.size }) + size <= ShareBatchStore.maximumBatchBytes
        else { throw SharePayloadError.limit }
        let copied = try await stager.stage(file: source)
        do {
            let item = ShareManifest.Item(directory: copied.deletingLastPathComponent().lastPathComponent,
                name: copied.lastPathComponent, contentType: contentType, size: size)
            _ = try validate(item)
            let child = try ShareFS.directory(item.directory, parent: directoryFD)
            defer { close(child) }
            try ShareFS.protect(child)
            let file = openat(child, item.name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard file >= 0 else { throw ShareFS.error() }
            defer { close(file) }
            try ShareFS.protect(file)
            items.append(item) // publication wins late cancellation, retain ownership
        } catch {
            try await stager.discard(copied)
            throw error
        }
    }

    func publish() throws {
        guard !released, !published, !retired, !items.isEmpty else { throw SharePayloadError.unsupported }
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(ShareManifest(version: 1, id: id, created: Date(), items: items))
        guard data.count <= 32 * 1024 else { throw SharePayloadError.limit }
        try ShareFS.write(data, name: ".manifest", parent: directoryFD)
        guard renameat(directoryFD, ".manifest", directoryFD, ".ready") == 0 else { throw ShareFS.error() }
        guard fsync(directoryFD) == 0 else { throw ShareFS.error() }
        published = true
    }

    func files() throws -> [URL] {
        guard !released, !retired else { throw SharePayloadError.busy }
        let data = try ShareFS.read(".ready", parent: directoryFD, maximum: 32 * 1024)
        let manifest = try JSONDecoder().decode(ShareManifest.self, from: data)
        guard manifest.version == 1, manifest.id == id,
              manifest.created.timeIntervalSince1970.isFinite,
              !manifest.items.isEmpty, manifest.items.count <= ShareBatchStore.maximumItems,
              Set(manifest.items.map(\.directory)).count == manifest.items.count
        else { throw SharePayloadError.malformed }
        var total: Int64 = 0
        for item in manifest.items {
            _ = try validate(item)
            total += item.size
            guard total <= ShareBatchStore.maximumBatchBytes else { throw SharePayloadError.limit }
        }
        return manifest.items.map { directory.appendingPathComponent($0.directory).appendingPathComponent($0.name) }
    }

    private func validate(_ item: ShareManifest.Item) throws -> stat {
        guard let uuid = UUID(uuidString: item.directory), uuid.uuidString == item.directory,
              !item.name.isEmpty, item.name.utf8.count <= 255,
              item.name != ".", item.name != "..", !item.name.contains("/"), !item.name.contains("\0"),
              item.size >= 0, item.size <= ShareBatchStore.maximumFileBytes,
              item.contentType.utf8.count <= 255,
              let type = UTType(item.contentType), type.conforms(to: .data), !type.conforms(to: .directory)
        else { throw SharePayloadError.malformed }
        let child = try ShareFS.directory(item.directory, parent: directoryFD)
        defer { close(child) }
        guard try ShareFS.names(child) == [item.name] else { throw SharePayloadError.malformed }
        let file = openat(child, item.name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw SharePayloadError.malformed }
        defer { close(file) }
        let info = try ShareFS.regular(file)
        guard info.st_size == item.size else { throw SharePayloadError.malformed }
        return info
    }

    func acknowledge() throws {
        guard !released else { throw SharePayloadError.busy }
        if !retired {
            guard renameat(directoryFD, ".ready", directoryFD, ".acked") == 0 else { throw ShareFS.error() }
            retired = true // durable no-replay marker before fallible payload cleanup
            guard fsync(directoryFD) == 0 else { throw ShareFS.error() }
        }
        try discard()
    }

    func discard() throws {
        guard !released else { return }
        // Validate the complete bounded inventory before unlinking anything. Never
        // recursively remove a path, follow a link, or touch another batch.
        let names = try ShareFS.names(directoryFD)
        guard names.count <= ShareBatchStore.maximumItems + 3 else { throw SharePayloadError.malformed }
        var copies: [(String, String)] = []
        for name in names where ![".lock", ".ready", ".acked", ".manifest"].contains(name) {
            guard let uuid = UUID(uuidString: name), uuid.uuidString == name else { throw SharePayloadError.malformed }
            let child = try ShareFS.directory(name, parent: directoryFD)
            defer { close(child) }
            let entries = try ShareFS.names(child)
            guard entries.count <= 1 else { throw SharePayloadError.malformed }
            if let entry = entries.first {
                let file = openat(child, entry, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                guard file >= 0 else { throw SharePayloadError.malformed }
                defer { close(file) }
                _ = try ShareFS.regular(file)
                copies.append((name, entry))
            } else { copies.append((name, "")) }
        }
        for (name, entry) in copies {
            let child = try ShareFS.directory(name, parent: directoryFD)
            defer { close(child) }
            if !entry.isEmpty, unlinkat(child, entry, 0) != 0 { throw ShareFS.error() }
            guard unlinkat(directoryFD, name, AT_REMOVEDIR) == 0 else { throw ShareFS.error() }
        }
        for name in [".ready", ".acked", ".manifest", ".lock"] {
            if unlinkat(directoryFD, name, 0) != 0, errno != ENOENT { throw ShareFS.error() }
        }
        guard unlinkat(rootFD, id.uuidString, AT_REMOVEDIR) == 0 else { throw ShareFS.error() }
        retired = true
        release()
    }

    func release() { if !released { released = true; flock(lockFD, LOCK_UN) } }
}

enum ShareFS {
    static func error() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    static func directory(_ name: String, parent: Int32 = AT_FDCWD) throws -> Int32 {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw error() }
        return fd
    }
    static func regular(_ fd: Int32) throws -> stat {
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1
        else { throw SharePayloadError.unsupported }
        return info
    }
    static func protect(_ fd: Int32) throws {
        #if os(iOS)
        guard fcntl(fd, F_SETPROTECTIONCLASS, 1) == 0 else { throw error() } // NSFileProtectionComplete
        #endif
    }
    static func names(_ fd: Int32) throws -> [String] {
        // Independent directory offset: dup alone shares offsets between scans.
        let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard copy >= 0 else { throw error() }
        guard let stream = fdopendir(copy) else { close(copy); throw error() }
        defer { closedir(stream) }
        var result: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." { result.append(name) }
            guard result.count <= 256 else { throw SharePayloadError.limit }
            errno = 0
        }
        guard errno == 0 else { throw error() }
        return result.sorted()
    }
    static func read(_ name: String, parent: Int32, maximum: Int) throws -> Data {
        let fd = openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw error() }
        defer { close(fd) }
        let info = try regular(fd)
        guard info.st_size > 0, info.st_size <= maximum else { throw SharePayloadError.malformed }
        var buffer = [UInt8](repeating: 0, count: maximum + 1)
        let count = Darwin.read(fd, &buffer, buffer.count)
        guard count == info.st_size else { throw SharePayloadError.malformed }
        return Data(buffer.prefix(count))
    }
    static func write(_ data: Data, name: String, parent: Int32) throws {
        let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw error() }
        defer { close(fd) }
        try protect(fd)
        let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard count == data.count, fsync(fd) == 0 else { throw error() }
    }
}
