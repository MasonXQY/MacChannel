import Foundation

public enum MeshConnectionRegistryError: Error, Equatable, Sendable {
    case untrustedPeer
    case resourceExhausted
    case stopped
}

public enum MeshConnectionOwnership: Sendable {
    case probe
    case pairing
    case handshake
    case queuedTransfer
    case activeTransfer
}

public actor MeshConnectionRegistry {
    public struct Token: Hashable, Sendable {
        fileprivate let rawValue: UUID
    }

    private struct Entry: Sendable {
        let device: DeviceID
        let ownership: MeshConnectionOwnership
        let close: @Sendable () async -> Void
    }

    public static let maximumEntries = 128
    public static let maximumConcurrentCloses = 4

    private let trustRepository: TrustRepository
    private var entries: [Token: Entry] = [:]
    private var observationTask: Task<Void, Never>?
    private var stopped = false

    public init(trustRepository: TrustRepository) {
        self.trustRepository = trustRepository
    }

    deinit { observationTask?.cancel() }

    public func claim(
        device: DeviceID,
        ownership: MeshConnectionOwnership,
        close: @escaping @Sendable () async -> Void
    ) async throws -> Token {
        guard !stopped else { throw MeshConnectionRegistryError.stopped }
        await startObservationIfNeeded()
        guard await trustRepository.isTrusted(device) else {
            throw MeshConnectionRegistryError.untrustedPeer
        }
        guard entries.count < Self.maximumEntries else {
            throw MeshConnectionRegistryError.resourceExhausted
        }
        let token = Token(rawValue: UUID())
        entries[token] = Entry(device: device, ownership: ownership, close: close)
        return token
    }

    public func release(_ token: Token) {
        entries.removeValue(forKey: token)
    }

    public func stop() async {
        guard !stopped else { return }
        stopped = true
        let observation = observationTask
        observationTask = nil
        observation?.cancel()
        let closures = entries.values.map(\.close)
        entries.removeAll()
        await closeBounded(closures)
        await observation?.value
    }

    func entryCount(for device: DeviceID? = nil) -> Int {
        guard let device else { return entries.count }
        return entries.values.filter { $0.device == device }.count
    }

    private func startObservationIfNeeded() async {
        guard observationTask == nil else { return }
        let stream = await trustRepository.updates()
        observationTask = Task { [weak self] in
            for await store in stream {
                guard !Task.isCancelled else { return }
                await self?.applyTrust(store)
            }
        }
    }

    private func applyTrust(_ store: TrustStore) async {
        let revoked = entries.filter { !store.isTrusted($0.value.device) }
        for token in revoked.keys { entries.removeValue(forKey: token) }
        await closeBounded(revoked.values.map(\.close))
    }

    private func closeBounded(_ closures: [@Sendable () async -> Void]) async {
        await withTaskGroup(of: Void.self) { group in
            var iterator = closures.makeIterator()
            for _ in 0..<min(Self.maximumConcurrentCloses, closures.count) {
                if let close = iterator.next() { group.addTask { await close() } }
            }
            while await group.next() != nil {
                if let close = iterator.next() { group.addTask { await close() } }
            }
        }
    }
}

public actor RegisteredMeshSecureChannel: SecureChannel {
    public nonisolated let route: ConnectionRoute

    private let channel: MeshSecureChannel
    private let registry: MeshConnectionRegistry
    private let token: MeshConnectionRegistry.Token
    private var closed = false

    init(
        channel: MeshSecureChannel,
        registry: MeshConnectionRegistry,
        token: MeshConnectionRegistry.Token
    ) {
        self.channel = channel
        self.registry = registry
        self.token = token
        route = channel.route
    }

    public func send(_ frame: Data) async throws { try await channel.send(frame) }
    public nonisolated func frames() -> AsyncThrowingStream<Data, Error> { channel.frames() }
    public func exportKey(label: String, context: Data, length: Int) async throws -> Data {
        try await channel.exportKey(label: label, context: context, length: length)
    }
    public func close() async {
        guard !closed else { return }
        closed = true
        await registry.release(token)
        await channel.close()
    }
}
