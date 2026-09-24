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
    public private(set) var trustSyncState: PresenceTrustSyncState = .idle
    private let origin: URL
    private let identity: DeviceIdentity
    private let repository: TrustRepository
    private let directory: DeviceDirectory
    private let makeClient: @Sendable (DeviceDirectory) -> PresenceClient
    private let makeSocket: @Sendable () async throws -> any PresenceWebSocket
    private let sleep: @Sendable (Duration) async throws -> Void
    private let onState: @Sendable (PresenceSessionState) async -> Void
    private let onTrustSyncState: @Sendable (PresenceTrustSyncState) async -> Void
    private let records: @Sendable () async throws -> TrustPublicationSnapshot
    private let persistedUpdates: (@Sendable () async -> AsyncStream<AuthenticatedTrustState?>)?
    private var trustObservers: [Task<Void, Never>] = []
    private let deadlineSleep: @Sendable (Duration) async throws -> Void
    private var loop: Task<Void, Never>?
    private var backoff: Task<Void, Error>?
    private var retryRequested = false
    private var stopped = false
    private var synchronizer: PresenceTrustSynchronizer?
    private var current: (token: PresenceSignalBridge.SocketToken, session: AuthenticatedPresenceSession)?
    private var retiredToken: PresenceSignalBridge.SocketToken?
    private var initialStop: Task<Void, Never>?
    private var finalDrain: Task<Void, Never>?
    private let accountController: AccountSessionController?
    private var accountAttachment: AccountRouteAttachment?
    private var accountWorker: Task<Void, Never>?

    /// Transport and clock seam; tests still execute AuthenticatedPresenceSession.
    public init(
        identity: DeviceIdentity, repository: TrustRepository, directory: DeviceDirectory, origin: URL,
        makeSocket: @escaping @Sendable () async throws -> any PresenceWebSocket,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        onState: @escaping @Sendable (PresenceSessionState) async -> Void = { _ in },
        onTrustSyncState: @escaping @Sendable (PresenceTrustSyncState) async -> Void = { _ in },
        records: (@Sendable () async throws -> [SignedTrustRecord])? = nil,
        publication: (@Sendable () async throws -> TrustPublicationSnapshot)? = nil,
        persistedUpdates: (@Sendable () async -> AsyncStream<AuthenticatedTrustState?>)? = nil,
        deadlineSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        accountController: AccountSessionController? = nil
    ) {
        self.init(identity: identity, repository: repository, directory: directory,
                  origin: origin, makeSocket: makeSocket, sleep: sleep, onState: onState,
                  onTrustSyncState: onTrustSyncState, records: records, publication: publication,
                  persistedUpdates: persistedUpdates, deadlineSleep: deadlineSleep, accountController: accountController,
                  makeClient: { PresenceClient(directory: $0) })
    }

    /// Internal construction seam to verify attempt-local client ownership.
    init(
        identity: DeviceIdentity, repository: TrustRepository, directory: DeviceDirectory, origin: URL,
        makeSocket: @escaping @Sendable () async throws -> any PresenceWebSocket,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        onState: @escaping @Sendable (PresenceSessionState) async -> Void = { _ in },
        onTrustSyncState: @escaping @Sendable (PresenceTrustSyncState) async -> Void = { _ in },
        records: (@Sendable () async throws -> [SignedTrustRecord])? = nil,
        publication: (@Sendable () async throws -> TrustPublicationSnapshot)? = nil,
        persistedUpdates: (@Sendable () async -> AsyncStream<AuthenticatedTrustState?>)? = nil,
        deadlineSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        accountController: AccountSessionController? = nil,
        makeClient: @escaping @Sendable (DeviceDirectory) -> PresenceClient
    ) {
        self.origin = origin
        self.identity = identity
        self.repository = repository
        self.directory = directory
        self.makeClient = makeClient
        self.makeSocket = makeSocket
        self.sleep = sleep
        self.onState = onState
        self.onTrustSyncState = onTrustSyncState
        self.records = publication ?? {
            if let records { return TrustPublicationSnapshot(records: try await records()) }
            return TrustPublicationSnapshot(records: await repository.authenticationRecords())
        }
        self.persistedUpdates = persistedUpdates
        self.deadlineSleep = deadlineSleep
        self.accountController = accountController
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
        if let current { beginAccountRetirement(current.token) }
        for observer in trustObservers { observer.cancel() }
        await synchronizer?.retire()
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

    /// Coalesces current records into the session's sole acknowledged writer.
    /// Connectivity alone never means the server accepted the local proofs.
    public func refreshTrust() async {
        guard !stopped, state == .online, let current else { return }
        guard isActive(current.token) else { return }
        await synchronizer?.refresh()
    }

    public static func reconnectDelay(_ failures: Int) -> Duration {
        [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15)][min(max(failures, 0), 4)]
    }

    private func runLoop() async {
        // Production publication refresh has one joined lifecycle owner. The
        // repository observer does not write persistence; receipt events only
        // follow successful checkpoints, including retries at the same revision.
        if let persistedUpdates, !stopped {
            trustObservers = [
                Task { [weak self, repository] in
                    for await _ in await repository.updates() {
                        guard !Task.isCancelled else { return }
                        await self?.refreshTrust()
                    }
                },
                Task { [weak self] in
                    for await _ in await persistedUpdates() {
                        guard !Task.isCancelled else { return }
                        await self?.refreshTrust()
                    }
                }
            ]
        }
        var failures = 0
        while !stopped, !Task.isCancelled {
            // Subscribe before checking readiness. A verification racing this
            // check stays buffered; absent authority opens no idle raw socket.
            var accountChanges: AsyncStream<Void>?
            if let accountController {
                let changes = await accountController.runtimeChanges()
                accountChanges = changes
                var ready = false
                for await _ in changes {
                    guard !stopped, !Task.isCancelled else { break }
                    if await accountController.isAccountRouteReady() {
                        #if DEBUG
                        print("DropMeshAccount route=ready")
                        #endif
                        ready = true; break
                    }
                }
                guard ready, !stopped, !Task.isCancelled else { break }
            }
            guard let token = await bridge.beginSocket() else { break }
            var session: AuthenticatedPresenceSession?
            var forwarders: [Task<Void, Never>] = []
            var cancelled = false
            var authenticated = false
            var authenticationDeadline: Task<Void, Never>?
            do {
                let socket = try await makeSocket()
                guard !stopped, !Task.isCancelled else { await socket.close(); break }
                let attempt = try AuthenticatedPresenceSession(
                    identity: identity, origin: origin,
                    socket: socket, client: makeClient(directory), trustRepository: repository
                )
                session = attempt
                current = (token, attempt)
                retiredToken = nil
                if let accountController {
                    let attachment = try await accountController.attachAccountRoute(to: attempt)
                    guard isActive(token), !Task.isCancelled else {
                        await accountController.detachAccountRoute(attachment)
                        throw CancellationError()
                    }
                    accountAttachment = attachment
                    #if DEBUG
                    print("DropMeshAccount route=attached")
                    #endif
                }
                await publish(failures == 0 ? .connecting : .reconnecting)
                try Task.checkCancellation()
                guard isActive(token) else { throw AttemptInterrupted.retry }
                authenticationDeadline = Task {
                    do { try await deadlineSleep(.seconds(15)); try Task.checkCancellation() }
                    catch { return }
                    await self.interrupt(token)
                }
                try await attempt.connect(includeTrustRecords: false)
                authenticationDeadline?.cancel()
                await authenticationDeadline?.value
                authenticationDeadline = nil
                authenticated = true
                #if DEBUG
                if accountController != nil { print("DropMeshAccount route=transport-authenticated") }
                #endif
                failures = 0
                guard !stopped, !Task.isCancelled else { throw CancellationError() }
                guard isActive(token) else { throw AttemptInterrupted.retry }
                let sync = PresenceTrustSynchronizer(records: records,
                    send: { try await attempt.sendTrustUpdate([$0]) }, sleep: deadlineSleep,
                    onState: { [weak self] in await self?.publishSync($0, token: token) },
                    onFailure: { [weak self] in await self?.interrupt(token) })
                synchronizer = sync
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
                let changes = accountChanges
                try await attempt.run(onStarted: {
                    await sync.refresh()
                    await self.startAccountWorker(token, session: attempt, changes: changes)
                },
                                      onTrustResult: { await sync.receive($0) })
            } catch is CancellationError {
                cancelled = true
            } catch {
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
            authenticationDeadline?.cancel()
            await authenticationDeadline?.value
            for task in forwarders { task.cancel() }
            let initialStop = initialStop
            let sync = synchronizer
            let worker = accountWorker
            let drain = Task {
                await initialStop?.value
                // connect() may return after an earlier stop() and set running
                // again. Stop once more after connect/run has actually returned.
                await session?.stop()
                await worker?.value
                await sync?.stop()
                for task in forwarders { await task.value }
            }
            finalDrain = drain
            await drain.value
            current = nil
            synchronizer = nil
            accountWorker = nil
            accountAttachment = nil
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
        for observer in trustObservers { observer.cancel() }
        for observer in trustObservers { await observer.value }
        trustObservers = []
        await bridge.finish()
        trustSyncState = .idle
        await onTrustSyncState(.idle)
        state = .stopped
        await onState(.stopped)
    }

    private func publish(_ value: PresenceSessionState) async {
        guard !stopped else { return }
        state = value
        // Caller must also check its runtime generation inside its own actor.
        await onState(value)
    }

    /// Never await a bind here: onStarted must return so the sole reader can
    /// consume the challenge and acknowledgement awaited by this retained task.
    private func startAccountWorker(_ token: PresenceSignalBridge.SocketToken,
                                    session: AuthenticatedPresenceSession, changes: AsyncStream<Void>?) {
        guard isActive(token), let accountController, let attachment = accountAttachment,
              let changes, accountWorker == nil else { return }
        accountWorker = Task { [weak self] in
            do {
                try Task.checkCancellation()
                try await accountController.bindAccountRoute(attachment, on: session)
                #if DEBUG
                print("DropMeshAccount route=bound")
                #endif
                for await _ in changes {
                    try Task.checkCancellation()
                    try await accountController.bindAccountRoute(attachment, on: session)
                }
            } catch {
                #if DEBUG
                print("DropMeshAccount route=bind-failed category=\(Self.diagnosticCategory(error))")
                #endif
                // Controller withdrawal may cancel only its bind task. That
                // still needs to retire this attempt's bridge immediately.
                if !Task.isCancelled { await self?.interrupt(token) }
            }
        }
    }

    private func beginAccountRetirement(_ token: PresenceSignalBridge.SocketToken) {
        guard let accountController, let current, current.token == token else { return }
        accountWorker?.cancel()
        let attachment = accountAttachment
        accountAttachment = nil
        if initialStop == nil {
            initialStop = Task {
                async let close: Void = current.session.stop()
                if let attachment { await accountController.detachAccountRoute(attachment) }
                await close
            }
        }
    }

    private func publishSync(_ value: PresenceTrustSyncState, token: PresenceSignalBridge.SocketToken) async {
        guard isActive(token) else { return }
        trustSyncState = value
        await onTrustSyncState(value)
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
        beginAccountRetirement(token)
        let sync = synchronizer
        await bridge.disconnect(token)
        await sync?.retire()
        guard !stopped, current?.token == token else { return }
        trustSyncState = .idle
        await onTrustSyncState(.idle)
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
