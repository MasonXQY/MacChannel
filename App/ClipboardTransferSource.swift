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

    private var cleanup: (@MainActor @Sendable () -> Bool)?

    init(
        urls: [URL],
        ownedTemporaryURLs: [URL],
        cleanup: (@MainActor @Sendable () -> Bool)? = nil
    ) {
        precondition(ownedTemporaryURLs.isEmpty || cleanup != nil)
        self.urls = urls
        self.ownedTemporaryURLs = ownedTemporaryURLs
        self.cleanup = cleanup
    }

    fileprivate init(
        urls: [URL],
        ownedTemporaryURLs: [URL],
        cleanupCapability: ClipboardTemporaryCleanupCapability
    ) {
        self.urls = urls
        self.ownedTemporaryURLs = ownedTemporaryURLs
        cleanup = { cleanupCapability.discardOwnedFiles() }
    }

    @discardableResult
    func discardTemporaryFiles() -> Bool {
        guard let cleanup else { return true }
        guard cleanup() else { return false }
        self.cleanup = nil
        return true
    }
}

private struct ClipboardOwnedTemporaryFile {
    let publishedName: String
    let name: String
    let isQuarantined: Bool
    let device: dev_t
    let inode: ino_t
    let fileType: mode_t

    init(name: String, device: dev_t, inode: ino_t, fileType: mode_t) {
        publishedName = name
        self.name = name
        isQuarantined = false
        self.device = device
        self.inode = inode
        self.fileType = fileType
    }

    private init(
        publishedName: String,
        name: String,
        isQuarantined: Bool,
        device: dev_t,
        inode: ino_t,
        fileType: mode_t
    ) {
        self.publishedName = publishedName
        self.name = name
        self.isQuarantined = isQuarantined
        self.device = device
        self.inode = inode
        self.fileType = fileType
    }

    func matches(_ metadata: stat) -> Bool {
        fileType == S_IFREG
            && (metadata.st_mode & S_IFMT) == fileType
            && metadata.st_dev == device
            && metadata.st_ino == inode
    }

    func quarantined(named name: String) -> ClipboardOwnedTemporaryFile {
        ClipboardOwnedTemporaryFile(
            publishedName: publishedName,
            name: name,
            isQuarantined: true,
            device: device,
            inode: inode,
            fileType: fileType
        )
    }

    func restoredToPublishedName() -> ClipboardOwnedTemporaryFile {
        ClipboardOwnedTemporaryFile(
            publishedName: publishedName,
            name: publishedName,
            isQuarantined: false,
            device: device,
            inode: inode,
            fileType: fileType
        )
    }
}

@MainActor
private final class ClipboardTemporaryCleanupCapability {
    typealias RenameOperation = @MainActor (Int32, String, String) -> Int32
    typealias UnlinkOperation = @MainActor (Int32, String) -> Int32

    private enum Inspection {
        case owned
        case missing
        case noLongerOwned
        case retryLater
    }

    private enum CleanupAttempt {
        case complete
        case retry(ClipboardOwnedTemporaryFile)
    }

    private var rootDescriptor: Int32
    private var ownedFiles: [ClipboardOwnedTemporaryFile]
    private let ownsRootDescriptor: Bool
    private let renameOperation: RenameOperation
    private let unlinkOperation: UnlinkOperation

    init(
        duplicatingRootDescriptor rootDescriptor: Int32,
        ownedFiles: [ClipboardOwnedTemporaryFile],
        renameOperation: @escaping RenameOperation = systemRename,
        unlinkOperation: @escaping UnlinkOperation = systemUnlink
    ) throws {
        self.rootDescriptor = try Self.duplicate(rootDescriptor)
        self.ownedFiles = ownedFiles
        ownsRootDescriptor = true
        self.renameOperation = renameOperation
        self.unlinkOperation = unlinkOperation
    }

    private init(
        borrowingRootDescriptor rootDescriptor: Int32,
        ownedFiles: [ClipboardOwnedTemporaryFile],
        renameOperation: @escaping RenameOperation,
        unlinkOperation: @escaping UnlinkOperation
    ) {
        self.rootDescriptor = rootDescriptor
        self.ownedFiles = ownedFiles
        ownsRootDescriptor = false
        self.renameOperation = renameOperation
        self.unlinkOperation = unlinkOperation
    }

    deinit {
        if ownsRootDescriptor, rootDescriptor >= 0 {
            _ = Darwin.close(rootDescriptor)
        }
    }

