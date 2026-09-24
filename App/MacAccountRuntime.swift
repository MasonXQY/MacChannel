import Foundation
import MacChannelCore

struct MacAccountRuntimeConfiguration: Sendable {
    let origin: URL
    let audience: String
    let webSocketOrigin: URL

    init(origin: URL, audience: String) throws {
        let binding = try AccountSessionBinding(deviceID: UUID(), audience: audience, origin: origin)
        var components = URLComponents(url: binding.origin, resolvingAgainstBaseURL: false)
        components?.scheme = "wss"
        components?.path = "/v1/ws"
        guard let webSocketOrigin = components?.url else {
            throw AccountSessionControllerError.unavailable
        }
        self.origin = binding.origin
        self.audience = binding.audience
        self.webSocketOrigin = webSocketOrigin
    }
}

struct MacAccountRuntime: Sendable {
    let controller: AccountSessionController
    let lifecycle: AccountForegroundLifecycle

    static func make(
        configuration: MacAccountRuntimeConfiguration,
        identity: DeviceIdentity,
        authorizationOwner: PeerAuthorizationOwner
    ) throws -> MacAccountRuntime {
        let service = try AccountServiceClient(
            identity: identity, origin: configuration.origin, audience: configuration.audience)
        let binding = try AccountSessionBinding(
            deviceID: identity.id.rawValue,
            audience: configuration.audience,
            origin: configuration.origin)
        let checkpoints = KeychainAccountGroupCheckpointStorage()
        let bootstrapIntents = KeychainAccountGroupBootstrapIntentStorage()
        let approvalIntents = KeychainAccountGroupApprovalIntentStorage()
        let invitationLinks = KeychainAccountInvitationLinkStorage()
        let invitations = KeychainAccountInvitationStorage()
        let deletion = AccountDeletionConfiguration(
            storage: KeychainAccountDeletionStorage(binding: binding),
            clearAccountCheckpoints: { binding, accountID in
                let account = accountID.uuidString.lowercased()
                try await checkpoints.removeForAccount(binding: binding, accountID: account)
                try await bootstrapIntents.removeForAccount(binding: binding, accountID: account)
                try await approvalIntents.removeForAccount(binding: binding, accountID: account)
                try await invitationLinks.removeForAccount(binding: binding, accountID: account)
                try await invitations.removeForAccount(binding: binding, accountID: account)
            })
        let authorization = try AccountPeerAuthorization(
            owner: authorizationOwner, identity: identity, binding: binding, freshness: 300)
        let controller = try AccountSessionController(
            service: service,
            storage: KeychainAccountSessionStorage(binding: binding),
            binding: binding,
            groupVerifier: AccountGroupHistoryVerifier(storage: checkpoints),
            peerAuthorization: authorization,
            firstDeviceEnrollment: AccountFirstDeviceEnrollment(
                identity: identity, intentStorage: bootstrapIntents),
            deviceApproval: AccountDeviceApproval(
                identity: identity, intentStorage: approvalIntents),
            deletion: deletion,
            invitations: AccountInvitationConfiguration(
                identity: identity, links: invitationLinks, invitations: invitations))
        return MacAccountRuntime(
            controller: controller,
            lifecycle: AccountForegroundLifecycle(
                controller: controller,
                automaticEnrollment: AccountAutomaticEnrollment(controller: controller)))
    }
}

