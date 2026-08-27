import CryptoKit
import Foundation
import XCTest

@testable import MacChannelCore

final class IdentityTests: XCTestCase {
    func testIdentityPersistsAndSigns() throws {
        let keychain = MemorySecretStore()
        let first = try DeviceIdentity.loadOrCreate(keychain: keychain)
        let second = try DeviceIdentity.loadOrCreate(keychain: keychain)
        let message = Data("challenge".utf8)

        XCTAssertEqual(first.id, second.id)
        XCTAssertTrue(try second.publicKey.isValidSignature(first.sign(message), for: message))
    }

    func testAuthenticatedTrustSnapshotStoreReopensSignedTrustFromDisk() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = MemorySecretStore()
        let identity = try DeviceIdentity.loadOrCreate(keychain: secrets)
        let peer = try DeviceIdentity.ephemeral()
        let firstStore = AuthenticatedTrustSnapshotStore(
            url: directory.appendingPathComponent("trust.json"),
            secrets: secrets
        )
        let firstRepository = try await firstStore.load(identity: identity)
        _ = try await firstRepository.issueAuthorization(
            subject: peer.id,
            subjectPublicKey: peer.publicKey.rawRepresentation,
            timestamp: Date()
        )
        try await firstStore.persistLatest(from: firstRepository)

        let reopenedStore = AuthenticatedTrustSnapshotStore(
            url: directory.appendingPathComponent("trust.json"),
            secrets: secrets
        )
        let reopenedRepository = try await reopenedStore.load(identity: identity)
        let reopenedPeerKey = await reopenedRepository.publicKey(for: peer.id)
        let authenticationRecords = await reopenedRepository.authenticationRecords()

