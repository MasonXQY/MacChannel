import Foundation

/// Explicit opt-in; these stores contain recovery metadata, not peer authority.
public struct AccountInvitationConfiguration: Sendable {
    let identity: DeviceIdentity?
    let links: KeychainAccountInvitationLinkStorage
    let invitations: KeychainAccountInvitationStorage
    public init(identity: DeviceIdentity? = nil,
                links: KeychainAccountInvitationLinkStorage = .init(),
                invitations: KeychainAccountInvitationStorage = .init()) {
        self.identity = identity
        self.links = links; self.invitations = invitations
    }
}
