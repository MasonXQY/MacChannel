import Foundation

public enum PresenceTrustSyncState: Equatable, Sendable {
    case idle, synchronizing, synchronized, pendingPersistence, needsAttention
}

/// One instance per authenticated session. Only the session's sole reader
/// delivers results; the worker is the sole trust-update writer. No wire request
/// identifier exists, so an expired acknowledgement retires the entire socket.
actor PresenceTrustSynchronizer {
    private let records: @Sendable () async throws -> TrustPublicationSnapshot
    private let send: @Sendable (SignedTrustRecord) async throws -> Void
    private let sleep: @Sendable (Duration) async throws -> Void
    private let onState: @Sendable (PresenceTrustSyncState) async -> Void
    private let onFailure: @Sendable () async -> Void
    private var worker: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var stopped = false
    private var refreshRequested = false
    private var snapshot: [SignedTrustRecord] = []
    private var pendingPersistence = false
    private var accounted: [SignedTrustRecord: RendezvousTrustResult] = [:]
    private var pending: UUID?
    private var result: RendezvousTrustResult?
    private var waiter: CheckedContinuation<RendezvousTrustResult?, Never>?

    init(records: @escaping @Sendable () async throws -> TrustPublicationSnapshot,
         send: @escaping @Sendable (SignedTrustRecord) async throws -> Void,
         sleep: @escaping @Sendable (Duration) async throws -> Void,
         onState: @escaping @Sendable (PresenceTrustSyncState) async -> Void,
         onFailure: @escaping @Sendable () async -> Void) {
        self.records = records
        self.send = send
        self.sleep = sleep
        self.onState = onState
        self.onFailure = onFailure
    }

    func refresh() {
        guard !stopped else { return }
        refreshRequested = true
        if worker == nil { worker = Task { await synchronize() } }
    }

    func receive(_ value: RendezvousTrustResult) async {
        guard !stopped else { return }
        guard pending != nil, result == nil else {
            // Unsolicited/duplicate results cannot safely identify a proof.
            await fail()
            return
        }
        result = value
        waiter?.resume(returning: value)
        waiter = nil
    }

    /// Retire without joining from a reader/failure callback; the owner joins
    /// this worker after the reader returns. This also releases an ACK waiter.
    func retire() {
        stopped = true
        worker?.cancel()
        deadline?.cancel()
        waiter?.resume(returning: nil)
        waiter = nil
    }

    func stop() async {
        retire()
        await worker?.value
        await deadline?.value
    }

    private func synchronize() async {
        defer { worker = nil }
        while !stopped, !Task.isCancelled {
            do {
                if refreshRequested {
                    refreshRequested = false
                    let publication = try await records()
                    pendingPersistence = publication.pendingPersistence
                    snapshot = publication.records.sorted {
                        if $0.issuer != $1.issuer {
                            return $0.issuer.rawValue.uuidString < $1.issuer.rawValue.uuidString
                        }
                        if $0.issuerSequence != $1.issuerSequence {
                            return $0.issuerSequence < $1.issuerSequence
                        }
                        return $0.signature.lexicographicallyPrecedes($1.signature)
                    }
                }
                guard !stopped, !Task.isCancelled else { return }
                if refreshRequested { continue }
                guard let record = snapshot.first(where: { accounted[$0] == nil }) else {
                    let rejected = snapshot.contains { accounted[$0] == .rejected }
                    await onState(rejected ? .needsAttention : (pendingPersistence ? .pendingPersistence : .synchronized))
                    if refreshRequested { continue }
                    return
                }
                await onState(snapshot.contains { accounted[$0] == .rejected }
                    ? .needsAttention : .synchronizing)
                guard !stopped, !Task.isCancelled else { return }
                if refreshRequested { continue }
                let id = UUID()
                pending = id
                result = nil
                deadline = Task {
                    do { try await sleep(.seconds(15)); try Task.checkCancellation() }
                    catch { return }
                    await self.expired(id)
                }
                // The result slot and deadline exist before send suspends: a
                // real server may ACK before the transport's send returns.
                try await send(record)
                let confirmation = await acknowledgement()
                deadline?.cancel()
                await deadline?.value
                deadline = nil
                pending = nil
                result = nil
                guard !stopped, let confirmation else { return }
                accounted[record] = confirmation
            } catch {
                await fail()
                return
            }
        }
    }

    private func acknowledgement() async -> RendezvousTrustResult? {
        if stopped { return nil }
        if let result { return result }
        return await withCheckedContinuation { waiter = $0 }
    }

    private func expired(_ id: UUID) async {
        guard !stopped, pending == id else { return }
        await fail()
    }

    private func fail() async {
        guard !stopped else { return }
        retire()
        await onFailure()
    }
}
