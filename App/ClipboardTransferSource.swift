import AppKit
import Darwin
import Foundation

enum ClipboardTransferPreparationError: Error, Equatable {
    case noSupportedContent
    case cannotCreateTemporaryFile
}

@MainActor
protocol ClipboardTransferPreparing: AnyObject {
    func prepare() throws -> PreparedClipboardTransfer
}

@MainActor
final class PreparedClipboardTransfer {
    let urls: [URL]
    let ownedTemporaryURLs: [URL]

    private let fileManager: FileManager
    private var discarded = false

    init(
        urls: [URL],
        ownedTemporaryURLs: [URL],
        fileManager: FileManager = .default
    ) {
        self.urls = urls
        self.ownedTemporaryURLs = ownedTemporaryURLs
        self.fileManager = fileManager
    }

    func discardTemporaryFiles() {
        guard !discarded else { return }
        discarded = true
        for url in ownedTemporaryURLs {
            try? fileManager.removeItem(at: url)
        }
    }
}

@MainActor
final class NativeClipboardTransferPreparer: ClipboardTransferPreparing {
    private struct FileReservation {
        let url: URL
        let name: String
        let device: dev_t
        let inode: ino_t
    }

    private enum MaterializationFailure: Error {
        case failed
    }

    private let pasteboard: NSPasteboard
    private let temporaryRoot: URL
    private let now: () -> Date
    private let fileManager: FileManager
    private let cacheDirectory: URL
    private let reservationHook: (@MainActor (URL) throws -> Void)?

    static var defaultTemporaryRoot: URL {
        defaultTemporaryRoot(
            in: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        )
    }

    init(
        pasteboard: NSPasteboard = .general,
        temporaryRoot: URL? = nil,
        now: @escaping () -> Date = Date.init,
        fileManager: FileManager = .default,
        cacheDirectory: URL? = nil,
        reservationHook: (@MainActor (URL) throws -> Void)? = nil
    ) {
        let cacheDirectory = cacheDirectory
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let usesProductionTemporaryRoot = temporaryRoot == nil
        self.pasteboard = pasteboard
        self.temporaryRoot = temporaryRoot ?? Self.defaultTemporaryRoot(in: cacheDirectory)
        self.now = now
        self.fileManager = fileManager
        self.cacheDirectory = cacheDirectory
        self.reservationHook = reservationHook

        if usesProductionTemporaryRoot {
            try? pruneAbandonedFiles(olderThan: .seconds(24 * 60 * 60))
        }

    }

    func prepare() throws -> PreparedClipboardTransfer {
        let fileURLs = fileURLsFromPasteboard()
        if !fileURLs.isEmpty {
            return PreparedClipboardTransfer(
                urls: fileURLs,
                ownedTemporaryURLs: [],
                fileManager: fileManager
            )
        }

        if let imageData = pngDataFromPasteboard() {
            return try materialize(imageData, kind: "图片", fileExtension: "png")
        }

        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return try materialize(Data(text.utf8), kind: "文字", fileExtension: "txt")
        }

