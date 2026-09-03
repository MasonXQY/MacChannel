import Darwin
import Foundation

public enum AuthenticatedTrustSnapshotStoreError: Error, Equatable, Sendable {
    case invalidGeneration
    case invalidIssuerSequence
    case invalidIssuerSequenceLock
    case issuerSequenceExhausted
}

public protocol TrustSnapshotPersisting: Sendable {
    func persistLatest(from repository: TrustRepository) async throws
}

private final class DurableIssuerSequenceReserver<Secrets: SecretStore & Sendable>:
    IssuerSequenceReserving, @unchecked Sendable
{
    private let secrets: Secrets
    private let policy: KeychainPolicy
    private let lockURL: URL
    private let account = "trust-issuer-sequence"

    init(secrets: Secrets, policy: KeychainPolicy, lockURL: URL) {
        self.secrets = secrets
        self.policy = policy
        self.lockURL = lockURL
    }

    func reserveIssuerSequence(after floor: UInt64) throws -> UInt64 {
        try withExclusiveFileLock {
            let stored: UInt64
            if let data = try secrets.data(for: account, policy: policy) {
                guard data.count == MemoryLayout<UInt64>.size else {
                    throw AuthenticatedTrustSnapshotStoreError.invalidIssuerSequence
                }
                stored = data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            } else {
                stored = 0
            }
            let base = max(stored, floor)
            guard base < UInt64.max else {
                throw AuthenticatedTrustSnapshotStoreError.issuerSequenceExhausted
            }
            let reserved = base + 1
            let data = Data(
                (0..<8).reversed().map { shift in
                    UInt8(truncatingIfNeeded: reserved >> UInt64(shift * 8))
                })
            try secrets.store(data, for: account, policy: policy)
            return reserved
        }
    }

    private func withExclusiveFileLock<T>(_ operation: () throws -> T) throws -> T {
        let descriptor = Darwin.open(
            lockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw AuthenticatedTrustSnapshotStoreError.invalidIssuerSequenceLock
        }
        defer { _ = Darwin.close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == geteuid(),
              information.st_nlink == 1,
              fchmod(descriptor, S_IRUSR | S_IWUSR) == 0
        else {
            throw AuthenticatedTrustSnapshotStoreError.invalidIssuerSequenceLock
        }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw AuthenticatedTrustSnapshotStoreError.invalidIssuerSequenceLock
            }
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }
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
    private let issuerSequenceReserver: DurableIssuerSequenceReserver<Secrets>

    public init(
        url: URL,
        secrets: Secrets,
        policy: KeychainPolicy = KeychainStore.identityPolicy
    ) {
        self.url = url.standardizedFileURL
        self.secrets = secrets
        self.policy = policy
        issuerSequenceReserver = DurableIssuerSequenceReserver(
            secrets: secrets,
            policy: policy,
            lockURL: url.appendingPathExtension("issuer-sequence.lock")
        )
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
                authenticationRecords: decoded?.authenticationRecords ?? [],
                issuerSequenceReserver: issuerSequenceReserver
            )
        }
        guard generation == 0 else {
            throw AuthenticatedTrustSnapshotStoreError.invalidGeneration
        }
        return try TrustRepository(
            ownerIdentity: identity,
            trustStore: TrustStore(owner: identity.id),
            persistedGeneration: 0,
            issuerSequenceReserver: issuerSequenceReserver
        )
    }

    /// Reserves before signing so a record exposed to a peer is never reused,
    /// even if local app data is later rebuilt or the system clock moves back.
    public func reserveIssuerSequence(after floor: UInt64) throws -> UInt64 {
        try issuerSequenceReserver.reserveIssuerSequence(after: floor)
    }

    public func persistLatest(from repository: TrustRepository) async throws {
        guard let repositoryState = try? await repository.persistenceState() else { return }
        let persistedState = PersistedState(
            version: 1,
            snapshot: repositoryState.snapshot,
            authenticationRecords: repositoryState.authenticationRecords
        )
        let data = try JSONEncoder().encode(persistedState)
        try data.write(to: url, options: .atomic)
        guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else {
            throw AuthenticatedTrustSnapshotStoreError.invalidGeneration
        }
        try storeGeneration(repositoryState.snapshot.generation)
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
        try storeUInt64(generation, account: Self.generationAccount)
    }

    private func storeUInt64(_ value: UInt64, account: String) throws {
        let data = Data(
            (0..<8).reversed().map { shift in
                UInt8(truncatingIfNeeded: value >> UInt64(shift * 8))
            })
        try secrets.store(data, for: account, policy: policy)
    }
}
