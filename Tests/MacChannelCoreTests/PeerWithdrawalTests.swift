import Foundation
import XCTest
@testable import MacChannelCore

final class PeerWithdrawalTests: XCTestCase {
    func testWithdrawalPreservesOwnerAndUnrelatedPeerAcrossDurableReloadAndRepair() async throws {
        let owner = try DeviceIdentity.ephemeral(), peer = try DeviceIdentity.ephemeral()
        let third = try DeviceIdentity.ephemeral()
        let repository = try TrustRepository(ownerIdentity: owner,
            trustStore: TrustStore(owner: owner.id), persistedGeneration: 0)
        let local = try await repository.prepareAuthorization(subject: peer.id,
            subjectPublicKey: peer.publicKey.rawRepresentation, timestamp: Date())
        let remote = try SignedTrustRecord.authorizing(owner, signedBy: peer, sequence: 1)
        try await repository.commitBilateralPairing(localAuthorization: local, peerAuthorization: remote)
        let unrelated = try await repository.issueAuthorization(subject: third.id,
            subjectPublicKey: third.publicKey.rawRepresentation, timestamp: Date())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let secrets = WithdrawalSecrets()
        let disk = AuthenticatedTrustSnapshotStore(url: root.appendingPathComponent("trust.json"), secrets: secrets)
        let before = try await disk.persistLatestState(from: repository)
        let withdrawal = try SignedTrustRecord.revoking(owner.id,
            subjectPublicKey: owner.publicKey.rawRepresentation, signedBy: peer, sequence: 3)
        let accepted = try await repository.ingestIfNew(withdrawal)
        XCTAssertTrue(accepted)
        let trust = await repository.currentTrustStore()
        XCTAssertEqual(trust.trustedDeviceIDs, [owner.id, third.id])
        let ownerKey = await repository.publicKey(for: owner.id)
        XCTAssertEqual(ownerKey, owner.publicKey.rawRepresentation)
        let current = await repository.authenticationRecords()
        XCTAssertEqual(current, [unrelated], "A subject cannot publish its peer's revocation")
        let pending = await repository.publicationSnapshot(persisted: before)
        XCTAssertEqual(pending.records, [unrelated])
        XCTAssertTrue(pending.pendingPersistence)
        let saved = try await disk.persistLatestState(from: repository)
        let publication = await repository.publicationSnapshot(persisted: saved)
        XCTAssertEqual(publication.records, [unrelated])
        XCTAssertFalse(publication.pendingPersistence)
        XCTAssertEqual(Set(saved?.authenticationRecords ?? []), [withdrawal, unrelated])
        let loaded = try await disk.load(identity: owner)
        let restored = await loaded.currentTrustStore()
        XCTAssertEqual(restored.trustedDeviceIDs, [owner.id, third.id])
        XCTAssertEqual(restored.issuerSequence(for: peer.id), 3)
        let loadedProofs = await loaded.authenticationRecords()
        XCTAssertEqual(loadedProofs, [unrelated])
        let savedState = try XCTUnwrap(saved)
        let missingRetainedProof = await loaded.publicationSnapshot(persisted:
            AuthenticatedTrustState(snapshot: savedState.snapshot, authenticationRecords: [unrelated]))
        XCTAssertTrue(missingRetainedProof.pendingPersistence,
            "Reload must retain the negative proof even though wire export excludes it")
        // Legacy readers may discard unsupported auxiliary proof types. The
        // unchanged owner-signed snapshot still prevents trust resurrection.
        let legacy = try TrustRepository(ownerIdentity: owner, trustStore: restored,
            persistedGeneration: restored.persistedGeneration, authenticationRecords: [unrelated])
        let legacyReplay = try await legacy.ingestIfNew(withdrawal)
        XCTAssertFalse(legacyReplay)
        let legacyTrust = await legacy.currentTrustStore()
        XCTAssertEqual(legacyTrust.trustedDeviceIDs, [owner.id, third.id])
        let duplicate = try await loaded.ingestIfNew(withdrawal)
        let older = try SignedTrustRecord.revoking(owner.id,
            subjectPublicKey: owner.publicKey.rawRepresentation, signedBy: peer, sequence: 2)
        let replay = try await loaded.ingestIfNew(older)
        XCTAssertFalse(duplicate)
        XCTAssertFalse(replay)
        let newer = try SignedTrustRecord.revoking(owner.id,
            subjectPublicKey: owner.publicKey.rawRepresentation, signedBy: peer, sequence: 4)
        let repeatedWithdrawal = try await loaded.ingestIfNew(newer)
        XCTAssertTrue(repeatedWithdrawal)
        do {
            try await loaded.commitBilateralPairing(localAuthorization: local, peerAuthorization: remote)
            XCTFail("Old bilateral proofs must not restore trust")
        } catch TrustStoreError.nonIncreasingSequence(peer.id) { }
        let localRepair = try await loaded.prepareAuthorization(subject: peer.id,
            subjectPublicKey: peer.publicKey.rawRepresentation, timestamp: Date())
        let peerRepair = try SignedTrustRecord.authorizing(owner, signedBy: peer, sequence: 5)
        try await loaded.commitBilateralPairing(localAuthorization: localRepair, peerAuthorization: peerRepair)
        let repaired = await loaded.currentTrustStore()
        XCTAssertEqual(repaired.trustedDeviceIDs, [owner.id, peer.id, third.id])
        let repairedProofs = await loaded.authenticationRecords()
        XCTAssertEqual(Set(repairedProofs), [localRepair, peerRepair, unrelated])
        let staleWithdrawal = try await loaded.ingestIfNew(newer)
        XCTAssertFalse(staleWithdrawal)
        let afterReplay = await loaded.currentTrustStore()
        XCTAssertEqual(afterReplay.trustedDeviceIDs, repaired.trustedDeviceIDs)
    }

