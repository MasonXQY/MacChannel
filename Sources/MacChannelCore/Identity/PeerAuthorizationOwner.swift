import Foundation

/// Memory-only owner; producers and scheduler are intentionally module-internal.
public final class PeerAuthorizationOwner: PeerAuthorizationProviding, @unchecked Sendable {
    private struct Effective { let key: Data; let continuity: UUID }
    private struct Account {
        let epoch: PeerAccountEpoch
        let binding: AccountSessionBinding
        let accountID: String
        let sessionID: String
        let localKey: Data
        let accessExpiry: Date
        var highWater: AccountGroupSnapshot?
        var freshUntil: Date?
        var keys: [DeviceID: Data] = [:]
    }
    private struct Registration {
        let lease: PeerAuthorizationLease
        let callback: @Sendable () -> Void
    }
    private let lock = NSLock()
    private let identity = UUID()
    private let local: DeviceID
    // Pure, synchronous, nonblocking clock; must not reenter this owner. Unlike
    // notification/scheduler callbacks, it is sampled at the locked admission.
    private let now: @Sendable () -> Date
    private let schedule: PeerDeadlineScheduler
    private var manual: [DeviceID: Data] = [:]
    private var account: Account?
    private var effective: [DeviceID: Effective] = [:]
    private var registrations: [UUID: Registration] = [:]
    private var timerID: UUID?
    private var cancelTimer: PeerDeadlineCancellation?
    private let publicationLock = NSLock()
    private var revision: UInt64 = 0
    private var observers: [UUID: AsyncStream<PeerAuthorizationSnapshot>.Continuation] = [:]

    init(local: DeviceID, now: @escaping @Sendable () -> Date, schedule: @escaping PeerDeadlineScheduler) {
        self.local = local; self.now = now; self.schedule = schedule
    }

    /// For the future synchronous TrustRepository commit seam. No observer or
    /// signed-record publication is modified by this owner.
    func replaceManual(_ store: TrustStore) throws {
        try replaceManual(Dictionary(uniqueKeysWithValues: store.trustedDeviceIDs.compactMap { id in
            store.trustedPublicKey(for: id).map { (id, $0) }
        }))
    }

    func replaceManual(_ keys: [DeviceID: Data]) throws {
        guard keys.allSatisfy({ Self.validKey($0.value, for: $0.key) }) else { throw PeerAuthorizationError.invalidEvidence }
        try transact { _ in manual = keys.filter { $0.key != local } }
    }

    func beginAccountSession(binding: AccountSessionBinding, accountID: String, sessionID: String,
                             localPublicKey: Data, accessExpiresAt: Date) throws -> PeerAccountEpoch {
        try transact { date in
            guard binding.deviceID == local.rawValue, Self.validKey(localPublicKey, for: local),
                  Self.validUUID(accountID), Self.validUUID(sessionID), Self.validDate(accessExpiresAt),
                  accessExpiresAt > date else { throw PeerAuthorizationError.invalidEvidence }
            // Explicit new lifecycle epoch, never a generation-number heuristic.
            let epoch = PeerAccountEpoch(owner: identity, id: UUID())
            account = Account(epoch: epoch, binding: binding, accountID: accountID,
                sessionID: sessionID, localKey: localPublicKey, accessExpiry: accessExpiresAt)
            return epoch
        }
    }

