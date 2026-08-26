import Foundation

/// A fixed, locally derived view of devices that are allowed to be discovered.
/// Revocations received at runtime are additionally applied by `DeviceDirectory`.
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

    public func device(matchingBonjourHash hash: String) -> DeviceID? {
        trustedIDs.first { BonjourPeerBrowser.deviceIDHash(for: $0) == hash }
    }
}

/// A network endpoint that is usable only while the peer has a fresh LAN sighting.
public enum DeviceEndpoint: Hashable, Sendable {
    case hostPort(host: String, port: UInt16)
    case bonjour(serviceName: String, type: String, domain: String)
}

public enum DevicePresence: Equatable, Sendable {
    case internet(DeviceID, online: Bool)
    case lan(DeviceID, host: String, port: UInt16)
    case bonjour(DeviceID, serviceName: String, type: String, domain: String)
    case revoked(DeviceID)
}

/// Merges authenticated rendezvous presence with locally resolved Bonjour peers.
/// A peer must be locally trusted before any sighting is retained or exposed.
public actor DeviceDirectory {
    public static let lanLifetime: TimeInterval = 15
    public static let internetLifetime: TimeInterval = 45

    private struct LANSighting: Sendable {
        let endpoint: DeviceEndpoint
        let expiresAt: Date
    }

    private let trust: DeviceTrust
    private let now: @Sendable () -> Date
    private var revokedIDs: Set<DeviceID> = []
    private var lanSightings: [DeviceID: LANSighting] = [:]
    private var internetSightings: [DeviceID: Date] = [:]
    private var subscribers: [UUID: AsyncStream<[DeviceSummary]>.Continuation] = [:]
    private var expirationTask: Task<Void, Never>?

    public init(
        trust: DeviceTrust,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.trust = trust
        self.now = now
    }

    public init(
        trust: TrustStore,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.init(trust: DeviceTrust(trustedIDs: trust.trustedDeviceIDs), now: now)
    }

    public func apply(_ presence: DevicePresence) {
        purgeExpiredSightings()

        switch presence {
        case let .revoked(device):
            guard trust.isTrusted(device) else { return }
            revokedIDs.insert(device)
            lanSightings.removeValue(forKey: device)
            internetSightings.removeValue(forKey: device)

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
                expiresAt: now().addingTimeInterval(Self.lanLifetime)
            )

        case let .bonjour(device, serviceName, type, domain):
            guard isEligible(device), type == BonjourPeerBrowser.serviceType,
                  !serviceName.isEmpty, !domain.isEmpty
            else { return }
            lanSightings[device] = LANSighting(
                endpoint: .bonjour(serviceName: serviceName, type: type, domain: domain),
                expiresAt: now().addingTimeInterval(Self.lanLifetime)
            )
        }
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
        purgeExpiredSightings()
        scheduleExpiryRefresh()
        return makeSnapshot()
    }

    /// Produces the current state immediately, then one deduplicated snapshot
    /// for each accepted presence change or expiry observed by the directory.
    public func devices() -> AsyncStream<[DeviceSummary]> {
        purgeExpiredSightings()
        scheduleExpiryRefresh()
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
        purgeExpiredSightings()
        guard isEligible(device) else { return nil }
        return lanSightings[device]?.endpoint
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    private func isEligible(_ device: DeviceID) -> Bool {
        trust.isTrusted(device) && !revokedIDs.contains(device)
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
        let devices = Set(lanSightings.keys).union(internetSightings.keys)
        return devices.compactMap { device in
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
