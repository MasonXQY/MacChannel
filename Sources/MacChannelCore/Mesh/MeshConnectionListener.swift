import CryptoKit
import Foundation
import Network

public struct MeshListenerBinding: Equatable, Sendable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

public protocol MeshListenerTransport: Sendable {
    func start(
        binding: MeshListenerBinding,
        onConnection: @escaping @Sendable (any MeshByteConnection) -> Void
    ) async throws
    func stop() async
}

public actor MeshConnectionListener {
    public static let binding = MeshListenerBinding(host: "127.0.0.1", port: 51_338)
    public static let maximumConcurrentHandshakes = 4

    private struct Handshake {
        let ordinal: UInt64
        let connection: any MeshByteConnection
        let task: Task<Void, Never>
    }

    private struct CompletedHandshake {
        let purpose: MeshConnectionPurpose?
        let connection: any MeshByteConnection
    }

    private struct ConnectionWaiter {
        let identifier: UUID
        let continuation: CheckedContinuation<(any MeshByteConnection)?, Error>
    }

    private let transport: any MeshListenerTransport
    private var started = false
    private var stopped = false
    private var handshakes: [UUID: Handshake] = [:]
    private var completedHandshakes: [UInt64: CompletedHandshake] = [:]
    private var nextAcceptanceOrdinal: UInt64 = 0
    private var nextDeliveryOrdinal: UInt64 = 0
    private var queues: [MeshConnectionPurpose: [any MeshByteConnection]] = [:]
    private var waiters: [MeshConnectionPurpose: [ConnectionWaiter]] = [:]

    public init(transport: any MeshListenerTransport = NWMeshListenerTransport()) {
        self.transport = transport
    }

    public func start() async throws {
        guard !started else { return }
        guard !stopped else { throw MeshWireError.connectionClosed }
        try await transport.start(binding: Self.binding) { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        started = true
    }

    public func stop() async {
        guard !stopped else { return }
        stopped = true
        started = false
        await transport.stop()

        let active = handshakes.values.map(\.connection)
        let tasks = handshakes.values.map(\.task)
        handshakes.removeAll()
        let retained = queues.values.flatMap { $0 }
        queues.removeAll()
        let completed = completedHandshakes.values.map(\.connection)
        completedHandshakes.removeAll()
        let pendingWaiters = waiters.values.flatMap { $0 }
        waiters.removeAll()

        for waiter in pendingWaiters { waiter.continuation.resume(returning: nil) }
        for connection in active + retained + completed { await connection.close() }
        for task in tasks {
            task.cancel()
            await task.value
        }
    }

    public func connections(
        for purpose: MeshConnectionPurpose
    ) -> AsyncThrowingStream<any MeshByteConnection, Error> {
        AsyncThrowingStream(unfolding: { [weak self] in
            guard let self else { return nil }
            return try await self.nextConnection(for: purpose)
        })
    }

    public func retainedConnectionCount() -> Int {
        queues.values.reduce(handshakes.count + completedHandshakes.count) { $0 + $1.count }
    }

    public func activeHandshakeCount() -> Int { handshakes.count }
    public func waitingConsumerCount() -> Int { waiters.values.reduce(0) { $0 + $1.count } }

    private func accept(_ connection: any MeshByteConnection) async {
        guard !stopped, handshakes.count < Self.maximumConcurrentHandshakes else {
            await connection.close()
            return
        }
        let identifier = UUID()
        let ordinal = nextAcceptanceOrdinal
        nextAcceptanceOrdinal &+= 1
        let task = Task { [weak self] in
            do {
                let framed = MeshFramedConnection(transport: connection)
                let frame = try await framed.receive(limit: .preauthentication)
                let replay = PrefixedMeshByteConnection(
                    prefix: try MeshWireProtocol.encode(
                        purpose: frame.purpose,
                        payload: frame.payload,
                        limit: .preauthentication
                    ),
                    base: connection
                )
                await self?.finishHandshake(identifier, purpose: frame.purpose, connection: replay)
            } catch {
                await self?.finishHandshake(identifier, purpose: nil, connection: connection)
            }
        }
        handshakes[identifier] = Handshake(
            ordinal: ordinal,
            connection: connection,
            task: task
        )
    }

    private func finishHandshake(
        _ identifier: UUID,
        purpose: MeshConnectionPurpose?,
        connection: (any MeshByteConnection)?
    ) async {
        guard let handshake = handshakes.removeValue(forKey: identifier) else { return }
        guard let connection else { return }
        completedHandshakes[handshake.ordinal] = CompletedHandshake(
            purpose: purpose,
            connection: connection
        )
        await drainCompletedHandshakes()
    }

    private func drainCompletedHandshakes() async {
        while let completed = completedHandshakes.removeValue(forKey: nextDeliveryOrdinal) {
            nextDeliveryOrdinal &+= 1
            await deliverCompletedHandshake(completed)
        }
    }

    private func deliverCompletedHandshake(_ completed: CompletedHandshake) async {
        guard !stopped, let purpose = completed.purpose else {
            await completed.connection.close()
            return
        }

        if var purposeWaiters = waiters[purpose], !purposeWaiters.isEmpty {
            let waiter = purposeWaiters.removeFirst()
            waiters[purpose] = purposeWaiters
            waiter.continuation.resume(returning: completed.connection)
            return
        }

        var queue = queues[purpose, default: []]
        guard queue.count < maximumRetainedConnections(for: purpose) else {
            await completed.connection.close()
            return
        }
        queue.append(completed.connection)
        queues[purpose] = queue
    }

    private func nextConnection(
        for purpose: MeshConnectionPurpose
    ) async throws -> (any MeshByteConnection)? {
        if var queue = queues[purpose], !queue.isEmpty {
            let connection = queue.removeFirst()
            queues[purpose] = queue
            return connection
        }
        guard !stopped else { return nil }
        let identifier = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[purpose, default: []].append(
                    ConnectionWaiter(identifier: identifier, continuation: continuation)
                )
            }
        } onCancel: {
            Task { await self.cancelWaiter(identifier, purpose: purpose) }
        }
    }

    private func cancelWaiter(_ identifier: UUID, purpose: MeshConnectionPurpose) {
        guard var purposeWaiters = waiters[purpose],
            let index = purposeWaiters.firstIndex(where: { $0.identifier == identifier })
        else { return }
        let waiter = purposeWaiters.remove(at: index)
        waiters[purpose] = purposeWaiters
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func maximumRetainedConnections(for purpose: MeshConnectionPurpose) -> Int {
        switch purpose {
        case .transfer:
            IncomingTransferCapacity.maximumEstablishedConnections
        case .probe, .pairing:
            Self.maximumConcurrentHandshakes
        }
    }
}

