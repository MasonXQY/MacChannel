import Foundation
import XCTest
@testable import MacChannelCore

final class NativeManualProducerTests: XCTestCase {
    func testReleasedExactTokenCannotWithdrawReplacementEvenWithInvalidClock() throws {
        let local = try DeviceIdentity.ephemeral(), peer = try DeviceIdentity.ephemeral()
        let clock = PeerTestBox(Date())
        let owner = PeerAuthorizationOwner(local: local.id, now: { clock.value }, schedule: { _, _ in {} })
        var store = TrustStore(owner: local.id)
        try store.authorize(SignedTrustRecord.authorizing(peer, signedBy: local, sequence: 1))
        let old = try owner.attachManual(identity: local, store: store)
        clock.update { $0 = Date(timeIntervalSince1970: .nan) }
        old.cancel()
        clock.update { $0 = Date() }
        let replacement = try owner.attachManual(identity: local, store: store)
        old.cancel()
        XCTAssertThrowsError(try old.replaceManual(TrustStore(owner: local.id)))
        XCTAssertNoThrow(try owner.acquire(for: peer.id))
        withExtendedLifetime(replacement) {}
    }

    func testInitialStoreOwnerMismatchAndDuplicateAttachment() async throws {
        let local = try DeviceIdentity.ephemeral(), peer = try DeviceIdentity.ephemeral()
        let owner = PeerAuthorizationOwner(local: local.id, now: Date.init, schedule: { _, _ in {} })
        var store = TrustStore(owner: local.id)
        try store.authorize(SignedTrustRecord.authorizing(peer, signedBy: local, sequence: 1))
        let repository = try TrustRepository(ownerIdentity: local, trustStore: store,
            persistedGeneration: 0, authorizationOwner: owner)
        XCTAssertNoThrow(try owner.acquire(for: peer.id))
        XCTAssertThrowsError(try TrustRepository(ownerIdentity: local, trustStore: TrustStore(owner: local.id),
            persistedGeneration: 0, authorizationOwner: owner))
        XCTAssertThrowsError(try TrustRepository(ownerIdentity: peer, trustStore: TrustStore(owner: peer.id),
            persistedGeneration: 0, authorizationOwner: owner))
        XCTAssertNoThrow(try owner.acquire(for: peer.id))
        _ = await repository.currentTrustStore()
    }

    func testPreparationRejectedCandidateAndNoOpNeverChangeAuthority() async throws {
        let local = try DeviceIdentity.ephemeral(), peer = try DeviceIdentity.ephemeral()
        let clock = PeerTestBox(Date())
        let owner = PeerAuthorizationOwner(local: local.id, now: { clock.value }, schedule: { _, _ in {} })
        let repository = try TrustRepository(ownerIdentity: local, trustStore: TrustStore(owner: local.id),
            persistedGeneration: 0, authorizationOwner: owner)
        let proof = try await repository.prepareAuthorization(subject: peer.id,
            subjectPublicKey: peer.publicKey.rawRepresentation, timestamp: Date())
        XCTAssertThrowsError(try owner.acquire(for: peer.id))
        do { _ = try await repository.issueAuthorization(subject: peer.id,
            subjectPublicKey: local.publicKey.rawRepresentation, timestamp: Date()); XCTFail("bad binding accepted") } catch {}
        XCTAssertThrowsError(try owner.acquire(for: peer.id))
        clock.update { $0 = Date(timeIntervalSince1970: .nan) }
        do { _ = try await repository.issueAuthorization(subject: peer.id,
            subjectPublicKey: peer.publicKey.rawRepresentation, timestamp: Date()); XCTFail("owner failure committed") } catch {}
        let changed = await repository.isTrusted(peer.id)
        XCTAssertFalse(changed)
        clock.update { $0 = Date() }
        let peerProof = try SignedTrustRecord.authorizing(local, signedBy: peer, sequence: 1)
        try await repository.commitBilateralPairing(localAuthorization: proof, peerAuthorization: peerProof)
        let lease = try owner.acquire(for: peer.id)
        try await repository.commitBilateralPairing(localAuthorization: proof, peerAuthorization: peerProof)
        let ingested = try await repository.ingestIfNew(peerProof)
        XCTAssertFalse(ingested)
        XCTAssertNoThrow(try owner.validate(lease))
    }

