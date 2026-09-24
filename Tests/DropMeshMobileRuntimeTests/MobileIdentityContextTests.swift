import Foundation
import XCTest
@testable import MacChannelCore
@testable import DropMeshMobileRuntime

final class MobileIdentityContextTests: XCTestCase {
    func testPersistedStateForwardsReceiptAndAuthenticatedReloadBaseline() async throws {
        let (root, layout) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let secrets = FixtureSecrets()
        let context = try await MobileIdentityContext.load(layout: layout, secrets: secrets)
        let initial = await context.persistedTrustState()
        XCTAssertNil(initial)
        let peer = try DeviceIdentity.ephemeral()
        _ = try await context.repository.issueAuthorization(subject: peer.id,
            subjectPublicKey: peer.publicKey.rawRepresentation, timestamp: Date())
        let unsaved = await context.persistedTrustState()
        XCTAssertNil(unsaved)
        let pending = await context.trustPublicationSnapshot()
        XCTAssertTrue(pending.records.isEmpty)
        XCTAssertTrue(pending.pendingPersistence)
        let saved = try await context.persistTrustState()
        XCTAssertNotNil(saved)
        let publication = await context.trustPublicationSnapshot()
        XCTAssertEqual(publication.records, saved?.authenticationRecords)
        XCTAssertFalse(publication.pendingPersistence)
        let reloaded = try await MobileIdentityContext.load(layout: layout, secrets: secrets)
        let baseline = await reloaded.persistedTrustState()
        XCTAssertEqual(baseline?.snapshot.signature, saved?.snapshot.signature)
        var updates = await context.persistedTrustUpdates().makeAsyncIterator()
        let observed = await updates.next()
        XCTAssertEqual(observed??.snapshot.signature, saved?.snapshot.signature)
    }

