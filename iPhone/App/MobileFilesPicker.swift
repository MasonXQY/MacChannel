import Foundation
import Observation
import UIKit
import UniformTypeIdentifiers

/// Retain this adapter while its picker or prepared files are in use. Dismissal,
/// background, or abandonment must call cancelAndWait. After preparation, callers
/// must first join any runtime.send that borrows files before discarding them.
@MainActor @Observable
final class MobileFilesPicker: NSObject, UIDocumentPickerDelegate {
    enum Phase: Equatable { case waiting, preparing, ready, cancelling, cancelled, failed }
    let controller: UIDocumentPickerViewController
    private(set) var phase: Phase = .waiting
    private(set) var files: [MobileImportedFile] = []
    private(set) var failure: MobileImportError?
    private let service: MobileImportService
    private let attempt: UUID
    private var work: Task<Void, Never>?
    private var cancellation: Task<Void, Error>?

    static func make(service: MobileImportService = .shared) async throws -> MobileFilesPicker {
        let attempt = try await service.begin()
        if Task.isCancelled {
            try await service.discard(attempt)
            throw MobileImportError.cancelled
        }
        return MobileFilesPicker(service: service, attempt: attempt)
    }

    private init(service: MobileImportService, attempt: UUID) {
        self.service = service
        self.attempt = attempt
        controller = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        controller.allowsMultipleSelection = true
        super.init()
        controller.delegate = self
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard phase == .waiting else { return }
        phase = .preparing // synchronous duplicate gate before starting any task
        work = Task { [self] in
            do {
                let imported = try await service.importFiles(urls, in: attempt)
                if phase == .preparing { files = imported; phase = .ready }
            } catch {
                if phase == .preparing {
                    failure = MobileImportError.category(error)
                    do { try await service.discard(attempt) }
                    catch { failure = .cleanupFailed }
                    phase = .failed
                }
            }
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        requestCancellation()
    }

    func waitForImport() async { await work?.value }

    /// Errors leave the exact service admission owned for another cleanup attempt.
    func cancelAndWait() async throws {
        requestCancellation()
        try await cancellation?.value
    }

    private func requestCancellation() {
        guard cancellation == nil, phase != .cancelled else { return }
        phase = .cancelling
        cancellation = Task { [self] in
            await service.cancel(attempt)
            await work?.value
            do {
                try await service.discard(attempt)
                files = []
                failure = nil
                phase = .cancelled
            } catch {
                failure = .cleanupFailed
                phase = .failed
                cancellation = nil
                throw MobileImportError.cleanupFailed
            }
        }
    }
}
