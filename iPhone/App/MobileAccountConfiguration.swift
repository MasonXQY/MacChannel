import Foundation
import MacChannelCore

struct MobileAccountConfiguration: Equatable, Sendable {
    let origin: URL
    let audience: String

    static func load(bundle: Bundle = .main) throws -> MobileAccountConfiguration? {
        try load(info: bundle.infoDictionary ?? [:], bundleIdentifier: bundle.bundleIdentifier)
    }

    static func load(info: [String: Any], bundleIdentifier: String?) throws -> MobileAccountConfiguration? {
        guard let raw = info["DropMeshAccountServiceOrigin"] as? String, !raw.isEmpty else { return nil }
        guard let origin = URL(string: raw), let audience = bundleIdentifier else {
            throw AccountSessionControllerError.unavailable
        }
        let validation = try AccountSessionBinding(deviceID: UUID(), audience: audience, origin: origin)
        return MobileAccountConfiguration(origin: validation.origin, audience: validation.audience)
    }
}
