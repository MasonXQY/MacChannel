import CryptoKit
import Foundation
import Network

public enum BonjourLifecycleState: Equatable, Sendable {
    case stopped
    case starting
    case ready
    case failed(String)
}

public enum BonjourPeerAdvertiserError: Error, Equatable, Sendable { case invalidPort }

public final class BonjourPeerAdvertiser: @unchecked Sendable {
    public let service: NWListener.Service
    private let port: NWEndpoint.Port
    private let onConnection: @Sendable (NWConnection) -> Void
    private let queue = DispatchQueue(label: "com.mason.macchannel.bonjour-advertiser")
    private var listener: NWListener?
    private var generation: UInt64 = 0
    private var lifecycleState: BonjourLifecycleState = .stopped

    public init(device: DeviceID, port: UInt16, onConnection: @escaping @Sendable (NWConnection) -> Void) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port), port != 0 else { throw BonjourPeerAdvertiserError.invalidPort }
        self.port = endpointPort
        self.onConnection = onConnection
        service = BonjourPeerBrowser.service(for: device)
    }

    public func state() -> BonjourLifecycleState { queue.sync { lifecycleState } }
    public func start() { queue.async { [weak self] in self?.startOnQueue() } }
    public func stop() { queue.async { [weak self] in
        guard let self else { return }
        self.generation &+= 1; self.listener?.cancel(); self.listener = nil; self.lifecycleState = .stopped
    } }

    private func startOnQueue() {
        guard listener == nil else { return }
        generation &+= 1
        let activeGeneration = generation
        lifecycleState = .starting
        do {
            let listener = try NWListener(using: .tcp, on: port)
            listener.service = service
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.isCurrent(activeGeneration) else { connection.cancel(); return }
                self.onConnection(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in self?.record(state: state, generation: activeGeneration) }
            self.listener = listener
            listener.start(queue: queue)
        } catch { lifecycleState = .failed("listener_creation_failed") }
    }

    private func record(state: NWListener.State, generation: UInt64) {
        guard isCurrent(generation) else { return }
        switch state {
        case .ready: lifecycleState = .ready
        case .failed: lifecycleState = .failed("listener_failed"); listener?.cancel(); listener = nil
        case .cancelled: lifecycleState = .stopped; listener = nil
        default: break
        }
    }
    private func isCurrent(_ candidate: UInt64) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return candidate == generation && (lifecycleState == .starting || lifecycleState == .ready)
    }
}

/// Browses TXT-aware Bonjour results on one serial queue. The exact resolved
/// `NWEndpoint` is retained (including interface) and renewed while stable.
public final class BonjourPeerBrowser: @unchecked Sendable {
    public static let serviceType = "_macchannel._tcp"
    public static let protocolVersion = "1"

    private let directory: DeviceDirectory
    private var trust: DeviceTrust
    private let renewalInterval: TimeInterval
    private let queue = DispatchQueue(label: "com.mason.macchannel.bonjour-browser")
    private var browser: NWBrowser?
    private var renewalTimer: DispatchSourceTimer?
    private var currentSightings: [DeviceID: NWEndpoint] = [:]
    private var generation: UInt64 = 0
    private var lifecycleState: BonjourLifecycleState = .stopped
    private var trustUpdateTask: Task<Void, Never>?
    private var trustObservationGeneration: UInt64 = 0
    private var directoryTasks: [UUID: Task<Void, Never>] = [:]
    private var directorySessionTask: Task<DeviceDirectory.LANDiscoverySessionToken?, Never>?
    private var directorySessionEndTask: Task<Void, Never>?
    private let beforeDirectoryApply: (@Sendable () async -> Void)?

