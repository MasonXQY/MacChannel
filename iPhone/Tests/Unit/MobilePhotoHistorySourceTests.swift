import Photos
import XCTest
@testable import DropMeshTestHost

final class MobilePhotoHistorySourceTests: XCTestCase {
    func testPassiveThumbnailDeniedDoesNotAuthorizeExportOrRequestImage() async {
        let calls = LockedPhotoCalls()
        let source = MobilePhotoHistorySource(authorize: { calls.authorize(); return .authorized },
            export: { _, _ in calls.export(); throw MobilePhotoHistorySourceError.downloadFailed },
            thumbnailStatus: { .denied }, requestThumbnail: { _ in calls.thumbnail(); return nil })
        let thumbnail = await source.thumbnail(assetIdentifier: "asset")
        XCTAssertNil(thumbnail)
        XCTAssertEqual(calls.values, [0, 0, 0])
    }
    func testPickerIdentifiersAttachInSelectionOrderWithoutPhotosAuthorization() {
        let attempt = UUID()
        let files = ["one", "two"].map {
            MobileImportedFile(url: URL(fileURLWithPath: "/tmp/\($0)"), attempt: attempt, copy: UUID())
        }
        let attached = MobilePhotoImport.attachAssetIdentifiers(to: files, identifiers: ["asset-1", "asset-2"])
        XCTAssertEqual(attached.map(\.photoAssetIdentifier), ["asset-1", "asset-2"])
    }

    func testDeniedAuthorizationDoesNotTouchExporter() async throws {
        let called = LockedFlag()
        let source = MobilePhotoHistorySource(authorize: { .denied }, export: { _, _ in
            called.set(); throw MobilePhotoHistorySourceError.downloadFailed
        })
        do {
            _ = try await source.resolve(assetIdentifier: "asset", destination: FileManager.default.temporaryDirectory)
            XCTFail("Denied Photos access resolved")
        } catch {
            XCTAssertEqual(error as? MobilePhotoHistorySourceError, .permissionDenied)
        }
        XCTAssertFalse(called.value)
    }

    func testLimitedAuthorizationExportsIntoOwnedDirectory() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = MobilePhotoHistorySource(authorize: { .limited }, export: { identifier, destination in
            XCTAssertEqual(identifier, "photos-id")
            let output = destination.appendingPathComponent("video.mov")
            try Data("video".utf8).write(to: output)
            return output
        })
        let output = try await source.resolve(assetIdentifier: "photos-id", destination: directory)
        XCTAssertEqual(try Data(contentsOf: output), Data("video".utf8))
    }

    func testCancellationAfterExportRemovesOnlyExactOutput() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let retained = directory.appendingPathComponent("retained")
        try Data("keep".utf8).write(to: retained)
        let gate = PhotoExportGate()
        let source = MobilePhotoHistorySource(authorize: { .authorized }, export: { _, destination in
            let output = destination.appendingPathComponent("temporary.jpg")
            try Data("photo".utf8).write(to: output)
            await gate.didExport(output)
            await gate.waitForRelease()
            return output
        })
        let task = Task { try await source.resolve(assetIdentifier: "photos-id", destination: directory) }
        let output = await gate.waitForOutput()
        task.cancel()
        await gate.release()
        do { _ = try await task.value; XCTFail("Cancelled resolution succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try Data(contentsOf: retained), Data("keep".utf8))
    }

    func testRejectsExporterEscapingOwnedDirectory() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outside = directory.deletingLastPathComponent().appendingPathComponent("outside-\(UUID())")
        defer { try? FileManager.default.removeItem(at: outside) }
        let source = MobilePhotoHistorySource(authorize: { .authorized }, export: { _, _ in
            try Data("outside".utf8).write(to: outside)
            return outside
        })
        do { _ = try await source.resolve(assetIdentifier: "asset", destination: directory); XCTFail("Escaped output accepted") }
        catch { XCTAssertEqual(error as? MobilePhotoHistorySourceError, .downloadFailed) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("photo-history-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return storage }
    func set() { lock.lock(); storage = true; lock.unlock() }
}
private final class LockedPhotoCalls: @unchecked Sendable {
    private let lock = NSLock(); private var storage = [0, 0, 0]
    var values: [Int] { lock.lock(); defer { lock.unlock() }; return storage }
    func authorize() { lock.lock(); storage[0] += 1; lock.unlock() }
    func export() { lock.lock(); storage[1] += 1; lock.unlock() }
    func thumbnail() { lock.lock(); storage[2] += 1; lock.unlock() }
}

private actor PhotoExportGate {
    private var output: URL?
    private var waiters: [CheckedContinuation<URL, Never>] = []
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    func didExport(_ url: URL) {
        output = url
        for waiter in waiters { waiter.resume(returning: url) }
        waiters.removeAll()
    }
    func waitForOutput() async -> URL {
        if let output { return output }
        return await withCheckedContinuation { waiters.append($0) }
    }
    func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }
    func release() {
        released = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll()
    }
}
