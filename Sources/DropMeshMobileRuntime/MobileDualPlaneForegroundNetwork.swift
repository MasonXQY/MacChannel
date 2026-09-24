import Foundation
import MacChannelCore

/// Explicit account transport selection; never changes the legacy pairing origin.
public struct MobileAccountPlaneConfiguration: Sendable {
    let webSocketOrigin: URL
    let controller: AccountSessionController
    let makeSocket: @Sendable () async throws -> any PresenceWebSocket
    let iceProvider: any ICEConfigurationProviding

    public init(webSocketOrigin: URL, controller: AccountSessionController,
                turnFetcher: any RendezvousTURNCredentialFetching) throws {
        try Self.validate(webSocketOrigin)
        self.webSocketOrigin = webSocketOrigin; self.controller = controller
        self.iceProvider = MobileAccountICEProvider(fetcher: turnFetcher)
        self.makeSocket = {
            try URLSessionPresenceWebSocket(origin: webSocketOrigin,
                session: URLSession(configuration: .ephemeral))
        }
    }

    init(webSocketOrigin: URL, controller: AccountSessionController,
         makeSocket: @escaping @Sendable () async throws -> any PresenceWebSocket,
         iceProvider: any ICEConfigurationProviding) throws {
        try Self.validate(webSocketOrigin)
        self.webSocketOrigin = webSocketOrigin; self.controller = controller
        self.makeSocket = makeSocket; self.iceProvider = iceProvider
    }

    private static func validate(_ origin: URL) throws {
        guard let value = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              value.scheme == "wss", let host = value.host, !host.isEmpty,
              value.user == nil, value.password == nil, value.query == nil, value.fragment == nil,
              value.path == "/v1/ws" else { throw RendezvousTURNClientError.insecureOrigin }
    }
}

