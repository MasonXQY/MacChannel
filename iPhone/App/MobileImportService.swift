import DropMeshMobileRuntime
import Foundation

enum MobileImportError: LocalizedError, Equatable, Sendable {
    case busy, cancelled, unavailable, storage, unsupported, cleanupFailed

    var errorDescription: String? {
        switch self {
        case .busy: String(localized: "import.error.busy")
        case .cancelled: String(localized: "import.error.cancelled")
        case .unavailable: String(localized: "import.error.unavailable")
        case .storage: String(localized: "import.error.storage")
        case .unsupported: String(localized: "import.error.unsupported")
        case .cleanupFailed: String(localized: "import.error.cleanup")
        }
    }

    static func category(_ error: any Error) -> Self {
        if let error = error as? Self { return error }
        if error is CancellationError { return .cancelled }
        let cocoa = error as NSError
        if cocoa.domain == NSCocoaErrorDomain,
           cocoa.code == CocoaError.Code.fileReadUnsupportedScheme.rawValue {
            return .unsupported
        }
        if cocoa.domain == NSCocoaErrorDomain,
           [NSFileWriteOutOfSpaceError, NSFileWriteNoPermissionError, NSFileWriteUnknownError].contains(cocoa.code) {
            return .storage
        }
        if cocoa.domain == NSPOSIXErrorDomain,
           [POSIXErrorCode.ENOSPC, .EDQUOT].contains(where: { Int($0.rawValue) == cocoa.code }) {
            return .storage
        }
        return .unavailable
    }
}

/// Only private copies are exposed. The service retains their exact stager until
/// explicit discard; copying this value does not transfer cleanup responsibility.
struct MobileImportedFile: Sendable {
    let url: URL
    let durableSourceBookmark: Data?
    let photoAssetIdentifier: String?
    fileprivate let attempt: UUID
    fileprivate let copy: UUID
    init(url: URL, durableSourceBookmark: Data? = nil, photoAssetIdentifier: String? = nil,
         attempt: UUID, copy: UUID) {
        self.url = url; self.durableSourceBookmark = durableSourceBookmark
        self.photoAssetIdentifier = photoAssetIdentifier
        self.attempt = attempt; self.copy = copy
    }
    func withPhotoAssetIdentifier(_ identifier: String?) -> MobileImportedFile {
        MobileImportedFile(url: url, durableSourceBookmark: durableSourceBookmark,
            photoAssetIdentifier: identifier, attempt: attempt, copy: copy)
    }
}

protocol MobileImportStaging: Sendable {
    func stage(_ source: URL, coordinated: Bool) async throws -> URL
    func discard(_ url: URL) async throws
}

struct MobileSystemImportStager: MobileImportStaging {
    private let stager: MobileImportStager
    init(directory: URL) { stager = MobileImportStager(directory: directory) }
    func stage(_ source: URL, coordinated: Bool) async throws -> URL {
        if coordinated { return try await stager.stageCoordinated(file: source) }
        return try await stager.stage(file: source)
    }
    func discard(_ url: URL) async throws { try await stager.discard(url) }
}

