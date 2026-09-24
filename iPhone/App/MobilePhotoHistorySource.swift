import Foundation
@preconcurrency import Photos

enum MobilePhotoHistorySourceError: Error, Equatable, Sendable {
    case permissionDenied
    case assetMissing
    case resourceMissing
    case downloadFailed
    case invalidDestination
}

/// Re-reads a user-selected Photos asset only when a history action requests it.
/// The caller owns the action directory and removes it after preview/share ends.
struct MobilePhotoHistorySource: Sendable {
    typealias Authorize = @Sendable () async -> PHAuthorizationStatus
    typealias Export = @Sendable (_ assetIdentifier: String, _ destination: URL) async throws -> URL

    private let authorize: Authorize
    private let export: Export
    private let thumbnailStatus: @Sendable () -> PHAuthorizationStatus
    private let requestThumbnail: @Sendable (String) async -> MobileHistoryThumbnail?

    init() {
        authorize = Self.requestReadWriteAuthorization
        export = Self.exportAsset
        thumbnailStatus = { PHPhotoLibrary.authorizationStatus(for: .readWrite) }
        requestThumbnail = Self.requestLocalThumbnail
    }

    init(authorize: @escaping Authorize, export: @escaping Export,
         thumbnailStatus: @escaping @Sendable () -> PHAuthorizationStatus = { PHPhotoLibrary.authorizationStatus(for: .readWrite) },
         requestThumbnail: @escaping @Sendable (String) async -> MobileHistoryThumbnail? = MobilePhotoHistorySource.requestLocalThumbnail) {
        self.authorize = authorize
        self.export = export
        self.thumbnailStatus = thumbnailStatus
        self.requestThumbnail = requestThumbnail
    }

    func resolve(assetIdentifier: String, destination: URL) async throws -> URL {
        try Task.checkCancellation()
        let status = await authorize()
        guard status == .authorized || status == .limited else {
            throw MobilePhotoHistorySourceError.permissionDenied
        }
        try Task.checkCancellation()
        guard Self.isDirectoryWithoutSymlink(destination) else {
            throw MobilePhotoHistorySourceError.invalidDestination
        }
        let output = try await export(assetIdentifier, destination)
        do {
            try Task.checkCancellation()
            guard Self.isDirectChild(output, of: destination), FileManager.default.fileExists(atPath: output.path)
            else { throw MobilePhotoHistorySourceError.downloadFailed }
            return output
        } catch {
            if Self.isDirectChild(output, of: destination) { try? FileManager.default.removeItem(at: output) }
            throw error
        }
    }

    func thumbnail(assetIdentifier: String) async -> MobileHistoryThumbnail? {
        let status = thumbnailStatus()
        guard status == .authorized || status == .limited else { return nil }
        return await requestThumbnail(assetIdentifier)
    }

    private static func requestLocalThumbnail(_ assetIdentifier: String) async -> MobileHistoryThumbnail? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        // High-quality delivery guarantees a terminal callback; targetSize still
        // bounds the requested local thumbnail and network access remains off.
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        let gate = PhotoThumbnailGate(manager: .default())
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.begin(continuation)
                let request = PHImageManager.default().requestImage(for: asset,
                    targetSize: CGSize(width: 160, height: 160), contentMode: .aspectFill,
                    options: options) { image, info in
                        if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                        let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
                        gate.finish(cancelled ? nil : image.map { MobileHistoryThumbnail(image: $0) })
                    }
                gate.install(request)
            }
        } onCancel: { gate.cancel() }
    }

    private static func requestReadWriteAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { continuation.resume(returning: $0) }
        }
    }

    private static func exportAsset(_ identifier: String, _ destination: URL) async throws -> URL {
        try Task.checkCancellation()
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            throw MobilePhotoHistorySourceError.assetMissing
        }
        guard let resource = preferredResource(for: asset) else {
            throw MobilePhotoHistorySourceError.resourceMissing
        }
        let output = destination.appendingPathComponent(
            "\(UUID().uuidString)-\(safeFilename(resource.originalFilename))", isDirectory: false)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().writeData(for: resource, toFile: output, options: options) { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
            try Task.checkCancellation()
            return output
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: output)
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw MobilePhotoHistorySourceError.downloadFailed
        }
    }

    private static func preferredResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        let preferredTypes: [PHAssetResourceType]
        switch asset.mediaType {
        case .image: preferredTypes = [.photo, .fullSizePhoto]
        case .video: preferredTypes = [.video, .fullSizeVideo]
        default: return nil
        }
        for type in preferredTypes {
            if let resource = resources.first(where: { $0.type == type }) { return resource }
        }
        return nil
    }

    private static func safeFilename(_ filename: String) -> String {
        let last = (filename as NSString).lastPathComponent
        return last.isEmpty || last == "." || last == ".." ? "Photos-asset" : last
    }

    private static func isDirectoryWithoutSymlink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func isDirectChild(_ url: URL, of directory: URL) -> Bool {
        url.standardizedFileURL.deletingLastPathComponent() == directory.standardizedFileURL
    }
}

private final class PhotoThumbnailGate: @unchecked Sendable {
    private let lock = NSLock()
    private let manager: PHImageManager
    private var continuation: CheckedContinuation<MobileHistoryThumbnail?, Never>?
    private var request: PHImageRequestID?
    private var cancelled = false
    init(manager: PHImageManager) { self.manager = manager }
    func begin(_ continuation: CheckedContinuation<MobileHistoryThumbnail?, Never>) {
        lock.lock(); if cancelled { lock.unlock(); continuation.resume(returning: nil); return }
        self.continuation = continuation; lock.unlock()
    }
    func install(_ request: PHImageRequestID) {
        lock.lock(); self.request = request; let cancel = cancelled; lock.unlock()
        if cancel { manager.cancelImageRequest(request) }
    }
    func finish(_ value: MobileHistoryThumbnail?) {
        lock.lock(); let current = continuation; continuation = nil; lock.unlock()
        current?.resume(returning: value)
    }
    func cancel() {
        lock.lock(); cancelled = true; let id = request; let current = continuation; continuation = nil; lock.unlock()
        if let id { manager.cancelImageRequest(id) }
        current?.resume(returning: nil)
    }
}
