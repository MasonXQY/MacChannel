import Foundation
import MacChannelCore
import Observation

enum MobileAccountGroupPhase: Equatable {
    case disabled, idle, checking, ready, preparing, awaitingConfirmation, joining
    case joined, approvalRequired, removed, unavailable, secureStorageError
}

@MainActor @Observable
final class MobileAccountGroupModel {
    private(set) var phase: MobileAccountGroupPhase = .disabled
    private(set) var messageKey: String?
    private let controller: AccountSessionController
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var ticket: UUID?

    init(controller: AccountSessionController) { self.controller = controller }
    var isBusy: Bool { operation != nil }
    var confirmationID: UUID? { phase == .awaitingConfirmation ? ticket : nil }

    func load() async {
        guard operation == nil, phase != .awaitingConfirmation else { return }
        let id = UUID()
        await start(phase: phase == .disabled ? .disabled : .checking, id: id) { [self] in
            let supported = await controller.supportsFirstDeviceEnrollment()
            guard generation == id, !Task.isCancelled else { throw CancellationError() }
            guard supported else { return .disabled }
            phase = .checking
            switch try await controller.discoverAccountGroup() {
            case .absent: return .ready
            case .present(let metadata):
                do { return try await membership(controller.syncGroup(groupID: metadata.groupID)) }
                catch AccountGroupCheckpointError.missingCheckpoint {
                    // Classify retained LOCAL consent only. This ticket is deliberately
                    // discarded; Join always requires a fresh preparation and acceptance.
                    _ = try await controller.prepareFirstDeviceJoin()
                    return .ready
                }
            }
        }.value
    }

    func prepareJoin() async {
        guard operation == nil, phase == .ready else { return }
        let id = UUID(); generation = id; phase = .preparing; messageKey = nil
        let task = Task { [self] in
            do {
                let prepared = try await controller.prepareFirstDeviceJoin()
                guard generation == id, !Task.isCancelled else { return }
                ticket = prepared; phase = .awaitingConfirmation
            } catch { if generation == id, !Task.isCancelled { fail(error) } }
            if generation == id { operation = nil }
        }
        operation = task
        await task.value
    }

    /// Admission and ticket consumption are synchronous, before SwiftUI dismisses
    /// its native dialog. Only this affirmative action starts core confirmation.
    @discardableResult func confirmJoin(attemptID: UUID? = nil) -> Task<Void, Never>? {
        guard operation == nil, phase == .awaitingConfirmation, let ticket else { return nil }
        if let attemptID, attemptID != ticket { return nil }
        self.ticket = nil
        return start(phase: .joining) { [self] in
            try await membership(controller.confirmFirstDeviceJoin(attemptID: ticket))
        }
    }

    func dismissConfirmation(attemptID: UUID? = nil) {
        guard phase == .awaitingConfirmation else { return }
        if let attemptID, attemptID != ticket { return }
        ticket = nil; generation = UUID(); phase = .ready
    }

    func cancel() {
        generation = UUID(); operation?.cancel(); operation = nil; ticket = nil
        messageKey = nil
        if phase != .disabled { phase = .idle }
    }

    private func start(phase: MobileAccountGroupPhase, id: UUID = UUID(),
                       action: @escaping @MainActor () async throws -> MobileAccountGroupPhase) -> Task<Void, Never> {
        generation = id
        if self.phase != phase { self.phase = phase }
        messageKey = nil
        let task = Task { [self] in
            do {
                let result = try await action()
                guard generation == id, !Task.isCancelled else { return }
                if self.phase != result { self.phase = result }
            } catch { if generation == id, !Task.isCancelled { fail(error) } }
            if generation == id { operation = nil }
        }
        operation = task
        return task
    }

    private func membership(_ group: AccountGroupSnapshot) async throws -> MobileAccountGroupPhase {
        let session = await controller.snapshot()
        guard session.phase == .signedIn, let identity = session.identity,
              group.accountID == identity.accountID.uuidString.lowercased() else {
            throw AccountSessionControllerError.needsSignIn
        }
        return group.members.contains { $0.deviceID == identity.deviceID.uuidString.lowercased() } ? .joined : .removed
    }

    private func fail(_ error: Error) {
        ticket = nil
        if error as? AccountFirstDeviceEnrollmentError == .approvalRequired {
            phase = .approvalRequired
        } else if error as? AccountFirstDeviceEnrollmentError == .secureStorage ||
                    error as? AccountGroupCheckpointError == .secureStorage ||
                    error as? AccountGroupCheckpointError == .invalidCheckpoint ||
                    error as? AccountSessionControllerError == .secureStorage {
            phase = .secureStorageError; messageKey = "account.group.error.secure-store"
        } else {
            phase = .unavailable; messageKey = "account.group.error.unavailable"
        }
    }
}
