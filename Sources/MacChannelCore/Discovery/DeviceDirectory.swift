import Foundation
import Network

/// A locally derived view of devices allowed by verified trust state.
public struct DeviceTrust: Sendable {
    private let trustedIDs: Set<DeviceID>

    public init(trustedIDs: Set<DeviceID>) {
        self.trustedIDs = trustedIDs
    }

    public static func allowing(_ devices: DeviceID...) -> DeviceTrust {
        DeviceTrust(trustedIDs: Set(devices))
    }

    public func isTrusted(_ device: DeviceID) -> Bool {
        trustedIDs.contains(device)
    }

    public var deviceIDs: Set<DeviceID> {
        trustedIDs
    }

    public func device(matchingBonjourHash hash: String) -> DeviceID? {
        trustedIDs.first { BonjourPeerBrowser.deviceIDHash(for: $0) == hash }
    }
}

/// A network endpoint that is usable only while the peer has a fresh LAN sighting.
public enum DeviceEndpoint: Hashable, Sendable {
    case hostPort(host: String, port: UInt16)
    case bonjour(NWEndpoint)
}

public enum DevicePresence: Equatable, Sendable {
    case internet(DeviceID, online: Bool)
    case lan(DeviceID, host: String, port: UInt16)
    case bonjour(DeviceID, endpoint: NWEndpoint)
}

