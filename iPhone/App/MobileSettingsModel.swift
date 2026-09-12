import Foundation
import Observation

/// This file lives inside the application's private state directory, never an app group.
struct MobileDiscoveryPreference {
    let url: URL
    func load() throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return try JSONDecoder().decode(Bool.self, from: Data(contentsOf: url))
    }
    func save(_ enabled: Bool) throws {
        try JSONEncoder().encode(enabled).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

@MainActor @Observable
final class MobileSettingsModel {
    private(set) var discoveryEnabled = false
    private(set) var localNetworkAvailable = false
    private(set) var saving = false
    private(set) var saveFailed = false
    let version: String
    private let session: any MobileAppSession
    // This retained model is the sole writer. Once a write completes, an older
    // in-flight observation cannot replace that durably acknowledged choice.
    private var hasSavedChoice = false
    init(session: any MobileAppSession, bundle: Bundle = .main) {
        self.session = session
        version = Self.versionDescription(info: bundle.infoDictionary ?? [:])
    }
    static func versionDescription(info: [String: Any]) -> String {
        guard let version = info["CFBundleShortVersionString"] as? String,
              let build = info["CFBundleVersion"] as? String else { return "—" }
        return "\(version) (\(build))"
    }
    func update(_ snapshot: MobileAppSnapshot) {
        localNetworkAvailable = snapshot.localNetworkAvailable
        if !saving && !hasSavedChoice { discoveryEnabled = snapshot.localDiscoveryEnabled }
    }
    func setDiscovery(_ enabled: Bool) async {
        guard !saving else { return }
        saving = true; saveFailed = false
        do {
            try await session.setLocalDiscoveryEnabled(enabled)
            discoveryEnabled = enabled
            hasSavedChoice = true
        } catch { saveFailed = true }
        saving = false
    }
}