    func install(_ evidence: VerifiedPeerAccountEvidence) throws {
        let timer: (UUID, Date) = try transact { date in
            guard var current = account, current.epoch == evidence.epoch,
                  current.binding == evidence.binding, current.accessExpiry > date else { throw PeerAuthorizationError.invalidEvidence }
            let snapshot = evidence.snapshot
            guard snapshot.accountID == current.accountID, Self.validUUID(snapshot.groupID),
                  snapshot.generation > 0, snapshot.generation <= UInt64(Int64.max),
                  snapshot.sequence > 0, snapshot.sequence <= UInt64(Int64.max), snapshot.headHash.count == 32,
                  !snapshot.members.isEmpty, snapshot.members.count <= 64,
                  Self.validDate(evidence.freshUntil), evidence.freshUntil > date,
                  evidence.freshUntil <= current.accessExpiry else { throw PeerAuthorizationError.invalidEvidence }
            var keys: [DeviceID: Data] = [:]
            for member in snapshot.members {
                guard AccountGroupCheckpoint.canonicalUUID(member.deviceID), let uuid = UUID(uuidString: member.deviceID) else { throw PeerAuthorizationError.invalidEvidence }
                let id = DeviceID(rawValue: uuid)
                guard Self.validKey(member.publicKey, for: id), keys[id] == nil else { throw PeerAuthorizationError.invalidEvidence }
                keys[id] = member.publicKey
            }
            guard keys[local] == current.localKey else { throw PeerAuthorizationError.invalidEvidence }
            if let previous = current.highWater {
                guard previous.groupID == snapshot.groupID, previous.generation == snapshot.generation,
                      snapshot.sequence >= previous.sequence else { throw PeerAuthorizationError.invalidEvidence }
                if previous.sequence == snapshot.sequence {
                    guard previous.headHash == snapshot.headHash,
                          Dictionary(uniqueKeysWithValues: previous.members.map { ($0.deviceID, $0.publicKey) }) == Dictionary(uniqueKeysWithValues: snapshot.members.map { ($0.deviceID, $0.publicKey) }) else { throw PeerAuthorizationError.invalidEvidence }
                }
            }
            keys.removeValue(forKey: local)
            current.highWater = snapshot; current.freshUntil = evidence.freshUntil; current.keys = keys
            account = current
            let id = UUID(); timerID = id
            return (id, evidence.freshUntil)
        }
        // Scheduling and cancellation are external operations, always unlocked.
        let cancellation = schedule(timer.1) { [weak self] in self?.expire() }
        let old = lock.withLock { () -> PeerDeadlineCancellation? in
            guard timerID == timer.0 else { return cancellation }
            let previous = cancelTimer; cancelTimer = cancellation; return previous
        }
        old?()
    }

    func invalidateAccount(_ epoch: PeerAccountEpoch) {
        try? transact { _ in if account?.epoch == epoch { account = nil } }
    }

    public func acquire(for peer: DeviceID) throws -> PeerAuthorizationLease {
        try transact { _ in
            guard let entry = effective[peer] else { throw PeerAuthorizationError.denied }
            return PeerAuthorizationLease(peer: peer, publicKey: entry.key, owner: identity, continuity: entry.continuity)
        }
    }

    public func validate(_ lease: PeerAuthorizationLease) throws {
        try transact { _ in guard isCurrent(lease) else { throw PeerAuthorizationError.denied } }
    }

    public func claim(_ lease: PeerAuthorizationLease, onInvalidation: @escaping @Sendable () -> Void) throws -> PeerAuthorizationRegistration {
        try transact { _ in
            guard isCurrent(lease) else { throw PeerAuthorizationError.denied }
            let id = UUID()
            registrations[id] = Registration(lease: lease, callback: onInvalidation)
            return PeerAuthorizationRegistration(owner: self, id: id)
        }
    }

    public func snapshot() -> PeerAuthorizationSnapshot {
        (try? transact { _ in projection() }) ?? PeerAuthorizationSnapshot(peers: [:], revision: lock.withLock { revision })
    }

    public func updates() -> AsyncStream<PeerAuthorizationSnapshot> {
        let (stream, continuation) = AsyncStream<PeerAuthorizationSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuation.onTermination = { [weak self] _ in self?.removeObserver(id) }
        lock.withLock { observers[id] = continuation }
        _ = snapshot() // Apply delayed expiry before the initial projection.
        publishCurrent()
        return stream
    }

    private func removeObserver(_ id: UUID) { _ = lock.withLock { observers.removeValue(forKey: id) } }
    private func projection() -> PeerAuthorizationSnapshot { PeerAuthorizationSnapshot(peers: effective.mapValues(\.key), revision: revision) }