        throw ClipboardTransferPreparationError.noSupportedContent
    }

    func pruneAbandonedFiles(olderThan age: Duration) throws {
        let rootDescriptor = try openTemporaryRoot()
        defer { _ = Darwin.close(rootDescriptor) }

        let cutoff = now().addingTimeInterval(-Self.timeInterval(for: age))
        let children = try fileManager.contentsOfDirectory(
            at: temporaryRoot,
            includingPropertiesForKeys: nil,
            options: []
        )
        for child in children {
            let name = child.lastPathComponent
            guard name != ".", name != "..", !name.contains("/") else { continue }
            removeIfExpiredRegularFile(
                named: name,
                rootDescriptor: rootDescriptor,
                cutoff: cutoff
            )
        }
    }

    private func fileURLsFromPasteboard() -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) ?? []
        return objects.compactMap { object in
            guard let url = object as? URL, url.isFileURL else { return nil }
            return url.standardizedFileURL
        }
    }

    private func pngDataFromPasteboard() -> Data? {
        guard let image = NSImage(pasteboard: pasteboard),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func materialize(
        _ data: Data,
        kind: String,
        fileExtension: String
    ) throws -> PreparedClipboardTransfer {
        do {
            let rootDescriptor = try openTemporaryRoot()
            defer { _ = Darwin.close(rootDescriptor) }
            let reservation = try reserveNextAvailableName(
                kind: kind,
                fileExtension: fileExtension,
                rootDescriptor: rootDescriptor
            )
            var published = false
            defer {
                if !published {
                    removeReservationIfOwned(reservation, rootDescriptor: rootDescriptor)
                }
            }

            try reservationHook?(reservation.url)
            try publish(data, over: reservation, rootDescriptor: rootDescriptor)
            published = true
            return PreparedClipboardTransfer(
                urls: [reservation.url],
                ownedTemporaryURLs: [reservation.url],
                fileManager: fileManager
            )
        } catch {
            throw ClipboardTransferPreparationError.cannotCreateTemporaryFile
        }
    }

    private func openTemporaryRoot() throws -> Int32 {
        let requestedRoot = temporaryRoot.standardizedFileURL
        guard let trustedBase = approvedAnchor(for: requestedRoot) else {
            throw MaterializationFailure.failed
        }
        let prefix = trustedBase.path + "/"

        var descriptor = Darwin.open(trustedBase.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw MaterializationFailure.failed }
        let relativeComponents = requestedRoot.path.dropFirst(prefix.count)
            .split(separator: "/")
            .map(String.init)
        for component in relativeComponents {
            var nextDescriptor = Darwin.openat(
                descriptor,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW
            )
            if nextDescriptor < 0 && errno == ENOENT {
                guard Darwin.mkdirat(descriptor, component, S_IRUSR | S_IWUSR | S_IXUSR) == 0 else {
                    _ = Darwin.close(descriptor)
                    throw MaterializationFailure.failed
                }
                nextDescriptor = Darwin.openat(
                    descriptor,
                    component,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW
                )
            }
            guard nextDescriptor >= 0 else {
                _ = Darwin.close(descriptor)
                throw MaterializationFailure.failed
            }
            _ = Darwin.close(descriptor)
            descriptor = nextDescriptor
        }

        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR | S_IXUSR) == 0 else {
            _ = Darwin.close(descriptor)
            throw MaterializationFailure.failed
        }
        return descriptor
    }

    private func approvedAnchor(for requestedRoot: URL) -> URL? {
        [cacheDirectory.standardizedFileURL, fileManager.temporaryDirectory.standardizedFileURL]
            .filter { anchor in requestedRoot.path.hasPrefix(anchor.path + "/") }
            .max { $0.path.count < $1.path.count }
    }

    private static func defaultTemporaryRoot(in cacheDirectory: URL) -> URL {
        cacheDirectory
            .appendingPathComponent("MacChannel", isDirectory: true)
            .appendingPathComponent("ClipboardTransfers", isDirectory: true)
    }

    private func removeIfExpiredRegularFile(
        named name: String,
        rootDescriptor: Int32,
        cutoff: Date
    ) {
        var metadata = stat()
        guard Darwin.fstatat(
            rootDescriptor,
            name,
            &metadata,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              creationOrModificationDate(for: metadata) < cutoff
        else {
            return
        }

        _ = Darwin.unlinkat(rootDescriptor, name, 0)
    }

    private func creationOrModificationDate(for metadata: stat) -> Date {
        let birthTime = metadata.st_birthtimespec
        let modificationTime = metadata.st_mtimespec
        let timestamp = birthTime.tv_sec == 0 ? modificationTime : birthTime
        return Date(
            timeIntervalSince1970: TimeInterval(timestamp.tv_sec)
                + TimeInterval(timestamp.tv_nsec) / 1_000_000_000
        )
    }

    private static func timeInterval(for duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private func reserveNextAvailableName(
        kind: String,
        fileExtension: String,
        rootDescriptor: Int32
    ) throws -> FileReservation {
        let timestamp = Self.filenameDateFormatter.string(from: now())
        let baseName = "剪贴板\(kind) \(timestamp)"
        var ordinal = 1
        while true {
            let name = candidateName(
                baseName: baseName,
                ordinal: ordinal,
                fileExtension: fileExtension
            )
            let descriptor = Darwin.openat(
                rootDescriptor,
                name,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
            if descriptor < 0 {
                if errno == EEXIST {
                    ordinal += 1
                    continue
                }
                throw MaterializationFailure.failed
            }
            defer { _ = Darwin.close(descriptor) }
            guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                _ = Darwin.unlinkat(rootDescriptor, name, 0)
                throw MaterializationFailure.failed
            }

            var metadata = stat()
            guard Darwin.fstat(descriptor, &metadata) == 0 else {
                _ = Darwin.unlinkat(rootDescriptor, name, 0)
                throw MaterializationFailure.failed
            }
            return FileReservation(
                url: temporaryRoot.appendingPathComponent(name),
                name: name,
                device: metadata.st_dev,
                inode: metadata.st_ino
            )
        }
    }

    private func publish(
        _ data: Data,
        over reservation: FileReservation,
        rootDescriptor: Int32
    ) throws {
        guard reservationIsStillOwned(reservation, rootDescriptor: rootDescriptor) else {
            throw MaterializationFailure.failed
        }

        let stagingName = ".dropmesh-clipboard-\(UUID().uuidString).tmp"
        var descriptor = Darwin.openat(
            rootDescriptor,
            stagingName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw MaterializationFailure.failed }
        var published = false
        defer {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            if !published { _ = Darwin.unlinkat(rootDescriptor, stagingName, 0) }
        }

        try write(data, to: descriptor)
        guard Darwin.fsync(descriptor) == 0,
              Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
              Darwin.close(descriptor) == 0
        else {
            throw MaterializationFailure.failed
        }
        descriptor = -1

        guard reservationIsStillOwned(reservation, rootDescriptor: rootDescriptor),
              Darwin.renameat(rootDescriptor, stagingName, rootDescriptor, reservation.name) == 0
        else {
            throw MaterializationFailure.failed
        }
        published = true
    }

    private func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                guard let baseAddress = bytes.baseAddress else {
                    throw MaterializationFailure.failed
                }
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    bytes.count - written
                )
                guard count > 0 else { throw MaterializationFailure.failed }
                written += count
            }
        }
    }

    private func reservationIsStillOwned(
        _ reservation: FileReservation,
        rootDescriptor: Int32
    ) -> Bool {
        var metadata = stat()
        return Darwin.fstatat(
            rootDescriptor,
            reservation.name,
            &metadata,
            AT_SYMLINK_NOFOLLOW
        ) == 0
            && (metadata.st_mode & S_IFMT) == S_IFREG
            && metadata.st_dev == reservation.device
            && metadata.st_ino == reservation.inode
    }

    private func removeReservationIfOwned(
        _ reservation: FileReservation,
        rootDescriptor: Int32
    ) {
        guard reservationIsStillOwned(reservation, rootDescriptor: rootDescriptor) else { return }
        _ = Darwin.unlinkat(rootDescriptor, reservation.name, 0)
    }

    private func candidateName(baseName: String, ordinal: Int, fileExtension: String) -> String {
        let suffix = ordinal == 1 ? "" : " \(ordinal)"
        return "\(baseName)\(suffix).\(fileExtension)"
    }

    private static let filenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()
}
