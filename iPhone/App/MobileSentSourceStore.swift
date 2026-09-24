import DropMeshMobileRuntime
import Darwin
import Foundation
import MacChannelCore

actor MobileSentSourceStore {
    private struct Reference: Codable { let transfer: UUID; let item: UUID; let name: String; let bookmark: Data?; let photoAssetIdentifier: String?; let recordedAt: Date }
    private struct Envelope: Codable { let version: Int; let references: [Reference] }
    private let url: URL
    private let actions: URL
    private var references: [UUID: Reference] = [:]
    private var unavailable = false
    private let resolvePhoto: @Sendable (String, URL) async throws -> URL
    private let actionStager: MobileImportStager

    init(url: URL, actions: URL,
         resolvePhoto: @escaping @Sendable (String, URL) async throws -> URL = { _, _ in throw CocoaError(.fileNoSuchFile) }) {
        self.url = url; self.actions = actions
        self.resolvePhoto = resolvePhoto
        try? FileManager.default.createDirectory(at: actions, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        actionStager = MobileImportStager(directory: actions)
        if FileManager.default.fileExists(atPath: url.path) {
        var status = stat()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
           status.st_uid == geteuid(), status.st_nlink == 1,
           (attributes[.size] as? NSNumber)?.intValue ?? -1 <= 1_048_576,
           (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
           let data = try? Data(contentsOf: url), data.count <= 1_048_576,
           let value = try? JSONDecoder().decode(Envelope.self, from: data), value.version == 1,
           value.references.count <= 1_000 else { unavailable = true; return }
            for reference in value.references {
                guard references[reference.item] == nil, Self.valid(reference.name),
                      reference.bookmark != nil || reference.photoAssetIdentifier != nil else {
                    unavailable = true; references = [:]; return
                }
                references[reference.item] = reference
            }
        }
    }
    func record(_ files: [MobileSentHistorySource], transfer: TransferID) {
        guard !unavailable else { return }
        var candidate = references
        for (offset, file) in files.enumerated() {
            guard file.bookmark?.count ?? 0 <= 65_536, Self.valid(file.name),
                  file.bookmark != nil || file.photoAssetIdentifier != nil else { continue }
            let item = Self.itemID(transfer.rawValue, offset)
            candidate[item] = Reference(transfer: transfer.rawValue, item: item, name: file.name,
                bookmark: file.bookmark, photoAssetIdentifier: file.photoAssetIdentifier, recordedAt: Date())
        }
        try? persist(candidate)
    }
    func contains(_ item: MobileHistoryFileID) -> Bool { references[item.rawValue] != nil }
    func transferIDs() -> Set<TransferID> { Set(references.values.map { TransferID(rawValue: $0.transfer) }) }
    func thumbnail(transfer: TransferID, item: MobileHistoryFileID,
                   photo: MobilePhotoHistorySource) async -> MobileHistoryThumbnail? {
        guard let reference = references[item.rawValue], reference.transfer == transfer.rawValue else { return nil }
        if let asset = reference.photoAssetIdentifier { return await photo.thumbnail(assetIdentifier: asset) }
        guard let bookmark = reference.bookmark else { return nil }
        var stale = false
        guard let source = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                    relativeTo: nil, bookmarkDataIsStale: &stale), !stale,
              source.startAccessingSecurityScopedResource() else { return nil }
        defer { source.stopAccessingSecurityScopedResource() }
        let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey,
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true else { return nil }
        if values?.isUbiquitousItem == true, values?.ubiquitousItemDownloadingStatus != .current { return nil }
        var status = stat()
        guard lstat(source.path, &status) == 0, status.st_flags & UInt32(SF_DATALESS) == 0 else { return nil }
        return await MobileHistoryThumbnailLoader.load(source)
    }
    func remove(transfers ids: Set<TransferID>) throws {
        guard !unavailable else { throw CocoaError(.fileReadCorruptFile) }
        let raw = Set(ids.map(\.rawValue))
        try persist(references.filter { !raw.contains($0.value.transfer) })
    }
    func resolve(transfer: TransferID, item: MobileHistoryFileID) async -> URL? {
        guard let reference = references[item.rawValue], reference.transfer == transfer.rawValue else { return nil }
        if let asset = reference.photoAssetIdentifier {
            var directory: URL?
            do {
                guard Self.validActionsRoot(actions) else { throw CocoaError(.fileReadNoPermission) }
                try FileManager.default.createDirectory(at: actions, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                let created = actions.appendingPathComponent(UUID().uuidString, isDirectory: true)
                directory = created
                try FileManager.default.createDirectory(at: created, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
                let output = try await resolvePhoto(asset, created).standardizedFileURL
                guard output.deletingLastPathComponent() == created.standardizedFileURL,
                      (try output.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile) == true,
                      (try output.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
                    throw CocoaError(.fileReadInvalidFileName)
                }
                return output
            } catch {
                if let directory { try? FileManager.default.removeItem(at: directory) }
                return nil
            }
        }
        guard let bookmark = reference.bookmark else { return nil }
        var stale = false
        guard let source = try? URL(resolvingBookmarkData: bookmark, options: [],
                                    relativeTo: nil, bookmarkDataIsStale: &stale), !stale else { return nil }
        guard source.startAccessingSecurityScopedResource() else { return nil }
        defer { source.stopAccessingSecurityScopedResource() }
        guard (try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile) == true,
              (try? source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return nil }
        do {
            return try await actionStager.stageCoordinated(file: source)
        } catch { return nil }
    }
    func release(_ output: URL) async {
        let directory = output.standardizedFileURL.deletingLastPathComponent()
        guard directory.deletingLastPathComponent().standardizedFileURL == actions.standardizedFileURL,
              UUID(uuidString: directory.lastPathComponent) != nil else { return }
        try? await actionStager.discard(output)
    }
    func recoverAbandonedActions() async { try? await actionStager.recoverAbandonedImports() }
    private func persist(_ candidate: [UUID: Reference]) throws {
        var values = Array(candidate.values.sorted { $0.recordedAt > $1.recordedAt }.prefix(1_000))
        var data = try JSONEncoder().encode(Envelope(version: 1, references: values))
        while data.count > 1_048_576, !values.isEmpty {
            values.removeLast()
            data = try JSONEncoder().encode(Envelope(version: 1, references: values))
        }
        guard data.count <= 1_048_576 else { throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        references = Dictionary(uniqueKeysWithValues: values.map { ($0.item, $0) })
    }
    private static func valid(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0") && name.utf8.count <= 255
    }
    private static func validActionsRoot(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0
            && status.st_mode & S_IFMT == S_IFDIR
            && status.st_uid == geteuid()
            && status.st_mode & 0o777 == 0o700
    }
    private static func itemID(_ transfer: UUID, _ offset: Int) -> UUID {
        if offset == 0 { return transfer }
        var bytes = withUnsafeBytes(of: transfer.uuid) { Array($0) }; var ordinal = UInt64(offset).bigEndian
        withUnsafeBytes(of: &ordinal) { raw in for index in 0..<8 { bytes[8 + index] ^= raw[index] } }
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
}
