import Foundation

/// Explicit producer configuration. Constructing this value grants no authority.
public struct AccountPeerAuthorization: Sendable {
    let owner: PeerAuthorizationOwner
    let localPublicKey: Data
    let binding: AccountSessionBinding
    let freshness: TimeInterval

    public init(owner: PeerAuthorizationOwner, identity: DeviceIdentity,
                binding: AccountSessionBinding, freshness: TimeInterval) throws {
        guard freshness.isFinite, freshness > 0, freshness <= 300,
              owner.localDeviceID == identity.id, binding.deviceID == identity.id.rawValue else {
            throw PeerAuthorizationError.invalidEvidence
        }
        self.owner = owner; self.localPublicKey = identity.publicKey.rawRepresentation
        self.binding = binding; self.freshness = freshness
    }
}