private actor PrefixedMeshByteConnection: MeshByteConnection {
    private var prefix: Data
    private let base: any MeshByteConnection
    private var isClosed = false

    init(prefix: Data, base: any MeshByteConnection) {
        self.prefix = prefix
        self.base = base
    }

    func send(_ bytes: Data) async throws {
        guard !isClosed else { throw MeshWireError.connectionClosed }
        try await base.send(bytes)
    }

    func receive(minimum: Int, maximum: Int) async throws -> Data {
        guard !isClosed else { throw MeshWireError.connectionClosed }
        guard prefix.isEmpty else {
            let bytes = Data(prefix.prefix(maximum))
            prefix.removeFirst(bytes.count)
            return bytes
        }
        return try await base.receive(minimum: minimum, maximum: maximum)
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        await base.close()
    }
}

public final class NWMeshListenerTransport: MeshListenerTransport, @unchecked Sendable {
    private struct ActiveListener {
        let listener: NWListener
        let lifecycle: NWListenerLifecycle
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.mason.macchannel.mesh-listener")
    private var activeListener: ActiveListener?

    public init() {}

    public func start(
        binding: MeshListenerBinding,
        onConnection: @escaping @Sendable (any MeshByteConnection) -> Void
    ) async throws {
        guard binding == MeshConnectionListener.binding,
            let port = NWEndpoint.Port(rawValue: binding.port),
            let loopback = IPv4Address(binding.host)
        else { throw MeshWireError.transportViolation }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(loopback), port: port)
        let listener = try NWListener(using: parameters)
        let lifecycle = NWListenerLifecycle()
        listener.stateUpdateHandler = { lifecycle.record($0) }
        listener.newConnectionHandler = { connection in
            onConnection(NWMeshByteConnection(connection: connection))
        }
        lock.withLock { activeListener = ActiveListener(listener: listener, lifecycle: lifecycle) }
        listener.start(queue: queue)
        try await lifecycle.waitUntilReady()
    }

