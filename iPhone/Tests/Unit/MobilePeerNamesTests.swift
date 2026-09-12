import Foundation
import MacChannelCore
import XCTest
@testable import DropMeshTestHost

final class MobilePeerNamesTests: XCTestCase {
    func testConfirmedNamesSurviveReloadButNeverSaveUntrustedNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-names-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("names.json")
        let peer = DeviceSummary(id: DeviceID(rawValue: UUID()), displayName: "工作室 Mac", availability: .offline)
        var store = MobilePeerNames(url: url)
        store.remember(peer, trustedIDs: [])
        XCTAssertTrue(store.values.isEmpty)
        store.remember(peer, trustedIDs: [peer.id])
        XCTAssertEqual(MobilePeerNames(url: url).values[peer.id], peer.displayName)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testFailedSaveAndInvalidOrOversizedDataFallBackWithoutThrowing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-names-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let peer = DeviceSummary(id: DeviceID(rawValue: UUID()), displayName: "Mac", availability: .offline)
        var failure = MobilePeerNames(url: root.appendingPathComponent("absent/names.json"))
        failure.remember(peer, trustedIDs: [peer.id])
        XCTAssertNil(failure.values[peer.id])
        let url = root.appendingPathComponent("names.json")
        try Data("invalid".utf8).write(to: url)
        XCTAssertTrue(MobilePeerNames(url: url).values.isEmpty)
        try Data(repeating: 65, count: 131_073).write(to: url)
        XCTAssertTrue(MobilePeerNames(url: url).values.isEmpty)
    }
}
