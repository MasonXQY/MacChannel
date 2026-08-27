import Foundation
import XCTest

@testable import MacChannelAppKit
@testable import MacChannelCore

final class PersonalMeshRuntimeTests: XCTestCase {
    func testNewInstallDefaultsToPersonalMeshButLegacySettingsRemainPublic() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let freshURL = root.appendingPathComponent("fresh.json")
        let fresh = try RuntimeSettingsStore(url: freshURL, trustedDevices: [])
        let freshSnapshot = await fresh.current()
        XCTAssertEqual(freshSnapshot.connectivityMode, .personalMesh)
        XCTAssertFalse(freshSnapshot.personalMeshEnabled)

        let peer = DeviceID(rawValue: UUID())
        let legacyURL = root.appendingPathComponent("legacy.json")
        let preMigration = try RuntimeSettingsStore(url: legacyURL, trustedDevices: [peer])
        try await preMigration.updateDefaultDirectory(URL(fileURLWithPath: "/tmp/downloads"))
        try await preMigration.updateRendezvousURL("wss://relay.example/v1/ws")
        try await preMigration.rename(peer, to: "书房 Mac")
        try await preMigration.updatePolicy(peer, autoAccept: false, maximumBytes: 123_456)
        try await preMigration.updateDirectory(URL(fileURLWithPath: "/tmp/peer"), for: peer)
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: legacyURL)) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "connectivityMode")
        legacyObject.removeValue(forKey: "personalMeshEnabled")
        try JSONSerialization.data(withJSONObject: legacyObject).write(to: legacyURL)

        let migrated = try RuntimeSettingsStore(
            url: legacyURL,
            trustedDevices: [peer]
        )
        let snapshot = await migrated.current()
        XCTAssertEqual(snapshot.connectivityMode, .publicService)
        XCTAssertFalse(snapshot.personalMeshEnabled)
        XCTAssertEqual(snapshot.defaultDirectory?.path, "/tmp/downloads")
        XCTAssertEqual(snapshot.rendezvousURL, "wss://relay.example/v1/ws")
        XCTAssertEqual(snapshot.devices.first?.displayName, "书房 Mac")
        XCTAssertFalse(try XCTUnwrap(snapshot.devices.first).autoAccept)
        XCTAssertEqual(snapshot.devices.first?.maximumMegabytes, "0.123456")
        XCTAssertEqual(snapshot.devices.first?.directory?.path, "/tmp/peer")
    }

    func testModeAndCommittedServeStatePersistOwnerOnlyWithoutLosingSettings() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.json")
        let peer = DeviceID(rawValue: UUID())
        let store = try RuntimeSettingsStore(url: url, trustedDevices: [peer])
        try await store.updateDefaultDirectory(URL(fileURLWithPath: "/tmp/downloads"))
        try await store.updateRendezvousURL("wss://relay.example/v1/ws")

        try await store.updateConnectivityMode(.publicService)
        try await store.updatePersonalMeshEnabled(true)

        let reloaded = try RuntimeSettingsStore(url: url, trustedDevices: [peer])
        let snapshot = await reloaded.current()
        XCTAssertEqual(snapshot.connectivityMode, .publicService)
        XCTAssertTrue(snapshot.personalMeshEnabled)
        XCTAssertEqual(snapshot.defaultDirectory?.path, "/tmp/downloads")
        XCTAssertEqual(snapshot.rendezvousURL, "wss://relay.example/v1/ws")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testSetupStatesAreTruthfulAndEnableIsExplicit() async throws {
        let missing = PersonalMeshSetupCoordinator(
            status: StubTailscaleStatus(result: .failure(TailscaleCommandError.notInstalled)),
            serve: StubTailscaleServe(state: .disabled)
        )
        let missingStatus = await missing.inspect()
        XCTAssertEqual(missingStatus, .tailscaleNotInstalled)

        let disconnected = PersonalMeshSetupCoordinator(
            status: StubTailscaleStatus(result: .failure(TailscaleCommandError.notConnected)),
            serve: StubTailscaleServe(state: .disabled)
        )
        let disconnectedStatus = await disconnected.inspect()
        XCTAssertEqual(disconnectedStatus, .tailscaleDisconnected)

        let conflict = PersonalMeshSetupCoordinator(
            status: StubTailscaleStatus(result: .success(TailscaleStatus(peers: []))),
            serve: StubTailscaleServe(state: .conflict)
        )
        let conflictStatus = await conflict.inspect()
        XCTAssertEqual(conflictStatus, .portConflict)

        let serve = StubTailscaleServe(state: .disabled)
        let ready = PersonalMeshSetupCoordinator(
            status: StubTailscaleStatus(result: .success(TailscaleStatus(peers: []))),
            serve: serve
        )
        let readyStatus = await ready.inspect()
        XCTAssertEqual(readyStatus, .readyToEnable)
        let enabledStatus = try await ready.enable()
        XCTAssertEqual(enabledStatus, .enabled)
        let enableCount = await serve.enableCount()
        XCTAssertEqual(enableCount, 1)
    }

    func testRestartReusesExactServeAndDisableOnlyRemovesOwnedMapping() async throws {
        let serve = StubTailscaleServe(state: .enabled)
        let coordinator = PersonalMeshSetupCoordinator(
            status: StubTailscaleStatus(result: .success(TailscaleStatus(peers: []))),
            serve: serve
        )
        let initialStatus = await coordinator.inspect()
        XCTAssertEqual(initialStatus, .enabled)
        let reconciledStatus = await coordinator.reconcileCommittedEnable()
        XCTAssertEqual(reconciledStatus, .enabled)
        let enableCount = await serve.enableCount()
        XCTAssertEqual(enableCount, 1)
        try await coordinator.disable()
        let disableCount = await serve.disableCount()
        XCTAssertEqual(disableCount, 1)
    }

    func testInstallActionUsesOfficialHTTPSGuide() {
        XCTAssertEqual(
            PersonalMeshInstallGuide.officialURL.absoluteString,
            "https://tailscale.com/download/mac"
        )
        XCTAssertEqual(PersonalMeshInstallGuide.officialURL.scheme, "https")
        XCTAssertEqual(PersonalMeshInstallGuide.officialURL.host, "tailscale.com")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor StubTailscaleStatus: TailscaleStatusProviding {
    let result: Result<TailscaleStatus, Error>
    init(result: Result<TailscaleStatus, Error>) { self.result = result }
    func status() async throws -> TailscaleStatus { try result.get() }
}

private actor StubTailscaleServe: TailscaleServeManaging {
    private var state: TailscaleServeState
    private var enables = 0
    private var disables = 0

    init(state: TailscaleServeState) { self.state = state }
    func inspect() async throws -> TailscaleServeState { state }
    func enable() async throws {
        enables += 1
        state = .enabled
    }
    func disable() async throws {
        disables += 1
        state = .disabled
    }
    func enableCount() -> Int { enables }
    func disableCount() -> Int { disables }
}
