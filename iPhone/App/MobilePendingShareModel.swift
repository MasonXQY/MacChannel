import Foundation
import Observation

@MainActor @Observable
final class MobilePendingShareModel {
    private(set) var batches: [UUID] = []
    private(set) var failureKey: String?
    private(set) var busy = false
    private let makeStore: @Sendable () async throws -> ShareBatchStore
    private var store: ShareBatchStore?

    init(makeStore: @escaping @Sendable () async throws -> ShareBatchStore = { try ShareBatchStore.applicationGroup() }) {
        self.makeStore = makeStore
    }

    func refresh() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            if store == nil { store = try await makeStore() }
            guard let store else { throw SharePayloadError.unavailable }
            try await store.cleanup()
            batches = try await store.pending()
            failureKey = nil
        } catch { failureKey = "share.error.storage" }
    }

    /// The sender admits synchronously after the cross-process claim. A picker,
    /// background transition or send winning that race leaves the shared copy ready.
    func prepare(_ id: UUID, using sender: MobileSendModel) async -> Bool {
        guard !busy, sender.canSelect, batches.contains(id), let store else { return false }
        busy = true; defer { busy = false }
        do {
            guard let batch = try await store.claim(id) else {
                batches = try await store.pending(); return false
            }
            guard sender.importSharedBatch(batch) else { await batch.release(); return false }
            batches.removeAll { $0 == id }; failureKey = nil
            return true
        } catch { failureKey = "share.error.invalid"; return false }
    }
}
