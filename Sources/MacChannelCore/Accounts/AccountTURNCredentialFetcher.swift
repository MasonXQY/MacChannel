import Foundation

/// No session/group tokens or authority snapshots cross into the graph or UI.
public struct AccountTURNCredentialFetcher: RendezvousTURNCredentialFetching {
    private let controller: AccountSessionController
    public init(controller: AccountSessionController) { self.controller = controller }
    public func fetch() async throws -> RendezvousTURNCredentials {
        try await controller.fetchAccountTURNCredentials()
    }
}
