import CryptoKit
import Foundation
import Network

public enum MeshPeerDirectoryError: Error, Equatable, Sendable {
    case tooManyPeers
    case invalidProbeResponse
    case responseTooLarge
    case timedOut
    case unsupportedEndpoint
}

public struct MeshPeerCandidate: Sendable, Equatable {
    public let nodeID: String
    public let endpoint: NWEndpoint
    public let probeNonce: Data
    public let deviceIDHash: Data
    public let displayName: String

    public init(
        nodeID: String,
        endpoint: NWEndpoint,
        probeNonce: Data,
        deviceIDHash: Data,
        displayName: String
    ) {
        self.nodeID = nodeID
        self.endpoint = endpoint
        self.probeNonce = probeNonce
        self.deviceIDHash = deviceIDHash
        self.displayName = displayName
    }
}

public struct MeshPeerProbeRequest: Codable, Equatable, Sendable {
    public let version: Int
    public let nonce: Data

    public init(version: Int = 1, nonce: Data) {
        self.version = version
        self.nonce = nonce
    }
}

public struct MeshPeerProbeResponse: Codable, Equatable, Sendable {
    public let version: Int
    public let nonce: Data
    public let deviceIDHash: Data
    public let displayName: String

    public init(version: Int, nonce: Data, deviceIDHash: Data, displayName: String) {
        self.version = version
        self.nonce = nonce
        self.deviceIDHash = deviceIDHash
        self.displayName = displayName
    }
}

public enum MeshPeerProbeCodec {
    public static let maximumPayloadBytes = 8 * 1_024

    public static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= maximumPayloadBytes else { throw MeshPeerDirectoryError.responseTooLarge }
        return data
    }

    public static func decode(_ data: Data, expectedNonce: Data) throws -> MeshPeerProbeResponse {
        guard data.count <= maximumPayloadBytes else { throw MeshPeerDirectoryError.responseTooLarge }
        let response: MeshPeerProbeResponse
        do {
            response = try JSONDecoder().decode(MeshPeerProbeResponse.self, from: data)
        } catch {
            throw MeshPeerDirectoryError.invalidProbeResponse
        }
        try validate(response, expectedNonce: expectedNonce)
        return response
    }

    public static func validate(_ response: MeshPeerProbeResponse, expectedNonce: Data) throws {
        let nameBytes = response.displayName.data(using: .utf8)?.count ?? 0
        guard response.version == 1,
            expectedNonce.count == 32,
            response.nonce == expectedNonce,
            response.deviceIDHash.count == 32,
            nameBytes > 0,
            nameBytes <= 128,
            response.displayName.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            })
        else { throw MeshPeerDirectoryError.invalidProbeResponse }
    }
}

public protocol TailscaleStatusProviding: Sendable {
    func status() async throws -> TailscaleStatus
}

extension TailscaleCommandClient: TailscaleStatusProviding {}

public protocol MeshPeerProbing: Sendable {
    func probe(
        nodeID: String,
        endpoint: NWEndpoint,
        nonce: Data,
        timeout: Duration,
        maximumResponseBytes: Int
    ) async throws -> MeshPeerProbeResponse
}

public protocol MeshRefreshSleeping: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct ContinuousMeshRefreshSleeper: MeshRefreshSleeping {
    public init() {}
    public func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}