    func testInvalidWithdrawalsNeverMutateAndOrdinaryOwnerRevocationRemainsForbidden() async throws {
        let owner = try DeviceIdentity.ephemeral(), peer = try DeviceIdentity.ephemeral()
        let unknown = try DeviceIdentity.ephemeral()
        let repository = try TrustRepository(ownerIdentity: owner,
            trustStore: TrustStore(owner: owner.id), persistedGeneration: 0)
        _ = try await repository.issueAuthorization(subject: peer.id,
            subjectPublicKey: peer.publicKey.rawRepresentation, timestamp: Date())
        let valid = try SignedTrustRecord.revoking(owner.id,
            subjectPublicKey: owner.publicKey.rawRepresentation, signedBy: peer, sequence: 2)
        let forged = SignedTrustRecord(issuer: valid.issuer, issuerPublicKey: valid.issuerPublicKey,
            subject: valid.subject, subjectPublicKey: valid.subjectPublicKey, action: valid.action,
            issuerSequence: 20, epochMilliseconds: valid.epochMilliseconds, signature: valid.signature)
        let wrongKey = try SignedTrustRecord.revoking(owner.id,
            subjectPublicKey: unknown.publicKey.rawRepresentation, signedBy: peer, sequence: 3)
        let foreign = try SignedTrustRecord.revoking(owner.id,
            subjectPublicKey: owner.publicKey.rawRepresentation, signedBy: unknown, sequence: 3)
        let selfRevoke = try SignedTrustRecord.revoking(owner.id,
            subjectPublicKey: owner.publicKey.rawRepresentation, signedBy: owner, sequence: 3)
        let before = try await repository.latestSignedSnapshot()
        for record in [forged, wrongKey, foreign, selfRevoke] {
            do { try await repository.ingest(record); XCTFail("Invalid withdrawal accepted") }
            catch { }
            let after = try await repository.latestSignedSnapshot()
            XCTAssertEqual(after.signature, before.signature)
        }
        do { try await repository.revoke(owner.id); XCTFail("Owner self-revocation accepted") }
        catch TrustStoreError.cannotRevokeOwner { }
        var store = await repository.currentTrustStore()
        XCTAssertThrowsError(try store.ingest(valid)) {
            XCTAssertEqual($0 as? TrustStoreError, .cannotRevokeOwner)
        }
        // A reused signature with changed fields must not use duplicate fast-path.
        try await repository.ingest(valid)
        do { try await repository.ingest(forged); XCTFail("Altered duplicate accepted") }
        catch { }
        let withdrawn = try await repository.latestSignedSnapshot()
        let illicitAuthorization = try SignedTrustRecord.authorizing(unknown, signedBy: peer, sequence: 30)
        let illicitGraphRevoke = try SignedTrustRecord.revoking(unknown.id,
            subjectPublicKey: unknown.publicKey.rawRepresentation, signedBy: peer, sequence: 31)
        for record in [illicitAuthorization, illicitGraphRevoke, forged, wrongKey, foreign, selfRevoke] {
            do { try await repository.ingest(record); XCTFail("Withdrawn peer gained authority") }
            catch { }
            let after = try await repository.latestSignedSnapshot()
            XCTAssertEqual(after.signature, withdrawn.signature)
        }
    }
}

private final class WithdrawalSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func data(for account: String, policy: KeychainPolicy) throws -> Data? {
        lock.withLock { values[policy.service + ":" + account] }
    }
    func store(_ data: Data, for account: String, policy: KeychainPolicy) throws {
        lock.withLock { values[policy.service + ":" + account] = data }
    }
}
