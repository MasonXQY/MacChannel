import AppKit
import Foundation
import XCTest

@testable import MacChannelAppKit

final class ClipboardTransferSourceTests: XCTestCase {
    private var temporaryRoot: URL!
    private let fixedDate = Date(timeIntervalSince1970: 1_704_164_245)

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardTransferSourceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporaryRoot)
    }

    @MainActor
    func testFilesWinOverImageAndTextWithoutMutatingPasteboard() throws {
        let pasteboard = makePasteboard()
        let file = temporaryRoot.appendingPathComponent("report.pdf")
        try Data("report".utf8).write(to: file)
        XCTAssertTrue(pasteboard.writeObjects([file as NSURL]))
        XCTAssertTrue(pasteboard.writeObjects([makeImage()]))
        pasteboard.setString("secret", forType: .string)
        let before = pasteboard.changeCount

        let prepared = try makePreparer(pasteboard).prepare()

        XCTAssertEqual(prepared.urls, [file.standardizedFileURL])
        XCTAssertTrue(prepared.ownedTemporaryURLs.isEmpty)
        XCTAssertEqual(pasteboard.changeCount, before)
    }

    @MainActor
    func testImageWinsOverTextAndProducesReadablePNG() throws {
        let pasteboard = makePasteboard()
        XCTAssertTrue(pasteboard.writeObjects([makeImage()]))
        pasteboard.setString("secret", forType: .string)

        let prepared = try makePreparer(pasteboard).prepare()

        XCTAssertEqual(prepared.urls, prepared.ownedTemporaryURLs)
        XCTAssertEqual(prepared.urls.count, 1)
        XCTAssertEqual(prepared.urls.first?.lastPathComponent, expectedName(kind: "图片", ext: "png"))
        XCTAssertNotNil(NSImage(contentsOf: try XCTUnwrap(prepared.urls.first)))
    }

    @MainActor
    func testTextProducesUTF8FileWithDeterministicName() throws {
        let pasteboard = makePasteboard()
        let text = "你好, DropMesh 👋"
        pasteboard.setString(text, forType: .string)

        let prepared = try makePreparer(pasteboard).prepare()

        let output = try XCTUnwrap(prepared.urls.first)
        XCTAssertEqual(prepared.urls, prepared.ownedTemporaryURLs)
        XCTAssertEqual(output.lastPathComponent, expectedName(kind: "文字", ext: "txt"))
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), text)
    }

    @MainActor
    func testExistingGeneratedNameUsesIncrementingSuffix() throws {
        let pasteboard = makePasteboard()
        pasteboard.setString("one", forType: .string)
        try Data().write(to: temporaryRoot.appendingPathComponent(expectedName(kind: "文字", ext: "txt")))

        let prepared = try makePreparer(pasteboard).prepare()

        XCTAssertEqual(
            prepared.urls.first?.lastPathComponent,
            expectedName(kind: "文字", suffix: 2, ext: "txt")
        )
    }

    @MainActor
    func testPreexistingTemporaryRootIsRestrictedToOwner() throws {
        let pasteboard = makePasteboard()
        pasteboard.setString("secret", forType: .string)

        _ = try makePreparer(pasteboard).prepare()

        let attributes = try FileManager.default.attributesOfItem(atPath: temporaryRoot.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
        XCTAssertEqual(permissions & 0o777, 0o700)
    }

    @MainActor
    func testEmptyTextIsNotSupportedAndDoesNotCreateAFile() throws {
        let pasteboard = makePasteboard()
        pasteboard.setString("", forType: .string)

        XCTAssertThrowsError(try makePreparer(pasteboard).prepare()) {
            XCTAssertEqual($0 as? ClipboardTransferPreparationError, .noSupportedContent)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporaryRoot.path), [])
    }

    @MainActor
    func testUnsupportedDataIsNotSupported() {
        let pasteboard = makePasteboard()
        pasteboard.setData(
            Data([0x01, 0x02]),
            forType: NSPasteboard.PasteboardType("com.dropmesh.unsupported")
        )

        XCTAssertThrowsError(try makePreparer(pasteboard).prepare()) {
            XCTAssertEqual($0 as? ClipboardTransferPreparationError, .noSupportedContent)
        }
    }

    @MainActor
    private func makePreparer(_ pasteboard: NSPasteboard) -> NativeClipboardTransferPreparer {
        NativeClipboardTransferPreparer(
            pasteboard: pasteboard,
            temporaryRoot: temporaryRoot,
            now: { self.fixedDate }
        )
    }

    @MainActor
    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pasteboard.clearContents()
        return pasteboard
    }

    @MainActor
    private func makeImage() -> NSImage {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.addRepresentation(bitmap)
        return image
    }

    private func expectedName(kind: String, suffix: Int? = nil, ext: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let suffixText = suffix.map { " \($0)" } ?? ""
        return "剪贴板\(kind) \(formatter.string(from: fixedDate))\(suffixText).\(ext)"
    }
}
