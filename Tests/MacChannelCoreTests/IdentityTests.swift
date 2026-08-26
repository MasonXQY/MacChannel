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
        try store.revoke(peer.id, signedBy: owner)

        XCTAssertFalse(store.isTrusted(peer.id))
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

    func data(for account: String) throws -> Data? {
        secrets[account]
    }

    func store(_ data: Data, for account: String) throws {
        secrets[account] = data
    }
}
