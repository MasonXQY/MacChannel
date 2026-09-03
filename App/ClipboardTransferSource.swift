import AppKit
import Foundation

enum ClipboardTransferPreparationError: Error, Equatable {
    case noSupportedContent
    case cannotCreateTemporaryFile
}

@MainActor
protocol ClipboardTransferPreparing: AnyObject {
    func prepare() throws -> PreparedClipboardTransfer
}

@MainActor
final class PreparedClipboardTransfer {
    let urls: [URL]
    let ownedTemporaryURLs: [URL]

    private let fileManager: FileManager
    private var discarded = false

    init(
        urls: [URL],
        ownedTemporaryURLs: [URL],
        fileManager: FileManager = .default
    ) {
        self.urls = urls
        self.ownedTemporaryURLs = ownedTemporaryURLs
        self.fileManager = fileManager
    }

    func discardTemporaryFiles() {
        guard !discarded else { return }
        discarded = true
        for url in ownedTemporaryURLs {
            try? fileManager.removeItem(at: url)
        }
    }
}

@MainActor
final class NativeClipboardTransferPreparer: ClipboardTransferPreparing {
    private let pasteboard: NSPasteboard
    private let temporaryRoot: URL
    private let now: () -> Date
    private let fileManager: FileManager

    init(
        pasteboard: NSPasteboard = .general,
        temporaryRoot: URL,
        now: @escaping () -> Date = Date.init,
        fileManager: FileManager = .default
    ) {
        self.pasteboard = pasteboard
        self.temporaryRoot = temporaryRoot
        self.now = now
        self.fileManager = fileManager
    }

    func prepare() throws -> PreparedClipboardTransfer {
        let fileURLs = fileURLsFromPasteboard()
        if !fileURLs.isEmpty {
            return PreparedClipboardTransfer(
                urls: fileURLs,
                ownedTemporaryURLs: [],
                fileManager: fileManager
            )
        }

        if let imageData = pngDataFromPasteboard() {
            return try materialize(imageData, kind: "图片", fileExtension: "png")
        }

        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return try materialize(Data(text.utf8), kind: "文字", fileExtension: "txt")
        }

        throw ClipboardTransferPreparationError.noSupportedContent
    }

    private func fileURLsFromPasteboard() -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) ?? []
        return objects.compactMap { object in
            guard let url = object as? URL, url.isFileURL else { return nil }
            return url.standardizedFileURL
        }
    }

    private func pngDataFromPasteboard() -> Data? {
        guard let image = NSImage(pasteboard: pasteboard),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func materialize(
        _ data: Data,
        kind: String,
        fileExtension: String
    ) throws -> PreparedClipboardTransfer {
        do {
            try fileManager.createDirectory(
                at: temporaryRoot,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: temporaryRoot.path
            )
            let url = nextAvailableURL(kind: kind, fileExtension: fileExtension)
            try data.write(to: url, options: .atomic)
            return PreparedClipboardTransfer(
                urls: [url],
                ownedTemporaryURLs: [url],
                fileManager: fileManager
            )
        } catch {
            throw ClipboardTransferPreparationError.cannotCreateTemporaryFile
        }
    }

    private func nextAvailableURL(kind: String, fileExtension: String) -> URL {
        let timestamp = Self.filenameDateFormatter.string(from: now())
        let baseName = "剪贴板\(kind) \(timestamp)"
        var ordinal = 1
        var url = temporaryRoot.appendingPathComponent("\(baseName).\(fileExtension)")

        while fileManager.fileExists(atPath: url.path) {
            ordinal += 1
            url = temporaryRoot.appendingPathComponent(
                "\(baseName) \(ordinal).\(fileExtension)"
            )
        }
        return url
    }

    private static let filenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()
}
