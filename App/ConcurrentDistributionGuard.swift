import AppKit

package enum RuntimeEligibility: Equatable, Sendable {
    case eligible
    case blocked

    static var conflictMessage: String { L10n.text(.statusDistributionConflict) }
}

@MainActor
package protocol RuntimeEligibilityMonitoring: AnyObject {
    var current: RuntimeEligibility { get }
    func updates() -> AsyncStream<RuntimeEligibility>
}

@MainActor
protocol RunningApplicationProviding: AnyObject {
    var runningBundleIdentifiers: Set<String> { get }
    func changes() -> AsyncStream<Void>
}

/// Notifications are invalidations, not authoritative process state. Re-read the
/// running list so delayed launch/termination callbacks cannot grant eligibility.
@MainActor
final class ConcurrentDistributionGuard: RuntimeEligibilityMonitoring {
    private let conflicts: Set<String>
    private let provider: any RunningApplicationProviding

    init(conflictingBundleIdentifiers: Set<String>, provider: any RunningApplicationProviding) {
        conflicts = conflictingBundleIdentifiers
        self.provider = provider
    }

    convenience init(conflictingBundleIdentifiers: Set<String>) {
        self.init(conflictingBundleIdentifiers: conflictingBundleIdentifiers,
                  provider: WorkspaceRunningApplications())
    }

    package var current: RuntimeEligibility {
        conflicts.isDisjoint(with: provider.runningBundleIdentifiers) ? .eligible : .blocked
    }

    package func updates() -> AsyncStream<RuntimeEligibility> {
        let changes = provider.changes()
        let pair = AsyncStream<RuntimeEligibility>.makeStream()
        let task = Task { [weak self] in
            for await _ in changes {
                guard !Task.isCancelled, let self else { break }
                pair.continuation.yield(current)
            }
            pair.continuation.finish()
        }
        pair.continuation.onTermination = { _ in task.cancel() }
        return pair.stream
    }
}

@MainActor
private final class WorkspaceRunningApplications: NSObject, RunningApplicationProviding {
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    override init() {
        super.init()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(applicationsChanged),
                           name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationsChanged),
                           name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    var runningBundleIdentifiers: Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    func changes() -> AsyncStream<Void> {
        let id = UUID()
        let pair = AsyncStream<Void>.makeStream()
        continuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.continuations.removeValue(forKey: id) }
        }
        return pair.stream
    }

    @objc private func applicationsChanged(_ notification: Notification) {
        continuations.values.forEach { $0.yield(()) }
    }
}