/// One admitted selection owns provider delivery, copies and cleanup. Construction
/// performs no filesystem work. Even failed setup gets a fresh stager next time.
actor MobileImportService {
    static let shared = MobileImportService(makeStager: {
        let manager = FileManager.default
        guard let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let documents = manager.urls(for: .documentDirectory, in: .userDomainMask).first
        else { throw MobileImportError.storage }
        let layout = MobileStorageLayout(applicationSupport: support, documents: documents)
        try layout.prepare()
        do { try await MobileImportStager(directory: layout.stagingDirectory).recoverAbandonedImports() }
        catch { throw MobileImportError.cleanupFailed }
        return MobileSystemImportStager(directory: layout.stagingDirectory)
    })

    private struct OwnedCopy: Sendable {
        let file: MobileImportedFile
        let stager: any MobileImportStaging
    }
    private final class Attempt {
        let id = UUID()
        var started = false
        var cancelled = false
        var stager: Task<any MobileImportStaging, Error>?
        var copies: [UUID: Task<OwnedCopy, Error>] = [:]
        var provider: Task<MobileImportedFile, Error>?
        var cleanup: Task<Void, Error>?
    }
    private let makeStager: @Sendable () async throws -> any MobileImportStaging
    private var active: Attempt?

    init(makeStager: @escaping @Sendable () async throws -> any MobileImportStaging) {
        self.makeStager = makeStager
    }

    func begin() throws -> UUID {
        guard active == nil else { throw MobileImportError.busy }
        let attempt = Attempt()
        active = attempt
        return attempt.id
    }

    func importFiles(_ sources: [URL], in id: UUID) async throws -> [MobileImportedFile] {
        let attempt = try claim(id)
        return try await withTaskCancellationHandler {
            guard !sources.isEmpty else { throw MobileImportError.unsupported }
            var files: [MobileImportedFile] = []
            for source in sources {
                let scoped = source.startAccessingSecurityScopedResource()
                defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                let bookmark = try? source.bookmarkData(options: [],
                    includingResourceValuesForKeys: nil, relativeTo: nil)
                files.append(try await copy(source, coordinated: true, attempt: attempt, bookmark: bookmark))
            }
            return files
        } onCancel: { Task { await self.cancel(id) } }
    }

    private func claim(_ id: UUID) throws -> Attempt {
        guard let active, active.id == id, !active.cancelled else { throw MobileImportError.cancelled }
        guard !active.started else { throw MobileImportError.busy }
        active.started = true
        return active
    }

    private func copy(_ source: URL, coordinated: Bool, attempt: Attempt, bookmark: Data? = nil) async throws -> MobileImportedFile {
        guard !attempt.cancelled else { throw MobileImportError.cancelled }
        if attempt.stager == nil {
            let factory = makeStager
            attempt.stager = Task.detached(priority: .utility) { try await factory() }
        }
        let stagerTask = attempt.stager!
        let copyID = UUID()
        let attemptID = attempt.id
        let task = Task {
            let stager = try await stagerTask.value
            try Task.checkCancellation()
            let url = try await stager.stage(source, coordinated: coordinated)
            // No cancellation check here: rename success must remain owned.
            return OwnedCopy(file: MobileImportedFile(url: url, durableSourceBookmark: bookmark,
                attempt: attemptID, copy: copyID), stager: stager)
        }
        attempt.copies[copyID] = task
        do { return try await task.value.file }
        catch { throw MobileImportError.category(error) }
    }

    /// Called ONLY inside the static FileRepresentation's importing closure.
    /// Admission is held through the provider's actual completion, including cancel.
    func importPhotoFile(_ source: URL) async throws -> MobileImportedFile {
        guard let active, active.provider != nil else { throw MobileImportError.cancelled }
        return try await copy(source, coordinated: false, attempt: active)
    }

    func importPhoto(in id: UUID, start: @escaping MobilePhotoImport.Start) async throws -> MobileImportedFile {
        try await importPhotos(in: id, starts: [start])[0]
    }

    /// One admission owns the whole selection. Providers run sequentially so the
    /// static FileRepresentation callback always belongs to the current provider.
    func importPhotos(in id: UUID, starts: [MobilePhotoImport.Start]) async throws -> [MobileImportedFile] {
        let attempt = try claim(id)
        guard !starts.isEmpty else { throw MobileImportError.unsupported }
        return try await withTaskCancellationHandler {
            do {
                var files: [MobileImportedFile] = []
                for start in starts {
                    guard !attempt.cancelled else { throw MobileImportError.cancelled }
                    let task = Task { try await MobilePhotoImport.load(start: start) }
                    attempt.provider = task
                    let file = try await task.value
                    attempt.provider = nil
                    guard file.attempt == id, attempt.copies[file.copy] != nil else { throw MobileImportError.unsupported }
                    guard !attempt.cancelled else { throw MobileImportError.cancelled }
                    files.append(file)
                }
                return files
            } catch { throw MobileImportError.category(error) }
        } onCancel: { Task { await self.cancel(id) } }
    }

    /// Requests both cancellation paths immediately; this is not a cleanup barrier.
    func cancel(_ id: UUID) {
        guard let active, active.id == id else { return }
        active.cancelled = true
        active.provider?.cancel()
        for task in active.copies.values { task.cancel() }
    }

    /// Caller must join every runtime.send borrower BEFORE calling this method.
    /// A failed discard retains admission and the exact remaining copies for retry.
    func discard(_ id: UUID) async throws {
        guard let attempt = active, attempt.id == id else { return }
        cancel(id)
        if let cleanup = attempt.cleanup { try await cleanup.value; return }
        let cleanup = Task { try await self.clean(attempt) }
        attempt.cleanup = cleanup
        do {
            try await cleanup.value
            if active === attempt { active = nil }
        } catch {
            attempt.cleanup = nil
            throw MobileImportError.cleanupFailed
        }
    }

    private func clean(_ attempt: Attempt) async throws {
        // Provider completion closes the static callback lifetime before admission
        // can move to another operation. Cancellation never resumes it early.
        _ = await attempt.provider?.result
        var completed: [(UUID, OwnedCopy)] = []
        for (id, task) in attempt.copies {
            if case let .success(owned) = await task.result {
                completed.append((id, owned))
            } else {
                attempt.copies[id] = nil
            }
        }
        _ = await attempt.stager?.result
        // Join every worker before any failing deletion can return to the caller.
        // Still attempt other exact removals; retain only failed copies for retry.
        var failed = false
        for (id, owned) in completed {
            do {
                try await owned.stager.discard(owned.file.url)
                attempt.copies[id] = nil
            } catch { failed = true }
        }
        if failed { throw MobileImportError.cleanupFailed }
    }
}