    public func stop() async {
        let active = lock.withLock { () -> ActiveListener? in
            defer { activeListener = nil }
            return activeListener
        }
        guard let active else { return }
        active.listener.cancel()
        await active.lifecycle.waitUntilStopped()
    }
}

private final class NWListenerLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var state: NWListener.State = .setup
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let immediate: Result<Void, Error>? = lock.withLock {
                switch state {
                case .ready:
                    return .success(())
                case .failed(let error):
                    return .failure(error)
                case .cancelled:
                    return .failure(MeshWireError.connectionClosed)
                default:
                    readyWaiters.append(continuation)
                    return nil
                }
            }
            if let immediate { continuation.resume(with: immediate) }
        }
    }

    func waitUntilStopped() async {
        await withCheckedContinuation { continuation in
            let alreadyStopped = lock.withLock {
                switch state {
                case .failed, .cancelled:
                    return true
                default:
                    stopWaiters.append(continuation)
                    return false
                }
            }
            if alreadyStopped { continuation.resume() }
        }
    }

    func record(_ newState: NWListener.State) {
        let completions = lock.withLock {
            () -> (
                [CheckedContinuation<Void, Error>],
                Result<Void, Error>?,
                [CheckedContinuation<Void, Never>]
            ) in
            state = newState
            switch newState {
            case .ready:
                let ready = readyWaiters
                readyWaiters.removeAll()
                return (ready, .success(()), [])
            case .failed(let error):
                let ready = readyWaiters
                let stopped = stopWaiters
                readyWaiters.removeAll()
                stopWaiters.removeAll()
                return (ready, .failure(error), stopped)
            case .cancelled:
                let ready = readyWaiters
                let stopped = stopWaiters
                readyWaiters.removeAll()
                stopWaiters.removeAll()
                return (ready, .failure(MeshWireError.connectionClosed), stopped)
            default:
                return ([], nil, [])
            }
        }
        if let result = completions.1 {
            for continuation in completions.0 { continuation.resume(with: result) }
        }
        for continuation in completions.2 { continuation.resume() }
    }
}

public protocol MeshPairingSourceIdentifying: Sendable {
    var meshPairingSourceKey: Data { get }
}

public final class NWMeshByteConnection: MeshByteConnection, MeshPairingSourceIdentifying,
    @unchecked Sendable
{
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.mason.macchannel.mesh-connection")
    private let state = NWMeshConnectionState()
    public let meshPairingSourceKey: Data

    public init(connection: NWConnection) {
        self.connection = connection
        let source: String
        switch connection.endpoint {
        case .hostPort(let host, _):
            source = String(describing: host)
        default:
            source = String(describing: connection.endpoint)
        }
        meshPairingSourceKey = Data(SHA256.hash(data: Data(source.utf8)))
        connection.stateUpdateHandler = { [state] newState in state.record(newState) }
        connection.start(queue: queue)
    }

    public func send(_ bytes: Data) async throws {
        guard state.isUsable() else { throw MeshWireError.connectionClosed }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: bytes,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
        }
    }

    public func receive(minimum: Int, maximum: Int) async throws -> Data {
        guard state.isUsable() else { throw MeshWireError.connectionClosed }
        guard minimum >= 0, maximum >= minimum else { throw MeshWireError.transportViolation }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: minimum, maximumLength: maximum) {
                content, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let content, !content.isEmpty {
                    continuation.resume(returning: content)
                } else if isComplete {
                    continuation.resume(throwing: MeshWireError.connectionClosed)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    public func close() async {
        if state.claimClose() { connection.cancel() }
        await state.waitUntilStopped()
    }
}

private final class NWMeshConnectionState: @unchecked Sendable {
    private let lock = NSLock()
    private var closing = false
    private var stopped = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    func claimClose() -> Bool {
        lock.withLock {
            guard !closing, !stopped else { return false }
            closing = true
            return true
        }
    }

    func isUsable() -> Bool { lock.withLock { !closing && !stopped } }

    func waitUntilStopped() async {
        await withCheckedContinuation { continuation in
            let alreadyStopped = lock.withLock {
                if stopped { return true }
                stopWaiters.append(continuation)
                return false
            }
            if alreadyStopped { continuation.resume() }
        }
    }

    func record(_ state: NWConnection.State) {
        switch state {
        case .failed, .cancelled:
            let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                stopped = true
                let current = stopWaiters
                stopWaiters.removeAll()
                return current
            }
            for waiter in waiters { waiter.resume() }
        default:
            break
        }
    }
}
