import Foundation
import XCTest
@testable import MacChannelCore

final class TrustPersistenceReceiptTests: XCTestCase {
    func testLegacySnapshotWithNoAuxiliaryProofNeverFabricatesPublication() async throws {
        let f = try ReceiptFixture(); defer { f.remove() }
        _ = try await f.authorize(try DeviceIdentity.ephemeral())
        let snapshot = try await f.repository.latestSignedSnapshot()
        try JSONEncoder().encode(snapshot).write(to: f.url)
        let loaded = try await f.store.load(identity: f.identity)
        let result = await loaded.publicationSnapshot(persisted: f.store.persistedState())
        XCTAssertTrue(result.records.isEmpty)
        XCTAssertFalse(result.pendingPersistence, "No unsaved current proof exists to retry")
        let trusted = await loaded.currentTrustStore().trustedDeviceIDs
        XCTAssertEqual(trusted.count, 2, "Loading must not erase existing trust to fabricate sync success")
    }

    func testPublicationWaitsForSuccessfulReceiptAndKeepsUnrelatedSavedProofs() async throws {
        let f = try ReceiptFixture(); defer { f.remove() }
        let first = try DeviceIdentity.ephemeral(), second = try DeviceIdentity.ephemeral()
        let a = try await f.authorize(first)
        let unsaved = await publication(f.repository, receipt: nil)
        XCTAssertTrue(unsaved.isEmpty)
        try await f.store.persistLatest(from: f.repository)
        let saved = await f.store.persistedState()
        _ = try await f.authorize(second)
        f.secrets.failAnchor = true
        do { try await f.store.persistLatest(from: f.repository); XCTFail("Expected failure") }
        catch ReceiptSecrets.Failure.anchor { }
        let partial = await publication(f.repository, receipt: saved)
        XCTAssertEqual(partial.map(\.signature), [a.signature])
        f.secrets.failAnchor = false
        try await f.store.persistLatest(from: f.repository)
        let all = await publication(f.repository, receipt: f.store.persistedState())
        XCTAssertEqual(all.count, 2)
    }

    func testPublicationNeverRestoresRevokedProofFromOlderReceipt() async throws {
        let f = try ReceiptFixture(); defer { f.remove() }
        let peer = try DeviceIdentity.ephemeral()
        _ = try await f.authorize(peer)
        try await f.store.persistLatest(from: f.repository)
        let older = await f.store.persistedState()
        let revoke = try await f.repository.revoke(peer.id)
        let pending = await publication(f.repository, receipt: older)
        XCTAssertTrue(pending.isEmpty)
        try await f.store.persistLatest(from: f.repository)
        let saved = await publication(f.repository, receipt: f.store.persistedState())
        XCTAssertEqual(saved.map(\.signature), [revoke.signature])
        let stale = await publication(f.repository, receipt: older)
        XCTAssertTrue(stale.isEmpty)
    }

    func testPublicationExcludesWrongOwnerFutureGenerationAndReusedSignatureContent() async throws {
        let f = try ReceiptFixture(), other = try ReceiptFixture()
        defer { f.remove(); other.remove() }
        let peer = try DeviceIdentity.ephemeral()
        let record = try await f.authorize(peer)
        _ = try await other.authorize(peer)
        let foreignSnapshot = try await other.repository.latestSignedSnapshot()
        let foreign = await publication(f.repository, receipt: AuthenticatedTrustState(
            snapshot: foreignSnapshot, authenticationRecords: [record]))
        XCTAssertTrue(foreign.isEmpty)
        let snapshot = try await f.repository.latestSignedSnapshot()
        let altered = SignedTrustRecord(issuer: record.issuer, issuerPublicKey: record.issuerPublicKey,
            subject: record.subject, subjectPublicKey: record.subjectPublicKey, action: .revoke,
            issuerSequence: record.issuerSequence, epochMilliseconds: record.epochMilliseconds,
            signature: record.signature)
        let reused = await publication(f.repository, receipt: AuthenticatedTrustState(
            snapshot: snapshot, authenticationRecords: [altered]))
        XCTAssertTrue(reused.isEmpty)
        let oldStore = await f.repository.currentTrustStore()
        let olderRepository = try TrustRepository(ownerIdentity: f.identity, trustStore: oldStore,
            persistedGeneration: oldStore.persistedGeneration, authenticationRecords: [record])
        _ = try await f.authorize(try DeviceIdentity.ephemeral())
        let futureSnapshot = try await f.repository.latestSignedSnapshot()
        let future = await publication(olderRepository, receipt: AuthenticatedTrustState(
            snapshot: futureSnapshot, authenticationRecords: [record]))
        XCTAssertTrue(future.isEmpty)
    }

    private func publication(_ repository: TrustRepository, receipt: AuthenticatedTrustState?) async -> [SignedTrustRecord] {
        await repository.publicationSnapshot(persisted: receipt).records
    }

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