public actor MeshPeerDirectory {
    public static let refreshInterval: Duration = .seconds(15)
    public static let probeTimeout: Duration = .seconds(2)
    public static let maximumConcurrentProbes = 8
    public static let maximumPeers = 100
    public static let servicePort: UInt16 = 51_337

    private struct ProbeInput: Sendable {
        let nodeID: String
        let endpoint: NWEndpoint
        let nonce: Data
    }

    private let statusProvider: any TailscaleStatusProviding
    private let prober: any MeshPeerProbing
    private let sleeper: any MeshRefreshSleeping
    private let now: @Sendable () -> Date
    private var currentPeers: [MeshPeerCandidate] = []
    private var currentPeersExpireAt: Date?
    private var subscribers: [UUID: AsyncStream<[MeshPeerCandidate]>.Continuation] = [:]
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration: UInt64 = 0

    public init(
        status: any TailscaleStatusProviding,
        prober: any MeshPeerProbing = NWMeshPeerProber(),
        sleeper: any MeshRefreshSleeping = ContinuousMeshRefreshSleeper(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        statusProvider = status
        self.prober = prober
        self.sleeper = sleeper
        self.now = now
    }

    public func refresh() async throws -> [MeshPeerCandidate] {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let status = try await statusProvider.status()
        guard status.peers.count <= Self.maximumPeers else { throw MeshPeerDirectoryError.tooManyPeers }
        let inputs = status.peers.compactMap(Self.probeInput)
        let probed = await probe(inputs)
        guard generation == refreshGeneration else { return currentPeers }

        var hashCounts: [Data: Int] = [:]
        for candidate in probed { hashCounts[candidate.deviceIDHash, default: 0] += 1 }
        currentPeers =
            probed
            .filter { hashCounts[$0.deviceIDHash] == 1 }
            .sorted { $0.nodeID < $1.nodeID }
        currentPeersExpireAt = now().addingTimeInterval(15)
        for continuation in subscribers.values { continuation.yield(currentPeers) }
        return currentPeers
    }

    public func peers() -> AsyncStream<[MeshPeerCandidate]> {
        let identifier = UUID()
        let initial = currentPeers
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            subscribers[identifier] = continuation
            continuation.yield(initial)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(identifier) }
            }
        }
    }

    public func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                _ = try? await self.refresh()
                do {
                    try await self.sleeper.sleep(for: Self.refreshInterval)
                } catch {
                    return
                }
            }
        }
    }

    public func stop() async {
        let task = refreshTask
        refreshTask = nil
        task?.cancel()
        await task?.value
    }

    public func isRefreshingPeriodically() -> Bool { refreshTask != nil }

    public func candidate(for device: DeviceID) -> MeshPeerCandidate? {
        guard let expiry = currentPeersExpireAt, now() < expiry else { return nil }
        let expected = Self.deviceIDHash(for: device)
        let matches = currentPeers.filter { $0.deviceIDHash == expected }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    public static func deviceIDHash(for device: DeviceID) -> Data {
        Data(SHA256.hash(data: Data(device.rawValue.uuidString.lowercased().utf8)))
    }

    private func probe(_ inputs: [ProbeInput]) async -> [MeshPeerCandidate] {
        await withTaskGroup(of: MeshPeerCandidate?.self) { group in
            var iterator = inputs.makeIterator()
            for _ in 0..<min(inputs.count, Self.maximumConcurrentProbes) {
                if let input = iterator.next() { addProbe(input, to: &group) }
            }

            var results: [MeshPeerCandidate] = []
            while let candidate = await group.next() {
                if let candidate { results.append(candidate) }
                if let input = iterator.next() { addProbe(input, to: &group) }
            }
            return results
        }
    }

    private func addProbe(
        _ input: ProbeInput,
        to group: inout TaskGroup<MeshPeerCandidate?>
    ) {
        let prober = self.prober
        group.addTask {
            do {
                let response = try await prober.probe(
                    nodeID: input.nodeID,
                    endpoint: input.endpoint,
                    nonce: input.nonce,
                    timeout: Self.probeTimeout,
                    maximumResponseBytes: MeshPeerProbeCodec.maximumPayloadBytes
                )
                try MeshPeerProbeCodec.validate(response, expectedNonce: input.nonce)
                return MeshPeerCandidate(
                    nodeID: input.nodeID,
                    endpoint: input.endpoint,
                    probeNonce: input.nonce,
                    deviceIDHash: response.deviceIDHash,
                    displayName: response.displayName
                )
            } catch {
                return nil
            }
        }
    }

    private static func probeInput(_ peer: TailscalePeer) -> ProbeInput? {
        guard peer.online,
            let address = peer.addresses.first,
            let port = NWEndpoint.Port(rawValue: servicePort)
        else { return nil }
        return ProbeInput(
            nodeID: peer.nodeID,
            endpoint: .hostPort(host: NWEndpoint.Host(address), port: port),
            nonce: randomNonce()
        )
    }

    private static func randomNonce() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    private func removeSubscriber(_ identifier: UUID) {
        subscribers.removeValue(forKey: identifier)
    }
}

public struct NWMeshPeerProber: MeshPeerProbing {
    public init() {}

    public func probe(
        nodeID: String,
        endpoint: NWEndpoint,
        nonce: Data,
        timeout: Duration,
        maximumResponseBytes: Int
    ) async throws -> MeshPeerProbeResponse {
        guard nonce.count == 32,
            timeout > .zero,
            maximumResponseBytes > 0,
            maximumResponseBytes <= MeshPeerProbeCodec.maximumPayloadBytes
        else { throw MeshPeerDirectoryError.invalidProbeResponse }

        let rawConnection = NWConnection(to: endpoint, using: .tcp)
        let connection = NWMeshByteConnection(connection: rawConnection)
        return try await withThrowingTaskGroup(of: MeshPeerProbeResponse.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    let framed = MeshFramedConnection(transport: connection)
                    let request = try MeshPeerProbeCodec.encode(MeshPeerProbeRequest(nonce: nonce))
                    try await framed.send(
                        MeshWireFrame(purpose: .probe, payload: request),
                        limit: .preauthentication
                    )
                    let response = try await framed.receive(limit: .preauthentication)
                    guard response.purpose == .probe, response.payload.count <= maximumResponseBytes else {
                        throw MeshPeerDirectoryError.invalidProbeResponse
                    }
                    return try MeshPeerProbeCodec.decode(response.payload, expectedNonce: nonce)
                } onCancel: {
                    Task { await connection.close() }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw MeshPeerDirectoryError.timedOut
            }

            defer { group.cancelAll() }
            guard let response = try await group.next() else {
                throw MeshPeerDirectoryError.invalidProbeResponse
            }
            await connection.close()
            return response
        }
    }
}
