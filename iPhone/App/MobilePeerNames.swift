import Foundation
import MacChannelCore

/// Optional private presentation metadata. Repository membership remains authority.
/// Its production owner is an actor, so filesystem work never runs on MainActor.
struct MobilePeerNames: Sendable {
    enum RenameError: Error, Equatable {
        case invalidName
        case untrustedPeer
    }

    private let url: URL
    private(set) var values: [DeviceID: String] = [:]

    init(url: URL) {
        self.url = url
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 131_072,
              let data = try? Data(contentsOf: url), data.count <= 131_072,
              let stored = try? JSONDecoder().decode([String: String].self, from: data), stored.count <= 256
        else { return }
        for (key, name) in stored where name.utf8.count <= 512 {
            if let id = UUID(uuidString: key) { values[DeviceID(rawValue: id)] = name }
        }
    }

    mutating func remember(_ peer: DeviceSummary, trustedIDs: Set<DeviceID>) {
        guard trustedIDs.contains(peer.id), !peer.displayName.isEmpty, peer.displayName.utf8.count <= 512 else { return }
        values = values.filter { trustedIDs.contains($0.key) }
        guard values.count < 256 || values[peer.id] != nil else { return }
        let previous = values
        values[peer.id] = peer.displayName
        do {
            try persist()
        } catch { values = previous }
    }

    mutating func rename(_ id: DeviceID, to proposedName: String, trustedIDs: Set<DeviceID>) throws {
        guard trustedIDs.contains(id) else { throw RenameError.untrustedPeer }
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 512 else { throw RenameError.invalidName }
        let previous = values
        values[id] = name
        do {
            try persist()
        } catch {
            values = previous
            throw error
        }
    }

    private func persist() throws {
        let stored = Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue.uuidString, $0.value) })
        let data = try JSONEncoder().encode(stored)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