/// Merges authenticated rendezvous presence with locally resolved Bonjour peers.
/// A peer must be locally trusted before any sighting is retained or exposed.
public actor DeviceDirectory {
    public static let lanLifetime: TimeInterval = 15
    public static let internetLifetime: TimeInterval = 45

    private struct LANSighting: Sendable {
        let endpoint: DeviceEndpoint
        let expiresAt: Date
        let discoverySession: UUID?
    }

    private var trust: DeviceTrust
    private let now: @Sendable () -> Date
    private var lanSightings: [DeviceID: LANSighting] = [:]
    private var internetSightings: [DeviceID: Date] = [:]
    private var subscribers: [UUID: AsyncStream<[DeviceSummary]>.Continuation] = [:]
    private var expirationTask: Task<Void, Never>?
    private var trustUpdateTask: Task<Void, Never>?
    private var observedTrustRepository: TrustRepository?
    private var observedAuthorization: (any PeerAuthorizationProviding)?
    private var observationID = UUID()
    private var observationRevision: UInt64?
    private var activeLANDiscoverySession: UUID?

    /// Opaque capability held by a single discovery lifecycle. A stale browser
    /// task cannot mutate LAN state after its token has been ended.
    public struct LANDiscoverySessionToken: Hashable, Sendable {
        fileprivate let value: UUID
    }

    public init(
        trust: DeviceTrust,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.trust = trust
        self.now = now
    }

    deinit {
        expirationTask?.cancel()
        trustUpdateTask?.cancel()
    }

    /// Starts applying only verified, actor-owned trust state. Revocation is a
    /// trust-state transition, never an unauthenticated presence frame.
    public func observeTrust(_ repository: TrustRepository) async {
        trustObservationDrain = nil
        trustUpdateTask?.cancel()
        let id = UUID()
        observationID = id
        observationRevision = nil
        observedAuthorization = nil
        observedTrustRepository = repository
        replaceProjection([])
        let store = await repository.currentTrustStore()
        guard observationID == id else { return }
        synchronizeTrust(store, observation: id)
        let updates = await repository.updates()
        guard observationID == id else { return }
        trustUpdateTask = Task { [weak self] in
            for await store in updates {
                guard !Task.isCancelled else { return }
                await self?.synchronizeTrust(store, observation: id)
            }
        }
    }

    /// Discovery projection only; transport admission must acquire its own lease.
    public func observeAuthorization(_ provider: any PeerAuthorizationProviding) {
        trustObservationDrain = nil
        trustUpdateTask?.cancel()
        let id = UUID()
        observationID = id
        observationRevision = nil
        observedTrustRepository = nil
        observedAuthorization = provider
        // Subscribe first; its initial value covers changes between these calls.
        let updates = provider.updates()
        synchronizeAuthorization(provider.snapshot(), observation: id)
        trustUpdateTask = Task { [weak self] in
            for await snapshot in updates {
                guard !Task.isCancelled else { return }
                await self?.synchronizeAuthorization(snapshot, observation: id)
            }
        }
    }

    private var trustObservationDrain: Task<Void, Never>?

    /// Retire an ephemeral directory's observation without modifying its owner.
    /// Existing process-lifetime directories need not call this method.
    public func stopObservingTrustAndWait() async {
        if let trustObservationDrain { await trustObservationDrain.value; return }
        observationID = UUID(); observationRevision = nil
        observedAuthorization = nil; observedTrustRepository = nil
        let observer = trustUpdateTask
        trustUpdateTask = nil
        observer?.cancel()
        replaceProjection([])
        let drain = Task<Void, Never> { await observer?.value }
        trustObservationDrain = drain
        await drain.value
    }

    /// Refreshes the current repository or provider observation without switching
    /// sources. This is a discovery projection, not transport authorization.
    public func waitForTrustUpdates() async {
        let id = observationID
        if let observedAuthorization {
            synchronizeAuthorization(observedAuthorization.snapshot(), observation: id)
            return
        }
        guard let observedTrustRepository else { return }
        synchronizeTrust(await observedTrustRepository.currentTrustStore(), observation: id)
    }

    public init(
        trust: TrustStore,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.init(trust: DeviceTrust(trustedIDs: trust.trustedDeviceIDs), now: now)
    }

    public func apply(_ presence: DevicePresence) {
        let expired = purgeExpiredSightings()
        scheduleExpiryRefresh()
        if expired { publishSnapshot() }

        switch presence {
        case let .internet(device, online):
            guard isEligible(device) else { return }
            if online {
                internetSightings[device] = now().addingTimeInterval(Self.internetLifetime)
            } else {
                internetSightings.removeValue(forKey: device)
            }

        case let .lan(device, host, port):
            guard isEligible(device), !host.isEmpty, port != 0 else { return }
            lanSightings[device] = LANSighting(
                endpoint: .hostPort(host: host, port: port),
                expiresAt: now().addingTimeInterval(Self.lanLifetime),
                discoverySession: nil
            )

        case let .bonjour(device, endpoint):
            // Bonjour sighting mutation requires the actor-owned discovery
            // capability below; generic presence input cannot bypass it.
            _ = device
            _ = endpoint
            return
        }
        scheduleExpiryRefresh()
        publishSnapshot()
    }

    public func beginLANDiscoverySession() -> LANDiscoverySessionToken {
        let token = LANDiscoverySessionToken(value: UUID())
        let displacedSession = activeLANDiscoverySession
        activeLANDiscoverySession = token.value
        guard let displacedSession else { return token }
        let before = lanSightings.count
        lanSightings = lanSightings.filter { $0.value.discoverySession != displacedSession }
        scheduleExpiryRefresh()
        if lanSightings.count != before { publishSnapshot() }
        return token
    }

    public func endLANDiscoverySession(_ token: LANDiscoverySessionToken) {
        guard activeLANDiscoverySession == token.value else { return }
        activeLANDiscoverySession = nil
        let before = lanSightings.count
        lanSightings = lanSightings.filter { $0.value.discoverySession != token.value }
        scheduleExpiryRefresh()
        if lanSightings.count != before { publishSnapshot() }
    }

    /// Rotate one browser's capability without renewing or inventing sightings.
    /// A delayed replacement cannot displace a newer/ended discovery lifecycle.
    func replaceLANDiscoverySession(_ token: LANDiscoverySessionToken,
                                    retaining devices: Set<DeviceID>) -> LANDiscoverySessionToken? {
        guard activeLANDiscoverySession == token.value else { return nil }
        let replacement = LANDiscoverySessionToken(value: UUID())
        activeLANDiscoverySession = replacement.value
        let current = now()
        for (device, sighting) in lanSightings where sighting.discoverySession == token.value {
            if devices.contains(device), isEligible(device), sighting.expiresAt > current {
                lanSightings[device] = LANSighting(endpoint: sighting.endpoint,
                    expiresAt: sighting.expiresAt, discoverySession: replacement.value)
            } else {
                lanSightings.removeValue(forKey: device)
            }
        }
        scheduleExpiryRefresh()
        publishSnapshot()
        return replacement
    }

    /// Atomically checks the discovery capability immediately before mutating
    /// a Bonjour sighting. This closes the queue-to-actor stop/apply race.
    public func applyLAN(_ device: DeviceID, endpoint: NWEndpoint, token: LANDiscoverySessionToken) {
        let expired = purgeExpiredSightings()
        scheduleExpiryRefresh()
        if expired { publishSnapshot() }
        guard activeLANDiscoverySession == token.value,
              isEligible(device),
              case let .service(name, type, domain, _) = endpoint,
              type == BonjourPeerBrowser.serviceType, !name.isEmpty, !domain.isEmpty
        else { return }
        lanSightings[device] = LANSighting(
            endpoint: .bonjour(endpoint),
            expiresAt: now().addingTimeInterval(Self.lanLifetime),
            discoverySession: token.value
        )
        scheduleExpiryRefresh()
        publishSnapshot()
    }

    /// Reconciles time-bounded sightings and emits the resulting change. This is
    /// also invoked by the directory's scheduled expiry task.
    public func refresh() {
        let changed = purgeExpiredSightings()
        scheduleExpiryRefresh()
        if changed {
            publishSnapshot()
        }
    }

    public func snapshot() -> [DeviceSummary] {
        let changed = purgeExpiredSightings()
        scheduleExpiryRefresh()
        if changed { publishSnapshot() }
        return makeSnapshot()
    }

    /// Produces the current state immediately, then one deduplicated snapshot
    /// for each accepted presence change or expiry observed by the directory.
    public func devices() -> AsyncStream<[DeviceSummary]> {
        let changed = purgeExpiredSightings()
        scheduleExpiryRefresh()
        if changed { publishSnapshot() }
        let id = UUID()
        var continuation: AsyncStream<[DeviceSummary]>.Continuation!
        let stream = AsyncStream<[DeviceSummary]>(bufferingPolicy: .bufferingNewest(1)) {
            continuation = $0
        }
        continuation.yield(makeSnapshot())
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        subscribers[id] = continuation
        return stream
    }

    /// Returns the fresh LAN route for a device. Internet presence intentionally
    /// has no direct endpoint because it must use authenticated signaling/ICE.
    public func endpoint(for device: DeviceID) -> DeviceEndpoint? {
        let changed = purgeExpiredSightings()
        scheduleExpiryRefresh()
        if changed { publishSnapshot() }
        guard isEligible(device) else { return nil }
        return lanSightings[device]?.endpoint
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    private func isEligible(_ device: DeviceID) -> Bool {
        trust.isTrusted(device)
    }

    private func synchronizeTrust(_ store: TrustStore, observation: UUID) {
        guard acceptRevision(store.persistedGeneration, observation: observation) else { return }
        replaceProjection(store.trustedDeviceIDs)
    }

    private func synchronizeAuthorization(_ snapshot: PeerAuthorizationSnapshot, observation: UUID) {
        guard acceptRevision(snapshot.revision, observation: observation) else { return }
        replaceProjection(Set(snapshot.peers.keys))
    }

    private func acceptRevision(_ revision: UInt64, observation: UUID) -> Bool {
        guard observationID == observation,
              observationRevision.map({ revision > $0 }) ?? true else { return false }
        observationRevision = revision
        return true
    }

    private func replaceProjection(_ devices: Set<DeviceID>) {
        trust = DeviceTrust(trustedIDs: devices)
        // Replacement is never a union with previous sources. Eligibility does
        // not create a sighting or grant transport authority.
        _ = purgeExpiredSightings()
        scheduleExpiryRefresh()
        publishSnapshot()
    }

    @discardableResult
    private func purgeExpiredSightings() -> Bool {
        let current = now()
        let previousLAN = lanSightings.count
        let previousInternet = internetSightings.count
        lanSightings = lanSightings.filter { $0.value.expiresAt > current && isEligible($0.key) }
        internetSightings = internetSightings.filter { $0.value > current && isEligible($0.key) }
        return previousLAN != lanSightings.count || previousInternet != internetSightings.count
    }

    private func scheduleExpiryRefresh() {
        expirationTask?.cancel()
        let nextExpiry = (lanSightings.values.map(\.expiresAt) + internetSightings.values)
            .min()
        guard let nextExpiry else {
            expirationTask = nil
            return
        }
        let delay = max(0, nextExpiry.timeIntervalSince(now()))
        expirationTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    private func makeSnapshot() -> [DeviceSummary] {
        // Every production route uses the authenticated rendezvous socket for
        // WebRTC signaling. Bonjour proves only that the app is visible on the
        // LAN; it must not advertise a peer as send-ready when that socket is
        // offline. A fresh LAN sighting still selects the preferred ICE route
        // once authenticated presence confirms the peer is reachable.
        return internetSightings.keys.compactMap { device in
            guard isEligible(device) else { return nil }
            let availability: DeviceAvailability = lanSightings[device] == nil ? .internet : .lan
            // Discovery carries no display name. A paired-device UI may join this
            // summary with separately stored, owner-approved presentation data.
            return DeviceSummary(id: device, displayName: "", availability: availability)
        }.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
    }

    private func publishSnapshot() {
        let current = makeSnapshot()
        for continuation in subscribers.values {
            continuation.yield(current)
        }
    }
}
