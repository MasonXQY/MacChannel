import Foundation
import XCTest

@testable import MacChannelAppKit
@testable import MacChannelCore

final class PersonalMeshRuntimeTests: XCTestCase {
    func testFreshSettingsUseBuiltInPublicChannel() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let freshURL = root.appendingPathComponent("fresh.json")
        let fresh = try RuntimeSettingsStore(url: freshURL, trustedDevices: [])
        let freshSnapshot = await fresh.current()
        XCTAssertEqual(freshSnapshot.connectivityMode, .publicService)
        XCTAssertFalse(freshSnapshot.personalMeshEnabled)
    }

    func testEssentialUserPreferencesPersistWithoutNetworkConfiguration() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.json")
        let store = try RuntimeSettingsStore(url: url, trustedDevices: [])

        try await store.updateLocalDisplayName("工作室 Mac")
        try await store.updateAutoReceive(false)
        try await store.updateLaunchAtLogin(true)

        let reloaded = try RuntimeSettingsStore(url: url, trustedDevices: [])
        let snapshot = await reloaded.current()
        XCTAssertEqual(snapshot.localDisplayName, "工作室 Mac")
        XCTAssertFalse(snapshot.autoReceive)
        XCTAssertTrue(snapshot.launchAtLogin)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 2)
        XCTAssertNil(object["connectivityMode"])
        XCTAssertNil(object["personalMeshEnabled"])
        XCTAssertNil(object["rendezvousURL"])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testLegacyPersonalMeshSettingsPreserveUserDataAndDropNetworkChoices() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let peer = DeviceID(rawValue: UUID())
        let legacyURL = root.appendingPathComponent("legacy.json")
        let legacyObject: [String: Any] = [
            "defaultDirectoryPath": "/tmp/downloads",
            "rendezvousURL": "wss://relay.example/v1/ws",
            "connectivityMode": "personalMesh",
            "personalMeshEnabled": true,
            "devices": [
                peer.rawValue.uuidString,
                [
                    "displayName": "书房 Mac",
                    "autoAccept": false,
                    "maximumBytes": 123_456,
                    "directoryPath": "/tmp/peer",
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: legacyObject).write(to: legacyURL)

        let migrated = try RuntimeSettingsStore(
            url: legacyURL,
            trustedDevices: [peer]
        )
        let snapshot = await migrated.current()
        XCTAssertEqual(snapshot.connectivityMode, .publicService)
        XCTAssertFalse(snapshot.personalMeshEnabled)
        XCTAssertEqual(snapshot.defaultDirectory?.path, "/tmp/downloads")
        XCTAssertEqual(snapshot.devices.first?.displayName, "书房 Mac")
        XCTAssertFalse(try XCTUnwrap(snapshot.devices.first).autoAccept)
        XCTAssertEqual(snapshot.devices.first?.maximumMegabytes, "0.123456")
        XCTAssertEqual(snapshot.devices.first?.directory?.path, "/tmp/peer")

        let migratedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: legacyURL)) as? [String: Any]
        )
        XCTAssertNil(migratedObject["connectivityMode"])
        XCTAssertNil(migratedObject["personalMeshEnabled"])
        XCTAssertNil(migratedObject["rendezvousURL"])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
