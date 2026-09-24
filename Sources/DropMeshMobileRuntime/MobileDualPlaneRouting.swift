import Foundation
import MacChannelCore

/// Plane selection is a preference only; every underlying attempt still acquires
/// its own union lease and the selected server independently admits its route.
actor MobileDualPlaneConnector: RouteEscalatingPeerConnector {
    private let repository: TrustRepository
    private let authorization: any PeerAuthorizationProviding
    private let legacy: any RouteEscalatingPeerConnector
    private let account: any RouteEscalatingPeerConnector
    private var stopped = false

    init(repository: TrustRepository, authorization: any PeerAuthorizationProviding,
         legacy: any RouteEscalatingPeerConnector, account: any RouteEscalatingPeerConnector) {
        self.repository = repository; self.authorization = authorization
        self.legacy = legacy; self.account = account
    }

    func closeAdmission() { stopped = true }
    func connect(to device: DeviceID) async throws -> any SecureChannel {
        try await forward(to: device) { try await $0.connect(to: device) }
    }
    func connect(to device: DeviceID, transferID: TransferID) async throws -> any SecureChannel {
        try await forward(to: device) { try await $0.connect(to: device, transferID: transferID) }
    }
    func connect(to device: DeviceID, transferID: TransferID, after failedRoute: ConnectionRoute?) async throws -> any SecureChannel {
        try await forward(to: device) { try await $0.connect(to: device, transferID: transferID, after: failedRoute) }
    }
    private func forward(to peer: DeviceID,
                         operation: @Sendable (any RouteEscalatingPeerConnector) async throws -> any SecureChannel) async throws -> any SecureChannel {
        guard !stopped else { throw CancellationError() }
        try Task.checkCancellation()
        let lease = try authorization.acquire(for: peer)
        let manualKey = await repository.publicKey(for: peer)
        try authorization.validate(lease)
        guard !stopped else { throw CancellationError() }
        // Hold this plane for the complete coordinator invocation and all of its
        // LAN/direct/relay attempts. Failure never retries the other origin.
        let selected = manualKey == lease.publicKey ? legacy : account
        let channel = try await operation(selected)
        do {
            try Task.checkCancellation()
            try authorization.validate(lease)
            guard !stopped else { throw CancellationError() }
            return channel
        } catch { await channel.close(); throw error }
    }
}

/// Candidate credentials are fetched through the controller on every non-LAN
/// attempt. An ICE cache must not outlive a controller session/authorization epoch.
struct MobileAccountICEProvider: ICEConfigurationProviding {
    let fetcher: any RendezvousTURNCredentialFetching
    func configuration(for route: ConnectionRoute) async throws -> ICEConfiguration {
        try Task.checkCancellation()
        if route == .lan { return ICEConfiguration(stunURLs: [], turnServers: []) }
        let credentials = try await fetcher.fetch()
        try Task.checkCancellation()
        guard credentials.isUsable() else { throw RendezvousTURNClientError.invalidResponse }
        let ice = credentials.iceConfiguration
        return ICEConfiguration(stunURLs: ice.stunURLs, turnServers: route == .relay ? ice.turnServers : [])
    }
}

/// Independent Internet sightings; the legacy directory also owns the single
/// Bonjour lifecycle and supplies only LAN endpoint freshness for candidate peers.
actor MobileDualPlaneProjection {
    private let legacy: DeviceDirectory
    private let account: DeviceDirectory
    private let repository: TrustRepository
    private let authorization: any PeerAuthorizationProviding
    private var observers: [Task<Void, Never>] = []
    private var subscribers: [UUID: AsyncStream<[DeviceSummary]>.Continuation] = [:]
    private var stopped = false
    private var revision: UInt64 = 0

    init(legacy: DeviceDirectory, account: DeviceDirectory, repository: TrustRepository,
         authorization: any PeerAuthorizationProviding) {
        self.legacy = legacy; self.account = account; self.repository = repository; self.authorization = authorization
    }
    func start() async {
        guard !stopped, observers.isEmpty else { return }
        // Install the retained tasks before their first cross-actor subscription.
        observers = [
            Task { [weak self, legacy] in for await _ in await legacy.devices() { if Task.isCancelled { return }; await self?.publish() } },
            Task { [weak self, account] in for await _ in await account.devices() { if Task.isCancelled { return }; await self?.publish() } },
            Task { [weak self, repository] in for await _ in await repository.updates() { if Task.isCancelled { return }; await self?.publish() } },
            Task { [weak self, authorization] in for await _ in authorization.updates() { if Task.isCancelled { return }; await self?.publish() } }
        ]
    }
    func snapshot() async -> [DeviceSummary] {
        guard !stopped else { return [] }
        let manual = await legacy.snapshot()
        let candidate = await account.snapshot()
        let effective = authorization.snapshot().peers
        var result: [DeviceSummary] = []
        for peer in Set(manual.map(\.id)).union(candidate.map(\.id)) {
            guard let key = effective[peer] else { continue }
            let manualKey = await repository.publicKey(for: peer)
            let useLegacy = manualKey == key
            guard let device = (useLegacy ? manual : candidate).first(where: { $0.id == peer }) else { continue }
            let endpoint = await legacy.endpoint(for: peer)
            guard authorization.snapshot().peers[peer] == key else { continue }
            result.append(DeviceSummary(id: peer, displayName: device.displayName,
                availability: endpoint == nil ? .internet : .lan))
        }
        guard !stopped else { return [] }
        return result.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
    }
    func devices() async -> AsyncStream<[DeviceSummary]> {
        let id = UUID()
        let pair = AsyncStream<[DeviceSummary]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        guard !stopped else { pair.continuation.finish(); return pair.stream }
        subscribers[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.remove(id) } }
        await publish()
        return pair.stream
    }
    private func remove(_ id: UUID) { subscribers[id] = nil }
    private func publish() async {
        revision &+= 1
        let current = revision
        let value = await snapshot()
        guard !stopped, current == revision else { return }
        subscribers.values.forEach { $0.yield(value) }
    }
    func stop() async {
        stopped = true; revision &+= 1
        let tasks = observers; observers = []
        tasks.forEach { $0.cancel() }
        subscribers.values.forEach { $0.finish() }; subscribers = [:]
        for task in tasks { await task.value }
    }
}
