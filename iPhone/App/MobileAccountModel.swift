import MacChannelCore
import Observation
import UIKit

enum MobileAccountViewPhase: Equatable {
    case disabled, signedOut, loading, awaitingApple, signingIn, signedIn, signingOut
    case unavailable, secureStorageError
}

@MainActor @Observable
final class MobileAccountModel {
    private(set) var phase: MobileAccountViewPhase = .disabled
    private(set) var messageKey: String?
    private(set) var group: MobileAccountGroupModel?
    private(set) var approvals: MobileAccountApprovalModel?
    private(set) var deletionSupported = false
    private(set) var deletionStatus: AccountDeletionStatus?
    private(set) var deletionConfirmationID: UUID?
    private(set) var deletionActivity: MobileAccountDeletionActivity = .idle
    private(set) var deletionMessageKey: String?
    func requestDeletionConfirmation() {
        guard deletionSupported, operation == nil,
              phase == .signedIn || (deletionStatus != nil && deletionStatus?.isCompleted == false) else { return }
        deletionConfirmationID = UUID()
    }
    func cancelDeletionConfirmation() { deletionConfirmationID = nil }
    func confirmDeletion(id: UUID, anchor: UIWindow?) async {
        guard operation == nil, deletionConfirmationID == id, let controller else { return }
        deletionConfirmationID = nil
        guard let anchor, anchor.windowScene != nil else { deletionMessageKey = "account.error.unavailable"; return }
        let operationID = UUID()
        let task = Task {
            deletionActivity = .authenticating; deletionMessageKey = nil
            var ticket: AccountDeletionAttempt?
            do {
                let fresh = try await controller.beginDeletionReauthentication()
                ticket = fresh
                await attemptHandoff()
                try Task.checkCancellation()
                let credential = try await apple.authorize(attempt: AccountLoginAttempt(id: fresh.id, challenge: fresh.challenge), anchor: anchor)
                try Task.checkCancellation()
                deletionActivity = .submitting
                _ = try await controller.confirmAccountDeletion(attemptID: fresh.id, code: credential.code,
                    identityToken: credential.identityToken, confirmation: true)
                await updateDeletionPresentation(controller)
            } catch {
                if let ticket { await controller.cancelDeletionReauthentication(attemptID: ticket.id) }
                await updateDeletionPresentation(controller)
                if !(error is CancellationError) { deletionFailure(error) }
            }
            deletionActivity = .idle
        }
        self.operationID = operationID; operation = task
        await task.value
        if self.operationID == operationID { operation = nil; self.operationID = nil }
    }
    func refreshDeletion() async {
        guard operation == nil, deletionStatus != nil, let controller else { return }
        let id = UUID()
        let task = Task {
            deletionMessageKey = nil; deletionActivity = .submitting
            do { _ = try await controller.resumeAccountDeletion(); await updateDeletionPresentation(controller) }
            catch { await updateDeletionPresentation(controller); deletionFailure(error) }
            deletionActivity = .idle
        }
        operationID = id; operation = task
        await task.value
        if operationID == id { operation = nil; operationID = nil }
    }
    private func updateDeletionPresentation(_ controller: AccountSessionController) async {
        let snapshot = await controller.snapshot()
        apply(snapshot)
        let status = await controller.deletionSnapshot()
        deletionStatus = snapshot.phase == .signedIn && status?.isCompleted == true ? nil : status
        if deletionStatus != nil { messageKey = nil }
    }
    private func deletionFailure(_ error: Error) {
        if phase == .secureStorageError || (error as? AccountSessionControllerError) == .secureStorage {
            deletionMessageKey = "account.delete.secure-store"
        } else {
            deletionMessageKey = deletionStatus == nil ? "account.error.unavailable" : "account.delete.error"
        }
    }
    private var approvalAccountID: UUID?
    private let loadController: @Sendable () async throws -> AccountSessionController?
    private let apple: any MobileAppleAuthorizing
    private let attemptHandoff: @Sendable () async -> Void
    private let loadLifecycle: @Sendable () async throws -> AccountForegroundLifecycle?
    private var lifecycle: AccountForegroundLifecycle?
    private var controller: AccountSessionController?
    private var operation: Task<Void, Never>?
    private var operationID: UUID?
    private var attemptID: UUID?

    init(loadController: @escaping @Sendable () async throws -> AccountSessionController?,
         apple: any MobileAppleAuthorizing,
         attemptHandoff: @escaping @Sendable () async -> Void = {},
         loadLifecycle: @escaping @Sendable () async throws -> AccountForegroundLifecycle? = { nil }) {
        self.loadController = loadController
        self.apple = apple
        self.attemptHandoff = attemptHandoff
        self.loadLifecycle = loadLifecycle
    }

    func load() async {
        guard operation == nil else { return }
        let id = UUID()
        let task = Task { await runLoad() }
        operationID = id
        operation = task
        await task.value
        if operationID == id { operation = nil; operationID = nil }
    }

