import Foundation
import MacChannelCore
import Observation

enum MobileAccountApprovalPhase: Equatable { case disabled, loading, ready, signedOut, unavailable, secureStorageError }
// Selects which read endpoints the entry needs, never grants membership authority.
enum MobileAccountApprovalReadScope { case ownRequests, memberRequests }

struct MobileAccountApprovalConfirmation: Identifiable {
    enum Action { case ticket(AccountDeviceApprovalTicket, String), cancel(String), reject(String) }
    let id: UUID
    let action: Action
    var titleKey: String {
        switch action {
        case .cancel: return "approval.cancel.title"
        case .reject: return "approval.reject.title"
        case .ticket(let ticket, _):
            switch ticket.operation {
            case .requestJoin: return "approval.request.title"
            case .approveJoin: return "approval.approve.title"
            case .confirmJoin: return "approval.confirm.title"
            case .verifyCommitted: return "approval.verify.title"
            }
        }
    }
}

@MainActor @Observable
final class MobileAccountApprovalModel {
    private(set) var phase: MobileAccountApprovalPhase = .disabled
    private(set) var requests: [AccountGroupPendingSummary] = []
    private(set) var recoveryRequestIDs: [String] = []
    private(set) var detail: AccountDeviceApprovalView?
    private(set) var confirmation: MobileAccountApprovalConfirmation?
    private(set) var messageKey: String?
    private(set) var selectedRequestID: String?
    private(set) var actionPresentationID: UUID?
    private(set) var readScope: MobileAccountApprovalReadScope = .ownRequests
    private let controller: AccountSessionController
    private let refreshAccount: @Sendable () async -> Void
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var invalidated = false
    private var presentationOwner: UUID?
    var isBusy: Bool { operation != nil }
    init(controller: AccountSessionController, refreshAccount: @escaping @Sendable () async -> Void = {}) {
        self.controller = controller; self.refreshAccount = refreshAccount
    }

    func refresh() async {
        guard !invalidated, operation == nil, confirmation == nil else { return }
        await start { [self] id in
            guard await controller.supportsDeviceApproval() else {
                if current(id) { phase = .disabled }; return
            }
            let rows = readScope == .memberRequests ? try await controller.pendingDeviceApprovals() : []
            let retained = try await controller.retainedDeviceApprovalRequestIDs()
            let value: AccountDeviceApprovalView?
            if let selectedRequestID { value = try await controller.deviceApproval(requestID: selectedRequestID) }
            else { value = nil }
            guard current(id) else { return }
            requests = rows; recoveryRequestIDs = retained.filter { id in !rows.contains { $0.requestID == id } }
            detail = value; phase = .ready
        }.value
    }

    func open(requestID: String?) async {
        guard operation == nil, confirmation == nil else { return }
        selectedRequestID = requestID; detail = nil
        await refresh()
    }

    func prepareJoin() async {
        guard phase == .ready else { return }
        await prepare { [controller] in try await controller.prepareDeviceJoin() }
    }
    func prepareApproval(code: String) async {
        guard let detail, detail.phase == .needsMemberVerification else { return }
        await prepare(code: code) { [controller] in try await controller.prepareDeviceApproval(requestID: detail.summary.requestID) }
    }
    func prepareSubject(code: String) async {
        guard let detail, detail.role == .subject,
              [.needsSubjectConfirmation, .verifyingHistory].contains(detail.phase) else { return }
        await prepare { [controller] in
            try await controller.prepareDeviceJoinConfirmation(requestID: detail.summary.requestID, memberCode: code)
        }
    }
    private func prepare(code: String = "", _ action: @escaping @Sendable () async throws -> AccountDeviceApprovalTicket) async {
        guard !invalidated, operation == nil, confirmation == nil else { return }
        await start(presentError: true) { [self] id in
            let ticket = try await action()
            guard current(id) else { await controller.dismissDeviceApprovalTicket(ticketID: ticket.id); return }
            confirmation = .init(id: ticket.id, action: .ticket(ticket, code)); phase = .ready
        }.value
    }

    func prepareCancellation() {
        guard !invalidated, !isBusy, confirmation == nil, let detail, detail.role == .subject else { return }
        confirmation = .init(id: UUID(), action: .cancel(detail.summary.requestID))
    }
    func prepareRejection() {
        guard !invalidated, !isBusy, confirmation == nil, let detail, detail.role != .subject else { return }
        confirmation = .init(id: UUID(), action: .reject(detail.summary.requestID))
    }

