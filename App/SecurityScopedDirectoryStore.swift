import Foundation
import MacChannelCore

package enum DirectoryAuthorizationMode: Equatable, Sendable { case directPath, securityScopedBookmarks }

struct StoredDirectoryReference: Codable, Equatable, Sendable {
    let path: String
    let bookmark: Data?
}

enum DirectoryAuthorizationError: LocalizedError {
    case reselect
    var errorDescription: String? { "接收目录授权已失效，请重新选择目录。" }
}

struct AuthorizedDirectory: Sendable {
    let reference: StoredDirectoryReference
    let lease: any UserSelectedSourceLease
    let wasStale: Bool
    var url: URL { URL(fileURLWithPath: reference.path, isDirectory: true) }
}

struct AuthorizedReceiveDirectories: Sendable {
    let directories: DownloadDirectory
    let leases: [any UserSelectedSourceLease]
    func release() { leases.forEach { $0.release() } }
}

struct SecurityScopedDirectoryStore: Sendable {
    /// Context is stored with the opaque OS bookmark so copying a reference across
    /// channel/device settings fails before any scope is opened.
    private struct BookmarkEnvelope: Codable {
        let namespace: String
        let settingKey: String
        let data: Data
    }
    let mode: DirectoryAuthorizationMode
    let namespace: String
    var createBookmark: @Sendable (URL) throws -> Data = {
        try $0.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    var resolveBookmark: @Sendable (Data) throws -> (URL, Bool) = {
        var stale = false
        let url = try URL(resolvingBookmarkData: $0, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        return (url, stale)
    }
    var start: @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }
    var stop: @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    var accessible: @Sendable (URL) -> Bool = {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory)
            && isDirectory.boolValue && FileManager.default.isWritableFile(atPath: $0.path)
            && FileManager.default.isReadableFile(atPath: $0.path)
    }

    @MainActor
    func selectedOnMainActor(_ url: URL, settingKey: String) throws -> StoredDirectoryReference {
        try select(url, settingKey: settingKey)
    }

    func select(_ url: URL, settingKey: String) throws -> StoredDirectoryReference {
        guard mode == .securityScopedBookmarks else {
            return StoredDirectoryReference(path: url.standardizedFileURL.path, bookmark: nil)
        }
        do {
            guard url.isFileURL, start(url) else { throw DirectoryAuthorizationError.reselect }
            defer { stop(url) }
            guard accessible(url) else { throw DirectoryAuthorizationError.reselect }
            return try reference(url, settingKey: settingKey)
        } catch { throw DirectoryAuthorizationError.reselect }
    }

    func resolve(_ stored: StoredDirectoryReference, settingKey: String) throws -> AuthorizedDirectory {
        guard mode == .securityScopedBookmarks else {
            return AuthorizedDirectory(reference: StoredDirectoryReference(path: stored.path, bookmark: nil), lease: SecurityScopeLease(), wasStale: false)
        }
        do {
            guard let bookmark = stored.bookmark else { throw DirectoryAuthorizationError.reselect }
            let envelope = try JSONDecoder().decode(BookmarkEnvelope.self, from: bookmark)
            guard envelope.namespace == namespace, envelope.settingKey == settingKey else { throw DirectoryAuthorizationError.reselect }
            let (url, stale) = try resolveBookmark(envelope.data)
            guard url.isFileURL, url.standardizedFileURL.path == stored.path,
                  start(url) else { throw DirectoryAuthorizationError.reselect }
            let lease = SecurityScopeLease(urls: [url], stop: stop)
            do {
                guard accessible(url) else { throw DirectoryAuthorizationError.reselect }
                let refreshed = stale ? try reference(url, settingKey: settingKey) : stored
                return AuthorizedDirectory(reference: refreshed, lease: lease, wasStale: stale)
            } catch { lease.release(); throw error }
        } catch { throw DirectoryAuthorizationError.reselect }
    }

    private func reference(_ url: URL, settingKey: String) throws -> StoredDirectoryReference {
        let envelope = BookmarkEnvelope(namespace: namespace, settingKey: settingKey, data: try createBookmark(url))
        return StoredDirectoryReference(path: url.standardizedFileURL.path, bookmark: try JSONEncoder().encode(envelope))
    }
}
