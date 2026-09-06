import Foundation

public struct DownloadDirectory: Sendable {
    private let homeDirectory: URL
    private let globalDirectory: URL?
    private let perSource: [DeviceID: URL]
    private let defaultFolderName: String

    public init(
        globalDirectory: URL? = nil,
        perSource: [DeviceID: URL] = [:],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
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
