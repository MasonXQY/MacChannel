import CoreTransferable
import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

extension MobileImportedFile: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            try await MobileImportService.shared.importPhotoFile(received.file)
        }
        FileRepresentation(importedContentType: .movie) { received in
            try await MobileImportService.shared.importPhotoFile(received.file)
        }
    }
}

/// Bridges provider completion without mistaking Progress.cancel for completion.
/// The service separately cancels/joins the local copy task and retains results.
enum MobilePhotoImport {
    typealias Completion = @Sendable (Result<MobileImportedFile?, Error>) -> Void
    typealias Start = @MainActor @Sendable (@escaping Completion) -> Progress

    @MainActor
    static func load(_ item: PhotosPickerItem, in attempt: UUID) async throws -> MobileImportedFile {
        try await MobileImportService.shared.importPhoto(in: attempt) { completion in
            item.loadTransferable(type: MobileImportedFile.self, completionHandler: completion)
        }
    }

    static func load(start: @escaping Start) async throws -> MobileImportedFile {
        let bridge = ProviderCompletion()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task { @MainActor in
                    let progress = start { result in bridge.complete(result, continuation: continuation) }
                    bridge.install(progress)
                }
            }
        } onCancel: { bridge.cancel() }
    }
}

private final class ProviderCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: Progress?
    private var cancelled = false
    private var finished = false

    func install(_ progress: Progress) {
        lock.lock()
        let cancelNow = cancelled
        if !finished { self.progress = progress }
        lock.unlock()
        if cancelNow { progress.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let progress = progress
        lock.unlock()
        progress?.cancel()
    }

    func complete(_ result: Result<MobileImportedFile?, Error>, continuation: CheckedContinuation<MobileImportedFile, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        progress = nil
        lock.unlock()
        switch result {
        case let .success(file?): continuation.resume(returning: file)
        case .success(nil): continuation.resume(throwing: MobileImportError.unsupported)
        case let .failure(error): continuation.resume(throwing: MobileImportError.category(error))
        }
    }
}
