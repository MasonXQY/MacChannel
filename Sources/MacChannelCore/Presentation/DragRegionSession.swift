import Foundation

public struct StatusItemDragFingerprint: Hashable, Sendable {
    public let sequenceNumber: Int
    public let pasteboardChangeCount: Int

    public init(sequenceNumber: Int, pasteboardChangeCount: Int) {
        self.sequenceNumber = sequenceNumber
        self.pasteboardChangeCount = pasteboardChangeCount
    }
}

public enum DragRegion: Hashable, Sendable {
    case icon
    case fan
}

@MainActor
public protocol DragRegionCancellation: AnyObject {
    func cancel()
}

public typealias DragRegionSchedule = @MainActor (
    Duration,
    @escaping @MainActor () -> Void
) -> any DragRegionCancellation

@MainActor
public final class DragRegionSession {
    public var onExpired: ((StatusItemDragToken) -> Void)?

    private struct ActiveDrag {
        let token: StatusItemDragToken
        let fingerprint: StatusItemDragFingerprint
        var regions: Set<DragRegion>
    }

    private let grace: Duration
    private let schedule: DragRegionSchedule
    private var active: ActiveDrag?
    private var generation: UInt64 = 0
    private var pendingExpiration: (any DragRegionCancellation)?

    public convenience init(grace: Duration = .milliseconds(120)) {
        self.init(grace: grace, schedule: Self.scheduleWithTask)
    }

    public init(
        grace: Duration = .milliseconds(120),
        schedule: @escaping DragRegionSchedule
    ) {
        self.grace = grace
        self.schedule = schedule
    }

    public func begin(
        token: StatusItemDragToken,
        fingerprint: StatusItemDragFingerprint,
        in region: DragRegion
    ) {
        advanceGeneration()
        pendingExpiration?.cancel()
        pendingExpiration = nil
        active = ActiveDrag(token: token, fingerprint: fingerprint, regions: [region])
    }

    @discardableResult
    public func enter(
        _ region: DragRegion,
        token: StatusItemDragToken,
        fingerprint: StatusItemDragFingerprint
    ) -> Bool {
        guard var active,
              active.token == token,
              active.fingerprint == fingerprint
        else { return false }
        advanceGeneration()
        pendingExpiration?.cancel()
        pendingExpiration = nil
        active.regions.insert(region)
        self.active = active
        return true
    }

    @discardableResult
    public func exit(
        _ region: DragRegion,
        token: StatusItemDragToken,
        fingerprint: StatusItemDragFingerprint
    ) -> Bool {
        guard var active,
              active.token == token,
              active.fingerprint == fingerprint,
              active.regions.remove(region) != nil
        else { return false }
        advanceGeneration()
        self.active = active
        guard active.regions.isEmpty else { return true }

        let exitGeneration = generation
        pendingExpiration = schedule(grace) { [weak self] in
            self?.expire(
                token: token,
                fingerprint: fingerprint,
                generation: exitGeneration
            )
        }
        return true
    }

    public func invalidate(token: StatusItemDragToken) {
        guard active?.token == token else { return }
        advanceGeneration()
        pendingExpiration?.cancel()
        pendingExpiration = nil
        active = nil
    }

    private func expire(
        token: StatusItemDragToken,
        fingerprint: StatusItemDragFingerprint,
        generation: UInt64
    ) {
        guard self.generation == generation,
              let active,
              active.token == token,
              active.fingerprint == fingerprint,
              active.regions.isEmpty
        else { return }
        advanceGeneration()
        pendingExpiration = nil
        self.active = nil
        onExpired?(token)
    }

    private func advanceGeneration() {
        generation &+= 1
    }

    private static func scheduleWithTask(
        _ delay: Duration,
        _ action: @escaping @MainActor () -> Void
    ) -> any DragRegionCancellation {
        let task = Task { @MainActor in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            action()
        }
        return TaskDragRegionCancellation(task: task)
    }
}

@MainActor
private final class TaskDragRegionCancellation: DragRegionCancellation {
    private let task: Task<Void, Never>

    init(task: Task<Void, Never>) {
        self.task = task
    }

    func cancel() {
        task.cancel()
    }
}
