import Darwin
import Foundation
import MacChannelCore

actor MobileHistoryDeletionStore {
    private struct Envelope: Codable { let version: Int; let ids: [UUID] }
    private let url: URL
    private var ids: Set<UUID> = []
    private var unavailable = false
    init(url: URL) {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var status = stat()
        guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(), status.st_nlink == 1,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? NSNumber)?.intValue ?? -1 <= 1_048_576,
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.version == 1,
              envelope.ids.count <= 20_000, Set(envelope.ids).count == envelope.ids.count else {
            unavailable = true; return
        }
        ids = Set(envelope.ids)
    }
    /// Corrupt/unreadable deletion state fails closed: hidden history is safer
    /// than resurrecting records the user explicitly removed.
    func contains(_ id: TransferID) -> Bool { unavailable || ids.contains(id.rawValue) }
    func add(_ values: Set<TransferID>) throws {
        guard !unavailable else { throw CocoaError(.fileReadCorruptFile) }
        let candidate = ids.union(values.map(\.rawValue))
        guard candidate.count <= 20_000 else { throw CocoaError(.fileWriteOutOfSpace) }
        let data = try JSONEncoder().encode(Envelope(version: 1, ids: candidate.sorted { $0.uuidString < $1.uuidString }))
        guard data.count <= 1_048_576 else { throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        ids = candidate
    }
}
