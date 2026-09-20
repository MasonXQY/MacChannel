import Foundation
import XCTest
@testable import MacChannelCore
import DropMeshMobileRuntime

final class MobileAuthorizationBootstrapTests: XCTestCase, @unchecked Sendable {
    func testFreshContextSharesOwnerWithSynchronousManualMutations() async throws {
        let (root, layout) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try await MobileIdentityContext.load(layout: layout, secrets: BootstrapSecrets())
        let owner = context.authorizationOwner
        XCTAssertTrue(owner === context.authorizationOwner)
        XCTAssertTrue(owner.snapshot().peers.isEmpty)
        XCTAssertThrowsError(try owner.acquire(for: context.identity.id))
        let peer = try DeviceIdentity.ephemeral()
        _ = try await context.repository.issueAuthorization(subject: peer.id,
            subjectPublicKey: peer.publicKey.rawRepresentation, timestamp: Date())
        XCTAssertEqual(owner.snapshot().peers[peer.id], peer.publicKey.rawRepresentation)
        let lease = try owner.acquire(for: peer.id)
        _ = try await context.repository.revoke(peer.id, timestamp: Date())
        XCTAssertTrue(owner.snapshot().peers.isEmpty)
        XCTAssertThrowsError(try owner.validate(lease))
    }

    func testAuthenticatedReloadSeedsPeerKeysAndKeepsOwnerAttached() async throws {
        let (root, layout) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let secrets = BootstrapSecrets()
        let first = try await MobileIdentityContext.load(layout: layout, secrets: secrets)
        let peer = try DeviceIdentity.ephemeral()
        _ = try await first.repository.issueAuthorization(subject: peer.id,
            subjectPublicKey: peer.publicKey.rawRepresentation, timestamp: Date())
        try await first.persistTrust()
        let second = try await MobileIdentityContext.load(layout: layout, secrets: secrets)
        XCTAssertEqual(second.identity.id, first.identity.id)
        XCTAssertFalse(second.authorizationOwner === first.authorizationOwner)
        XCTAssertEqual(second.authorizationOwner.snapshot().peers, [peer.id: peer.publicKey.rawRepresentation])
        let lease = try second.authorizationOwner.acquire(for: peer.id)
        _ = try await second.repository.revoke(peer.id, timestamp: Date())
        XCTAssertThrowsError(try second.authorizationOwner.validate(lease))
        XCTAssertNoThrow(try first.authorizationOwner.acquire(for: peer.id))
    }

    func testSnapshotLoadRejectsMismatchedOwnerForFreshAndRestoredTrust() async throws {
        for persisted in [false, true] {
            let (root, layout) = fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let secrets = BootstrapSecrets()
            let context = try await MobileIdentityContext.load(layout: layout, secrets: secrets)
            if persisted {
                let peer = try DeviceIdentity.ephemeral()
                _ = try await context.repository.issueAuthorization(subject: peer.id,
                    subjectPublicKey: peer.publicKey.rawRepresentation, timestamp: Date())
                try await context.persistTrust()
            }
            let snapshots = AuthenticatedTrustSnapshotStore(url: layout.trustFile,
                secrets: secrets, policy: MobileIdentityPolicy.policy)
            let foreignOwner = PeerAuthorizationOwner.live(identity: try DeviceIdentity.ephemeral())
            do {
                _ = try await snapshots.load(identity: context.identity, authorizationOwner: foreignOwner)
                XCTFail("Mismatched authorization owner must fail closed (persisted: \(persisted))")
            } catch {
                XCTAssertEqual(error as? PeerAuthorizationError, .invalidEvidence)
            }
            XCTAssertTrue(foreignOwner.snapshot().peers.isEmpty)
        }
    }

    private func fixture() -> (URL, MobileStorageLayout) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (root, MobileStorageLayout(applicationSupport: root.appendingPathComponent("Support"),
            documents: root.appendingPathComponent("Documents")))
    }
}

private final class BootstrapSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func data(for account: String, policy: KeychainPolicy) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return values[policy.service + ":" + account]
    }
    func store(_ data: Data, for account: String, policy: KeychainPolicy) throws {
        lock.lock(); defer { lock.unlock() }
        values[policy.service + ":" + account] = data
    }
}
