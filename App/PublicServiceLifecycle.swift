import Foundation
import MacChannelCore

enum PublicServiceState: Equatable, Sendable {
    case connecting
    case online
    case degraded
    case offline
}

struct PublicServiceConnection: Sendable {
    let connect: @Sendable () async throws -> Void
    let run: @Sendable () async throws -> Void
    let stop: @Sendable () async -> Void

    init(
        connect: @escaping @Sendable () async throws -> Void,
        run: @escaping @Sendable () async throws -> Void,
        stop: @escaping @Sendable () async -> Void
    ) {
        self.connect = connect
        self.run = run
        self.stop = stop
    }
}

struct PublicServiceBackoff: Sendable {
    let wait: @Sendable (_ failureCount: Int) async throws -> Void

    static let immediateForTests = PublicServiceBackoff { _ in await Task.yield() }

    static let production = PublicServiceBackoff { failureCount in
        let exponent = min(max(failureCount - 1, 0), 5)
        let base = min(pow(2.0, Double(exponent)), 30)
        let jitter = Double.random(in: 0.8...1.2)
        try await Task.sleep(for: .seconds(base * jitter))
    }
}

private actor PublicServiceRetrySignal {
    private var generation = 0
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func snapshot() -> Int { generation }

    func signal() {
        generation &+= 1
        let continuations = waiters.values
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }

    func wait(after observedGeneration: Int) async {
        if generation != observedGeneration || Task.isCancelled { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if generation != observedGeneration || Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }
}

private actor PublicServiceShutdownGate {
    private var finished = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        if finished { return }
        await withCheckedContinuation { continuation in
            if finished { continuation.resume() } else { waiter = continuation }
        }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        waiter?.resume()
        waiter = nil
    }
}

actor PublicServiceLifecycle {
    typealias ConnectionFactory = @Sendable () async throws -> PublicServiceConnection

    private let connectionFactory: ConnectionFactory
    private let backoff: PublicServiceBackoff
    private let retrySignal = PublicServiceRetrySignal()
    private var runTask: Task<Void, Never>?
    private var connection: PublicServiceConnection?
    private var state: PublicServiceState = .offline
    private let stateContinuation: AsyncStream<PublicServiceState>.Continuation

    nonisolated let states: AsyncStream<PublicServiceState>

    init(
        connectionFactory: @escaping ConnectionFactory,
        backoff: PublicServiceBackoff = .production
    ) {
        self.connectionFactory = connectionFactory
        self.backoff = backoff
        let stream = AsyncStream<PublicServiceState>.makeStream(bufferingPolicy: .bufferingNewest(8))
        states = stream.stream
        stateContinuation = stream.continuation
        stateContinuation.yield(.offline)
    }

    deinit {
        runTask?.cancel()
        stateContinuation.finish()
    }

    func start() {
        guard runTask == nil else { return }
        runTask = Task { await runLoop() }
    }

    func reconnectNow() async {
        await retrySignal.signal()
        if let connection { await connection.stop() }
    }

    func stop() async {
        guard let task = runTask else {
            transition(to: .offline)
            return
        }
        task.cancel()
        await retrySignal.signal()
        if let connection { await connection.stop() }
        let gate = PublicServiceShutdownGate()
        let completion = Task {
            await task.value
            await gate.finish()
        }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(2))
            await gate.finish()
        }
        await gate.wait()
        completion.cancel()
        deadline.cancel()
        runTask = nil
        connection = nil
        transition(to: .offline)
    }

    func currentState() -> PublicServiceState { state }

    private func runLoop() async {
        var failureCount = 0
        while !Task.isCancelled {
            transition(to: .connecting)
            var candidate: PublicServiceConnection?
            do {
                let created = try await connectionFactory()
                candidate = created
                connection = created
                try await created.connect()
                guard !Task.isCancelled else { throw CancellationError() }
                failureCount = 0
                transition(to: .online)
                try await created.run()
                guard !Task.isCancelled else { throw CancellationError() }
                throw PublicServiceLifecycleError.sessionEnded
            } catch {
                if let candidate { await candidate.stop() }
                connection = nil
                if Task.isCancelled { break }
                failureCount += 1
                transition(to: .degraded)
                await waitForRetry(failureCount: failureCount)
            }
        }
    }

    private func waitForRetry(failureCount: Int) async {
        let generation = await retrySignal.snapshot()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                try? await self.backoff.wait(failureCount)
            }
            group.addTask {
                await self.retrySignal.wait(after: generation)
            }
            _ = await group.next()
            group.cancelAll()
        }
    }

    private func transition(to newState: PublicServiceState) {
        guard state != newState else { return }
        state = newState
        stateContinuation.yield(newState)
    }
}

private enum PublicServiceLifecycleError: Error { case sessionEnded }

actor ReconnectableRendezvousSignalSession: RendezvousSignalSession {
    private let frameContinuation: AsyncStream<RendezvousSignalFrame>.Continuation
    private let frames: AsyncStream<RendezvousSignalFrame>
    private let errorContinuation: AsyncStream<RendezvousProtocolError>.Continuation
    private let errors: AsyncStream<RendezvousProtocolError>
    private var activeToken: UUID?
    private var activeSession: AuthenticatedPresenceSession?
    private var forwardingTask: Task<Void, Never>?
    private var errorForwardingTask: Task<Void, Never>?

    init() {
        let stream = AsyncStream<RendezvousSignalFrame>.makeStream(
            bufferingPolicy: .bufferingOldest(256)
        )
        frames = stream.stream
        frameContinuation = stream.continuation
        let errorStream = AsyncStream<RendezvousProtocolError>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        errors = errorStream.stream
        errorContinuation = errorStream.continuation
    }

    deinit {
        forwardingTask?.cancel()
        errorForwardingTask?.cancel()
        frameContinuation.finish()
        errorContinuation.finish()
    }

    func install(_ session: AuthenticatedPresenceSession, token: UUID) async {
        forwardingTask?.cancel()
        errorForwardingTask?.cancel()
        activeToken = token
        activeSession = session
        let source = await session.signalFrames()
        forwardingTask = Task { [weak self] in
            for await frame in source {
                guard !Task.isCancelled else { return }
                self?.frameContinuation.yield(frame)
            }
        }
        let errorSource = await session.protocolErrors()
        errorForwardingTask = Task { [weak self] in
            for await error in errorSource {
                guard !Task.isCancelled else { return }
                self?.errorContinuation.yield(error)
            }
        }
    }

    func remove(token: UUID) {
        guard activeToken == token else { return }
        forwardingTask?.cancel()
        forwardingTask = nil
        errorForwardingTask?.cancel()
        errorForwardingTask = nil
        activeToken = nil
        activeSession = nil
    }

    func signalFrames() -> AsyncStream<RendezvousSignalFrame> { frames }
    func protocolErrors() -> AsyncStream<RendezvousProtocolError> { errors }

    func sendSignal(_ payload: Data, to device: DeviceID) async throws {
        guard let activeSession else {
            throw AuthenticatedPresenceError.transport("public_service_offline")
        }
        try await activeSession.sendSignal(payload, to: device)
    }

    func sendTrustUpdate(_ records: [SignedTrustRecord]) async throws {
        guard let activeSession else {
            throw AuthenticatedPresenceError.transport("public_service_offline")
        }
        try await activeSession.sendTrustUpdate(records)
    }

    func finish() {
        forwardingTask?.cancel()
        forwardingTask = nil
        errorForwardingTask?.cancel()
        errorForwardingTask = nil
        activeToken = nil
        activeSession = nil
        frameContinuation.finish()
        errorContinuation.finish()
    }
}
