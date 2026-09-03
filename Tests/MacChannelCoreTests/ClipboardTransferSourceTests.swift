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
    func testPruneRemovesOnlyExpiredRegularFilesDirectlyInsideTemporaryRoot() throws {
        let fileManager = FileManager.default
        let oldOwned = temporaryRoot.appendingPathComponent("old-owned.txt")
        let recentOwned = temporaryRoot.appendingPathComponent("recent-owned.txt")
        let nestedDirectory = temporaryRoot.appendingPathComponent("nested", isDirectory: true)
        let nestedFile = nestedDirectory.appendingPathComponent("old-nested.txt")
        let symlink = temporaryRoot.appendingPathComponent("old-link.txt")
        let outside = temporaryRoot.deletingLastPathComponent().appendingPathComponent("old-owned.txt")
        let oldDate = fixedDate.addingTimeInterval(-25 * 60 * 60)
        let recentDate = fixedDate.addingTimeInterval(-23 * 60 * 60)

        try Data("old".utf8).write(to: oldOwned)
        try Data("recent".utf8).write(to: recentOwned)
        try fileManager.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: nestedFile)
        try Data("outside".utf8).write(to: outside)
        try fileManager.createSymbolicLink(at: symlink, withDestinationURL: outside)
        try setDates(oldDate, on: oldOwned)
        try setDates(recentDate, on: recentOwned)
        try setDates(oldDate, on: nestedFile)

        let preparer = NativeClipboardTransferPreparer(
            pasteboard: makePasteboard(),
            temporaryRoot: temporaryRoot,
            now: { self.fixedDate }
        )

        try preparer.pruneAbandonedFiles(olderThan: .seconds(24 * 60 * 60))

        XCTAssertFalse(fileManager.fileExists(atPath: oldOwned.path))
        XCTAssertTrue(fileManager.fileExists(atPath: recentOwned.path))
        XCTAssertTrue(fileManager.fileExists(atPath: outside.path))
        XCTAssertTrue(fileManager.fileExists(atPath: nestedDirectory.path))
        XCTAssertTrue(fileManager.fileExists(atPath: nestedFile.path))
        XCTAssertTrue(fileManager.fileExists(atPath: symlink.path))
    }

    @MainActor
    func testPruneRestoresNewFileReplacedAfterMetadataCheck() throws {
        let fileManager = FileManager.default
        let oldOwned = temporaryRoot.appendingPathComponent("old-owned.txt")
        let displacedOld = temporaryRoot.appendingPathComponent("displaced-old.txt")
        let oldDate = fixedDate.addingTimeInterval(-25 * 60 * 60)
        try Data("old".utf8).write(to: oldOwned)
        try setDates(oldDate, on: oldOwned)

        let preparer = NativeClipboardTransferPreparer(
            pasteboard: makePasteboard(),
            temporaryRoot: temporaryRoot,
            now: { self.fixedDate },
            pruneBeforeQuarantineHook: { name in
                guard name == oldOwned.lastPathComponent else { return }
                try fileManager.moveItem(at: oldOwned, to: displacedOld)
                try Data("new".utf8).write(to: oldOwned)
            }
        )

        try preparer.pruneAbandonedFiles(olderThan: .seconds(24 * 60 * 60))

        XCTAssertEqual(try String(contentsOf: oldOwned, encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: displacedOld, encoding: .utf8), "old")
    }

    @MainActor
    func testPruneRestoresSymlinkReplacedAfterMetadataCheck() throws {
        let fileManager = FileManager.default
        let oldOwned = temporaryRoot.appendingPathComponent("old-owned.txt")
        let displacedOld = temporaryRoot.appendingPathComponent("displaced-old.txt")
        let outside = temporaryRoot.deletingLastPathComponent().appendingPathComponent("outside.txt")
        let oldDate = fixedDate.addingTimeInterval(-25 * 60 * 60)
        try Data("old".utf8).write(to: oldOwned)
        try Data("outside".utf8).write(to: outside)
        try setDates(oldDate, on: oldOwned)

        let preparer = NativeClipboardTransferPreparer(
            pasteboard: makePasteboard(),
            temporaryRoot: temporaryRoot,
            now: { self.fixedDate },
            pruneBeforeQuarantineHook: { name in
                guard name == oldOwned.lastPathComponent else { return }
                try fileManager.moveItem(at: oldOwned, to: displacedOld)
                try fileManager.createSymbolicLink(at: oldOwned, withDestinationURL: outside)
            }
        )

        try preparer.pruneAbandonedFiles(olderThan: .seconds(24 * 60 * 60))

        XCTAssertTrue(fileManager.fileExists(atPath: oldOwned.path))
        XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: oldOwned.path), outside.path)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "outside")
        XCTAssertEqual(try String(contentsOf: displacedOld, encoding: .utf8), "old")
    }

    @MainActor
    func testPruneEnumeratesTheOpenedRootWhenItsPathIsReplaced() throws {
        let fileManager = FileManager.default
        let originalRoot = temporaryRoot!
        let relocatedRoot = originalRoot.deletingLastPathComponent()
            .appendingPathComponent("relocated-root", isDirectory: true)
        let oldOwned = originalRoot.appendingPathComponent("old-owned.txt")
        let replacementOwned = originalRoot.appendingPathComponent("replacement.txt")
        let oldDate = fixedDate.addingTimeInterval(-25 * 60 * 60)
        defer { try? fileManager.removeItem(at: relocatedRoot) }
        try Data("old".utf8).write(to: oldOwned)
        try setDates(oldDate, on: oldOwned)

        let preparer = NativeClipboardTransferPreparer(
            pasteboard: makePasteboard(),
            temporaryRoot: originalRoot,
            now: { self.fixedDate },
            pruneRootOpenedHook: {
                try fileManager.moveItem(at: originalRoot, to: relocatedRoot)
                try fileManager.createDirectory(at: originalRoot, withIntermediateDirectories: true)
                try Data("replacement".utf8).write(to: replacementOwned)
            }
        )

        try preparer.pruneAbandonedFiles(olderThan: .seconds(24 * 60 * 60))

        XCTAssertFalse(fileManager.fileExists(atPath: relocatedRoot.appendingPathComponent("old-owned.txt").path))
        XCTAssertEqual(try String(contentsOf: replacementOwned, encoding: .utf8), "replacement")
    }

    @MainActor
    func testProductionInitializerPrunesOnceWithoutPruningAgainDuringPreparation() throws {
        let fileManager = FileManager.default
        let cacheDirectory = temporaryRoot.appendingPathComponent("cache", isDirectory: true)
        let dedicatedRoot = cacheDirectory
            .appendingPathComponent("MacChannel", isDirectory: true)
            .appendingPathComponent("ClipboardTransfers", isDirectory: true)
        let abandoned = dedicatedRoot.appendingPathComponent("abandoned.txt")
        let laterAbandoned = dedicatedRoot.appendingPathComponent("later-abandoned.txt")
        let outside = cacheDirectory.appendingPathComponent("abandoned.txt")
        let oldDate = fixedDate.addingTimeInterval(-25 * 60 * 60)
        try fileManager.createDirectory(at: dedicatedRoot, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: abandoned)
        try Data("outside".utf8).write(to: outside)
        try setDates(oldDate, on: abandoned)

        let preparer = NativeClipboardTransferPreparer(
            pasteboard: makePasteboard(),
            now: { self.fixedDate },
            cacheDirectory: cacheDirectory
        )

        XCTAssertFalse(fileManager.fileExists(atPath: abandoned.path))
        XCTAssertTrue(fileManager.fileExists(atPath: outside.path))

        try Data("later".utf8).write(to: laterAbandoned)
        try setDates(oldDate, on: laterAbandoned)
        XCTAssertThrowsError(try preparer.prepare())

        XCTAssertTrue(fileManager.fileExists(atPath: laterAbandoned.path))
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

    private func setDates(_ date: Date, on url: URL) throws {
        try FileManager.default.setAttributes(
            [.creationDate: date, .modificationDate: date],
            ofItemAtPath: url.path
        )
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
