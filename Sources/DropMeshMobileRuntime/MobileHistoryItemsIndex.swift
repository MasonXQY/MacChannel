import Darwin
import Foundation
import MacChannelCore

actor MobileHistoryItemsIndex {
    struct Stored: Codable, Sendable {
        let id: UUID
        let name: String
        let size: UInt64
        let isDirectory: Bool
        let device: UInt64?
        let inode: UInt64?
        /// Relative to the single collision-resolved published output root.
        let relativePath: [String]?
    }
    private struct Transfer: Codable { let id: UUID; let direction: String; let recordedAt: Date; let files: [Stored] }
    private struct Envelope: Codable { let version: Int; let transfers: [Transfer] }
    private let url: URL
    private var transfers: [UUID: Transfer] = [:]
    private var unavailable = false

    init(url: URL) {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var status = stat()
        guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(), status.st_nlink == 1,
              status.st_mode & 0o777 == 0o600, status.st_size >= 0, status.st_size <= 1_048_576,
              let data = try? Data(contentsOf: url), data.count <= 1_048_576,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.version == 1,
              envelope.transfers.count <= 1_000 else { unavailable = true; return }
        var transferIDs = Set<UUID>()
        var itemIDs = Set<UUID>()
        for transfer in envelope.transfers {
            guard transferIDs.insert(transfer.id).inserted, transfer.recordedAt.timeIntervalSince1970.isFinite,
                  transfer.files.count <= 10_000, ["inbound", "outbound"].contains(transfer.direction),
                  !transfer.files.isEmpty,
                  transfer.files.allSatisfy({ file in
                      itemIDs.insert(file.id).inserted && Self.valid(file.name)
                          && (file.relativePath?.allSatisfy(Self.valid) ?? true)
                          && ((transfer.direction == "inbound") == (file.relativePath != nil))
                          && ((file.device == nil) == (file.inode == nil))
                          && ((transfer.direction == "inbound") == (file.device != nil))
                          && (file.inode.map { $0 > 0 } ?? true)
                  }) else { unavailable = true; transfers = [:]; return }
            transfers[transfer.id] = transfer
        }
    }

    func files(for id: TransferID) -> [Stored]? { transfers[id.rawValue]?.files }

    func recordReceive(_ result: TransferReceiveResult) throws {
        guard !unavailable, transfers[result.transferID.rawValue] == nil, let output = result.receivedURLs.first,
              result.receivedURLs.count == 1 else { return }
        let metadata = result.items.isEmpty
            ? [TransferReceivedItemMetadata(relativePathComponents: [], name: output.lastPathComponent,
                size: (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0,
                isDirectory: (try? output.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)]
            : result.items
        guard metadata.count <= 10_000 else { return }
        let files = try metadata.enumerated().map { offset, item in
            let itemURL = item.relativePathComponents.reduce(output) { $0.appendingPathComponent($1) }
            var status = stat()
            guard lstat(itemURL.path, &status) == 0,
                  status.st_mode & S_IFMT == (item.isDirectory ? S_IFDIR : S_IFREG) else { throw CocoaError(.fileReadUnknown) }
            return Stored(id: Self.itemID(transfer: result.transferID.rawValue, offset: offset), name: item.name,
                   size: item.size, isDirectory: item.isDirectory,
                   device: UInt64(UInt32(bitPattern: status.st_dev)), inode: UInt64(status.st_ino),
                   relativePath: item.relativePathComponents)
        }
        guard !files.isEmpty, files.allSatisfy({ Self.valid($0.name) && ($0.relativePath?.allSatisfy(Self.valid) ?? false) }) else { return }
        let transfer = Transfer(id: result.transferID.rawValue, direction: "inbound", recordedAt: result.completedAt, files: files)
        var candidate = transfers; candidate[result.transferID.rawValue] = transfer
        try persist(candidate, newest: result.transferID.rawValue)
    }

    func recordSend(id: TransferID, urls: [URL]) throws {
        guard !unavailable, transfers[id.rawValue] == nil else { return }
        let files = urls.enumerated().map { offset, source -> Stored in
            let values = try? source.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            return Stored(id: Self.itemID(transfer: id.rawValue, offset: offset), name: source.lastPathComponent,
                size: UInt64(max(0, values?.fileSize ?? 0)), isDirectory: values?.isDirectory == true,
                device: nil, inode: nil, relativePath: nil)
        }
        guard !files.isEmpty, files.count <= 10_000, files.allSatisfy({ Self.valid($0.name) }) else { return }
        let transfer = Transfer(id: id.rawValue, direction: "outbound", recordedAt: Date(), files: files)
        var candidate = transfers; candidate[id.rawValue] = transfer
        try persist(candidate, newest: id.rawValue)
    }

    private func persist(_ candidate: [UUID: Transfer], newest: UUID) throws {
        var retained = Array(candidate.values.sorted { $0.recordedAt > $1.recordedAt }.prefix(1_000))
        var data = try JSONEncoder().encode(Envelope(version: 1, transfers: retained))
        while data.count > 1_048_576, retained.count > 1 {
            retained.removeLast()
            data = try JSONEncoder().encode(Envelope(version: 1, transfers: retained))
        }
        // One oversized record is metadata-only and may be skipped. Do not let
        // it poison the in-memory store or prevent a later ordinary record.
        guard data.count <= 1_048_576, retained.contains(where: { $0.id == newest }) else { return }
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        transfers = Dictionary(uniqueKeysWithValues: retained.map { ($0.id, $0) })
    }

    private static func itemID(transfer: UUID, offset: Int) -> UUID {
        if offset == 0 { return transfer }
        var bytes = withUnsafeBytes(of: transfer.uuid) { Array($0) }
        var ordinal = UInt64(offset).bigEndian
        withUnsafeBytes(of: &ordinal) { raw in for index in 0..<8 { bytes[8 + index] ^= raw[index] } }
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    private static func valid(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\0") && value.utf8.count <= 255
    }
}
