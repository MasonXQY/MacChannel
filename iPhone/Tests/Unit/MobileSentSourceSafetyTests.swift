import XCTest
import Foundation
import MacChannelCore
import DropMeshMobileRuntime
@testable import DropMeshTestHost

final class MobileSentSourceSafetyTests: XCTestCase {
    func testPassiveThumbnailRejectsInvalidBookmarkWithoutActionCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let actions = root.appendingPathComponent("actions")
        let store = MobileSentSourceStore(url: root.appendingPathComponent("references.json"), actions: actions)
        let id = TransferID(rawValue: UUID())
        await store.record([MobileSentHistorySource(name: "missing.pdf", bookmark: Data([1, 2, 3]))], transfer: id)
        let thumbnail = await store.thumbnail(transfer: id, item: MobileHistoryFileID(rawValue: id.rawValue),
            photo: MobilePhotoHistorySource())
        XCTAssertNil(thumbnail)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: actions.path), [])
    }

    func testThumbnailLoaderReturnsNilForMissingSource() async {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let thumbnail = await MobileHistoryThumbnailLoader.load(missing)
        XCTAssertNil(thumbnail)
    }
    func testSelectiveDeletionKeepsActiveTransferReferenceAcrossRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("references.json")
        let actions = root.appendingPathComponent("actions")
        let deleted = TransferID(rawValue: UUID()), active = TransferID(rawValue: UUID())
        let store = MobileSentSourceStore(url: url, actions: actions)
        await store.record([MobileSentHistorySource(name: "deleted.txt", bookmark: Data([1]))], transfer: deleted)
        await store.record([MobileSentHistorySource(name: "active.txt", bookmark: Data([2]))], transfer: active)
        try await store.remove(transfers: [deleted])
        let reopened = MobileSentSourceStore(url: url, actions: actions)
        let ids = await reopened.transferIDs()
        XCTAssertEqual(ids, [active])
    }
    func testPhotosRejectsSymlinkActionRootBeforeExport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let actions = root.appendingPathComponent("actions")
        try FileManager.default.createSymbolicLink(at: actions, withDestinationURL: outside)
        let store = MobileSentSourceStore(url: root.appendingPathComponent("refs.json"), actions: actions,
            resolvePhoto: { _, destination in
                let output = destination.appendingPathComponent("photo.jpg")
                try Data("private".utf8).write(to: output)
                return output
            })
        let id = TransferID(rawValue: UUID())
        await store.record([MobileSentHistorySource(name: "photo.jpg", bookmark: nil, photoAssetIdentifier: "asset")], transfer: id)
        let result = await store.resolve(transfer: id, item: MobileHistoryFileID(rawValue: id.rawValue))
        XCTAssertNil(result)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }
    func testPhotoExportFailureCleansPartialActionDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let actions = root.appendingPathComponent("actions")
        let store = MobileSentSourceStore(url: root.appendingPathComponent("references.json"), actions: actions,
            resolvePhoto: { _, destination in
                try Data("partial".utf8).write(to: destination.appendingPathComponent("partial.jpg"))
                throw CocoaError(.fileReadUnknown)
            })
        let id = TransferID(rawValue: UUID())
        await store.record([MobileSentHistorySource(name: "photo.jpg", bookmark: nil, photoAssetIdentifier: "selected-asset")], transfer: id)
        let output = await store.resolve(transfer: id, item: MobileHistoryFileID(rawValue: id.rawValue))
        XCTAssertNil(output)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: actions.path), [])
    }
    func testMalformedIndexIsNotOverwrittenByNextSend() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("references.json")
        let invalid = Data("corrupt index".utf8)
        try invalid.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let store = MobileSentSourceStore(url: url, actions: root.appendingPathComponent("actions"))
        await store.record([MobileSentHistorySource(name: "new.txt", bookmark: Data([1]))], transfer: TransferID(rawValue: UUID()))
        XCTAssertEqual(try Data(contentsOf: url), invalid)
    }
    func testOversizedMetadataDoesNotPreventNextSmallRecordFromPersisting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("references.json")
        let actions = root.appendingPathComponent("actions")
        let store = MobileSentSourceStore(url: url, actions: actions)
        let huge = (0..<30).map { MobileSentHistorySource(name: "file-\($0).txt", bookmark: Data(repeating: 3, count: 60_000)) }
        await store.record(huge, transfer: TransferID(rawValue: UUID()))
        let smallID = TransferID(rawValue: UUID())
        await store.record([MobileSentHistorySource(name: "small.txt", bookmark: Data([1]))], transfer: smallID)
        let reopened = MobileSentSourceStore(url: url, actions: actions)
        let exists = await reopened.contains(MobileHistoryFileID(rawValue: smallID.rawValue))
        XCTAssertTrue(exists)
    }

    func testReleaseCannotRemoveAnUnownedDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let unrelated = root.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = unrelated.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: file)
        let store = MobileSentSourceStore(url: root.appendingPathComponent("references.json"), actions: root.appendingPathComponent("actions"))
        await store.release(file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
}