        XCTAssertNotEqual(ObjectIdentifier(firstRepository), ObjectIdentifier(reopenedRepository))
        XCTAssertEqual(reopenedPeerKey, peer.publicKey.rawRepresentation)
        XCTAssertEqual(authenticationRecords.count, 1)
        XCTAssertEqual(authenticationRecords.first?.subject, peer.id)
    }

    func testAuthenticatedTrustSnapshotStoreRejectsStaleAuthorizationForRevokedPeer() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("trust.json")
        let secrets = MemorySecretStore()
        let identity = try DeviceIdentity.loadOrCreate(keychain: secrets)
        let peer = try DeviceIdentity.ephemeral()
        let store = AuthenticatedTrustSnapshotStore(url: url, secrets: secrets)
        let repository = try await store.load(identity: identity)
        let staleAuthorization = try await repository.issueAuthorization(
            subject: peer.id,
            subjectPublicKey: peer.publicKey.rawRepresentation,
            timestamp: Date()
        )
        _ = try await repository.revoke(peer.id)
        try await store.persistLatest(from: repository)

        var persisted = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        persisted["authenticationRecords"] = [
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(staleAuthorization))
        ]
        try JSONSerialization.data(withJSONObject: persisted, options: [.sortedKeys])
            .write(to: url, options: .atomic)

        let reopened = AuthenticatedTrustSnapshotStore(url: url, secrets: secrets)
        do {
            _ = try await reopened.load(identity: identity)
            XCTFail("A revoked snapshot must not accept an older signed authorization proof")
        } catch {
            XCTAssertEqual(error as? TrustRepositoryError, .invalidOwner)
        }
    }

    func testRevokedDeviceIsNoLongerTrusted() throws {
        let owner = try DeviceIdentity.ephemeral()
        let peer = try DeviceIdentity.ephemeral()
        var store = TrustStore(owner: owner.id)

        try store.authorize(SignedTrustRecord.authorizing(peer, signedBy: owner))
        _ = try store.revoke(peer.id, signedBy: owner)

        XCTAssertFalse(store.isTrusted(peer.id))
    }

    func testTrustRepositoryReturnsOnlyCurrentlyTrustedIdentityKeys() async throws {
        let owner = try DeviceIdentity.ephemeral()
        let peer = try DeviceIdentity.ephemeral()
        let repository = try TrustRepository(
            ownerIdentity: owner,
            trustStore: TrustStore(owner: owner.id),
            persistedGeneration: 0
        )
        _ = try await repository.issueAuthorization(
            subject: peer.id,
            subjectPublicKey: peer.publicKey.rawRepresentation,
            timestamp: Date()
        )

        let ownerKey = await repository.publicKey(for: owner.id)
        let peerKey = await repository.publicKey(for: peer.id)
        _ = try await repository.revoke(peer.id)
        let revokedKey = await repository.publicKey(for: peer.id)

        XCTAssertEqual(ownerKey, owner.publicKey.rawRepresentation)
        XCTAssertEqual(peerKey, peer.publicKey.rawRepresentation)
        XCTAssertNil(revokedKey)
    }

    func testInboundRevocationIsAppliedOnAnotherTrustStore() throws {
        let owner = try DeviceIdentity.ephemeral()
        let peer = try DeviceIdentity.ephemeral()
        let authorization = try SignedTrustRecord.authorizing(peer, signedBy: owner)
        var localStore = TrustStore(owner: owner.id)
        var receivingStore = TrustStore(owner: owner.id)

        try localStore.ingest(authorization)
        try receivingStore.ingest(authorization)
        let revocation = try localStore.revoke(peer.id, signedBy: owner)
        try receivingStore.ingest(revocation)

        XCTAssertFalse(receivingStore.isTrusted(peer.id))
    }

    func testRestoredStoreRejectsLowerSequenceAfterRestart() throws {
        let owner = try DeviceIdentity.ephemeral()
        let firstPeer = try DeviceIdentity.ephemeral()
        let secondPeer = try DeviceIdentity.ephemeral()
        var store = TrustStore(owner: owner.id)

        try store.ingest(SignedTrustRecord.authorizing(firstPeer, signedBy: owner, sequence: 2))
        let snapshot = try JSONDecoder().decode(
            TrustStoreSnapshot.self,
            from: JSONEncoder().encode(try store.snapshot(signedBy: owner))
        )
        var restored = try TrustStore(
            snapshot: snapshot,
            expectedOwner: owner,
            minimumGeneration: 0
        )

        XCTAssertThrowsError(
            try restored.ingest(
                SignedTrustRecord.authorizing(secondPeer, signedBy: owner, sequence: 1)
            )
        )
    }

    func testRestoredStoreRetainsRevocation() throws {
        let owner = try DeviceIdentity.ephemeral()
        let peer = try DeviceIdentity.ephemeral()
        var store = TrustStore(owner: owner.id)

        try store.ingest(SignedTrustRecord.authorizing(peer, signedBy: owner))
        _ = try store.revoke(peer.id, signedBy: owner)
        let snapshot = try JSONDecoder().decode(
            TrustStoreSnapshot.self,
            from: JSONEncoder().encode(try store.snapshot(signedBy: owner))
        )
        let restored = try TrustStore(
            snapshot: snapshot,
            expectedOwner: owner,
            minimumGeneration: 0
        )

        XCTAssertFalse(restored.isTrusted(peer.id))
        XCTAssertTrue(snapshot.revokedDevices.contains(peer.id))
    }

    func testExtremeTimestampIsRejectedWithTypedValidationError() throws {
        let owner = try DeviceIdentity.ephemeral()
        let peer = try DeviceIdentity.ephemeral()
        XCTAssertThrowsError(
            try SignedTrustRecord.authorizing(
                peer,
                signedBy: owner,
                timestamp: Date(timeIntervalSince1970: .infinity)
            )
        ) { error in
            XCTAssertEqual(error as? TrustRecordValidationError, .invalidTimestamp)
        }
    }

    func testAuthorizationRejectsInvalidSubjectPublicKey() throws {
        let owner = try DeviceIdentity.ephemeral()
        let peer = try DeviceIdentity.ephemeral()
        let validRecord = try SignedTrustRecord.authorizing(peer, signedBy: owner)
        let invalidRecord = SignedTrustRecord(
            issuer: validRecord.issuer,
            issuerPublicKey: validRecord.issuerPublicKey,
            subject: validRecord.subject,
            subjectPublicKey: Data("not-a-p256-key".utf8),
            action: validRecord.action,
            issuerSequence: validRecord.issuerSequence,
            epochMilliseconds: validRecord.epochMilliseconds,
            signature: validRecord.signature
        )
        var store = TrustStore(owner: owner.id)

        XCTAssertThrowsError(try store.ingest(invalidRecord)) { error in
            XCTAssertEqual(error as? TrustRecordValidationError, .invalidSubjectPublicKey)
        }
    }

    func testAuthorizationRejectsTamperedSubject() throws {
        let owner = try DeviceIdentity.ephemeral()
        let peer = try DeviceIdentity.ephemeral()
        let validRecord = try SignedTrustRecord.authorizing(peer, signedBy: owner)
        let tamperedRecord = SignedTrustRecord(
            issuer: validRecord.issuer,
            issuerPublicKey: validRecord.issuerPublicKey,
            subject: DeviceID(rawValue: UUID()),
            subjectPublicKey: validRecord.subjectPublicKey,
            action: validRecord.action,
            issuerSequence: validRecord.issuerSequence,
            epochMilliseconds: validRecord.epochMilliseconds,
            signature: validRecord.signature
        )
        var store = TrustStore(owner: owner.id)

        XCTAssertThrowsError(try store.ingest(tamperedRecord)) { error in
            XCTAssertEqual(error as? TrustRecordValidationError, .invalidSubjectIdentity)
        }
    }

    func testIdentityRequestsDeviceOnlyNonSynchronizableKeychainPolicy() throws {
        let keychain = MemorySecretStore()

        _ = try DeviceIdentity.loadOrCreate(keychain: keychain)

        XCTAssertEqual(
            keychain.requestedPolicies,
            [KeychainStore.identityPolicy, KeychainStore.identityPolicy])
    }

    func testAuthorizationRejectsInvalidSignature() throws {
        let owner = try DeviceIdentity.ephemeral()
        let peer = try DeviceIdentity.ephemeral()
        let record = try SignedTrustRecord.authorizing(peer, signedBy: owner)
        let invalidRecord = SignedTrustRecord(
            issuer: record.issuer,
            issuerPublicKey: record.issuerPublicKey,
            subject: record.subject,
            subjectPublicKey: record.subjectPublicKey,
            action: record.action,
            issuerSequence: record.issuerSequence,
            epochMilliseconds: record.epochMilliseconds,
            signature: Data()
        )
        var store = TrustStore(owner: owner.id)

        XCTAssertThrowsError(try store.authorize(invalidRecord))
        XCTAssertFalse(store.isTrusted(peer.id))
    }

    func testAuthorizationRejectsReplayedIssuerSequence() throws {
        let owner = try DeviceIdentity.ephemeral()
        let firstPeer = try DeviceIdentity.ephemeral()
        let secondPeer = try DeviceIdentity.ephemeral()
        var store = TrustStore(owner: owner.id)

        try store.authorize(
            SignedTrustRecord.authorizing(firstPeer, signedBy: owner, sequence: 1)
        )

        XCTAssertThrowsError(
            try store.authorize(
                SignedTrustRecord.authorizing(secondPeer, signedBy: owner, sequence: 1)
            )
        )
        XCTAssertFalse(store.isTrusted(secondPeer.id))
    }

    func testAuthorizationRejectsUntrustedIssuer() throws {
        let owner = try DeviceIdentity.ephemeral()
        let untrustedIssuer = try DeviceIdentity.ephemeral()
        let peer = try DeviceIdentity.ephemeral()
        var store = TrustStore(owner: owner.id)

        XCTAssertThrowsError(
            try store.authorize(SignedTrustRecord.authorizing(peer, signedBy: untrustedIssuer))
        )
        XCTAssertFalse(store.isTrusted(peer.id))
    }

    func testPeerCannotRevokeOwner() throws {
        let owner = try DeviceIdentity.ephemeral()
        let peer = try DeviceIdentity.ephemeral()
        var store = TrustStore(owner: owner.id)

        try store.ingest(SignedTrustRecord.authorizing(peer, signedBy: owner))
        let ownerRevocation = try SignedTrustRecord.revoking(
            owner.id,
            subjectPublicKey: owner.publicKey.rawRepresentation,
            signedBy: peer,
            sequence: 1
        )

        XCTAssertThrowsError(try store.ingest(ownerRevocation)) { error in
            XCTAssertEqual(error as? TrustStoreError, .cannotRevokeOwner)
        }
        XCTAssertTrue(store.isTrusted(owner.id))
    }

    func testLocalRevokeRejectsOwnerBeforeMutation() throws {
        let owner = try DeviceIdentity.ephemeral()
        var store = TrustStore(owner: owner.id)

        XCTAssertThrowsError(try store.revoke(owner.id, signedBy: owner)) { error in
            XCTAssertEqual(error as? TrustStoreError, .cannotRevokeOwner)
        }
        XCTAssertTrue(store.isTrusted(owner.id))
    }

    func testSnapshotRejectsOwnerRevocation() throws {
        let owner = try DeviceIdentity.ephemeral()
        var store = TrustStore(owner: owner.id)
        let snapshot = try store.snapshot(signedBy: owner)
        let revokedOwner = try snapshotByReplacing(
            snapshot, key: "revokedDevices",
            with: [
                [
                    "rawValue": owner.id.rawValue.uuidString
                ]
            ])

        XCTAssertThrowsError(
            try TrustStore(snapshot: revokedOwner, expectedOwner: owner, minimumGeneration: 0)
        ) { error in
            XCTAssertEqual(error as? TrustStoreError, .snapshotRevokesOwner)
        }
    }

    func testSnapshotRejectsTampering() throws {
        let owner = try DeviceIdentity.ephemeral()
        var store = TrustStore(owner: owner.id)
        let snapshot = try store.snapshot(signedBy: owner)
        let tampered = try snapshotByReplacing(snapshot, key: "generation", with: 99)

        XCTAssertThrowsError(
            try TrustStore(snapshot: tampered, expectedOwner: owner, minimumGeneration: 0)
        ) { error in
            XCTAssertEqual(error as? TrustStoreError, .invalidSnapshotSignature)
        }
    }

    func testSnapshotRejectsRollbackBelowMinimumGeneration() throws {
        let owner = try DeviceIdentity.ephemeral()
        var store = TrustStore(owner: owner.id)
        let snapshot = try store.snapshot(signedBy: owner)

        XCTAssertThrowsError(
            try TrustStore(
                snapshot: snapshot,
                expectedOwner: owner,
                minimumGeneration: snapshot.generation + 1
            )
        ) { error in
            XCTAssertEqual(error as? TrustStoreError, .snapshotGenerationTooLow)
        }
    }

    func testRevokeRejectsSequenceExhaustion() throws {
        let owner = try DeviceIdentity.ephemeral()
        let peer = try DeviceIdentity.ephemeral()
        var store = TrustStore(owner: owner.id)

        try store.ingest(
            SignedTrustRecord.authorizing(peer, signedBy: owner, sequence: UInt64.max)
        )

        XCTAssertThrowsError(try store.revoke(peer.id, signedBy: owner)) { error in
            XCTAssertEqual(error as? TrustStoreError, .sequenceExhausted(owner.id))
        }
    }

    func testRecordTimestampIsNormalizedToMillisecondPrecision() throws {
        let owner = try DeviceIdentity.ephemeral()
        let peer = try DeviceIdentity.ephemeral()

        let record = try SignedTrustRecord.authorizing(
            peer,
            signedBy: owner,
            timestamp: Date(timeIntervalSince1970: 1_726_000_000.123_987)
        )
        let roundTripped = try JSONDecoder().decode(
            SignedTrustRecord.self,
            from: JSONEncoder().encode(record)
        )

        XCTAssertEqual(record.epochMilliseconds, 1_726_000_000_123)
        XCTAssertEqual(roundTripped.epochMilliseconds, record.epochMilliseconds)
        try roundTripped.validated()
    }

    func testRestoreRejectsValidSnapshotSignedByDifferentOwner() throws {
        let expectedOwner = try DeviceIdentity.ephemeral()
        let attacker = try DeviceIdentity.ephemeral()
        var attackerStore = TrustStore(owner: attacker.id)
        let foreignSnapshot = try attackerStore.snapshot(signedBy: attacker)

        XCTAssertThrowsError(
            try TrustStore(
                snapshot: foreignSnapshot,
                expectedOwner: expectedOwner,
                minimumGeneration: foreignSnapshot.generation
            )
        ) { error in
            XCTAssertEqual(error as? TrustStoreError, .snapshotAnchorMismatch)
        }
    }

    func testConfirmedPairingBootstrapKeepsLocalOwnerImmutable() throws {
        let localOwner = try DeviceIdentity.ephemeral()
        let confirmedHost = try DeviceIdentity.ephemeral()
        let authorization = try SignedTrustRecord.authorizing(
            subject: localOwner.id,
            subjectPublicKey: localOwner.publicKey.rawRepresentation,
            signedBy: confirmedHost,
            sequence: 1
        )
        var store = TrustStore(owner: localOwner.id)

        try store.bootstrapFromConfirmedPairing(
            authorization,
            localIdentity: localOwner
        )

        XCTAssertTrue(store.isTrusted(localOwner.id))
        XCTAssertTrue(store.isTrusted(confirmedHost.id))
        XCTAssertThrowsError(try store.revoke(localOwner.id, signedBy: localOwner)) { error in
            XCTAssertEqual(error as? TrustStoreError, .cannotRevokeOwner)
        }
    }
}

private func snapshotByReplacing(
    _ snapshot: TrustStoreSnapshot,
    key: String,
    with value: Any
) throws -> TrustStoreSnapshot {
    var object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
    )
    object[key] = value
    return try JSONDecoder().decode(
        TrustStoreSnapshot.self,
        from: JSONSerialization.data(withJSONObject: object)
    )
}

private final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private var secrets: [String: Data] = [:]
    private(set) var requestedPolicies: [KeychainPolicy] = []

    func data(for account: String, policy: KeychainPolicy) throws -> Data? {
        requestedPolicies.append(policy)
        return secrets[account]
    }

    func store(_ data: Data, for account: String, policy: KeychainPolicy) throws {
        requestedPolicies.append(policy)
        secrets[account] = data
    }
}