/// Projects two independent authenticated Internet planes into the single
/// device list used by the Mac UI and LAN route selection. Neither source can
/// mark a peer offline while the other still has a fresh authenticated sighting.
actor MacDualPlaneProjection {
    private let manual: DeviceDirectory
    private let account: DeviceDirectory
    private let destination: DeviceDirectory
    private var observers: [Task<Void, Never>] = []
    private var visible: Set<DeviceID> = []
    private var stopped = false

    init(manual: DeviceDirectory, account: DeviceDirectory, destination: DeviceDirectory) {
        self.manual = manual
        self.account = account
        self.destination = destination
    }

    func start() async {
        guard !stopped, observers.isEmpty else { return }
        let manualStream = await manual.devices()
        let accountStream = await account.devices()
        observers = [
            Task { [weak self] in
                for await _ in manualStream {
                    guard !Task.isCancelled else { return }
                    await self?.publish()
                }
            },
            Task { [weak self] in
                for await _ in accountStream {
                    guard !Task.isCancelled else { return }
                    await self?.publish()
                }
            },
        ]
        await publish()
    }

    private func publish() async {
        guard !stopped else { return }
        let manualPeers = await manual.snapshot()
        let accountPeers = await account.snapshot()
        let next = Set(manualPeers.map(\.id)).union(accountPeers.map(\.id))
        for peer in next { await destination.apply(.internet(peer, online: true)) }
        for peer in visible.subtracting(next) { await destination.apply(.internet(peer, online: false)) }
        visible = next
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        let tasks = observers
        observers = []
        tasks.forEach { $0.cancel() }
        for peer in visible { await destination.apply(.internet(peer, online: false)) }
        visible = []
        for task in tasks { await task.value }
    }
}

/// Chooses the only plane authorized for the peer at the start of a transfer.
/// A lease is revalidated after connection so account/manual authority cannot
/// be switched underneath an in-flight attempt.
actor MacDualPlaneConnector: RouteEscalatingPeerConnector {
    private let repository: TrustRepository
    private let authorization: any PeerAuthorizationProviding
    private let manual: any RouteEscalatingPeerConnector
    private let account: any RouteEscalatingPeerConnector
    private var stopped = false

    init(repository: TrustRepository, authorization: any PeerAuthorizationProviding,
         manual: any RouteEscalatingPeerConnector, account: any RouteEscalatingPeerConnector) {
        self.repository = repository
        self.authorization = authorization
        self.manual = manual
        self.account = account
    }

    func stop() { stopped = true }

    func connect(to device: DeviceID) async throws -> any SecureChannel {
        try await forward(to: device) { try await $0.connect(to: device) }
    }

    func connect(to device: DeviceID, transferID: TransferID) async throws -> any SecureChannel {
        try await forward(to: device) { try await $0.connect(to: device, transferID: transferID) }
    }

    func connect(to device: DeviceID, transferID: TransferID,
                 after failedRoute: ConnectionRoute?) async throws -> any SecureChannel {
        try await forward(to: device) {
            try await $0.connect(to: device, transferID: transferID, after: failedRoute)
        }
    }

    private func forward(
        to peer: DeviceID,
        operation: @Sendable (any RouteEscalatingPeerConnector) async throws -> any SecureChannel
    ) async throws -> any SecureChannel {
        guard !stopped else { throw CancellationError() }
        let lease = try authorization.acquire(for: peer)
        let manualKey = await repository.publicKey(for: peer)
        try authorization.validate(lease)
        let selected = manualKey == lease.publicKey ? manual : account
        let channel = try await operation(selected)
        do {
            try Task.checkCancellation()
            try authorization.validate(lease)
            guard !stopped else { throw CancellationError() }
            return channel
        } catch {
            await channel.close()
            throw error
        }
    }
}

struct MacAccountICEProvider: ICEConfigurationProviding {
    let fetcher: any RendezvousTURNCredentialFetching

    func configuration(for route: ConnectionRoute) async throws -> ICEConfiguration {
        if route == .lan { return ICEConfiguration(stunURLs: [], turnServers: []) }
        let credentials = try await fetcher.fetch()
        guard credentials.isUsable() else { throw RendezvousTURNClientError.invalidResponse }
        let ice = credentials.iceConfiguration
        return ICEConfiguration(
            stunURLs: ice.stunURLs,
            turnServers: route == .relay ? ice.turnServers : [])
    }
}