    static func discardPublishedFile(
        _ ownedFile: ClipboardOwnedTemporaryFile,
        rootDescriptor: Int32,
        renameOperation: @escaping RenameOperation,
        unlinkOperation: @escaping UnlinkOperation
    ) -> Bool {
        ClipboardTemporaryCleanupCapability(
            borrowingRootDescriptor: rootDescriptor,
            ownedFiles: [ownedFile],
            renameOperation: renameOperation,
            unlinkOperation: unlinkOperation
        ).discardOwnedFiles()
    }

    func discardOwnedFiles() -> Bool {
        guard rootDescriptor >= 0 else { return true }
        var remaining: [ClipboardOwnedTemporaryFile] = []
        for ownedFile in ownedFiles {
            switch discard(ownedFile) {
            case .complete:
                break
            case .retry(let retryable):
                remaining.append(retryable)
            }
        }
        ownedFiles = remaining
        if ownedFiles.isEmpty { closeRootDescriptor() }
        return ownedFiles.isEmpty
    }

    private func discard(_ ownedFile: ClipboardOwnedTemporaryFile) -> CleanupAttempt {
        switch inspect(ownedFile) {
        case .missing:
            return .complete
        case .retryLater:
            return .retry(ownedFile)
        case .noLongerOwned:
            return ownedFile.isQuarantined
                ? restoreRacedReplacement(ownedFile)
                : .complete
        case .owned:
            return ownedFile.isQuarantined
                ? unlinkVerifiedQuarantine(ownedFile)
                : quarantineAndUnlink(ownedFile)
        }
    }

    private func quarantineAndUnlink(
        _ ownedFile: ClipboardOwnedTemporaryFile
    ) -> CleanupAttempt {
        let quarantineName = ".dropmesh-clipboard-cleanup-\(UUID().uuidString.lowercased())"
        let error = renameToQuarantine(
            from: ownedFile.name,
            to: quarantineName
        )
        if error == ENOENT { return .complete }
        guard error == 0 else { return .retry(ownedFile) }

        let quarantined = ownedFile.quarantined(named: quarantineName)
        switch inspect(quarantined) {
        case .missing:
            return .complete
        case .retryLater:
            return .retry(quarantined)
        case .noLongerOwned:
            return restoreRacedReplacement(quarantined)
        case .owned:
            return unlinkVerifiedQuarantine(quarantined)
        }
    }

    private func unlinkVerifiedQuarantine(
        _ quarantined: ClipboardOwnedTemporaryFile
    ) -> CleanupAttempt {
        let error = unlinkOwnedFile(named: quarantined.name)
        if error == 0 || error == ENOENT { return .complete }

        switch inspect(quarantined) {
        case .missing:
            return .complete
        case .retryLater:
            return .retry(quarantined)
        case .noLongerOwned:
            return restoreRacedReplacement(quarantined)
        case .owned:
            let restoreError = restoreFromQuarantine(quarantined)
            if restoreError == 0 {
                return .retry(quarantined.restoredToPublishedName())
            }
            if restoreError == ENOENT { return .complete }
            return .retry(quarantined)
        }
    }

    private func restoreRacedReplacement(
        _ quarantined: ClipboardOwnedTemporaryFile
    ) -> CleanupAttempt {
        let error = restoreFromQuarantine(quarantined)
        if error == 0 || error == ENOENT { return .complete }
        return .retry(quarantined)
    }

    private func inspect(_ ownedFile: ClipboardOwnedTemporaryFile) -> Inspection {
        var metadata = stat()
        let error = Self.status(
            rootDescriptor: rootDescriptor,
            name: ownedFile.name,
            metadata: &metadata
        )
        if error == ENOENT { return .missing }
        guard error == 0 else { return .retryLater }
        return ownedFile.matches(metadata) ? .owned : .noLongerOwned
    }

    private func renameToQuarantine(from sourceName: String, to quarantineName: String) -> Int32 {
        while true {
            let error = renameOperation(rootDescriptor, sourceName, quarantineName)
            if error == 0 { return 0 }
            if error == EINTR { continue }
            return error
        }
    }

    private func restoreFromQuarantine(_ quarantined: ClipboardOwnedTemporaryFile) -> Int32 {
        while true {
            let error = Self.systemRename(
                rootDescriptor: rootDescriptor,
                sourceName: quarantined.name,
                destinationName: quarantined.publishedName
            )
            if error == 0 { return 0 }
            if error == EINTR { continue }
            return error
        }
    }

