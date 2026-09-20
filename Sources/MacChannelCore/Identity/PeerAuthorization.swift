import Foundation

public enum PeerAuthorizationError: Error, Equatable { case denied, invalidEvidence }

/// A discovery projection only. It never carries an admission capability.
public struct PeerAuthorizationSnapshot: Sendable {
    public let peers: [DeviceID: Data]
    public let revision: UInt64
}

public struct PeerAuthorizationLease: Sendable {
    public let peer: DeviceID
    public let publicKey: Data
    let owner: UUID
    let continuity: UUID
}

public protocol PeerAuthorizationProviding: Sendable {
    func acquire(for peer: DeviceID) throws -> PeerAuthorizationLease
    func validate(_ lease: PeerAuthorizationLease) throws
    func claim(_ lease: PeerAuthorizationLease, onInvalidation: @escaping @Sendable () -> Void) throws -> PeerAuthorizationRegistration
    func snapshot() -> PeerAuthorizationSnapshot
    func updates() -> AsyncStream<PeerAuthorizationSnapshot>
}

public final class PeerAuthorizationRegistration: @unchecked Sendable {
    weak var owner: PeerAuthorizationOwner?
    let id: UUID
    init(owner: PeerAuthorizationOwner, id: UUID) { self.owner = owner; self.id = id }
    public func requireCurrent() throws { guard let owner else { throw PeerAuthorizationError.denied }; try owner.requireCurrent(id) }
    public func cancel() { owner?.cancel(id) }
    deinit { cancel() }
}

/// Module-internal producer contract. The verified controller producer is not
/// wired in this slice; a UI snapshot cannot create public account authority.
struct PeerAccountEpoch: Equatable, Sendable { let owner: UUID; let id: UUID }
struct VerifiedPeerAccountEvidence: Sendable {
    let epoch: PeerAccountEpoch
    let binding: AccountSessionBinding
    let snapshot: AccountGroupSnapshot
    let freshUntil: Date
}

typealias PeerDeadlineCancellation = @Sendable () -> Void
/// Uses the injected clock's time domain; callback is delivered at/after the
/// deadline. Cancellation is idempotent and may race a callback. Implementations
/// must not retain the owner; the owner supplies a weak callback and also checks
/// time on every admission. No production freshness or timer is selected here.
typealias PeerDeadlineScheduler = @Sendable (Date, @escaping @Sendable () -> Void) -> PeerDeadlineCancellation
