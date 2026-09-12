import Foundation

public struct DownloadDirectory: Sendable {
    public static var platformHomeDirectory: URL {
        #if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser
        #else
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #endif
    }

    private let homeDirectory: URL
    private let globalDirectory: URL?
    private let perSource: [DeviceID: URL]
    private let defaultFolderName: String

    public init(
        globalDirectory: URL? = nil,
        perSource: [DeviceID: URL] = [:],
        homeDirectory: URL = DownloadDirectory.platformHomeDirectory,
        defaultFolderName: String = "Mac 通道"
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.globalDirectory = globalDirectory?.standardizedFileURL
        self.perSource = perSource.mapValues(\.standardizedFileURL)
        self.defaultFolderName = defaultFolderName
    }

    public func directory(for source: DeviceID) -> URL {
        if let sourceDirectory = perSource[source] { return sourceDirectory }
        if let globalDirectory { return globalDirectory }
        return defaultDirectory
    }

    public var defaultDirectory: URL {
        homeDirectory
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent(defaultFolderName, isDirectory: true)
    }
}
