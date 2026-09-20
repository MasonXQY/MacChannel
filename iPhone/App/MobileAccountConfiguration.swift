import Foundation
import CoreFoundation
import MacChannelCore

struct MobileAccountConfiguration: Equatable, Sendable {
    let origin: URL
    let audience: String
    let groupsEnabled: Bool
    let transportOrigin: URL?

    /// Group settings alone cannot authorize transfers on the legacy plane.
    func makePeerAuthorization(owner: PeerAuthorizationOwner, identity: DeviceIdentity) throws -> AccountPeerAuthorization? {
        guard groupsEnabled, transportOrigin != nil else { return nil }
        let binding = try AccountSessionBinding(deviceID: identity.id.rawValue, audience: audience, origin: origin)
        return try AccountPeerAuthorization(owner: owner, identity: identity, binding: binding, freshness: 300)
    }

    static func load(bundle: Bundle = .main) throws -> MobileAccountConfiguration? {
        try load(info: bundle.infoDictionary ?? [:], bundleIdentifier: bundle.bundleIdentifier)
    }

    static func load(info: [String: Any], bundleIdentifier: String?) throws -> MobileAccountConfiguration? {
        guard let configured = info["DropMeshAccountServiceOrigin"] else {
            guard info["DropMeshAccountTransportOrigin"] == nil else { throw AccountSessionControllerError.unavailable }
            return nil
        }
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
        var transportOrigin: URL?
        if let configured = info["DropMeshAccountTransportOrigin"] {
            guard groupsEnabled, let raw = configured as? String, !raw.isEmpty,
                  let origin = URL(string: raw) else { throw AccountSessionControllerError.unavailable }
            let binding = try AccountSessionBinding(deviceID: validation.deviceID, audience: validation.audience, origin: origin)
            guard binding.origin == validation.origin else { throw AccountSessionControllerError.unavailable }
            transportOrigin = binding.origin
        }
        return MobileAccountConfiguration(origin: validation.origin, audience: validation.audience,
                                          groupsEnabled: groupsEnabled, transportOrigin: transportOrigin)
    }
}