    private func runLoad() async {
        phase = .loading; messageKey = nil; deletionMessageKey = nil
        do {
            let loaded = try await loadController()
            guard let loaded else {
                group?.cancel(); group = nil; clearApprovals(); controller = nil; phase = .disabled
                deletionSupported = false; deletionStatus = nil; deletionConfirmationID = nil
                return
            }
            if controller !== loaded { group?.cancel(); group = nil; clearApprovals() }
            controller = loaded
            lifecycle = try await loadLifecycle()
            await loaded.restore()
            deletionSupported = await loaded.supportsAccountDeletion()
            await updateDeletionPresentation(loaded)
            if deletionSupported, let status = deletionStatus, !status.isCompleted {
                do { _ = try await loaded.resumeAccountDeletion(); await updateDeletionPresentation(loaded) }
                catch { await updateDeletionPresentation(loaded); deletionFailure(error) }
            }
        } catch { fail(error) }
    }

    func signIn(anchor: UIWindow?) async {
        guard operation == nil, let controller else { return }
        guard let anchor, anchor.windowScene != nil else {
            phase = .unavailable; messageKey = "account.error.unavailable"; return
        }
        let id = UUID()
        let task = Task { await runSignIn(controller: controller, anchor: anchor) }
        operationID = id
        operation = task
        await task.value
        if operationID == id { operation = nil; operationID = nil }
    }

    private func runSignIn(controller: AccountSessionController, anchor: UIWindow) async {
        messageKey = nil
        do {
            let attempt = try await controller.beginLogin()
            attemptID = attempt.id
            await attemptHandoff()
            try Task.checkCancellation()
            apply(await controller.snapshot())
            let credential: MobileAppleCredential
            do { credential = try await apple.authorize(attempt: attempt, anchor: anchor) }
            catch {
                await controller.cancelLogin(attemptID: attempt.id)
                attemptID = nil
                if error is CancellationError { apply(await controller.snapshot()); return }
                throw error
            }
            try Task.checkCancellation()
            attemptID = nil
            phase = .signingIn
            try await controller.completeLogin(attemptID: attempt.id, code: credential.code,
                                               identityToken: credential.identityToken)
            await updateDeletionPresentation(controller)
        } catch is CancellationError {
            await cancelRetainedAttempt(controller: controller)
            apply(await controller.snapshot())
        } catch {
            if Task.isCancelled { await cancelRetainedAttempt(controller: controller) }
            let snapshot = await controller.snapshot()
            if Task.isCancelled { apply(snapshot) }
            else { fail(error, snapshot: snapshot) }
        }
    }

    func cancel() {
        group?.cancel()
        deletionConfirmationID = nil
        guard phase != .signingIn, phase != .signingOut, deletionActivity != .submitting else { return }
        operation?.cancel()
        apple.cancel()
    }

    func signOut() async {
        guard operation == nil, let controller else { return }
        group?.cancel(); group = nil; clearApprovals()
        let id = UUID()
        let task = Task {
            phase = .signingOut; messageKey = nil
            do { try await controller.logout(); apply(await controller.snapshot()) }
            catch { fail(error, snapshot: await controller.snapshot()) }
        }
        operationID = id
        operation = task
        await task.value
        if operationID == id { operation = nil; operationID = nil }
    }

    private func apply(_ snapshot: AccountSessionSnapshot) {
        messageKey = nil
        if snapshot.phase == .signedIn, let controller {
            if group == nil { group = MobileAccountGroupModel(controller: controller, lifecycle: lifecycle) }
            if approvalAccountID != snapshot.identity?.accountID { clearApprovals() }
            if approvals == nil {
                let lifecycle = lifecycle
                approvals = MobileAccountApprovalModel(controller: controller, refreshAccount: {
                    _ = await lifecycle?.requestRefresh()
                })
                approvalAccountID = snapshot.identity?.accountID
            }
        } else { group?.cancel(); group = nil; clearApprovals() }
        switch snapshot.phase {
        case .signedOut, .needsSignIn: phase = .signedOut
        case .restoring, .preparingLogin, .refreshing: phase = .loading
        case .awaitingApple: phase = .awaitingApple
        case .signingIn: phase = .signingIn
        case .signedIn: phase = .signedIn
        case .signingOut: phase = .signingOut
        case .unavailable: phase = .unavailable; messageKey = "account.error.unavailable"
        case .secureStorageError: phase = .secureStorageError; messageKey = "account.error.secure-store"
        }
    }

    private func cancelRetainedAttempt(controller: AccountSessionController) async {
        guard let attemptID else { return }
        await controller.cancelLogin(attemptID: attemptID)
        self.attemptID = nil
    }

    private func clearApprovals() {
        approvals?.invalidate(); approvals = nil; approvalAccountID = nil
    }

    private func fail(_ error: Error, snapshot: AccountSessionSnapshot? = nil) {
        if let snapshot, snapshot.phase == .secureStorageError {
            phase = .secureStorageError; messageKey = "account.error.secure-store"
        } else if (error as? AccountSessionControllerError) == .secureStorage {
            phase = .secureStorageError; messageKey = "account.error.secure-store"
        } else {
            phase = .unavailable; messageKey = "account.error.unavailable"
        }
    }
}

enum MobileAccountDeletionActivity { case idle, authenticating, submitting }
