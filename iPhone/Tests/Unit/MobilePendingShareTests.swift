import Foundation
import XCTest
@testable import DropMeshTestHost

@MainActor final class MobilePendingShareTests: XCTestCase {
    func testPartialPrivateImportCleanupFailureRetainsSharedClaimUntilRetry() async throws {
        let fixture = try ShareFixture(); defer { fixture.remove() }
        let store = ShareBatchStore(root: fixture.root)
        let batch = try await store.begin()
        for _ in 0..<2 { try await batch.append(fixture.source, contentType: "public.data") }
        try await batch.publish(); await batch.release()
        let privateRoot = fixture.base.appendingPathComponent("private")
        try FileManager.default.createDirectory(at: privateRoot, withIntermediateDirectories: false)
        let stager = PendingFailureStager(root: privateRoot)
        let service = MobileImportService(makeStager: { stager })
        let sender = MobileSendModel(session: InertMobileSession(), service: service)
        sender.setForeground(true)
        let pending = MobilePendingShareModel(makeStore: { store })
        await pending.refresh()
        let accepted = await pending.prepare(batch.id, using: sender)
        XCTAssertTrue(accepted)
        await sender.waitForWork()
        XCTAssertEqual(sender.phase, .cleanupFailed)
        let blocked = try await store.claim(batch.id)
        XCTAssertNil(blocked)
        sender.retryCleanup(); await sender.cancelAndWait()
        XCTAssertEqual(sender.phase, .idle)
        let reclaimed = try await store.claim(batch.id)
        XCTAssertNotNil(reclaimed)
        let originals = try await reclaimed?.files()
        XCTAssertEqual(originals?.count, 2)
        try await reclaimed?.discard()
    }
    func testPendingBatchRequiresExplicitImportRecipientAndSend() async throws {
        let fixture = try ShareFixture(); defer { fixture.remove() }
        let store = ShareBatchStore(root: fixture.root)
        let batch = try await store.begin()
        try await batch.append(fixture.source, contentType: "public.data")
        try await batch.publish(); await batch.release()
        let privateRoot = fixture.base.appendingPathComponent("private")
        try FileManager.default.createDirectory(at: privateRoot, withIntermediateDirectories: false)
        let service = MobileImportService(makeStager: { MobileSystemImportStager(directory: privateRoot) })
        let session = InertMobileSession()
        await session.setPresence(.online, peers: [session.peer])
        let sender = MobileSendModel(session: session, service: service)
        sender.setForeground(true)
        let pending = MobilePendingShareModel(makeStore: { store })
        await pending.refresh()
        XCTAssertEqual(pending.batches, [batch.id])
        XCTAssertTrue(sender.files.isEmpty)
        let imported = await pending.prepare(batch.id, using: sender)
        XCTAssertTrue(imported)
        await sender.waitForWork()
        XCTAssertEqual(sender.phase, .ready)
        XCTAssertNil(sender.selectedRecipient)
        var sends = await session.sendCount
        XCTAssertEqual(sends, 0)
        sender.send(); await sender.waitForWork()
        sends = await session.sendCount
        XCTAssertEqual(sends, 0)
        XCTAssertTrue(sender.files[0].url.path.hasPrefix(privateRoot.path + "/"))
        let remaining = try await store.pending()
        XCTAssertTrue(remaining.isEmpty)
        sender.selectRecipient(session.peer.id); sender.send(); await sender.waitForWork()
        sends = await session.sendCount
        XCTAssertEqual(sends, 1)
    }

    func testPendingCannotReplaceActivePickerAndRemainsAvailable() async throws {
        let fixture = try ShareFixture(); defer { fixture.remove() }
        let store = ShareBatchStore(root: fixture.root)
        let batch = try await store.begin()
        try await batch.append(fixture.source, contentType: "public.data")
        try await batch.publish(); await batch.release()
        let sender = MobileSendModel(session: InertMobileSession())
        sender.setForeground(true); sender.openPhotos()
        let presentation = sender.presentation?.id
        let pending = MobilePendingShareModel(makeStore: { store })
        await pending.refresh()
        let accepted = await pending.prepare(batch.id, using: sender)
        XCTAssertFalse(accepted)
        XCTAssertEqual(sender.presentation?.id, presentation)
        XCTAssertEqual(pending.batches, [batch.id])
        await sender.cancelAndWait()
    }
}

private actor PendingFailureStager: MobileImportStaging {
    private let actual: MobileSystemImportStager
    private var count = 0
    private var failCleanup = true
    init(root: URL) { actual = MobileSystemImportStager(directory: root) }
    func stage(_ source: URL, coordinated: Bool) async throws -> URL {
        count += 1
        if count == 2 { throw MobileImportError.unavailable }
        return try await actual.stage(source, coordinated: coordinated)
    }
    func discard(_ url: URL) async throws {
        if failCleanup { failCleanup = false; throw MobileImportError.cleanupFailed }
        try await actual.discard(url)
    }
}
