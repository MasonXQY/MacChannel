import Foundation

/// Owns ordering of the app's manual runtime and optional account lifecycle.
public actor MobileForegroundOwnership {
    private let startRuntime: @Sendable () async throws -> Void
    private let stopRuntime: @Sendable () async -> Void
    private let startAccount: @Sendable () async -> Void
    private let stopAccount: @Sendable () async -> Void
    private var desired = false
    private var revision = UUID()
    private var startup: Task<Void, Error>?
    private var drain: Task<Void, Never>?
    private var drainID = UUID()

    public init(startRuntime: @escaping @Sendable () async throws -> Void,
                stopRuntime: @escaping @Sendable () async -> Void,
                startAccount: @escaping @Sendable () async -> Void,
                stopAccount: @escaping @Sendable () async -> Void) {
        self.startRuntime = startRuntime; self.stopRuntime = stopRuntime
        self.startAccount = startAccount; self.stopAccount = stopAccount
    }

    public func start() async throws {
        if desired, let startup { return try await startup.value }
        desired = true
        let id = UUID(); revision = id
        let priorDrain = drain
        let task = Task {
            await priorDrain?.value
            try self.requireCurrent(id)
            try await self.startRuntime()
            try self.requireCurrent(id)
            await self.startAccount()
            try self.requireCurrent(id)
        }
        startup = task
        do { try await task.value }
        catch {
            if revision == id { startup = nil }
            throw error
        }
    }

    public func stop() async {
        if !desired, let drain { await drain.value; return }
        desired = false
        revision = UUID()
        let oldStart = startup, oldDrain = drain
        startup = nil
        oldStart?.cancel()
        let id = UUID(); drainID = id
        let task = Task {
            // Revoke both planes promptly, even while startup is suspended.
            async let initialStop: Void = self.stopBoth()
            await oldDrain?.value
            _ = await oldStart?.result
            await initialStop
            // A cancellation-insensitive old start may have crossed its last
            // admission check. Converge again before allowing any new start.
            if oldStart != nil { await self.stopBoth() }
        }
        drain = task
        await task.value
        if drainID == id { drain = nil }
    }

    private func requireCurrent(_ id: UUID) throws {
        guard desired, revision == id, !Task.isCancelled else { throw MobileRuntimeError.interrupted }
    }

    private func stopBoth() async {
        async let account: Void = stopAccount()
        async let runtime: Void = stopRuntime()
        _ = await (account, runtime)
    }
}
