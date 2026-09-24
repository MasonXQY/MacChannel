import Foundation

/// An opaque, controller-issued attachment to one account-plane socket.
/// Possession of an attachment is not peer authorization.
public struct AccountRouteAttachment: Equatable, Sendable {
    let id: UUID
    init() { id = UUID() }
}

public enum AccountRouteBindingError: Error, Equatable, Sendable {
    case missingVerifiedContext, invalidAttachment, busy
}

/// Lets cancellation revoke admission and queued work synchronously even while
/// the controller is suspended in a noncooperative history/storage operation.
final class AccountRouteLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    private var operation: Task<Void, Error>?
    var isValid: Bool { lock.withLock { valid } }
    func clearOperation() { lock.withLock { operation = nil } }
    func track(_ task: Task<Void, Error>) {
        let accepted = lock.withLock {
            guard valid else { return false }
            operation = task
            return true
        }
        if !accepted { task.cancel() }
    }
    func invalidate() {
        let task = lock.withLock {
            valid = false
            let task = operation
            operation = nil
            return task
        }
        task?.cancel()
    }
}
