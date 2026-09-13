import Foundation

public enum PresenceSessionState: Equatable, Sendable {
    case inactive, connecting, online, reconnecting, stopping, stopped
}

/// Owns all authenticated socket attempts for ONE runtime generation. Call
/// stop and await its drain before replacing this owner or its DeviceDirectory.
/// Reconnect never replaces the stable bridge, router, or transfer coordinator.
public actor AuthenticatedPresenceSupervisor {
    // Closed vocabulary only: never interpolate raw errors or associated payloads.
    public nonisolated static func diagnosticCategory(_ error: any Error) -> String {
        guard let error = error as? AuthenticatedPresenceError else { return "other" }
        switch error {
        case .authenticationRejected: return "authentication_rejected"
        case .invalidChallenge: return "invalid_challenge"
        case .invalidFrame: return "invalid_frame"
        case .frameTooLarge: return "frame_too_large"
        case .insecureOrigin: return "insecure_origin"
        case .transport: return "transport"
        }
    }
    private enum AttemptInterrupted: Error { case retry }
    public nonisolated let bridge = PresenceSignalBridge()
    public private(set) var state: PresenceSessionState = .inactive
    private let origin: URL
    private let identity: DeviceIdentity
    private let repository: TrustRepository
    private let directory: DeviceDirectory
    private let makeSocket: @Sendable () async throws -> any PresenceWebSocket
    private let sleep: @Sendable (Duration) async throws -> Void
    private let onState: @Sendable (PresenceSessionState) async -> Void
    private var loop: Task<Void, Never>?
    private var backoff: Task<Void, Error>?
    private var retryRequested = false
    private var stopped = false
    private var identityOnlyRecovery = false
    private var recoveryAvailable = true
    private var current: (token: PresenceSignalBridge.SocketToken, session: AuthenticatedPresenceSession)?
    private var retiredToken: PresenceSignalBridge.SocketToken?
    private var initialStop: Task<Void, Never>?
    private var finalDrain: Task<Void, Never>?

    /// Transport and clock seam; tests still execute AuthenticatedPresenceSession.
    public init(
        identity: DeviceIdentity, repository: TrustRepository, directory: DeviceDirectory, origin: URL,
        makeSocket: @escaping @Sendable () async throws -> any PresenceWebSocket,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        onState: @escaping @Sendable (PresenceSessionState) async -> Void = { _ in }
    ) {
        self.origin = origin
        self.identity = identity
        self.repository = repository
        self.directory = directory
        self.makeSocket = makeSocket
        self.sleep = sleep
        self.onState = onState
    }

    public func start() {
        guard !stopped, loop == nil else { return }
        loop = Task { await runLoop() }
    }

    /// Idempotent and deliberately unbounded: a cancellation-insensitive socket
    /// keeps the owner stopping. A timeout must never license a second owner.
    public func stop() async {
        if state == .stopped { await loop?.value; return }
        stopped = true
        state = .stopping
        loop?.cancel()
        backoff?.cancel()
        await bridge.finish()
        if let current { await stopCurrentSocket(current.token) }
        if let loop { await loop.value }
        state = .stopped
    }

    public func retryConnection() async {
        guard !stopped else { return }
        retryRequested = true
        if let backoff { backoff.cancel() }
        else if let current {
            await beginDraining(current.token)
            await stopCurrentSocket(current.token)
        }
    }

    /// The platform runtime persists trust and refreshes incoming policy first.
    /// A failed update closes this attempt; the loop then reauthenticates using
    /// current repository records. Initial connect requires no redundant update.
    public func refreshTrust() async {
        guard !stopped, state == .online, let current else { return }
        let records = await repository.authenticationRecords()
        guard isActive(current.token), !records.isEmpty else { return }
        do {
            if identityOnlyRecovery {
                try await publishRecoveryRecords(records, through: current.session)
            } else {
                try await current.session.sendTrustUpdate(records)
            }
        }
        catch { await interrupt(current.token) }
    }

    private func publishRecoveryRecords(
        _ records: [SignedTrustRecord], through session: AuthenticatedPresenceSession
    ) async throws {
        // Isolate stale proofs from valid revocations and newly approved
        // pairings. Each record still receives the existing server validation;
        // transport send is not confirmation and local durable state is intact.
        for record in records {
            try Task.checkCancellation()
            try await session.sendTrustUpdate([record])
        }
    }

    public static func reconnectDelay(_ failures: Int) -> Duration {
        [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15)][min(max(failures, 0), 4)]
    }

    private func runLoop() async {
        var failures = 0
        while !stopped, !Task.isCancelled {
            guard let token = await bridge.beginSocket() else { break }
            var session: AuthenticatedPresenceSession?
            var forwarders: [Task<Void, Never>] = []
            var cancelled = false
            var authenticated = false
            let identityOnlyAttempt = identityOnlyRecovery
            do {
                let socket = try await makeSocket()
                guard !stopped, !Task.isCancelled else { await socket.close(); break }
                let attempt = try AuthenticatedPresenceSession(
                    identity: identity, origin: origin,
                    socket: socket, client: PresenceClient(directory: directory), trustRepository: repository
                )
                session = attempt
                current = (token, attempt)
                retiredToken = nil
                await publish(failures == 0 ? .connecting : .reconnecting)
                try Task.checkCancellation()
                guard isActive(token) else { throw AttemptInterrupted.retry }
                try await attempt.connect(includeTrustRecords: !identityOnlyAttempt)
                authenticated = true
                failures = 0
                guard !stopped, !Task.isCancelled else { throw CancellationError() }
                guard isActive(token) else { throw AttemptInterrupted.retry }
                if identityOnlyAttempt {
                    try await publishRecoveryRecords(
                        repository.authenticationRecords(), through: attempt)
                    guard isActive(token) else { throw AttemptInterrupted.retry }
                }
                await bridge.activate(token) { payload, peer in try await attempt.sendSignal(payload, to: peer) }
                guard !stopped, !Task.isCancelled else { throw CancellationError() }
                guard isActive(token) else { throw AttemptInterrupted.retry }
                forwarders = [
                    Task { [weak self] in
                        for await frame in await attempt.signalFrames() {
                            guard !Task.isCancelled else { return }
                            await self?.forward(frame, token: token)
                        }
                    },
                    Task { [weak self] in
                        for await error in await attempt.protocolErrors() {
                            guard !Task.isCancelled else { return }
                            await self?.forward(error, token: token)
                        }
                    }
                ]
                if isActive(token) { await publish(.online) }
                try Task.checkCancellation()
                guard isActive(token) else { throw AttemptInterrupted.retry }
                try await attempt.run()
            } catch is CancellationError {
                cancelled = true
            } catch {
                if !authenticated, !stopped, !Task.isCancelled, isActive(token) {
                    if identityOnlyAttempt {
                        // Capacity and transport failure do not reject identity.
                        // Keep this mode through normal backoff, without granting
                        // another proof-to-identity recovery budget.
                        let capacity = await session?.authenticationCapacityRejected ?? false
                        let transport: Bool
                        if case .transport = error as? AuthenticatedPresenceError {
                            transport = true
                        } else {
                            transport = error is URLError
                        }
                        if isActive(token), !Task.isCancelled {
                            identityOnlyRecovery = capacity || transport
                        }
                    } else if recoveryAvailable,
                        error as? AuthenticatedPresenceError == .authenticationRejected,
                        let session, await session.trustAuthenticationRejected,
                        isActive(token), !Task.isCancelled
                    {
                        recoveryAvailable = false
                        identityOnlyRecovery = true
                    }
                }
                // No peer IDs, URLs, payloads, credentials or raw transport errors
                // enter diagnostics. The owner exposes a coarse reconnect state.
                #if DEBUG
                print("DropMeshPresence stage=\(authenticated ? "connected" : "authentication") category=\(Self.diagnosticCategory(error))")
                #endif
            }
            // AuthenticatedPresenceSession directly mutates the directory. Join
            // connect/run above, then stop and join every forwarder before next
            // makeSocket. Signal token checks alone cannot protect presence.
            await beginDraining(token)
            for task in forwarders { task.cancel() }
            let initialStop = initialStop
            let drain = Task {
                await initialStop?.value
                // connect() may return after an earlier stop() and set running
                // again. Stop once more after connect/run has actually returned.
                await session?.stop()
                for task in forwarders { await task.value }
            }
            finalDrain = drain
            await drain.value
            current = nil
            self.initialStop = nil
            finalDrain = nil
            guard !stopped, !Task.isCancelled, !cancelled else { break }
            if retryRequested {
                retryRequested = false
                continue
            }
            let delay = Self.reconnectDelay(failures)
            failures = min(failures + 1, 4)
            let wait = Task { try await sleep(delay) }
            backoff = wait
            await publish(.reconnecting)
            _ = await wait.result
            backoff = nil
            retryRequested = false
        }
        await bridge.finish()
        state = .stopped
        await onState(.stopped)
    }

    private func publish(_ value: PresenceSessionState) async {
        guard !stopped else { return }
        state = value
        // Caller must also check its runtime generation inside its own actor.
        await onState(value)
    }

    private func forward(_ frame: RendezvousSignalFrame, token: PresenceSignalBridge.SocketToken) async {
        guard isActive(token) else { return }
        if !(await bridge.receive(frame, socket: token)) { await interrupt(token) }
    }

    private func forward(_ error: RendezvousProtocolError, token: PresenceSignalBridge.SocketToken) async {
        guard isActive(token) else { return }
        if !(await bridge.receive(error, socket: token)) { await interrupt(token) }
    }

    private func interrupt(_ token: PresenceSignalBridge.SocketToken) async {
        guard !stopped, let current, current.token == token else { return }
        await beginDraining(token)
        guard !stopped, self.current?.token == token, finalDrain == nil else { return }
        // A forwarder cannot join finalDrain: that drain joins the forwarder.
        // Initiate close here and leave the join to the sole loop owner.
        if initialStop == nil { initialStop = Task { await current.session.stop() } }
    }

    /// Invalidates the socket route and publishes a truthful non-online state
    /// before any cancellation-insensitive close work is awaited.
    private func beginDraining(_ token: PresenceSignalBridge.SocketToken) async {
        guard isActive(token) else { return }
        // Retirement must be visible before bridge/callback actor hops. The
        // loop may finish this attempt while the callback is still suspended.
        retiredToken = token
        await bridge.disconnect(token)
        guard !stopped, current?.token == token else { return }
        await publish(.reconnecting)
    }

    private func isActive(_ token: PresenceSignalBridge.SocketToken) -> Bool {
        !stopped && current?.token == token && retiredToken != token
    }

    /// Every concurrent early stop joins the same operation. Final cleanup joins
    /// it before closing again, so a lingering old disconnect cannot clear a
    /// replacement session's presence after reconnect.
    private func stopCurrentSocket(_ token: PresenceSignalBridge.SocketToken) async {
        guard let current, current.token == token else { return }
        if let finalDrain { await finalDrain.value; return }
        if initialStop == nil { initialStop = Task { await current.session.stop() } }
        await initialStop?.value
    }
}