    public convenience init(directory: DeviceDirectory, trust: DeviceTrust, renewalInterval: TimeInterval = 5) {
        self.init(directory: directory, trust: trust, renewalInterval: renewalInterval, beforeDirectoryApply: nil)
    }
    init(
        directory: DeviceDirectory,
        trust: DeviceTrust,
        renewalInterval: TimeInterval,
        beforeDirectoryApply: (@Sendable () async -> Void)?
    ) {
        self.directory = directory; self.trust = trust; self.renewalInterval = max(0.1, renewalInterval); self.beforeDirectoryApply = beforeDirectoryApply
    }
    // Deinitialization cannot provide an ordered actor boundary. Normal callers
    // must await stop(); this is only best-effort cleanup for abandoned owners.
    deinit {
        trustUpdateTask?.cancel()
        directoryTasks.values.forEach { $0.cancel() }
        if let directorySessionTask {
            let directory = self.directory
            Task {
                guard let token = await directorySessionTask.value else { return }
                await directory.endLANDiscoverySession(token)
            }
        }
    }
    public static func txtRecord(for device: DeviceID) -> [String: String] { ["id": deviceIDHash(for: device), "version": protocolVersion] }
    public static func service(for device: DeviceID) -> NWListener.Service { NWListener.Service(name: deviceIDHash(for: device), type: serviceType, txtRecord: NWTXTRecord(txtRecord(for: device))) }
    public static func deviceIDHash(for device: DeviceID) -> String { SHA256.hash(data: Data(device.rawValue.uuidString.lowercased().utf8)).map { String(format: "%02x", $0) }.joined() }
    public func state() -> BonjourLifecycleState { queue.sync { lifecycleState } }
    public func observeTrust(_ repository: TrustRepository) {
        queue.async { [weak self] in self?.observeTrustOnQueue(repository) }
    }
    private func observeTrustOnQueue(_ repository: TrustRepository) {
        dispatchPrecondition(condition: .onQueue(queue))
        trustUpdateTask?.cancel()
        trustObservationGeneration &+= 1
        let observationGeneration = trustObservationGeneration
        trustUpdateTask = Task { [weak self] in
            let updates = await repository.updates()
            for await store in updates {
                guard !Task.isCancelled else { return }
                self?.queue.async { [weak self] in
                    guard let self, self.trustObservationGeneration == observationGeneration else { return }
                    let updatedTrust = DeviceTrust(trustedIDs: store.trustedDeviceIDs)
                    self.trust = updatedTrust
                    self.currentSightings = self.currentSightings.filter { updatedTrust.isTrusted($0.key) }
                }
            }
        }
    }
    public func start() { queue.async { [weak self] in self?.startOnQueue() } }
    /// Ordered lifecycle boundary: all future discovery applications carry an
    /// ended token before this returns, and earlier token sightings are purged.
    public func stop() async {
        let sessionTask: Task<DeviceDirectory.LANDiscoverySessionToken?, Never>? = await withCheckedContinuation { (continuation: CheckedContinuation<Task<DeviceDirectory.LANDiscoverySessionToken?, Never>?, Never>) in
            queue.async { [weak self] in
                guard let self else { continuation.resume(returning: nil); return }
                self.generation &+= 1
                self.browser?.cancel(); self.browser = nil
                self.renewalTimer?.cancel(); self.renewalTimer = nil
                self.currentSightings = [:]
                let task = self.directorySessionTask
                self.directorySessionTask = nil
                self.cancelOwnedTasksOnQueue()
                self.lifecycleState = .stopped
                continuation.resume(returning: task)
            }
        }
        guard let sessionTask, let token = await sessionTask.value else { return }
        await directory.endLANDiscoverySession(token)
    }

    /// Internal test hook; production calls this only from the NWBrowser handler.
    func accept(endpoint: NWEndpoint, txtRecord: [String: String], generation: UInt64? = nil) {
        queue.async { [weak self] in guard let self else { return }; self.acceptOnQueue(endpoint: endpoint, txtRecord: txtRecord, generation: generation ?? self.generation) }
    }