    private func fixture() throws -> (URL, MobileStorageLayout) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let layout = MobileStorageLayout(
            applicationSupport: root.appendingPathComponent("Library/Application Support"),
            documents: root.appendingPathComponent("Documents")
        )
        return (root, layout)
    }

    func testLayoutSeparatesReceivedFilesFromPrivateState() throws {
        let (root, layout) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try layout.prepare()
        XCTAssertEqual(layout.receiveDirectory.path, root.appendingPathComponent("Documents/DropMesh").path)
        XCTAssertTrue(layout.stagingDirectory.path.hasPrefix(layout.stateDirectory.path + "/"))
        XCTAssertFalse(layout.trustFile.path.hasPrefix(layout.receiveDirectory.path + "/"))
        for directory in [layout.stateDirectory, layout.stagingDirectory, layout.receiveDirectory] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: layout.stateDirectory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testReloadPreservesIdentityAndTrustOwner() async throws {
        let (root, layout) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let secrets = FixtureSecrets()
        let first = try await MobileIdentityContext.load(layout: layout, secrets: secrets)
        try await first.persistTrust()
        let second = try await MobileIdentityContext.load(layout: layout, secrets: secrets)
        XCTAssertEqual(first.identity.id, second.identity.id)
        XCTAssertEqual(second.repository.ownerID, first.identity.id)
        let trusted = await second.repository.isTrusted(first.identity.id)
        XCTAssertTrue(trusted)
    }

    func testCorruptTrustDoesNotResetIdentityOrSilentlyStartFresh() async throws {
        let (root, layout) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let secrets = FixtureSecrets()
        let first = try await MobileIdentityContext.load(layout: layout, secrets: secrets)
        try Data("not a trust snapshot".utf8).write(to: layout.trustFile)
        do {
            _ = try await MobileIdentityContext.load(layout: layout, secrets: secrets)
            XCTFail("Corrupt trust must fail closed")
        } catch { }
        let retained = try DeviceIdentity.loadOrCreate(keychain: secrets, policy: MobileIdentityPolicy.policy)
        XCTAssertEqual(retained.id, first.identity.id)
    }

    func testRetainedGenerationWithMissingContainerStateIsRecoverableReinstall() async throws {
        let (root, layout) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let secrets = FixtureSecrets()
        try secrets.storeUInt64(3, account: "trust-snapshot-generation")

        do {
            _ = try await MobileIdentityContext.load(layout: layout, secrets: secrets)
            XCTFail("A retained checkpoint without its container must not silently start fresh")
        } catch let error as MobileIdentityRecoveryError {
            XCTAssertEqual(error, .orphanedInstallation)
        }
    }

    func testRecoveryRechecksOrphanAndPreservesReceivedFiles() async throws {
        let (root, layout) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try layout.prepare()
        let received = layout.receiveDirectory.appendingPathComponent("kept.txt")
        try Data("keep me".utf8).write(to: received)
        let secrets = FixtureSecrets()
        try secrets.storeUInt64(2, account: "trust-snapshot-generation")
        var eraseCalls = 0

        try MobileIdentityRecovery.recreateOrphanedIdentity(
            layout: layout,
            secrets: secrets,
            erase: { eraseCalls += 1; secrets.removeAll() }
        )

        XCTAssertEqual(eraseCalls, 1)
        XCTAssertEqual(try Data(contentsOf: received), Data("keep me".utf8))
        _ = try await MobileIdentityContext.load(layout: layout, secrets: secrets)
        XCTAssertEqual(try Data(contentsOf: received), Data("keep me".utf8))
    }

    func testRecoveryRefusesCorruptOrPartiallyPresentState() throws {
        let (root, layout) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try layout.prepare()
        let secrets = FixtureSecrets()
        try secrets.storeUInt64(2, account: "trust-snapshot-generation")
        try Data("partial".utf8).write(to: layout.transferDatabaseFile)
        var eraseCalls = 0

        XCTAssertThrowsError(try MobileIdentityRecovery.recreateOrphanedIdentity(
            layout: layout, secrets: secrets, erase: { eraseCalls += 1 }
        )) { error in
            XCTAssertEqual(error as? MobileIdentityRecoveryError, .conditionChanged)
        }
        XCTAssertEqual(eraseCalls, 0)
    }

    func testRecoveryRefusesDanglingStateSymlink() throws {
        let (root, layout) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try layout.prepare()
        let secrets = FixtureSecrets()
        try secrets.storeUInt64(2, account: "trust-snapshot-generation")
        try FileManager.default.createSymbolicLink(
            at: layout.trustFile,
            withDestinationURL: root.appendingPathComponent("missing-trust")
        )
        var eraseCalls = 0

        XCTAssertThrowsError(try MobileIdentityRecovery.recreateOrphanedIdentity(
            layout: layout, secrets: secrets, erase: { eraseCalls += 1 }
        )) { error in
            XCTAssertEqual(error as? MobileIdentityRecoveryError, .conditionChanged)
        }
        XCTAssertEqual(eraseCalls, 0)
    }

    func testPolicyIsPrivateDeviceOnlyAndSeparateFromDesktopDefault() {
        let policy = MobileIdentityPolicy.policy
        XCTAssertNotEqual(policy.service, KeychainStore.identityPolicy.service)
        XCTAssertNil(policy.accessGroup)
        XCTAssertFalse(policy.synchronizable)
        XCTAssertEqual(policy.accessibility, .afterFirstUnlockThisDeviceOnly)
    }

    func testPairingStartsIdleUsingExistingCoordinator() async throws {
        let (root, layout) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try await MobileIdentityContext.load(layout: layout, secrets: FixtureSecrets())
        let transport = MemoryPairingTransport(server: MemoryPairingServer(), observedSource: "mobile-fixture")
        let coordinator = try context.makePairingCoordinator(displayName: "iPhone", transport: transport)
        let state = await coordinator.currentState()
        XCTAssertEqual(state, .idle)
    }
}

private final class FixtureSecrets: SecretStore, @unchecked Sendable {
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
    func storeUInt64(_ value: UInt64, account: String) throws {
        try store(Data((0..<8).reversed().map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }),
                  for: account, policy: MobileIdentityPolicy.policy)
    }
    func removeAll() { lock.lock(); values.removeAll(); lock.unlock() }
}
