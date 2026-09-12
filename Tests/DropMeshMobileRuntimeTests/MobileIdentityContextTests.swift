import Foundation
import XCTest
import MacChannelCore
@testable import DropMeshMobileRuntime

final class MobileIdentityContextTests: XCTestCase {
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
}