    private func startOnQueue() {
        guard browser == nil else { return }
        generation &+= 1; let activeGeneration = generation; lifecycleState = .starting
        let directory = self.directory
        let sessionTask: Task<DeviceDirectory.LANDiscoverySessionToken?, Never> = Task { [weak self, directory] in
            guard self != nil, !Task.isCancelled else { return nil }
            return await directory.beginLANDiscoverySession()
        }
        directorySessionTask = sessionTask
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in self?.consume(results, generation: activeGeneration) }
        browser.stateUpdateHandler = { [weak self] state in self?.record(state: state, generation: activeGeneration) }
        self.browser = browser
        installRenewalTimer(generation: activeGeneration)
        browser.start(queue: queue)
    }

    private func record(state: NWBrowser.State, generation: UInt64) {
        guard isCurrent(generation) else { return }
        switch state {
        case .ready: lifecycleState = .ready
        case .failed:
            lifecycleState = .failed("browser_failed")
            browser?.cancel(); browser = nil
            renewalTimer?.cancel(); renewalTimer = nil
            currentSightings = [:]
            endDirectorySessionOnQueue()
            cancelOwnedTasksOnQueue()
        case .cancelled: lifecycleState = .stopped; browser = nil; endDirectorySessionOnQueue(); cancelOwnedTasksOnQueue()
        default: break
        }
    }
    private func consume(_ results: Set<NWBrowser.Result>, generation: UInt64) {
        guard isCurrent(generation) else { return }
        currentSightings = [:]
        for result in results { if case let .bonjour(record) = result.metadata { acceptOnQueue(endpoint: result.endpoint, txtRecord: record.dictionary, generation: generation) } }
    }
    private func acceptOnQueue(endpoint: NWEndpoint, txtRecord: [String: String], generation: UInt64) {
        guard isCurrent(generation), case let .service(_, type, _, _) = endpoint, type == Self.serviceType, txtRecord["version"] == Self.protocolVersion, let hash = txtRecord["id"], let device = trust.device(matchingBonjourHash: hash) else { return }
        currentSightings[device] = endpoint
        scheduleDirectoryApply(device: device, endpoint: endpoint)
    }
    private func installRenewalTimer(generation: UInt64) {
        renewalTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + renewalInterval, repeating: renewalInterval)
        timer.setEventHandler { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            for (device, endpoint) in self.currentSightings { self.scheduleDirectoryApply(device: device, endpoint: endpoint) }
        }
        renewalTimer = timer; timer.resume()
    }
    private func scheduleDirectoryApply(device: DeviceID, endpoint: NWEndpoint) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let sessionTask = directorySessionTask else { return }
        let identifier = UUID()
        let task = Task { [weak self, directory] in
            guard let self else { return }
            defer { self.removeDirectoryTask(identifier) }
            guard let token = await sessionTask.value else { return }
            if let beforeDirectoryApply { await beforeDirectoryApply() }
            await directory.applyLAN(device, endpoint: endpoint, token: token)
        }
        directoryTasks[identifier] = task
    }
    private func removeDirectoryTask(_ identifier: UUID) {
        queue.async { [weak self] in self?.directoryTasks.removeValue(forKey: identifier) }
    }
    private func endDirectorySessionOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let sessionTask = directorySessionTask else { return }
        directorySessionTask = nil
        directorySessionEndTask?.cancel()
        directorySessionEndTask = Task { [directory] in
            guard let token = await sessionTask.value else { return }
            await directory.endLANDiscoverySession(token)
        }
    }
    private func cancelOwnedTasksOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
        trustObservationGeneration &+= 1
        trustUpdateTask?.cancel()
        trustUpdateTask = nil
        directoryTasks.values.forEach { $0.cancel() }
        directoryTasks.removeAll()
    }
    private func isCurrent(_ candidate: UInt64) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return candidate == generation && (lifecycleState == .starting || lifecycleState == .ready)
    }
}
