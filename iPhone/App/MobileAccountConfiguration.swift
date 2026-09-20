import Foundation
import CoreFoundation
import MacChannelCore

struct MobileAccountConfiguration: Equatable, Sendable {
    let origin: URL
    let audience: String
    let groupsEnabled: Bool

    static func load(bundle: Bundle = .main) throws -> MobileAccountConfiguration? {
        try load(info: bundle.infoDictionary ?? [:], bundleIdentifier: bundle.bundleIdentifier)
    }

    static func load(info: [String: Any], bundleIdentifier: String?) throws -> MobileAccountConfiguration? {
        guard let configured = info["DropMeshAccountServiceOrigin"] else { return nil }
        guard let raw = configured as? String, !raw.isEmpty else {
            throw AccountSessionControllerError.unavailable
        }
        guard let origin = URL(string: raw), let audience = bundleIdentifier else {
            throw AccountSessionControllerError.unavailable
        }
        let validation = try AccountSessionBinding(deviceID: UUID(), audience: audience, origin: origin)
        var groupsEnabled = false
        if let value = info["DropMeshAccountGroupsEnabled"] {
            guard let boolean = value as? NSNumber, CFGetTypeID(boolean) == CFBooleanGetTypeID() else {
                throw AccountSessionControllerError.unavailable
            }
            groupsEnabled = boolean.boolValue
        }
        return MobileAccountConfiguration(origin: validation.origin, audience: validation.audience,
                                          groupsEnabled: groupsEnabled)
    }
}