    /// Consume local consent before creating the task. An old sheet's dismissal
    /// cannot withdraw accepted work or dismiss the next presentation.
    @discardableResult func accept(id: UUID) -> Task<Void, Never>? {
        guard !invalidated, operation == nil, let choice = confirmation, choice.id == id else { return nil }
        confirmation = nil
        if case .ticket(let ticket, _) = choice.action { selectedRequestID = ticket.presentation.requestID }
        return start(presentResult: true, presentError: true) { [self] generation in
            let value: AccountDeviceApprovalView
            switch choice.action {
            case .cancel(let request): value = try await controller.cancelDeviceJoin(requestID: request)
            case .reject(let request): value = try await controller.rejectDeviceJoin(requestID: request)
            case .ticket(let ticket, let code):
                switch ticket.operation {
                case .requestJoin: value = try await controller.confirmDeviceJoin(ticketID: ticket.id)
                case .approveJoin: value = try await controller.confirmDeviceApproval(ticketID: ticket.id, joiningCode: code)
                case .confirmJoin, .verifyCommitted: value = try await controller.confirmDeviceJoinConfirmation(ticketID: ticket.id)
                }
            }
            await refreshAccount()
            guard current(generation) else { return }
            selectedRequestID = value.summary.requestID; detail = value; phase = .ready
        }
    }
    func dismiss(id: UUID) {
        guard let choice = confirmation, choice.id == id else { return }
        confirmation = nil
        if case .ticket(let ticket, _) = choice.action {
            Task { await controller.dismissDeviceApprovalTicket(ticketID: ticket.id) }
        }
    }
    func resume() async {
        guard !invalidated, operation == nil, confirmation == nil, let selectedRequestID else { return }
        await start(presentResult: true, presentError: true) { [self] id in
            let value = try await controller.resumeDeviceApproval(requestID: selectedRequestID)
            await refreshAccount()
            guard current(id) else { return }; detail = value; phase = .ready
        }.value
    }
    func beginPresentation(owner: UUID, readScope: MobileAccountApprovalReadScope = .ownRequests) {
        if presentationOwner != owner || self.readScope != readScope { leave() }
        presentationOwner = owner; self.readScope = readScope
    }
    func leave(owner: UUID? = nil) {
        if let owner, presentationOwner != owner { return }
        presentationOwner = nil
        readScope = .ownRequests
        actionPresentationID = nil
        generation = UUID(); operation?.cancel(); operation = nil
        if let confirmation { dismiss(id: confirmation.id) }
        detail = nil; requests = []; recoveryRequestIDs = []; selectedRequestID = nil; messageKey = nil; phase = .disabled
    }
    func invalidate() { invalidated = true; leave() }
    private func current(_ id: UUID) -> Bool { !invalidated && generation == id && !Task.isCancelled }
    private func start(presentResult: Bool = false, presentError: Bool = false,
                       _ action: @escaping @MainActor (UUID) async throws -> Void) -> Task<Void, Never> {
        let id = UUID(); generation = id; messageKey = nil; phase = .loading
        let task = Task { [self] in
            guard current(id) else { return }
            do {
                try await action(id)
                if current(id), presentResult { actionPresentationID = UUID() }
            } catch {
                if current(id) {
                    fail(error)
                    if presentError { actionPresentationID = UUID() }
                }
            }
            if generation == id { operation = nil }
        }
        operation = task; return task
    }
    private func fail(_ error: Error) {
        if error as? AccountDeviceApprovalError == .secureStorage ||
            error as? AccountDeviceApprovalValueError == .secureStorage ||
            error as? AccountSessionControllerError == .secureStorage ||
            error as? AccountGroupCheckpointError == .secureStorage {
            phase = .secureStorageError; messageKey = "account.error.secure-store"
        } else if error as? AccountDeviceApprovalError == .sessionChanged ||
                    error as? AccountSessionControllerError == .needsSignIn {
            phase = .signedOut; detail = nil; requests = []; recoveryRequestIDs = []; messageKey = "approval.signed-out"
        } else {
            phase = .unavailable
            switch error as? AccountDeviceApprovalError {
            case .verificationMismatch: messageKey = "approval.error.comparison"
            case .requestExpired, .invalidTicket: messageKey = "approval.error.expired"
            case .requestConflict, .invalidHistory: messageKey = "approval.error.changed"
            default: messageKey = "approval.error.retry"
            }
        }
    }
}

extension AccountDeviceApprovalView.Phase {
    var mobileMessageKey: String {
        switch self {
        case .waitingForMember: return "approval.state.waiting-member"
        case .needsMemberVerification: return "approval.state.member-verification"
        case .waitingForSubject: return "approval.state.waiting-subject"
        case .needsSubjectConfirmation: return "approval.state.subject-confirmation"
        case .waitingForActor: return "approval.state.waiting-actor"
        case .verifyingHistory: return "approval.state.verifying-history"
        case .joined: return "approval.state.joined"
        case .removed: return "approval.state.removed"
        case .rejected: return "approval.state.rejected"
        case .cancelled: return "approval.state.cancelled"
        case .expired: return "approval.state.expired"
        case .invalidated: return "approval.state.invalidated"
        case .needsSignIn: return "approval.signed-out"
        case .retryableFailure: return "approval.error.retry"
        }
    }
}