    private func publishCurrent() {
        // Serialize discovery delivery separately. Refresh the projection after
        // taking this lock, so a delayed publisher cannot overwrite a newer one.
        publicationLock.withLock {
            let (value, sinks) = lock.withLock { (projection(), Array(observers.values)) }
            sinks.forEach { $0.yield(value) }
        }
    }

    func requireCurrent(_ id: UUID) throws {
        try transact { _ in guard let entry = registrations[id], isCurrent(entry.lease) else { throw PeerAuthorizationError.denied } }
    }
    func cancel(_ id: UUID) { _ = lock.withLock { registrations.removeValue(forKey: id) } }
    private func expire() { try? transact { _ in } }

    private func isCurrent(_ lease: PeerAuthorizationLease) -> Bool {
        lease.owner == identity && effective[lease.peer]?.continuity == lease.continuity && effective[lease.peer]?.key == lease.publicKey
    }

    /// Reconcile before admission and after mutations. Lost continuity never
    /// revives, including a conflict followed by a same-key restoration.
    private func reconcile() -> [@Sendable () -> Void] {
        let combined = PeerAuthorizationKeys.merge(manual: manual, account: account?.keys ?? [:])
        if combined != effective.mapValues(\.key) { revision &+= 1 }
        var next: [DeviceID: Effective] = [:]
        for (id, key) in combined {
            if let old = effective[id], old.key == key { next[id] = old }
            else { next[id] = Effective(key: key, continuity: UUID()) }
        }
        effective = next
        var calls: [@Sendable () -> Void] = []
        for (id, registration) in registrations where !isCurrent(registration.lease) {
            registrations.removeValue(forKey: id)
            calls.append(registration.callback)
        }
        return calls
    }

    private func transact<T>(_ body: (Date) throws -> T) throws -> T {
        lock.lock()
        let previousRevision = revision
        let date = now()
        if !Self.validDate(date) || account.map({ $0.accessExpiry <= date }) == true { account = nil }
        else if let deadline = account?.freshUntil, deadline <= date {
            account?.keys = [:]; account?.freshUntil = nil
        }
        var calls = reconcile()
        let result: Result<T, Error>
        if !Self.validDate(date) { result = .failure(PeerAuthorizationError.denied) }
        else { result = Result { try body(date) } }
        calls += reconcile()
        var cancellation: PeerDeadlineCancellation?
        if account?.freshUntil == nil {
            timerID = nil; cancellation = cancelTimer; cancelTimer = nil
        }
        lock.unlock()
        cancellation?()
        calls.forEach { $0() }
        if lock.withLock({ revision != previousRevision }) { publishCurrent() }
        return try result.get()
    }

    private static func validKey(_ key: Data, for id: DeviceID) -> Bool {
        (try? AccountGroupEvent.deviceID(publicKey: key)) == id.rawValue.uuidString.lowercased()
    }
    private static func validUUID(_ value: String) -> Bool {
        AccountGroupCheckpoint.canonicalUUID(value) && value != "00000000-0000-0000-0000-000000000000"
    }
    private static func validDate(_ value: Date) -> Bool { AccountServiceClient.validEpochMilliseconds(value) != nil }

    deinit {
        cancelTimer?()
        observers.values.forEach { $0.finish() }
        // Registrations hold only a weak owner; subsequent checks fail closed.
        registrations.values.forEach { $0.callback() }
    }
}

/// Pure direct-source union; never a transitive graph. Kept separate so conflict
/// semantics can be exercised without bypassing the owner's key/ID validation.
enum PeerAuthorizationKeys {
    static func merge(manual: [DeviceID: Data], account: [DeviceID: Data]) -> [DeviceID: Data] {
        var result = manual
        for (id, key) in account {
            if let old = manual[id], old != key { result.removeValue(forKey: id) }
            else { result[id] = key }
        }
        return result
    }
}
