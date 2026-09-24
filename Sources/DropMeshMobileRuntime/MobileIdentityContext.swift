import Darwin
import Foundation
import MacChannelCore

public enum MobileIdentityRecoveryError: Error, Equatable, Sendable {
    case orphanedInstallation
    case conditionChanged
}

/// Recognizes the one safe reinstall mismatch: the device-only trust
/// generation survived in Keychain while every corresponding container
/// checkpoint was removed. It never treats corrupt or partial state as a
/// recoverable reinstall.
public enum MobileIdentityRecovery {
    private static let generationAccount = "trust-snapshot-generation"

    public static func recreateOrphanedIdentity<Secrets: SecretStore>(
        layout: MobileStorageLayout,
        secrets: Secrets,
        erase: () throws -> Void
    ) throws {
        guard try isOrphanedInstallation(layout: layout, secrets: secrets) else {
            throw MobileIdentityRecoveryError.conditionChanged
        }
        try erase()
    }

    static func isOrphanedInstallation<Secrets: SecretStore>(
        layout: MobileStorageLayout,
        secrets: Secrets
    ) throws -> Bool {
        guard let generation = try secrets.data(
            for: generationAccount,
            policy: MobileIdentityPolicy.policy
        ), generation.count == MemoryLayout<UInt64>.size,
              generation.contains(where: { $0 != 0 })
        else { return false }
        let stateFiles = [
            layout.trustFile,
            layout.trustFile.appendingPathExtension("issuer-sequence.lock"),
            layout.transferDatabaseFile,
            URL(fileURLWithPath: layout.transferDatabaseFile.path + "-wal"),
            URL(fileURLWithPath: layout.transferDatabaseFile.path + "-shm"),
        ]
        return stateFiles.allSatisfy(isDefinitelyAbsent)
    }

    private static func isDefinitelyAbsent(_ url: URL) -> Bool {
        var information = stat()
        if lstat(url.path, &information) == 0 { return false }
        return errno == ENOENT
    }
}

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
    public let authorizationOwner: PeerAuthorizationOwner
    public let layout: MobileStorageLayout
    private let snapshots: AuthenticatedTrustSnapshotStore<Secrets>

    public static func load(layout: MobileStorageLayout, secrets: Secrets) async throws -> Self {
        try layout.prepare()
        if try MobileIdentityRecovery.isOrphanedInstallation(layout: layout, secrets: secrets) {
            throw MobileIdentityRecoveryError.orphanedInstallation
        }
        let identity = try DeviceIdentity.loadOrCreate(keychain: secrets, policy: MobileIdentityPolicy.policy)
        let authorizationOwner = PeerAuthorizationOwner.live(identity: identity)
        let snapshots = AuthenticatedTrustSnapshotStore(
            url: layout.trustFile, secrets: secrets, policy: MobileIdentityPolicy.policy
        )
        // Trust or keychain errors propagate. Never repair corruption by resetting identity.
        let repository = try await snapshots.load(identity: identity, authorizationOwner: authorizationOwner)
        return Self(identity: identity, repository: repository, authorizationOwner: authorizationOwner,
            layout: layout, snapshots: snapshots)
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
