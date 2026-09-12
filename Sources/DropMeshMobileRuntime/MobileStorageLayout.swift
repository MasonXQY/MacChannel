import Foundation

/// Roots must be supplied by the app's sandbox container, never from a peer.
public struct MobileStorageLayout: Sendable {
    public let stateDirectory: URL
    public let receiveDirectory: URL
    public var stagingDirectory: URL { stateDirectory.appendingPathComponent("staging", isDirectory: true) }
    public var trustFile: URL { stateDirectory.appendingPathComponent("trust.json") }
    public var transferDatabaseFile: URL { stateDirectory.appendingPathComponent("transfers.sqlite3") }
    public var receivedOutputIndexFile: URL { stateDirectory.appendingPathComponent("received-outputs-v1.json") }

    public init(applicationSupport: URL, documents: URL) {
        stateDirectory = applicationSupport.standardizedFileURL.appendingPathComponent("DropMesh", isDirectory: true)
        receiveDirectory = documents.standardizedFileURL.appendingPathComponent("DropMesh", isDirectory: true)
    }

    public func prepare() throws {
        for directory in [stateDirectory, stagingDirectory, receiveDirectory] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }
}