/// One foreground graph, two independent Internet planes, one LAN lifecycle and
/// one shared inbound budget. Account transport cannot overwrite legacy sightings.
actor MobileDualPlaneForegroundNetwork: MobileForegroundNetwork {
    nonisolated let connector: any RouteEscalatingPeerConnector
    nonisolated let source: any IncomingTransferConnectionSource
    nonisolated let sources: [any IncomingTransferConnectionSource]
    private let outgoing: MobileDualPlaneConnector
    private let legacy: MobileProductionForegroundNetwork
    private let accountPresence: MobilePresenceSupervisor
    private let accountListener: WebRTCConnectionListener
    private let accountDirectory: DeviceDirectory
    private let authorization: any PeerAuthorizationProviding
    private let projection: MobileDualPlaneProjection
    private let status: MobileDualPlaneStatus
    private var stopped = false
    private var startup: Task<Void, Never>?
    private var drain: Task<Void, Never>?

    init(identity: DeviceIdentity, repository: TrustRepository,
         authorizationProvider: any PeerAuthorizationProviding, directory: DeviceDirectory,
         account: MobileAccountPlaneConfiguration,
         publication: @escaping @Sendable () async throws -> TrustPublicationSnapshot,
         persistedUpdates: @escaping @Sendable () async -> AsyncStream<AuthenticatedTrustState?>,
         onState: @escaping @Sendable (MobilePresenceState) async -> Void,
         onTrustSyncState: @escaping @Sendable (PresenceTrustSyncState) async -> Void,
         onDiscovery: @escaping @Sendable (Bool) async -> Void) throws {
        let status = MobileDualPlaneStatus(changed: onState)
        self.status = status
        let budget = WebRTCAcceptanceBudget()
        let legacy = try MobileProductionForegroundNetwork(identity: identity, repository: repository,
            authorizationProvider: authorizationProvider, directory: directory,
            publication: publication, persistedUpdates: persistedUpdates,
            onState: { await status.update($0, account: false) },
            onTrustSyncState: onTrustSyncState, onDiscovery: onDiscovery, acceptanceBudget: budget)
        self.legacy = legacy
        let accountDirectory = DeviceDirectory(trust: DeviceTrust(trustedIDs: []))
        self.accountDirectory = accountDirectory
        authorization = authorizationProvider
        let presence = MobilePresenceSupervisor(identity: identity, repository: repository,
            directory: accountDirectory, accountOrigin: account.webSocketOrigin,
            accountController: account.controller, makeSocket: account.makeSocket,
            onState: { await status.update($0, account: true) },
            publication: { TrustPublicationSnapshot(records: []) })
        accountPresence = presence
        let signaling = RendezvousWebRTCSignaling(session: presence.bridge)
        // The shared directory supplies only endpoint(for:) to these WebRTC
        // adapters. Candidate Internet presence never enters that directory.
        let candidate = ConnectionCoordinator(attempts: WebRTCConnectionAttempts(directory: directory,
            identity: identity, authorizationProvider: authorizationProvider,
            signaling: signaling, iceProvider: account.iceProvider, factory: WebRTCFactory()))
        accountListener = WebRTCConnectionListener(directory: directory, identity: identity,
            authorizationProvider: authorizationProvider, signaling: signaling,
            iceProvider: account.iceProvider, factory: WebRTCFactory(), acceptanceBudget: budget)
        outgoing = MobileDualPlaneConnector(repository: repository, authorization: authorizationProvider,
            legacy: legacy.connector, account: candidate)
        connector = outgoing
        source = legacy.source
        sources = [legacy.source, accountListener]
        projection = MobileDualPlaneProjection(legacy: directory, account: accountDirectory,
            repository: repository, authorization: authorizationProvider)
    }

    func projectedDevices() async -> AsyncStream<[DeviceSummary]>? { await projection.devices() }
    func start() async {
        if let startup { await startup.value; return }
        guard !stopped else { return }
        let task = Task { await startBody() }
        startup = task
        await task.value
    }
    private func startBody() async {
        guard !stopped else { return }
        await accountDirectory.observeAuthorization(authorization)
        guard !stopped else { return }
        await projection.start()
        guard !stopped else { return }
        async let first: Void = legacy.start()
        async let second: Void = accountPresence.start()
        _ = await (first, second)
    }
    func retryConnection() async {
        guard !stopped else { return }
        async let first: Void = legacy.retryConnection()
        async let second: Void = accountPresence.retryConnection()
        _ = await (first, second)
    }
    func refreshTrust() async { guard !stopped else { return }; await legacy.refreshTrust() }
    func setLocalDiscoveryEnabled(_ enabled: Bool) async { guard !stopped else { return }; await legacy.setLocalDiscoveryEnabled(enabled) }
    func stop() async {
        if let drain { await drain.value; return }
        stopped = true
        startup?.cancel()
        let startup = startup
        let task = Task { [outgoing, legacy, accountPresence, accountListener, accountDirectory, projection, status] in
            await outgoing.closeAdmission()
            await status.stop()
            // Initiate every close before joining; a hung account operation must
            // not prevent legacy shutdown from starting, or license replacement.
            async let first: Void = legacy.stop()
            async let second: Void = accountPresence.stop()
            async let inbound: Void = accountListener.stopAndWait()
            async let discovery: Void = projection.stop()
            async let observation: Void = accountDirectory.stopObservingTrustAndWait()
            _ = await (first, second, inbound, discovery, observation)
            await startup?.value
            // A startup already crossing into the directory may have installed
            // its observer while the first close was in flight.
            await accountDirectory.stopObservingTrustAndWait()
        }
        drain = task
        await task.value
    }
}

private actor MobileDualPlaneStatus {
    private var legacy: PresenceSessionState = .inactive
    private var candidate: PresenceSessionState = .inactive
    private var stopped = false
    private let changed: @Sendable (PresenceSessionState) async -> Void
    init(changed: @escaping @Sendable (PresenceSessionState) async -> Void) { self.changed = changed }
    func update(_ value: PresenceSessionState, account: Bool) async {
        guard !stopped else { return }
        if account { candidate = value } else { legacy = value }
        let combined: PresenceSessionState = legacy == .online || candidate == .online
            ? .online : (legacy == .inactive ? candidate : legacy)
        await changed(combined)
    }
    func stop() { stopped = true }
}
