import Foundation
import XCTest
@testable import MacChannelCore

final class TrustAuthenticationExportTests: XCTestCase {
    func testLiveGraphAuthorizationIsNotExportedAsOwnerAuthentication() async throws {
        let owner = try DeviceIdentity.ephemeral()
        let peer = try DeviceIdentity.ephemeral()
        let third = try DeviceIdentity.ephemeral()
        let repository = try TrustRepository(ownerIdentity: owner,
            trustStore: TrustStore(owner: owner.id), persistedGeneration: 0)
        let ownerProof = try await repository.issueAuthorization(subject: peer.id,
            subjectPublicKey: peer.publicKey.rawRepresentation, timestamp: Date())
        let graphProof = try SignedTrustRecord.authorizing(third, signedBy: peer, sequence: 1)

        let first = try await repository.ingestIfNew(graphProof)
        let repeated = try await repository.ingestIfNew(graphProof)
        let trusted = await repository.isTrusted(third.id)
        let records = await repository.authenticationRecords()
        XCTAssertTrue(first)
        XCTAssertFalse(repeated)
        XCTAssertTrue(trusted)
        XCTAssertEqual(records.map(\.signature), [ownerProof.signature])

        let snapshot = try await repository.latestSignedSnapshot()
        let restored = try TrustRepository(ownerIdentity: owner,
            trustStore: TrustStore(snapshot: snapshot, expectedOwner: owner,
                minimumGeneration: snapshot.generation),
            persistedGeneration: snapshot.generation, authenticationRecords: records)
        let restoredRecords = await restored.authenticationRecords()
        let restoredTrust = await restored.isTrusted(third.id)
        let restoredReplay = try await restored.ingestIfNew(graphProof)
        XCTAssertEqual(restoredRecords.map(\.signature), records.map(\.signature))
        XCTAssertTrue(restoredTrust)
        XCTAssertFalse(restoredReplay)
        XCTAssertEqual(snapshot.issuerSequences[peer.id], 1)
    }

    func testLiveGraphRevocationKeepsRevocationButIsNotAuthenticationProof() async throws {
        let owner = try DeviceIdentity.ephemeral()
        let peer = try DeviceIdentity.ephemeral()
        let third = try DeviceIdentity.ephemeral()
        let repository = try TrustRepository(ownerIdentity: owner,
            trustStore: TrustStore(owner: owner.id), persistedGeneration: 0)
        let ownerProof = try await repository.issueAuthorization(subject: peer.id,
            subjectPublicKey: peer.publicKey.rawRepresentation, timestamp: Date())
        try await repository.ingest(SignedTrustRecord.authorizing(third, signedBy: peer, sequence: 1))
        let revocation = try SignedTrustRecord.revoking(third.id,
            subjectPublicKey: third.publicKey.rawRepresentation, signedBy: peer, sequence: 2)
        try await repository.ingest(revocation)

        let trusted = await repository.isTrusted(third.id)
        let records = await repository.authenticationRecords()
        let snapshot = try await repository.latestSignedSnapshot()
        let repeated = try await repository.ingestIfNew(revocation)
        XCTAssertFalse(trusted)
        XCTAssertFalse(repeated)
        XCTAssertTrue(snapshot.revokedDevices.contains(third.id))
        XCTAssertEqual(snapshot.issuerSequences[peer.id], 2)
        XCTAssertEqual(records.map(\.signature), [ownerProof.signature])
    }
}
