import Foundation
import MacChannelCore

protocol UserSelectedSourceAccessing: Sendable {
    func acquire(_ urls: [URL]) throws -> any UserSelectedSourceLease
}

protocol UserSelectedSourceLease: Sendable { func release() }

/// Shared by source admission and listener-owned destination authorization.
final class SecurityScopeLease: UserSelectedSourceLease, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL]
    private let stop: @Sendable (URL) -> Void
    init(urls: [URL] = [], stop: @escaping @Sendable (URL) -> Void = { _ in }) {
        self.urls = urls
        self.stop = stop
    }
    func release() {
        lock.lock()
        let acquired = urls
        urls = []
        lock.unlock()
        acquired.reversed().forEach(stop)
    }
    deinit { release() }
}

struct NoOpSourceAccess: UserSelectedSourceAccessing {
    func acquire(_ urls: [URL]) throws -> any UserSelectedSourceLease { SecurityScopeLease() }
}

struct UserSelectedSourceAccess: UserSelectedSourceAccessing {
    var start: @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }
    var stop: @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    var readable: @Sendable (URL) -> Bool = { FileManager.default.isReadableFile(atPath: $0.path) }

    func acquire(_ urls: [URL]) throws -> any UserSelectedSourceLease {
        var acquired: [URL] = []
        var seen = Set<URL>()
        do {
            for url in urls {
                let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
                guard seen.insert(canonical).inserted else { continue }
                // Start with the original Powerbox URL, which carries the grant.
                if start(url) { acquired.append(url) }
                guard url.isFileURL, readable(url) else { throw CocoaError(.fileReadNoPermission) }
            }
            return SecurityScopeLease(urls: acquired, stop: stop)
        } catch {
            acquired.reversed().forEach(stop)
            throw error
        }
    }
}

actor SourceAccessTransferCoordinator: TransferCoordinating {
    private let coordinator: any TransferCoordinating
    private let access: any UserSelectedSourceAccessing
    init(coordinator: any TransferCoordinating, access: any UserSelectedSourceAccessing) {
        self.coordinator = coordinator
        self.access = access
    }
    func send(items: [URL], to device: DeviceID) async throws -> TransferID {
        try Task.checkCancellation()
        let lease = try access.acquire(items)
        defer { lease.release() }
        // Cancellation must not release access while durable admission is still using it.
        return try await coordinator.send(items: items, to: device)
    }
    func pause(_ id: TransferID) async throws { try await coordinator.pause(id) }
    func resume(_ id: TransferID) async throws { try await coordinator.resume(id) }
    func cancel(_ id: TransferID) async -> TransferCancellationResult { await coordinator.cancel(id) }
}
