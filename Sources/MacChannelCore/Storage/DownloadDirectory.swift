import Foundation

public struct DownloadDirectory: Sendable {
    private let homeDirectory: URL
    private let globalDirectory: URL?
    private let perSource: [DeviceID: URL]

    public init(
        globalDirectory: URL? = nil,
        perSource: [DeviceID: URL] = [:],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.globalDirectory = globalDirectory?.standardizedFileURL
        self.perSource = perSource.mapValues(\.standardizedFileURL)
    }

    public func directory(for source: DeviceID) -> URL {
        if let sourceDirectory = perSource[source] { return sourceDirectory }
        if let globalDirectory { return globalDirectory }
        return defaultDirectory
    }

    public var defaultDirectory: URL {
        homeDirectory
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("Mac 通道", isDirectory: true)
    }
}
