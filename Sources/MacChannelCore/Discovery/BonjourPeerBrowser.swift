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

    public init(directory: DeviceDirectory, trust: DeviceTrust, renewalInterval: TimeInterval = 5) {
        self.directory = directory; self.trust = trust; self.renewalInterval = max(0.1, renewalInterval)
    }
    public static func txtRecord(for device: DeviceID) -> [String: String] { ["id": deviceIDHash(for: device), "version": protocolVersion] }
    public static func service(for device: DeviceID) -> NWListener.Service { NWListener.Service(name: deviceIDHash(for: device), type: serviceType, txtRecord: NWTXTRecord(txtRecord(for: device))) }
    public static func deviceIDHash(for device: DeviceID) -> String { SHA256.hash(data: Data(device.rawValue.uuidString.lowercased().utf8)).map { String(format: "%02x", $0) }.joined() }
    public func state() -> BonjourLifecycleState { queue.sync { lifecycleState } }
    public func observeTrust(_ repository: TrustRepository) {
        trustUpdateTask?.cancel()
        trustUpdateTask = Task { [weak self] in
            let updates = await repository.updates()
            for await store in updates {
                guard !Task.isCancelled else { return }
                self?.queue.async { [weak self] in self?.trust = DeviceTrust(trustedIDs: store.trustedDeviceIDs) }
            }
        }
    }
    public func start() { queue.async { [weak self] in self?.startOnQueue() } }
    public func stop() { queue.async { [weak self] in
        guard let self else { return }
        self.generation &+= 1; self.browser?.cancel(); self.browser = nil; self.renewalTimer?.cancel(); self.renewalTimer = nil; self.currentSightings = [:]; self.lifecycleState = .stopped
    } }

    /// Internal test hook; production calls this only from the NWBrowser handler.
    func accept(endpoint: NWEndpoint, txtRecord: [String: String], generation: UInt64? = nil) {
        queue.async { [weak self] in guard let self else { return }; self.acceptOnQueue(endpoint: endpoint, txtRecord: txtRecord, generation: generation ?? self.generation) }
    }

    private func startOnQueue() {
        guard browser == nil else { return }
        generation &+= 1; let activeGeneration = generation; lifecycleState = .starting
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
        case .cancelled: lifecycleState = .stopped; browser = nil
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
        Task { [directory] in await directory.apply(.bonjour(device, endpoint: endpoint)) }
    }
    private func installRenewalTimer(generation: UInt64) {
        renewalTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + renewalInterval, repeating: renewalInterval)
        timer.setEventHandler { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            for (device, endpoint) in self.currentSightings { Task { [directory = self.directory] in await directory.apply(.bonjour(device, endpoint: endpoint)) } }
        }
        renewalTimer = timer; timer.resume()
    }
    private func isCurrent(_ candidate: UInt64) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return candidate == generation && (lifecycleState == .starting || lifecycleState == .ready)
    }
}
