import Foundation
import ImageIO
import QuickLookThumbnailing
import UIKit

enum MobileHistoryThumbnailLoader {
    static func load(_ url: URL) async -> MobileHistoryThumbnail? {
        let work = Task.detached(priority: .utility) { await render(url) }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }
    private static func render(_ url: URL) async -> MobileHistoryThumbnail? {
        guard !Task.isCancelled else { return nil }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        if let source = CGImageSourceCreateWithURL(url as CFURL, options),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 160,
                kCGImageSourceShouldCacheImmediately: true,
           ] as CFDictionary) {
            return MobileHistoryThumbnail(image: UIImage(cgImage: image))
        }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 160, height: 160),
            scale: 1, representationTypes: [.thumbnail, .lowQualityThumbnail])
        request.iconMode = false
        guard !Task.isCancelled else { return nil }
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        guard !Task.isCancelled else { return nil }
        return MobileHistoryThumbnail(image: representation.uiImage)
    }
}
