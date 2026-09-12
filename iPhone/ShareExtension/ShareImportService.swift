import CoreTransferable
import Foundation
import UniformTypeIdentifiers

struct ShareReceivedFile: Sendable, Transferable {
    let attempt: UUID
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .data) { received in
            // This await remains INSIDE the provider's file lifetime.
            try await ShareImportService.shared.importFile(received.file)
        }
    }
}

/// Extension-only provider owner. Its immutable factory can resolve only Apple's
/// entitlement container. Controlled providers inject an isolated store in tests.
actor ShareImportService {
    typealias Completion = @Sendable (Result<ShareReceivedFile, Error>) -> Void
    typealias Start = @MainActor @Sendable (@escaping Completion) -> Progress
    static let shared = ShareImportService(makeStore: { try ShareBatchStore.applicationGroup() })
    private let makeStore: @Sendable () async throws -> ShareBatchStore
    private var active: UUID?
    private var batch: ShareBatch?
    private var cancelled = false
    private var provider: Task<ShareReceivedFile, Error>?
    private var copy: Task<Void, Error>?
    private var cleaning: Task<Void, Error>?

    init(makeStore: @escaping @Sendable () async throws -> ShareBatchStore) { self.makeStore = makeStore }

    func save(_ starts: [Start]) async throws -> UUID {
        guard active == nil else { throw SharePayloadError.busy }
        guard !starts.isEmpty, starts.count <= ShareBatchStore.maximumItems else { throw SharePayloadError.unsupported }
        let id = UUID(); active = id; cancelled = false
        return try await withTaskCancellationHandler {
            do {
                let store = try await makeStore()
                try await store.cleanup()
                batch = try await store.begin()
                guard let batch else { throw SharePayloadError.unavailable }
                for start in starts {
                    guard !cancelled else { throw CancellationError() }
                    let task = Task { try await ShareProviderCompletion.load(start) }
                    provider = task
                    let receipt = try await task.value
                    // Join all local work even if a provider delivers early/error.
                    try await copy?.value
                    guard receipt.attempt == id, copy != nil else { throw SharePayloadError.malformed }
                    provider = nil; copy = nil
                }
                guard !cancelled else { throw CancellationError() }
                try await batch.publish()
                await batch.release()
                self.batch = nil; active = nil
                return batch.id
            } catch {
                do { try await cleanup() }
                catch { throw SharePayloadError.cleanup }
                throw error
            }
        } onCancel: { Task { await self.cancel() } }
    }

    func importFile(_ source: URL) async throws -> ShareReceivedFile {
        guard let active, let batch, provider != nil, copy == nil, !cancelled else { throw CancellationError() }
        let type = UTType(filenameExtension: source.pathExtension) ?? .data
        let task = Task { try await batch.append(source, contentType: type.identifier) }
        copy = task
        try await task.value
        return ShareReceivedFile(attempt: active)
    }

    func cancel() { cancelled = true; provider?.cancel(); copy?.cancel() }

    func cleanup() async throws {
        if let cleaning { try await cleaning.value; return }
        cancel()
        let task = Task {
            _ = await provider?.result
            _ = await copy?.result
            try await batch?.discard()
        }
        cleaning = task
        do {
            try await task.value
            provider = nil; copy = nil; batch = nil; active = nil; cleaning = nil
        } catch { cleaning = nil; throw SharePayloadError.cleanup }
    }
}

private final class ShareProviderCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: Progress?
    private var cancelled = false
    private var finished = false
    static func load(_ start: @escaping ShareImportService.Start) async throws -> ShareReceivedFile {
        let bridge = ShareProviderCompletion()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task { @MainActor in
                    let progress = start { bridge.complete($0, continuation) }
                    bridge.install(progress)
                }
            }
        } onCancel: { bridge.cancel() }
    }
    private func install(_ progress: Progress) {
        lock.lock(); let cancelNow = cancelled
        if !finished { self.progress = progress }
        lock.unlock()
        if cancelNow { progress.cancel() }
    }
    private func cancel() {
        lock.lock(); cancelled = true; let progress = progress; lock.unlock()
        progress?.cancel()
    }
    private func complete(_ result: Result<ShareReceivedFile, Error>, _ continuation: CheckedContinuation<ShareReceivedFile, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true; progress = nil; lock.unlock()
        continuation.resume(with: result)
    }
}
