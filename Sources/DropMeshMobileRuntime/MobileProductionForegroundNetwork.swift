import Foundation
import MacChannelCore

/// Transport seam only. The runtime always owns the real incoming listener,
/// real transfer coordinator and database even when tests inject this graph.
protocol MobileForegroundNetwork: Sendable {
    var connector: any RouteEscalatingPeerConnector { get }
    var source: any IncomingTransferConnectionSource { get }
    func start() async
    func stop() async
    func retryConnection() async
    func refreshTrust() async
    func setLocalDiscoveryEnabled(_ enabled: Bool) async
}

actor MobileProductionForegroundNetwork: MobileForegroundNetwork {
    nonisolated let connector: any RouteEscalatingPeerConnector
    nonisolated let source: any IncomingTransferConnectionSource
    private let listener: WebRTCConnectionListener
    private let presence: MobilePresenceSupervisor
    private let session: URLSession
    private let browser: BonjourPeerBrowser
    private let advertiser: BonjourPeerAdvertiser
    private let repository: TrustRepository
    private let onDiscovery: @Sendable (Bool) async -> Void
    private var stopped = false
    private var drain: Task<Void, Never>?
    private var discoveryTasks: [Task<Void, Never>] = []
    private var discoveryRevision: UInt64 = 0
    private var browserReady = false
    private var advertiserReady = false

    init(identity: DeviceIdentity, repository: TrustRepository, directory: DeviceDirectory,
         onState: @escaping @Sendable (MobilePresenceState) async -> Void,
         onDiscovery: @escaping @Sendable (Bool) async -> Void) throws {
        self.repository = repository
        self.onDiscovery = onDiscovery
        session = URLSession(configuration: .ephemeral)
        presence = MobilePresenceSupervisor(identity: identity, repository: repository,
            directory: directory, onState: onState)
        let signaling = RendezvousWebRTCSignaling(session: presence.bridge)
        let turn = try RendezvousTURNCredentialClient(identity: identity,
            origin: MobileRuntimeConfiguration.httpOrigin, session: session)
        let ice = RefreshingICEConfigurationProvider(
            base: ICEConfiguration(stunURLs: [], turnServers: []), fetcher: turn)
        connector = ConnectionCoordinator(directory: directory, identity: identity,
            trustRepository: repository, signaling: signaling, iceProvider: ice)
        listener = WebRTCConnectionListener(directory: directory, identity: identity,
            trustRepository: repository, signaling: signaling, iceProvider: ice)
        source = listener
        browser = BonjourPeerBrowser(directory: directory, trust: DeviceTrust(trustedIDs: []))
        advertiser = try BonjourPeerAdvertiser(device: identity.id, port: 45_873) { $0.cancel() }
    }

    func start() async { guard !stopped else { return }; await presence.start() }
    func retryConnection() async { guard !stopped else { return }; await presence.retryConnection() }
    func refreshTrust() async { guard !stopped else { return }; await presence.refreshTrust() }

    func stop() async {
        if let drain { await drain.value; return }
        stopped = true
        discoveryRevision &+= 1
        let observers = discoveryTasks
        discoveryTasks = []
        observers.forEach { $0.cancel() }
        // HTTP cancellation begins immediately, separately from socket sessions.
        session.invalidateAndCancel()
        let task = Task { [listener, presence, browser, advertiser] in
            async let inbound: Void = listener.stop()
            async let socket: Void = presence.stop()
            async let browsing: Void = browser.stop()
            async let advertising: Void = advertiser.stopAndWait()
            _ = await (inbound, socket, browsing, advertising)
            for observer in observers { await observer.value }
        }
        drain = task
        await task.value
    }

    func setLocalDiscoveryEnabled(_ enabled: Bool) async {
        guard !stopped else { return }
        discoveryRevision &+= 1
        let revision = discoveryRevision
        let old = discoveryTasks
        old.forEach { $0.cancel() }
        discoveryTasks = []
        browserReady = false; advertiserReady = false
        async let browsing: Void = browser.stop()
        async let advertising: Void = advertiser.stopAndWait()
        _ = await (browsing, advertising)
        for observer in old { await observer.value }
        guard !stopped, revision == discoveryRevision else { return }
        await onDiscovery(false)
        guard enabled, !stopped, revision == discoveryRevision else { return }
        browser.observeTrust(repository)
        let browserStates = browser.states()
        let advertiserStates = advertiser.states()
        discoveryTasks = [
            Task { [weak self] in for await state in browserStates {
                guard !Task.isCancelled else { return }
                await self?.discoveryState(state, browser: true, revision: revision)
            } },
            Task { [weak self] in for await state in advertiserStates {
                guard !Task.isCancelled else { return }
                await self?.discoveryState(state, browser: false, revision: revision)
            } }
        ]
        browser.start(); advertiser.start()
    }

    private func discoveryState(_ state: BonjourLifecycleState, browser: Bool, revision: UInt64) async {
        guard !stopped, revision == discoveryRevision else { return }
        if browser { browserReady = state == .ready } else { advertiserReady = state == .ready }
        await onDiscovery(browserReady && advertiserReady)
    }
}
