import Darwin
import Foundation

public enum AuthenticatedTrustSnapshotStoreError: Error, Equatable, Sendable {
    case invalidGeneration
}

public protocol TrustSnapshotPersisting: Sendable {
    func persistLatest(from repository: TrustRepository) async throws
}

/// Persists an owner-signed trust snapshot beside a monotonic generation
/// anchor kept in the device-only secret store.
public actor AuthenticatedTrustSnapshotStore<Secrets: SecretStore & Sendable>:
    TrustSnapshotPersisting
{
    private struct PersistedState: Codable {
        let version: Int
        let snapshot: TrustStoreSnapshot
        let authenticationRecords: [SignedTrustRecord]
    }

    private static var generationAccount: String { "trust-snapshot-generation" }

    private let url: URL
    private let secrets: Secrets
    private let policy: KeychainPolicy

    public init(
        url: URL,
        secrets: Secrets,
        policy: KeychainPolicy = KeychainStore.identityPolicy
    ) {
        self.url = url.standardizedFileURL
        self.secrets = secrets
        self.policy = policy
    }

    public func load(identity: DeviceIdentity) throws -> TrustRepository {
        let generation = try storedGeneration()
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            let decoded = try? JSONDecoder().decode(PersistedState.self, from: data)
            let snapshot =
                try decoded?.snapshot
                ?? JSONDecoder().decode(
                    TrustStoreSnapshot.self,
                    from: data
                )
            guard decoded == nil || decoded?.version == 1 else {
                throw AuthenticatedTrustSnapshotStoreError.invalidGeneration
            }
            let store = try TrustStore(
                snapshot: snapshot,
                expectedOwner: identity,
                minimumGeneration: generation
            )
            if snapshot.generation > generation {
                try storeGeneration(snapshot.generation)
            }
            return try TrustRepository(
                ownerIdentity: identity,
                trustStore: store,
                persistedGeneration: snapshot.generation,
                authenticationRecords: decoded?.authenticationRecords ?? []
            )
        }
        guard generation == 0 else {
            throw AuthenticatedTrustSnapshotStoreError.invalidGeneration
        }
        return try TrustRepository(
            ownerIdentity: identity,
            trustStore: TrustStore(owner: identity.id),
            persistedGeneration: 0
        )
    }

    public func persistLatest(from repository: TrustRepository) async throws {
        guard let snapshot = try? await repository.latestSignedSnapshot() else { return }
        let state = PersistedState(
            version: 1,
            snapshot: snapshot,
            authenticationRecords: await repository.authenticationRecords()
        )
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: .atomic)
        guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else {
            throw AuthenticatedTrustSnapshotStoreError.invalidGeneration
        }
        try storeGeneration(snapshot.generation)
    }

    private func storedGeneration() throws -> UInt64 {
        guard let data = try secrets.data(for: Self.generationAccount, policy: policy)
        else { return 0 }
        guard data.count == MemoryLayout<UInt64>.size else {
            throw AuthenticatedTrustSnapshotStoreError.invalidGeneration
        }
        return data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private func storeGeneration(_ generation: UInt64) throws {
        let data = Data(
            (0..<8).reversed().map { shift in
                UInt8(truncatingIfNeeded: generation >> UInt64(shift * 8))
            })
        try secrets.store(data, for: Self.generationAccount, policy: policy)
    }
}