    private func unlinkOwnedFile(named name: String) -> Int32 {
        while true {
            let error = unlinkOperation(rootDescriptor, name)
            if error == 0 { return 0 }
            if error == EINTR { continue }
            return error
        }
    }

    fileprivate static func systemUnlink(rootDescriptor: Int32, name: String) -> Int32 {
        let result = name.withCString {
            Darwin.unlinkat(rootDescriptor, $0, 0)
        }
        return result == 0 ? 0 : errno
    }

    fileprivate static func systemRename(
        rootDescriptor: Int32,
        sourceName: String,
        destinationName: String
    ) -> Int32 {
        let result = sourceName.withCString { source in
            destinationName.withCString { destination in
                Darwin.renameatx_np(
                    rootDescriptor,
                    source,
                    rootDescriptor,
                    destination,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        return result == 0 ? 0 : errno
    }

    private static func status(
        rootDescriptor: Int32,
        name: String,
        metadata: inout stat
    ) -> Int32 {
        while true {
            let result = name.withCString {
                Darwin.fstatat(rootDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
            }
            if result == 0 { return 0 }
            let error = errno
            if error == EINTR { continue }
            return error
        }
    }

    private static func duplicate(_ descriptor: Int32) throws -> Int32 {
        while true {
            let duplicate = Darwin.fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
            if duplicate >= 0 { return duplicate }
            if errno == EINTR { continue }
            throw ClipboardTransferPreparationError.cannotCreateTemporaryFile
        }
    }

    private func closeRootDescriptor() {
        guard rootDescriptor >= 0 else { return }
        if ownsRootDescriptor {
            _ = Darwin.close(rootDescriptor)
        }
        rootDescriptor = -1
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
    private let cleanupCapabilityCreationHook: (@MainActor () throws -> Void)?
    private let pruneBeforeQuarantineHook: (@MainActor (String) throws -> Void)?
    private let pruneRootOpenedHook: (@MainActor () throws -> Void)?
    private let terminalCleanupRename: @MainActor (Int32, String, String) -> Int32
    private let terminalCleanupUnlink: @MainActor (Int32, String) -> Int32

    static var defaultTemporaryRoot: URL {
        defaultTemporaryRoot(
            in: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        )
    }

    init(
        pasteboard: NSPasteboard = NSPasteboard.general,
        temporaryRoot: URL? = nil,
        now: @escaping () -> Date = Date.init,
        fileManager: FileManager = .default,
        cacheDirectory: URL? = nil,
        reservationHook: (@MainActor (URL) throws -> Void)? = nil,
        cleanupCapabilityCreationHook: (@MainActor () throws -> Void)? = nil,
        pruneBeforeQuarantineHook: (@MainActor (String) throws -> Void)? = nil,
        pruneRootOpenedHook: (@MainActor () throws -> Void)? = nil,
        terminalCleanupRename: @escaping @MainActor (Int32, String, String) -> Int32 =
            ClipboardTemporaryCleanupCapability.systemRename,
        terminalCleanupUnlink: @escaping @MainActor (Int32, String) -> Int32 =
            ClipboardTemporaryCleanupCapability.systemUnlink
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
        self.cleanupCapabilityCreationHook = cleanupCapabilityCreationHook
        self.pruneBeforeQuarantineHook = pruneBeforeQuarantineHook
        self.pruneRootOpenedHook = pruneRootOpenedHook
        self.terminalCleanupRename = terminalCleanupRename
        self.terminalCleanupUnlink = terminalCleanupUnlink

        if usesProductionTemporaryRoot {
            try? pruneAbandonedFiles(olderThan: .seconds(24 * 60 * 60))
        }

    }

    func prepare() throws -> PreparedClipboardTransfer {
        let fileURLs = fileURLsFromPasteboard()
        if !fileURLs.isEmpty {
            return PreparedClipboardTransfer(
                urls: fileURLs,
                ownedTemporaryURLs: []
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
        try pruneRootOpenedHook?()
        for name in try directChildNames(rootDescriptor: rootDescriptor) {
            quarantineAndRemoveExpiredRegularFile(
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
            var publishedOwnership: ClipboardOwnedTemporaryFile?
            defer {
                if !published {
                    if let publishedOwnership {
                        _ = ClipboardTemporaryCleanupCapability.discardPublishedFile(
                            publishedOwnership,
                            rootDescriptor: rootDescriptor,
                            renameOperation: terminalCleanupRename,
                            unlinkOperation: terminalCleanupUnlink
                        )
                    } else {
                        removeReservationIfOwned(reservation, rootDescriptor: rootDescriptor)
                    }
                }
            }

            try reservationHook?(reservation.url)
            let ownership = try publish(
                data,
                over: reservation,
                rootDescriptor: rootDescriptor
            )
            publishedOwnership = ownership
            try cleanupCapabilityCreationHook?()
            let cleanupCapability = try ClipboardTemporaryCleanupCapability(
                duplicatingRootDescriptor: rootDescriptor,
                ownedFiles: [ownership],
                renameOperation: terminalCleanupRename,
                unlinkOperation: terminalCleanupUnlink
            )
            published = true
            return PreparedClipboardTransfer(
                urls: [reservation.url],
                ownedTemporaryURLs: [reservation.url],
                cleanupCapability: cleanupCapability
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

        var descriptor = Darwin.open(
            trustedBase.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw MaterializationFailure.failed }
        let relativeComponents = requestedRoot.path.dropFirst(prefix.count)
            .split(separator: "/")
            .map(String.init)
        for component in relativeComponents {
            var nextDescriptor = Darwin.openat(
                descriptor,
                component,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            if nextDescriptor < 0 && errno == ENOENT {
                guard Darwin.mkdirat(descriptor, component, S_IRUSR | S_IWUSR | S_IXUSR) == 0 else {
                    _ = Darwin.close(descriptor)
                    throw MaterializationFailure.failed
                }
                nextDescriptor = Darwin.openat(
                    descriptor,
                    component,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
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

    private func directChildNames(rootDescriptor: Int32) throws -> [String] {
        let independentDescriptor = Darwin.openat(
            rootDescriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard independentDescriptor >= 0,
              let directory = Darwin.fdopendir(independentDescriptor)
        else {
            if independentDescriptor >= 0 { _ = Darwin.close(independentDescriptor) }
            throw MaterializationFailure.failed
        }

        var names: [String] = []
        errno = 0
        while let entry = Darwin.readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." { names.append(name) }
        }
        let readError = errno
        guard Darwin.closedir(directory) == 0, readError == 0 else {
            throw MaterializationFailure.failed
        }
        return names
    }

    private func quarantineAndRemoveExpiredRegularFile(
        named name: String,
        rootDescriptor: Int32,
        cutoff: Date
    ) {
        var expected = stat()
        guard Darwin.fstatat(
            rootDescriptor,
            name,
            &expected,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
              isExpiredRegularFile(expected, before: cutoff)
        else {
            return
        }

        do {
            try pruneBeforeQuarantineHook?(name)
        } catch {
            return
        }

        let quarantineName = ".dropmesh-clipboard-prune-\(UUID().uuidString.lowercased())"
        guard Darwin.renameatx_np(
            rootDescriptor,
            name,
            rootDescriptor,
            quarantineName,
            UInt32(RENAME_EXCL)
        ) == 0
        else {
            return
        }

        var moved = stat()
        guard Darwin.fstatat(
            rootDescriptor,
            quarantineName,
            &moved,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
              moved.st_dev == expected.st_dev,
              moved.st_ino == expected.st_ino,
              isExpiredRegularFile(moved, before: cutoff)
        else {
            restoreQuarantinedCandidate(
                named: name,
                quarantineName: quarantineName,
                rootDescriptor: rootDescriptor
            )
            return
        }

        _ = Darwin.unlinkat(rootDescriptor, quarantineName, 0)
    }

    private func restoreQuarantinedCandidate(
        named name: String,
        quarantineName: String,
        rootDescriptor: Int32
    ) {
        _ = Darwin.renameatx_np(
            rootDescriptor,
            quarantineName,
            rootDescriptor,
            name,
            UInt32(RENAME_EXCL)
        )
    }

    private func isExpiredRegularFile(_ metadata: stat, before cutoff: Date) -> Bool {
        (metadata.st_mode & S_IFMT) == S_IFREG
            && creationOrModificationDate(for: metadata) < cutoff
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
    ) throws -> ClipboardOwnedTemporaryFile {
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
        var stagedMetadata = stat()
        guard Darwin.fsync(descriptor) == 0,
              Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
              Darwin.fstat(descriptor, &stagedMetadata) == 0,
              (stagedMetadata.st_mode & S_IFMT) == S_IFREG,
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
        return ClipboardOwnedTemporaryFile(
            name: reservation.name,
            device: stagedMetadata.st_dev,
            inode: stagedMetadata.st_ino,
            fileType: stagedMetadata.st_mode & S_IFMT
        )
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
