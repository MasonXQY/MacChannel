import Foundation

/// Composition supplies the existing private staging directory. The caller owns
/// each result until discard, including a success racing UI cancellation.
public actor MobileImportStager {
    private nonisolated let copy: MobileImportCopy
    private let queue: OperationQueue
    private let access: MobileImportSecurityAccess
    private let makeCoordinator: @Sendable () -> any MobileImportCoordinating

    public init(directory: URL) {
        copy = MobileImportCopy(directory: directory)
        queue = Self.workerQueue()
        access = .system
        makeCoordinator = { MobileSystemImportCoordinator() }
    }

    init(directory: URL, access: MobileImportSecurityAccess = .system,
         makeCoordinator: @escaping @Sendable () -> any MobileImportCoordinating = { MobileSystemImportCoordinator() },
         didCopyFirstChunk: (@Sendable () -> Void)? = nil,
         didFinalize: (@Sendable () -> Void)? = nil) {
        copy = MobileImportCopy(directory: directory, didCopyFirstChunk: didCopyFirstChunk, didFinalize: didFinalize)
        queue = Self.workerQueue()
        self.access = access
        self.makeCoordinator = makeCoordinator
    }

    init(directory: URL, didCopyFirstChunk: @escaping @Sendable () -> Void) {
        copy = MobileImportCopy(directory: directory, didCopyFirstChunk: didCopyFirstChunk)
        queue = Self.workerQueue()
        access = .system
        makeCoordinator = { MobileSystemImportCoordinator() }
    }

    public func stage(file source: URL) async throws -> URL {
        let cancellation = MobileImportCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.addOperation { [copy] in
                    continuation.resume(with: Result { try copy.stage(file: source, cancellation: cancellation) })
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    /// Call inline inside an off-main NSItemProvider callback before it returns.
    /// Async FileRepresentation importing closures can await stage(file:) fully.
    /// Bind the configured stager in composition, never a mutable global root.
    public nonisolated func copyProviderFile(_ source: URL, cancellation: MobileImportCancellation) throws -> URL {
        try copy.stage(file: source, cancellation: cancellation)
    }

    public func stageCoordinated(file source: URL) async throws -> URL {
        let cancellation = MobileImportCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.addOperation { [copy, queue, access, makeCoordinator] in
                    do { try cancellation.check() } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                    let coordinator = makeCoordinator()
                    let scoped = access.start(source)
                    coordinator.coordinate(file: source, queue: queue) { coordinatedURL, error in
                        let result = Result {
                            try cancellation.check()
                            if let error { throw error }
                            return try copy.stage(file: coordinatedURL, cancellation: cancellation)
                        }
                        // Serial queue runs this only AFTER the accessor returns.
                        // Copy itself is inline and never waits on this queue.
                        queue.addOperation {
                            if scoped { access.stop(source) }
                            cancellation.clear()
                            withExtendedLifetime(coordinator) { continuation.resume(with: result) }
                        }
                    }
                    // Register after acquisition is submitted, so cancellation
                    // racing setup cancels a pending coordinator operation.
                    cancellation.install { coordinator.cancel() }
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    public func discard(_ stagedFile: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.addOperation { [copy] in
                continuation.resume(with: Result { try copy.discard(stagedFile) })
            }
        }
    }

    private nonisolated static func workerQueue() -> OperationQueue {
        let queue = OperationQueue()
        queue.name = "DropMesh.private-import"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
        return queue
    }
}

/// Per-import flag. Legacy provider Progress owners cancel both their Progress
/// and this token. Cancellation never abandons local cleanup.
public final class MobileImportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var cancelProvider: (@Sendable () -> Void)?
    public init() {}
    public func cancel() {
        lock.lock()
        cancelled = true
        let action = cancelProvider
        cancelProvider = nil
        lock.unlock()
        action?()
    }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }
    func install(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        let runNow = cancelled
        if !runNow { cancelProvider = action }
        lock.unlock()
        if runNow { action() }
    }
    func clear() { lock.lock(); cancelProvider = nil; lock.unlock() }
}

struct MobileImportSecurityAccess: Sendable {
    var start: @Sendable (URL) -> Bool
    var stop: @Sendable (URL) -> Void
    static let system = Self(start: { $0.startAccessingSecurityScopedResource() },
                             stop: { $0.stopAccessingSecurityScopedResource() })
}

protocol MobileImportCoordinating: AnyObject, Sendable {
    // Invoke accessor exactly once on queue, including failure/cancellation.
    func coordinate(file: URL, queue: OperationQueue, accessor: @escaping @Sendable (URL, Error?) -> Void)
    func cancel()
}

private final class MobileSystemImportCoordinator: MobileImportCoordinating, @unchecked Sendable {
    private let coordinator = NSFileCoordinator()
    func coordinate(file: URL, queue: OperationQueue, accessor: @escaping @Sendable (URL, Error?) -> Void) {
        let intent = NSFileAccessIntent.readingIntent(with: file, options: [])
        coordinator.coordinate(with: [intent], queue: queue) { error in accessor(intent.url, error) }
    }
    func cancel() { coordinator.cancel() }
}
