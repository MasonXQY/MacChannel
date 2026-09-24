import Foundation
import Observation
import UIKit

@MainActor @Observable
final class MobileReceivedFolderNavigation {
    private(set) var opening = false
    private(set) var unavailable = false
    var fallbackFolder: URL?
    private let openURL: @MainActor (URL) async -> Bool
    init(openURL: @escaping @MainActor (URL) async -> Bool = { await UIApplication.shared.open($0) }) {
        self.openURL = openURL
    }
    func open(folder: URL?) async {
        guard !opening else { return }
        unavailable = false
        guard let folder, folder.isFileURL else { unavailable = true; return }
        var destination = URLComponents()
        destination.scheme = "shareddocuments"
        destination.host = ""
        destination.path = folder.path
        guard let url = destination.url else { unavailable = true; return }
        opening = true
        defer { opening = false }
        if !(await openURL(url)) { fallbackFolder = folder }
    }
}