    func testBootstrapAndIngestUpdateOwnerBeforeReturning() async throws {
        let local = try DeviceIdentity.ephemeral(), peer = try DeviceIdentity.ephemeral(), third = try DeviceIdentity.ephemeral()
        let owner = PeerAuthorizationOwner(local: local.id, now: Date.init, schedule: { _, _ in {} })
        let repository = try TrustRepository(ownerIdentity: local, trustStore: TrustStore(owner: local.id),
            persistedGeneration: 0, authorizationOwner: owner)
        try await repository.bootstrapFromConfirmedPairing(SignedTrustRecord.authorizing(local, signedBy: peer, sequence: 1))
        XCTAssertNoThrow(try owner.acquire(for: peer.id))
        try await repository.ingest(SignedTrustRecord.authorizing(third, signedBy: peer, sequence: 2))
        XCTAssertNoThrow(try owner.acquire(for: third.id))
        try await repository.ingest(SignedTrustRecord.revoking(local.id, subjectPublicKey: local.publicKey.rawRepresentation,
            signedBy: peer, sequence: 3))
        XCTAssertThrowsError(try owner.acquire(for: peer.id))
    }

    func testRepositoryDeinitWithdrawsOnlyManualAndPermitsReplacement() async throws {
        let local = try DeviceIdentity.ephemeral(), peer = try DeviceIdentity.ephemeral()
        let owner = PeerAuthorizationOwner(local: local.id, now: Date.init, schedule: { _, _ in {} })
        var repository: TrustRepository? = try TrustRepository(ownerIdentity: local, trustStore: TrustStore(owner: local.id),
            persistedGeneration: 0, authorizationOwner: owner)
        _ = try await repository?.issueAuthorization(subject: peer.id,
            subjectPublicKey: peer.publicKey.rawRepresentation, timestamp: Date())
        let lease = try owner.acquire(for: peer.id)
        repository = nil
        XCTAssertThrowsError(try owner.validate(lease))
        let replacement = try TrustRepository(ownerIdentity: local, trustStore: TrustStore(owner: local.id),
            persistedGeneration: 0, authorizationOwner: owner)
        XCTAssertTrue(owner.snapshot().peers.isEmpty)
        _ = await replacement.currentTrustStore()
    }

    func testSuccessfulCommitImmediatelyGrantsAndRevokeInvalidatesRegistration() async throws {
        let local = try DeviceIdentity.ephemeral(), peer = try DeviceIdentity.ephemeral()
        let owner = PeerAuthorizationOwner(local: local.id, now: Date.init, schedule: { _, _ in {} })
        let repository = try TrustRepository(ownerIdentity: local, trustStore: TrustStore(owner: local.id),
            persistedGeneration: 0, authorizationOwner: owner)
        let proof = try await repository.issueAuthorization(subject: peer.id,
            subjectPublicKey: peer.publicKey.rawRepresentation, timestamp: Date())
        XCTAssertEqual(owner.snapshot().peers[peer.id], peer.publicKey.rawRepresentation)
        guard let lease = try? owner.acquire(for: peer.id) else { return XCTFail("successful repository commit must grant synchronously") }
        let calls = PeerTestBox(0)
        let registration = try owner.claim(lease) { calls.update { $0 += 1 } }
        let publication = await repository.publicationSnapshot(persisted: nil)
        XCTAssertTrue(publication.records.isEmpty)
        XCTAssertTrue(publication.pendingPersistence)
        let records = await repository.authenticationRecords()
        XCTAssertEqual(records.map(\.signature), [proof.signature])
        _ = try await repository.revoke(peer.id)
        XCTAssertEqual(calls.value, 1)
        XCTAssertThrowsError(try registration.requireCurrent())
        XCTAssertThrowsError(try owner.acquire(for: peer.id))
    }
}
