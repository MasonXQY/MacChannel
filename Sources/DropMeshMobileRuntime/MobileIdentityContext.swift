import Foundation
import MacChannelCore

public enum MobileIdentityPolicy {
    /// This namespace is private to the mobile runtime, not an App Store registration.
    public static let policy = KeychainPolicy(
        service: "com.zensystech.dropmesh.mobile.identity",
        accessGroup: nil,
        accessibility: .afterFirstUnlockThisDeviceOnly,
        synchronizable: false
    )
}

/// Bootstrap once per app process. Caller owns pairing lifecycle and persistence
/// checkpoints; constructing this value never starts a network connection.
public struct MobileIdentityContext<Secrets: SecretStore & Sendable>: Sendable {
    public let identity: DeviceIdentity
    public let repository: TrustRepository
    public let layout: MobileStorageLayout
    private let snapshots: AuthenticatedTrustSnapshotStore<Secrets>

    public static func load(layout: MobileStorageLayout, secrets: Secrets) async throws -> Self {
        try layout.prepare()
        let identity = try DeviceIdentity.loadOrCreate(keychain: secrets, policy: MobileIdentityPolicy.policy)
        let snapshots = AuthenticatedTrustSnapshotStore(
            url: layout.trustFile, secrets: secrets, policy: MobileIdentityPolicy.policy
        )
        // Trust or keychain errors propagate. Never repair corruption by resetting identity.
        let repository = try await snapshots.load(identity: identity)
        return Self(identity: identity, repository: repository, layout: layout, snapshots: snapshots)
    }

    public func persistTrust() async throws {
        _ = try await persistTrustState()
    }

    public func persistTrustState() async throws -> AuthenticatedTrustState? {
        try await snapshots.persistLatestState(from: repository)
    }

    public func persistedTrustState() async -> AuthenticatedTrustState? {
        await snapshots.persistedState()
    }

    public func trustPublicationSnapshot() async -> TrustPublicationSnapshot {
        await repository.publicationSnapshot(persisted: snapshots.persistedState())
    }

    public func persistedTrustUpdates() async -> AsyncStream<AuthenticatedTrustState?> {
        await snapshots.persistedUpdates()
    }

    public func makePairingSession(
        displayName: String, transport: any PairingTransport
    ) throws -> MobilePairingSession {
        let coordinator = try makePairingCoordinator(displayName: displayName, transport: transport)
        return MobilePairingSession(coordinator: coordinator, persistTrust: { try await self.persistTrust() })
    }

    public func makePairingCoordinator(
        displayName: String, transport: any PairingTransport
    ) throws -> PairingCoordinator {
        try PairingCoordinator(
            identity: identity, displayName: displayName,
            trustRepository: repository, transport: transport
        )
    }
}
