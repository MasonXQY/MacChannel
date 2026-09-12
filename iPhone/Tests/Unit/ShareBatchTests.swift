import Darwin
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import DropMeshTestHost

final class ShareBatchTests: XCTestCase {
    func testProtectionSetterFailureCannotBeReportedAsSuccess() {
        XCTAssertThrowsError(try ShareFS.protect(-1))
    }
    func testAbandonedPartialCopyIsNeverReadyAndIsCleanedOnlyAfterExpiry() async throws {
        let fixture = try ShareFixture(); defer { fixture.remove() }
        let store = ShareBatchStore(root: fixture.root)
        let batch = try await store.begin()
        let partialDirectory = fixture.root.appendingPathComponent(batch.id.uuidString).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: partialDirectory, withIntermediateDirectories: false)
        try Data("partial copy".utf8).write(to: partialDirectory.appendingPathComponent(".\(UUID().uuidString).partial"))
        await batch.release() // exact on-disk state after process death during copy
        let pending = try await store.pending()
        XCTAssertTrue(pending.isEmpty)
        try await store.cleanup()
        XCTAssertTrue(FileManager.default.fileExists(atPath: partialDirectory.path))
        try await store.cleanup(now: Date().addingTimeInterval(48 * 3600))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), [])
    }
    func testMalformedTraversalAndOversizedManifestAreRejected() async throws {
        for mutation in ["traversal", "directory", "oversized", "invalid-json"] {
            let fixture = try ShareFixture(); defer { fixture.remove() }
            let store = ShareBatchStore(root: fixture.root)
            let batch = try await store.begin()
            try await batch.append(fixture.source, contentType: "public.data")
            try await batch.publish(); await batch.release()
            let manifest = fixture.root.appendingPathComponent(batch.id.uuidString).appendingPathComponent(".ready")
            let original = try JSONDecoder().decode(ShareManifest.self, from: Data(contentsOf: manifest))
            if mutation == "oversized" { try Data(repeating: 65, count: 32769).write(to: manifest) }
            else if mutation == "invalid-json" { try Data("broken".utf8).write(to: manifest) }
            else {
                let item = original.items[0]
                let changed = ShareManifest.Item(directory: mutation == "directory" ? "../outside" : item.directory,
                    name: mutation == "traversal" ? "../outside" : item.name, contentType: item.contentType, size: item.size)
                try JSONEncoder().encode(ShareManifest(version: 1, id: batch.id, created: Date(), items: [changed])).write(to: manifest)
            }
            do { _ = try await store.claim(batch.id); XCTFail("accepted malformed manifest: \(mutation)") } catch {}
            XCTAssertEqual(try Data(contentsOf: fixture.source), Data("payload".utf8))
        }
    }

    func testSymlinkPayloadAndSymlinkBatchRootsAreRejectedWithoutFollowing() async throws {
        let fixture = try ShareFixture(); defer { fixture.remove() }
        let store = ShareBatchStore(root: fixture.root)
        let batch = try await store.begin()
        try await batch.append(fixture.source, contentType: "public.data")
        try await batch.publish()
        let files = try await batch.files()
        await batch.release()
        try FileManager.default.removeItem(at: files[0])
        try FileManager.default.createSymbolicLink(at: files[0], withDestinationURL: fixture.source)
        do { _ = try await store.claim(batch.id); XCTFail("followed payload symlink") } catch {}
        do { try await store.cleanup(now: Date().addingTimeInterval(48 * 3600)); XCTFail("removed unvalidated copy") } catch {}
        XCTAssertEqual(try Data(contentsOf: fixture.source), Data("payload".utf8))
        let alias = fixture.base.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root)
        do { _ = try await ShareBatchStore(root: alias).begin(); XCTFail("followed root symlink") } catch {}
    }

    func testFIFOAndTooManyItemsAreRejectedWithExactCleanup() async throws {
        let fixture = try ShareFixture(); defer { fixture.remove() }
        let fifo = fixture.base.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let store = ShareBatchStore(root: fixture.root)
        let batch = try await store.begin()
        do { try await batch.append(fifo, contentType: "public.data"); XCTFail("accepted FIFO") } catch {}
        for _ in 0..<10 { try await batch.append(fixture.source, contentType: "public.data") }
        do { try await batch.append(fixture.source, contentType: "public.data"); XCTFail("accepted eleventh item") } catch {}
        try await batch.discard()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), [])
    }

    func testConcurrentClaimsHaveExactlyOneOwner() async throws {
        let fixture = try ShareFixture(); defer { fixture.remove() }
        let store = ShareBatchStore(root: fixture.root)
        let batch = try await store.begin()
        try await batch.append(fixture.source, contentType: "public.data")
        try await batch.publish(); await batch.release()
        async let first = ShareBatchStore(root: fixture.root).claim(batch.id)
        async let second = ShareBatchStore(root: fixture.root).claim(batch.id)
        let claims = try await [first, second].compactMap { $0 }
        XCTAssertEqual(claims.count, 1)
        try await claims[0].acknowledge()
    }

    func testCopiesUseCompleteProtectionAndExcludedBackupRoot() async throws {
        let fixture = try ShareFixture(); defer { fixture.remove() }
        let store = ShareBatchStore(root: fixture.root)
        let batch = try await store.begin()
        try await batch.append(fixture.source, contentType: "public.data")
        try await batch.publish()
        let file = try await batch.files()[0]
        // Simulator FileManager omits protectionKey; query the actual policy via
        // the matching descriptor API. Locked-device enforcement is a device gate.
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW)
        defer { close(descriptor) }
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(fcntl(descriptor, F_GETPROTECTIONCLASS), 1)
        XCTAssertEqual(try fixture.root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        try await batch.discard()
    }
    func testOnlyPublishedCompleteBatchCanBeClaimedAndAcknowledgementRetiresIt() async throws {
        let fixture = try ShareFixture(); defer { fixture.remove() }
        let store = ShareBatchStore(root: fixture.root)
        var batch: ShareBatch? = try await store.begin()
        let owner = try XCTUnwrap(batch)
        try await owner.append(fixture.source, contentType: UTType.data.identifier)
        let unpublished = try await store.pending()
        XCTAssertTrue(unpublished.isEmpty)
        try await owner.publish()
        let id = owner.id
        let held = try await store.claim(id)
        XCTAssertNil(held) // writer still owns its lock
        await owner.release()
        batch = nil
        let pending = try await store.pending()
        XCTAssertEqual(pending, [id])
        let acquired = try await store.claim(id)
        let claim = try XCTUnwrap(acquired)
        let duplicate = try await ShareBatchStore(root: fixture.root).claim(id)
        XCTAssertNil(duplicate)
        let files = try await claim.files()
        XCTAssertEqual(try Data(contentsOf: files[0]), Data("payload".utf8))
        try await claim.acknowledge()
        let remaining = try await store.pending()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
    }

    func testSameNameItemsKeepSeparateCopiesAndCancellationRemovesOnlyOwnedBatch() async throws {
        let fixture = try ShareFixture(); defer { fixture.remove() }
        let store = ShareBatchStore(root: fixture.root)
        let batch = try await store.begin()
        try await batch.append(fixture.source, contentType: UTType.data.identifier)
        try await batch.append(fixture.source, contentType: UTType.data.identifier)
        try await batch.publish()
        let files = try await batch.files()
        XCTAssertEqual(files.count, 2)
        XCTAssertNotEqual(files[0], files[1])
        try await batch.discard()
        let remaining = try await store.pending()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
    }

    func testSymlinkAndDirectorySourcesNeverPublish() async throws {
        let fixture = try ShareFixture(); defer { fixture.remove() }
        let link = fixture.base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.source)
        let store = ShareBatchStore(root: fixture.root)
        let batch = try await store.begin()
        for url in [link, fixture.base] {
            do { try await batch.append(url, contentType: UTType.data.identifier); XCTFail("accepted non-regular source") }
            catch {}
        }
        let remaining = try await store.pending()
        XCTAssertTrue(remaining.isEmpty)
        try await batch.discard()
    }

    func testStaleCleanupSkipsLiveWriterThenReclaimsAbandonedCopies() async throws {
        let fixture = try ShareFixture(); defer { fixture.remove() }
        let store = ShareBatchStore(root: fixture.root)
        let batch = try await store.begin()
        try await batch.append(fixture.source, contentType: UTType.data.identifier)
        try await store.cleanup(now: Date().addingTimeInterval(48 * 3600))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(batch.id.uuidString).path))
        await batch.release() // models process termination, without a ready manifest
        try await store.cleanup(now: Date().addingTimeInterval(48 * 3600))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(batch.id.uuidString).path))
    }
}

struct ShareFixture {
    let base: URL
    let root: URL
    let source: URL
    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = base.appendingPathComponent("shares")
        source = base.appendingPathComponent("example.txt")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: source)
    }
    func remove() { try? FileManager.default.removeItem(at: base) }
}
