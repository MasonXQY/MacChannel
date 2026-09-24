import XCTest
import UIKit
import MacChannelCore
import DropMeshMobileRuntime
@testable import DropMeshTestHost

@MainActor
final class MobileThumbnailUXTests: XCTestCase {
    func testDocumentFirstPageThumbnail() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 320, height: 480)).pdfData { context in
            context.beginPage()
            UIColor.systemBlue.setFill()
            context.cgContext.fill(CGRect(x: 20, y: 20, width: 280, height: 80))
        }.write(to: url)
        let image = await MobileHistoryThumbnailLoader.load(url)
        XCTAssertNotNil(image)
    }
    func testSentBatchUsesAvailableIndividualImageWithoutOpeningPreview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("photo.png")
        try UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400)).pngData { c in
            UIColor.systemGreen.setFill(); c.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        }.write(to: url)
        let session = InertMobileSession()
        let id = TransferID(rawValue: UUID())
        let first = MobileHistoryFileID(rawValue: UUID()), second = MobileHistoryFileID(rawValue: UUID())
        var row = MobileHistoryEntry(id: id, peer: session.peer.id, displayName: "2 files", aggregateSize: 1,
            completedBytes: 1, updatedAt: Date(), route: .lan, phase: .cancelled, direction: .outbound, isAvailable: false)
        row.files = [first, second].map { MobileTransferHistoryFile(id: $0, name: "photo.png", size: 1,
            isDirectory: false, isAvailable: true, availableURL: nil) }
        await session.setHistory([row]); await session.setHistoryFileURLs([second: url])
        let model = MobileHistoryModel(session: session)
        await model.refresh()
        let image = await model.thumbnail(for: id)
        XCTAssertNotNil(image)
        let requests = await session.thumbnailRequests
        XCTAssertEqual(requests, [first, second])
        XCTAssertNil(model.presentation)
        _ = await model.deleteRecords(ids: [id])
        let deleted = await model.thumbnail(for: id)
        XCTAssertNil(deleted)
    }
    func testActualImageIsDownsampledAndDoesNotOpenPreview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("fixture.png")
        let data = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 480)).pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
        }
        try data.write(to: url)
        let session = InertMobileSession()
        let id = TransferID(rawValue: UUID())
        await session.setReceivedURL(url)
        await session.setHistory([MobileHistoryEntry(id: id, peer: session.peer.id,
            displayName: "fixture.png", aggregateSize: UInt64(data.count), completedBytes: UInt64(data.count),
            updatedAt: Date(), route: .lan, phase: .completed, direction: .inbound, isAvailable: true)])
        let model = MobileHistoryModel(session: session)
        await model.refresh()
        let result = await model.thumbnail(for: id)
        let thumbnail = try XCTUnwrap(result)
        XCTAssertLessThanOrEqual(max(thumbnail.image.size.width, thumbnail.image.size.height), 160)
        XCTAssertGreaterThan(thumbnail.image.size.width, 0)
        XCTAssertNil(model.presentation)
        model.close()
        let afterClose = await model.thumbnail(for: id)
        XCTAssertNil(afterClose)
    }
}
