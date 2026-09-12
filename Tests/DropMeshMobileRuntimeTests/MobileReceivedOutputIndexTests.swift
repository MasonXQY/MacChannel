import Darwin
import Foundation
import SQLite3
import XCTest
@testable import MacChannelCore
@testable import DropMeshMobileRuntime

final class MobileReceivedOutputIndexTests: XCTestCase {
    func testReplacedIndexReportsCoarseAvailabilityFailure() async throws {
        let f = try HistoryFixture(); defer { f.remove() }
        let result = try await f.receive("valid")
        let index = f.index()
        try await index.recordCompletedReceive(result)
        try FileManager.default.moveItem(at: f.indexURL, to: f.root.appendingPathComponent("old-index"))
        try Data("bad".utf8).write(to: f.indexURL)
        let url = await index.availableURL(for: result.transferID)
        let failure = await index.availabilityFailure
        XCTAssertNil(url)
        XCTAssertEqual(failure, .receivedOutputIndexUnavailable)
    }
    func testFreshLookupRechecksDatabasePhaseDirectionAndBytes() async throws {
        let f = try HistoryFixture(); defer { f.remove() }
        let result = try await f.receive("valid")
        let index = f.index()
        try await index.recordCompletedReceive(result)
        var connection: OpaquePointer?
        let databaseURL = f.indexURL.deletingLastPathComponent().appendingPathComponent("transfers.sqlite3")
        XCTAssertEqual(sqlite3_open(databaseURL.path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        for update in ["phase = 'failed'", "phase = 'completed', direction = 'outbound'", "direction = 'inbound', completed_bytes = 0"] {
            XCTAssertEqual(sqlite3_exec(connection, "UPDATE transfers SET \(update)", nil, nil, nil), SQLITE_OK)
            let url = await index.availableURL(for: result.transferID)
            XCTAssertNil(url)
        }
    }

    func testRejectsCallbackDotTraversalEvenWhenItNormalizesInsideRoot() async throws {
        let f = try HistoryFixture(); defer { f.remove() }
        let result = try await f.receive("valid")
        let aliased = URL(fileURLWithPath: f.receiveRoot.path + "/nested/../valid")
        await reject(f.index(), TransferReceiveResult(transferID: result.transferID, receivedURLs: [aliased], source: f.peer))
    }

    func testRejectsIndexSymlinkFIFOHardLinkAndNonprivateMode() async throws {
        let f = try HistoryFixture(); defer { f.remove() }
        let result = try await f.receive("valid")
        try await f.index().recordCompletedReceive(result)
        let saved = f.root.appendingPathComponent("saved-index")
        try FileManager.default.moveItem(at: f.indexURL, to: saved)
        for kind in ["symlink", "fifo", "hardlink", "permissions"] {
            switch kind {
            case "symlink": try FileManager.default.createSymbolicLink(at: f.indexURL, withDestinationURL: saved)
            case "fifo": XCTAssertEqual(mkfifo(f.indexURL.path, 0o600), 0)
            case "hardlink": XCTAssertEqual(link(saved.path, f.indexURL.path), 0)
            default:
                try FileManager.default.copyItem(at: saved, to: f.indexURL)
                XCTAssertEqual(chmod(f.indexURL.path, 0o644), 0)
            }
            let index = f.index()
            let url = await index.availableURL(for: result.transferID)
            let diagnostic = await index.availabilityFailure
            XCTAssertNil(url)
            XCTAssertEqual(diagnostic, .receivedOutputIndexUnavailable)
            try FileManager.default.removeItem(at: f.indexURL)
        }
    }

    func testRestartPinsCollisionResolvedFileAndDirectory() async throws {
        let f = try HistoryFixture(); defer { f.remove() }
        for directory in [false, true] {
            let result = try await f.receive(directory ? "folder (2)" : "report (2).pdf", directory: directory)
            let index = f.index()
            try await index.recordCompletedReceive(result)
            let reopened = f.index()
            let url = await reopened.availableURL(for: result.transferID)
            XCTAssertEqual(url?.path, result.receivedURLs.first?.path)
            let mode = try FileManager.default.attributesOfItem(atPath: f.indexURL.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o600)
        }
    }

    func testDatabaseAndSourceGates() async throws {
        let f = try HistoryFixture(); defer { f.remove() }
        let index = f.index()
        for (phase, direction, bytes) in [(TransferPhase.failed, TransferRecordDirection.inbound, Int64(1)), (.completed, .outbound, 1), (.completed, .inbound, 0)] {
            let r = try await f.receive(UUID().uuidString, phase: phase, direction: direction, bytes: bytes)
            await reject(index, r)
        }
        let good = try await f.receive("valid")
        await reject(index, TransferReceiveResult(transferID: good.transferID, receivedURLs: good.receivedURLs))
        await reject(index, TransferReceiveResult(transferID: good.transferID, receivedURLs: good.receivedURLs, source: DeviceID(rawValue: UUID())))
        await reject(index, TransferReceiveResult(transferID: TransferID(rawValue: UUID()), receivedURLs: good.receivedURLs, source: f.peer))
    }

    func testRejectsUntrustedCallbackPathsAndSpecialFiles() async throws {
        let f = try HistoryFixture(); defer { f.remove() }
        let r = try await f.receive("valid")
        let nested = f.receiveRoot.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let outside = f.root.appendingPathComponent("outside")
        try Data([1]).write(to: outside)
        let link = f.receiveRoot.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let fifo = f.receiveRoot.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let index = f.index()
        for urls in [[], r.receivedURLs + r.receivedURLs, [URL(string: "https://example.invalid/item")!], [outside], [nested.appendingPathComponent("child")], [link], [fifo], [f.receiveRoot], [f.receiveRoot.appendingPathComponent("..")], [URL(string: f.receiveRoot.absoluteString + "/nested%2Fchild")!]] {
            await reject(index, TransferReceiveResult(transferID: r.transferID, receivedURLs: urls, source: f.peer))
        }
    }

    func testFreshLookupRejectsMovedReplacedSymlinkAndKindChanges() async throws {
        let f = try HistoryFixture(); defer { f.remove() }
        for replacement in ["missing", "file", "directory", "symlink"] {
            let r = try await f.receive(replacement)
            let index = f.index()
            try await index.recordCompletedReceive(r)
            let url = r.receivedURLs[0]
            // Retain the old inode so the filesystem cannot recycle it in this test.
            try FileManager.default.moveItem(at: url, to: f.root.appendingPathComponent(replacement + "-moved"))
            switch replacement {
            case "file": try Data([2]).write(to: url)
            case "directory": try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            case "symlink": try FileManager.default.createSymbolicLink(at: url, withDestinationURL: f.root)
            default: break
            }
            let available = await index.availableURL(for: r.transferID)
            XCTAssertNil(available)
        }
    }

    func testRejectsCorruptUnboundedAndUnsafeIndexWithoutRemovingIt() async throws {
        let f = try HistoryFixture(); defer { f.remove() }
        let r = try await f.receive("valid")
        try await f.index().recordCompletedReceive(r)
        let original = try Data(contentsOf: f.indexURL)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        let entry = try XCTUnwrap((envelope["entries"] as? [[String: Any]])?.first)
        var bad: [Data] = [Data("bad".utf8), Data(repeating: 32, count: 1_048_577)]
        for leaf in ["", ".", "..", "../secret", "/secret", "nested/child", "nested%2Fchild", "bad\0name"] {
            var edited = entry; edited["leafName"] = leaf
            bad.append(try JSONSerialization.data(withJSONObject: ["version": 1, "entries": [edited]]))
        }
        for payload: [String: Any] in [["version": 2, "entries": [entry]], ["version": 1, "entries": [entry, entry]], ["version": 1, "entries": Array(repeating: entry, count: 1001)]] {
            bad.append(try JSONSerialization.data(withJSONObject: payload))
        }
        for data in bad {
            try data.write(to: f.indexURL)
            let index = f.index()
            let available = await index.availableURL(for: r.transferID)
            XCTAssertNil(available)
            let diagnostic = await index.availabilityFailure
            XCTAssertEqual(diagnostic, .receivedOutputIndexUnavailable)
            XCTAssertEqual(try Data(contentsOf: f.indexURL), data)
        }
    }

    func testIndexAndRootReplacementFailClosed() async throws {
        let f = try HistoryFixture(); defer { f.remove() }
        let r = try await f.receive("valid")
        let index = f.index()
        try await index.recordCompletedReceive(r)
        try FileManager.default.moveItem(at: f.receiveRoot, to: f.root.appendingPathComponent("old-root"))
        try FileManager.default.createDirectory(at: f.receiveRoot, withIntermediateDirectories: false)
        let available = await index.availableURL(for: r.transferID)
        XCTAssertNil(available)
        try FileManager.default.removeItem(at: f.indexURL)
        try FileManager.default.createSymbolicLink(at: f.indexURL, withDestinationURL: f.root.appendingPathComponent("untouched"))
        await reject(index, r)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("untouched").path))
    }

