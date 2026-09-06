import Foundation
import XCTest
@testable import MacChannelAppKit
@testable import MacChannelCore

final class SecurityScopedDirectoryStoreTests: XCTestCase {
    func testFailedAuthorizationPreservesPriorSettingsAndStaleRefreshIsPersisted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.json")
        let destination = root.appendingPathComponent("destination")
        let edges = DirectoryEdges()
        let authorization = SecurityScopedDirectoryStore(mode: .securityScopedBookmarks, namespace: "test-channel", createBookmark: { _ in edges.bookmark() }, resolveBookmark: { _ in (destination, true) }, start: { _ in edges.allowed }, stop: { _ in edges.stopped() }, accessible: { _ in true })
        let store = try RuntimeSettingsStore(url: url, trustedDevices: [], authorization: authorization)
        try await store.updateDefaultDirectory(destination)
        let original = try Data(contentsOf: url)
        edges.allowed = false
        do { try await store.updateDefaultDirectory(root.appendingPathComponent("replacement")); XCTFail("Expected denied grant") } catch { XCTAssertTrue(error.localizedDescription.contains("重新选择目录")) }
        XCTAssertEqual(try Data(contentsOf: url), original)
        let unchanged = await store.current()
        XCTAssertEqual(unchanged.defaultDirectory, destination)
        do { _ = try await store.authorizeReceiveDirectories(); XCTFail("Expected revoked bookmark") } catch {}
        XCTAssertEqual(try Data(contentsOf: url), original)
        edges.allowed = true
        let resolved = try await store.authorizeReceiveDirectories()
        XCTAssertNotEqual(try Data(contentsOf: url), original, "Stale OS bookmark must be durably refreshed")
        resolved.release()
        let reopened = try RuntimeSettingsStore(url: url, trustedDevices: [], authorization: authorization)
        let snapshot = await reopened.current()
        XCTAssertEqual(snapshot.defaultDirectory, destination)
    }
    func testSettingsSchemaTwoMigratesWithoutLosingDirectPaths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settingsURL = root.appendingPathComponent("settings.json")
        let fixture = """
        {"schemaVersion":2,"localDisplayName":"Original","defaultDirectoryPath":"/tmp/legacy","autoReceive":false,"launchAtLogin":true,"devices":[]}
        """
        try Data(fixture.utf8).write(to: settingsURL)
        let store = try RuntimeSettingsStore(url: settingsURL, trustedDevices: [])
        let snapshot = await store.current()
        XCTAssertEqual(snapshot.localDisplayName, "Original")
        XCTAssertEqual(snapshot.defaultDirectory?.path, "/tmp/legacy")
        XCTAssertFalse(snapshot.autoReceive)
        XCTAssertTrue(snapshot.launchAtLogin)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 3)
        let reference = try XCTUnwrap(json["defaultDirectoryReference"] as? [String: Any])
        XCTAssertEqual(reference["path"] as? String, "/tmp/legacy")
        XCTAssertNil(reference["bookmark"])
    }
    func testSelectionResolutionAndStaleRefreshAreBoundToSettingAndChannel() throws {
        let calls = ScopeCalls()
        let url = URL(fileURLWithPath: "/tmp/destination")
        let store = SecurityScopedDirectoryStore(mode: .securityScopedBookmarks, namespace: "channel-a", createBookmark: { _ in Data("real-bookmark".utf8) }, resolveBookmark: { _ in (url, true) }, start: { calls.start($0); return true }, stop: { calls.stop($0) }, accessible: { _ in true })
        let reference = try store.select(url, settingKey: "default")
        XCTAssertNotNil(reference.bookmark)
        let resolved = try store.resolve(reference, settingKey: "default")
        XCTAssertTrue(resolved.wasStale)
        resolved.lease.release()
        XCTAssertEqual(calls.counts, [2, 2])
        XCTAssertThrowsError(try store.resolve(reference, settingKey: "device"))
        let other = SecurityScopedDirectoryStore(mode: .securityScopedBookmarks, namespace: "channel-b")
        XCTAssertThrowsError(try other.resolve(reference, settingKey: "default"))
    }

    func testDirectSelectionNeverCreatesBookmark() throws {
        let store = SecurityScopedDirectoryStore(mode: .directPath, namespace: "direct", createBookmark: { _ in XCTFail("Direct must never create bookmarks"); return Data() })
        let reference = try store.select(URL(fileURLWithPath: "/tmp/../tmp/destination"), settingKey: "default")
        XCTAssertEqual(reference.path, "/tmp/destination")
        XCTAssertNil(reference.bookmark)
    }

    func testMalformedMissingMismatchedAndDeniedReferencesRequireReselection() throws {
        let selected = URL(fileURLWithPath: "/tmp/a")
        let factory = SecurityScopedDirectoryStore(mode: .securityScopedBookmarks, namespace: "store", createBookmark: { _ in Data([1]) }, start: { _ in true }, stop: { _ in }, accessible: { _ in true })
        let reference = try factory.select(selected, settingKey: "default")
        for (url, starts, accessible) in [(URL(fileURLWithPath: "/tmp/b"), true, true), (selected, false, true), (selected, true, false)] {
            let store = SecurityScopedDirectoryStore(mode: .securityScopedBookmarks, namespace: "store", resolveBookmark: { _ in (url, false) }, start: { _ in starts }, stop: { _ in }, accessible: { _ in accessible })
            XCTAssertThrowsError(try store.resolve(reference, settingKey: "default")) { XCTAssertTrue($0.localizedDescription.contains("重新选择目录")) }
        }
        XCTAssertThrowsError(try factory.resolve(StoredDirectoryReference(path: selected.path, bookmark: nil), settingKey: "default"))
        XCTAssertThrowsError(try factory.resolve(StoredDirectoryReference(path: selected.path, bookmark: Data([0])), settingKey: "default"))
    }
}

private final class DirectoryEdges: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = true
    private var generation = 0
    private var stops = 0
    var allowed: Bool {
        get { lock.withLock { enabled } }
        set { lock.withLock { enabled = newValue } }
    }
    func bookmark() -> Data { lock.withLock { generation += 1; return Data("os-bookmark-\(generation)".utf8) } }
    func stopped() { lock.withLock { stops += 1 } }
}
