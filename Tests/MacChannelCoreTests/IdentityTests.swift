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

    func testRevokedDeviceIsNoLongerTrusted() throws {
        let owner = try DeviceIdentity.ephemeral()
        let peer = try DeviceIdentity.ephemeral()
        var store = TrustStore(owner: owner.id)

        try store.authorize(SignedTrustRecord.authorizing(peer, signedBy: owner))
        _ = try store.revoke(peer.id, signedBy: owner)

        XCTAssertFalse(store.isTrusted(peer.id))
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
            from: JSONEncoder().encode(store.snapshot())
        )
        var restored = try TrustStore(snapshot: snapshot)

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
            from: JSONEncoder().encode(store.snapshot())
        )
        let restored = try TrustStore(snapshot: snapshot)

        XCTAssertFalse(restored.isTrusted(peer.id))
        XCTAssertTrue(snapshot.revokedDevices.contains(peer.id))
    }

    func testExtremeTimestampIsRejectedWithTypedValidationError() throws {
        let owner = try DeviceIdentity.ephemeral()
        let peer = try DeviceIdentity.ephemeral()
        let validRecord = try SignedTrustRecord.authorizing(peer, signedBy: owner)
        let extremeRecord = SignedTrustRecord(
            issuer: validRecord.issuer,
            issuerPublicKey: validRecord.issuerPublicKey,
            subject: validRecord.subject,
            subjectPublicKey: validRecord.subjectPublicKey,
            action: validRecord.action,
            issuerSequence: validRecord.issuerSequence,
            timestamp: Date(timeIntervalSince1970: .infinity),
            signature: validRecord.signature
        )

        XCTAssertThrowsError(try extremeRecord.validated()) { error in
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
            timestamp: validRecord.timestamp,
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
            timestamp: validRecord.timestamp,
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

        XCTAssertEqual(keychain.requestedPolicies, [KeychainStore.identityPolicy, KeychainStore.identityPolicy])
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
            timestamp: record.timestamp,
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
}

private final class MemorySecretStore: SecretStore {
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
