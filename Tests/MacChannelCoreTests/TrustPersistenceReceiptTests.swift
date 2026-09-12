import Foundation
import XCTest
@testable import MacChannelCore

final class TrustPersistenceReceiptTests: XCTestCase {
    func testRepeatedCheckpointRetainsExistingWriteAndFailureSemantics() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.remove() }
        _ = try await fixture.authorize(DeviceIdentity.ephemeral())
        try await fixture.store.persistLatest(from: fixture.repository)
        fixture.secrets.failAnchor = true
        do {
            try await fixture.store.persistLatest(from: fixture.repository)
            XCTFail("Existing Void callers must still run their requested checkpoint")
        } catch ReceiptSecrets.Failure.anchor { }
    }

    func testNoSnapshotProducesNoReceiptOrDurableBaseline() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.remove() }
        let receipt = try await fixture.store.persistLatestState(from: fixture.repository)
        XCTAssertNil(receipt)
        let current = await fixture.store.persistedState()
        XCTAssertNil(current)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.path))
    }

    func testReceiptAndReloadExposeOnlyAnchoredSignedState() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.remove() }
        let peer = try DeviceIdentity.ephemeral()
        let record = try await fixture.authorize(peer)
        fixture.secrets.failAnchor = true
        do {
            _ = try await fixture.store.persistLatestState(from: fixture.repository)
            XCTFail("Expected anchor failure")
        } catch ReceiptSecrets.Failure.anchor { }
        let failed = await fixture.store.persistedState()
        XCTAssertNil(failed, "A written file alone is not an anchored receipt")
        fixture.secrets.failAnchor = false
        let result = try await fixture.store.persistLatestState(from: fixture.repository)
        let saved = try XCTUnwrap(result)
        XCTAssertEqual(saved.snapshot.trustedPublicKeys[peer.id], peer.publicKey.rawRepresentation)
        XCTAssertEqual(saved.authenticationRecords.map(\.signature), [record.signature])
        let reloaded = AuthenticatedTrustSnapshotStore(url: fixture.url, secrets: fixture.secrets)
        _ = try await reloaded.load(identity: fixture.identity)
        let baseline = await reloaded.persistedState()
        XCTAssertEqual(baseline?.snapshot.signature, saved.snapshot.signature)
        XCTAssertEqual(baseline?.authenticationRecords.map(\.signature), [record.signature])
    }

    func testConcurrentMutationAndSavesNeverRegressDurableGeneration() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.remove() }
        let peers = try (0..<12).map { _ in try DeviceIdentity.ephemeral() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for peer in peers {
                group.addTask {
                    _ = try await fixture.authorize(peer)
                    _ = try await fixture.store.persistLatestState(from: fixture.repository)
                }
            }
            try await group.waitForAll()
        }
        let latest = try await fixture.repository.latestSignedSnapshot()
        let receipt = await fixture.store.persistedState()
        XCTAssertEqual(receipt?.snapshot.generation, latest.generation)
        XCTAssertEqual(receipt?.snapshot.trustedPublicKeys.count, peers.count + 1)
        let reloaded = AuthenticatedTrustSnapshotStore(url: fixture.url, secrets: fixture.secrets)
        let repository = try await reloaded.load(identity: fixture.identity)
        let loaded = await repository.currentTrustStore()
        XCTAssertEqual(loaded.persistedGeneration, latest.generation)
        XCTAssertEqual(loaded.trustedDeviceIDs, Set(peers.map(\.id)).union([fixture.identity.id]))
    }

    func testOlderCaptureCannotReplaceNewerCheckpoint() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.remove() }
        let older = try TrustRepository(ownerIdentity: fixture.identity,
            trustStore: TrustStore(owner: fixture.identity.id), persistedGeneration: 0)
        let peer = try DeviceIdentity.ephemeral()
        _ = try await older.issueAuthorization(subject: peer.id,
            subjectPublicKey: peer.publicKey.rawRepresentation, timestamp: Date())
        _ = try await fixture.authorize(peer)
        _ = try await fixture.repository.revoke(peer.id)
        let newer = try await fixture.store.persistLatestState(from: fixture.repository)
        let late = try await fixture.store.persistLatestState(from: older)
        XCTAssertEqual(late?.snapshot.signature, newer?.snapshot.signature)
        let reloaded = AuthenticatedTrustSnapshotStore(url: fixture.url, secrets: fixture.secrets)
        let repository = try await reloaded.load(identity: fixture.identity)
        let trusted = await repository.isTrusted(peer.id)
        XCTAssertFalse(trusted, "Late older capture must not roll back disk or its generation anchor")
    }
}

private struct ReceiptFixture: Sendable {
    let root: URL
    let url: URL
    let identity: DeviceIdentity
    let secrets: ReceiptSecrets
    let repository: TrustRepository
    let store: AuthenticatedTrustSnapshotStore<ReceiptSecrets>
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        url = root.appendingPathComponent("trust.json")
        identity = try DeviceIdentity.ephemeral()
        secrets = ReceiptSecrets()
        repository = try TrustRepository(ownerIdentity: identity,
            trustStore: TrustStore(owner: identity.id), persistedGeneration: 0)
        store = AuthenticatedTrustSnapshotStore(url: url, secrets: secrets)
    }
    func authorize(_ peer: DeviceIdentity) async throws -> SignedTrustRecord {
        try await repository.issueAuthorization(subject: peer.id,
            subjectPublicKey: peer.publicKey.rawRepresentation, timestamp: Date())
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class ReceiptSecrets: SecretStore, @unchecked Sendable {
    enum Failure: Error { case anchor }
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var failing = false
    var failAnchor: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }
    func data(for account: String, policy: KeychainPolicy) throws -> Data? {
        lock.withLock { values[policy.service + ":" + account] }
    }
    func store(_ data: Data, for account: String, policy: KeychainPolicy) throws {
        try lock.withLock {
            if account == "trust-snapshot-generation", failing { throw Failure.anchor }
            values[policy.service + ":" + account] = data
        }
    }
}
