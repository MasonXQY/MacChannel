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
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
        XCTAssertEqual(permissions & 0o777, 0o600)
    }

    @MainActor
    func testDefaultRootIsAClipboardTransfersChildOfTheUserCachesDirectory() {
        let cachesDirectory = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0].standardizedFileURL
        let defaultRoot = NativeClipboardTransferPreparer.defaultTemporaryRoot.standardizedFileURL

        XCTAssertTrue(isStrictDescendant(defaultRoot, of: cachesDirectory))
        XCTAssertEqual(defaultRoot.lastPathComponent, "ClipboardTransfers")
        XCTAssertEqual(defaultRoot.deletingLastPathComponent().lastPathComponent, "MacChannel")
    }

    @MainActor
    func testCacheDefaultPreparesUTF8ContentUsingAnInjectedCacheDirectory() throws {
        let pasteboard = makePasteboard()
        pasteboard.setString("cache payload", forType: .string)
        let cacheDirectory = temporaryRoot.appendingPathComponent("cache-root")
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        let prepared = try NativeClipboardTransferPreparer(
            pasteboard: pasteboard,
            now: { self.fixedDate },
            cacheDirectory: cacheDirectory
        ).prepare()
        let output = try XCTUnwrap(prepared.urls.first)

        XCTAssertTrue(isStrictDescendant(output, of: cacheDirectory))
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "cache payload")
    }

    @MainActor
    func testWhitespaceOnlyTextIsAcceptedByteForByte() throws {
        let pasteboard = makePasteboard()
        let text = " \n\t "
        pasteboard.setString(text, forType: .string)

        let prepared = try makePreparer(pasteboard).prepare()

        XCTAssertEqual(
            try Data(contentsOf: XCTUnwrap(prepared.urls.first)),
            Data(text.utf8)
        )
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
    func testInterleavedPreparersReserveDifferentNamesWithoutOverwritingEitherPayload() throws {
        let firstPasteboard = makePasteboard()
        firstPasteboard.setString("first", forType: .string)
        let secondPasteboard = makePasteboard()
        secondPasteboard.setString("second", forType: .string)
        var secondPrepared: PreparedClipboardTransfer?
        let firstPreparer = NativeClipboardTransferPreparer(
            pasteboard: firstPasteboard,
            temporaryRoot: temporaryRoot,
            now: { self.fixedDate },
            reservationHook: { _ in
                secondPrepared = try NativeClipboardTransferPreparer(
                    pasteboard: secondPasteboard,
                    temporaryRoot: self.temporaryRoot,
                    now: { self.fixedDate }
                ).prepare()
            }
        )

        let firstPrepared = try firstPreparer.prepare()
        let secondOutput = try XCTUnwrap(secondPrepared?.urls.first)
        let firstOutput = try XCTUnwrap(firstPrepared.urls.first)

        XCTAssertNotEqual(firstOutput, secondOutput)
        XCTAssertEqual(try String(contentsOf: firstOutput, encoding: .utf8), "first")
        XCTAssertEqual(try String(contentsOf: secondOutput, encoding: .utf8), "second")
    }

    @MainActor
    func testDiscardTemporaryFilesDeletesOnlyOwnedURLsAndIsIdempotent() throws {
        let copiedSource = temporaryRoot.appendingPathComponent("copied-source.txt")
        let ownedTemporary = temporaryRoot.appendingPathComponent("owned-temporary.txt")
        try Data("source".utf8).write(to: copiedSource)
        try Data("temporary".utf8).write(to: ownedTemporary)
        let prepared = PreparedClipboardTransfer(
            urls: [copiedSource, ownedTemporary],
            ownedTemporaryURLs: [ownedTemporary]
        )

        prepared.discardTemporaryFiles()
        prepared.discardTemporaryFiles()

        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedSource.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedTemporary.path))
    }

    @MainActor
    func testPreparationFailureCleansItsReservedPlaceholder() throws {
        let pasteboard = makePasteboard()
        pasteboard.setString("secret", forType: .string)
        let preparer = NativeClipboardTransferPreparer(
            pasteboard: pasteboard,
            temporaryRoot: temporaryRoot,
            now: { self.fixedDate },
            reservationHook: { _ in throw ClipboardTestFailure.expected }
        )

        XCTAssertThrowsError(try preparer.prepare()) {
            XCTAssertEqual($0 as? ClipboardTransferPreparationError, .cannotCreateTemporaryFile)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporaryRoot.path), [])
    }

    @MainActor
    func testSymlinkTemporaryRootIsRejectedWithoutWritingOutsideIt() throws {
        let pasteboard = makePasteboard()
        pasteboard.setString("secret", forType: .string)
        let outsideRoot = temporaryRoot.appendingPathComponent("outside")
        let symlinkRoot = temporaryRoot.appendingPathComponent("symlink-root")
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: outsideRoot)

        XCTAssertThrowsError(
            try NativeClipboardTransferPreparer(
                pasteboard: pasteboard,
                temporaryRoot: symlinkRoot,
                now: { self.fixedDate }
            ).prepare()
        ) {
            XCTAssertEqual($0 as? ClipboardTransferPreparationError, .cannotCreateTemporaryFile)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outsideRoot.path), [])
    }

    @MainActor
    func testAncestorSymlinkIsRejectedWithoutCreatingAChildOutsideTheRoot() throws {
        let pasteboard = makePasteboard()
        pasteboard.setString("secret", forType: .string)
        let outsideRoot = temporaryRoot.appendingPathComponent("outside")
        let symlinkParent = temporaryRoot.appendingPathComponent("symlink-parent")
        let requestedRoot = symlinkParent.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlinkParent, withDestinationURL: outsideRoot)

        XCTAssertThrowsError(
            try NativeClipboardTransferPreparer(
                pasteboard: pasteboard,
                temporaryRoot: requestedRoot,
                now: { self.fixedDate }
            ).prepare()
        ) {
            XCTAssertEqual($0 as? ClipboardTransferPreparationError, .cannotCreateTemporaryFile)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outsideRoot.path), [])
    }

    @MainActor
    func testOutsideApprovedAnchorsAreRejectedWithoutCreatingFiles() {
        let pasteboard = makePasteboard()
        pasteboard.setString("secret", forType: .string)
        let outsideRoot = URL(fileURLWithPath: "/private/var/tmp/DropMesh-\(UUID().uuidString)")

        XCTAssertThrowsError(
            try NativeClipboardTransferPreparer(
                pasteboard: pasteboard,
                temporaryRoot: outsideRoot,
                now: { self.fixedDate }
            ).prepare()
        ) {
            XCTAssertEqual($0 as? ClipboardTransferPreparationError, .cannotCreateTemporaryFile)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outsideRoot.path))
    }

    @MainActor
    func testCacheRootFinalSymlinkIsRejectedWithoutWritingOutsideIt() throws {
        let pasteboard = makePasteboard()
        pasteboard.setString("secret", forType: .string)
        let cacheDirectory = temporaryRoot.appendingPathComponent("cache-root")
        let outsideRoot = temporaryRoot.appendingPathComponent("outside")
        let namespace = cacheDirectory.appendingPathComponent("MacChannel")
        let requestedRoot = namespace.appendingPathComponent("ClipboardTransfers")
        try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: requestedRoot, withDestinationURL: outsideRoot)

        XCTAssertThrowsError(
            try NativeClipboardTransferPreparer(
                pasteboard: pasteboard,
                temporaryRoot: requestedRoot,
                now: { self.fixedDate },
                cacheDirectory: cacheDirectory
            ).prepare()
        ) {
            XCTAssertEqual($0 as? ClipboardTransferPreparationError, .cannotCreateTemporaryFile)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outsideRoot.path), [])
    }

    @MainActor
    func testCacheRootAncestorSymlinkIsRejectedWithoutWritingOutsideIt() throws {
        let pasteboard = makePasteboard()
        pasteboard.setString("secret", forType: .string)
        let cacheDirectory = temporaryRoot.appendingPathComponent("cache-root")
        let outsideRoot = temporaryRoot.appendingPathComponent("outside")
        let namespace = cacheDirectory.appendingPathComponent("MacChannel")
        let requestedRoot = namespace.appendingPathComponent("ClipboardTransfers")
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: namespace, withDestinationURL: outsideRoot)

        XCTAssertThrowsError(
            try NativeClipboardTransferPreparer(
                pasteboard: pasteboard,
                temporaryRoot: requestedRoot,
                now: { self.fixedDate },
                cacheDirectory: cacheDirectory
            ).prepare()
        ) {
            XCTAssertEqual($0 as? ClipboardTransferPreparationError, .cannotCreateTemporaryFile)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outsideRoot.path), [])
    }

    @MainActor
    func testInjectedCacheAnchorSymlinkIsRejectedWithoutWritingOutsideIt() throws {
        let pasteboard = makePasteboard()
        pasteboard.setString("secret", forType: .string)
        let cacheDirectory = temporaryRoot.appendingPathComponent("cache-root")
        let outsideRoot = temporaryRoot.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: cacheDirectory, withDestinationURL: outsideRoot)

        XCTAssertThrowsError(
            try NativeClipboardTransferPreparer(
                pasteboard: pasteboard,
                now: { self.fixedDate },
                cacheDirectory: cacheDirectory
            ).prepare()
        ) {
            XCTAssertEqual($0 as? ClipboardTransferPreparationError, .cannotCreateTemporaryFile)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outsideRoot.path), [])
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

    private func isStrictDescendant(_ child: URL, of ancestor: URL) -> Bool {
        let childPath = child.standardizedFileURL.path
        let ancestorPath = ancestor.standardizedFileURL.path
        return childPath.hasPrefix(ancestorPath + "/")
    }
}

private enum ClipboardTestFailure: Error {
    case expected
}