    func testBoundAndDuplicateCallbackPreservePinnedIdentity() async throws {
        let f = try HistoryFixture(); defer { f.remove() }
        let index = f.index(maximum: 2)
        var results: [TransferReceiveResult] = []
        for i in 0..<3 { let r = try await f.receive("item\(i)"); results.append(r); try await index.recordCompletedReceive(r) }
        let evicted = await index.availableURL(for: results[0].transferID)
        XCTAssertNil(evicted)
        try await index.recordCompletedReceive(results[2])
        let last = await index.availableURL(for: results[2].transferID)
        XCTAssertNotNil(last)
        try FileManager.default.moveItem(at: results[2].receivedURLs[0], to: f.root.appendingPathComponent("old"))
        try Data([2]).write(to: results[2].receivedURLs[0])
        await reject(index, results[2])
        let replaced = await index.availableURL(for: results[2].transferID)
        XCTAssertNil(replaced)
    }

    private func reject(_ index: MobileReceivedOutputIndex, _ result: TransferReceiveResult) async {
        do { try await index.recordCompletedReceive(result); XCTFail("Must reject invalid association") } catch { }
        let url = await index.availableURL(for: result.transferID)
        XCTAssertNil(url)
    }
}

struct HistoryFixture {
    let root: URL
    let receiveRoot: URL
    let indexURL: URL
    let database: TransferDatabase
    let peer = DeviceID(rawValue: UUID())
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mobile-history-\(UUID())")
        let state = root.appendingPathComponent("state")
        receiveRoot = root.appendingPathComponent("receive")
        for url in [state, receiveRoot] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        indexURL = state.appendingPathComponent("received-outputs-v1.json")
        database = try TransferDatabase(url: state.appendingPathComponent("transfers.sqlite3"))
    }
    func index(maximum: Int = 1000) -> MobileReceivedOutputIndex {
        MobileReceivedOutputIndex(url: indexURL, receiveDirectory: receiveRoot, database: database, maximumEntryCount: maximum)
    }
    func receive(_ leaf: String, directory: Bool = false, phase: TransferPhase = .completed, direction: TransferRecordDirection = .inbound, bytes: Int64 = 1) async throws -> TransferReceiveResult {
        let url = receiveRoot.appendingPathComponent(leaf, isDirectory: directory)
        if directory { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
        else { try Data([1]).write(to: url) }
        let id = TransferID(rawValue: UUID())
        try await database.record(TransferSnapshot(id: id, peer: peer, phase: phase, completedBytes: bytes, totalBytes: 1, route: .lan), displayFilename: "metadata-only", direction: direction)
        return TransferReceiveResult(transferID: id, receivedURLs: [url], source: peer)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
