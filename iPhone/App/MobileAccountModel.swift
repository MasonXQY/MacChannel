import Foundation
import MacChannelCore
import DropMeshMobileRuntime
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
    private(set) var invitationSupported = false
    private(set) var invitationInbox: [MobileAccountInvitationItem] = []
    private(set) var invitationOutbox: [MobileAccountInvitationItem] = []
    private(set) var invitationShareURL: String?
    private(set) var invitationMessageKey: String?
    private(set) var invitationBusy = false
    var invitationLinkText = ""
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
    private func updateInvitationPresentation(_ controller: AccountSessionController) async {
        invitationSupported = await controller.supportsInvitations()
        if invitationSupported, phase == .signedIn {
            invitationMessageKey = nil
        }
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
    private var invitationOperation: Task<Void, Never>?
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
            await updateInvitationPresentation(loaded)
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
            await updateInvitationPresentation(controller)
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
        invitationOperation?.cancel()
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
            catch {
                do {
                    try await controller.discardLocalSessionAfterLogoutFailure()
                    apply(await controller.snapshot())
                    messageKey = "account.sign-out.local"
                } catch {
                    fail(error, snapshot: await controller.snapshot())
                }
            }
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
        } else {
            group?.cancel(); group = nil; clearApprovals()
            invitationSupported = false; invitationInbox = []; invitationOutbox = []
            invitationShareURL = nil; invitationMessageKey = nil; invitationLinkText = ""
        }
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

    func copyInvitationLink() async {
        guard invitationSupported, !invitationBusy, let controller else { return }
        await invitationTask { [self] in
            let existing: AccountInvitationLink?
            do {
                existing = try await controller.invitationShareLink()
            } catch AccountInvitationError.conflict {
                existing = nil
            }
            let link: AccountInvitationLink
            if let existing { link = existing }
            else { link = try await controller.rotateInvitationShareLink() }
            invitationShareURL = link.shareURL.absoluteString
            invitationMessageKey = copyInvitationURL(link.shareURL)
                ? "account.invitation.copied" : "account.invitation.copy-manual"
        }
    }

    func rotateInvitationLink() async {
        guard invitationSupported, !invitationBusy, let controller else { return }
        await invitationTask { [self] in
            let link = try await controller.rotateInvitationShareLink()
            invitationShareURL = link.shareURL.absoluteString
            invitationMessageKey = copyInvitationURL(link.shareURL)
                ? "account.invitation.copied" : "account.invitation.copy-manual"
        }
    }

    func requestConnectionFromTypedLink() async {
        guard invitationSupported, !invitationBusy, let controller else { return }
        let text = invitationLinkText
        await invitationTask { [self] in
            try await prepareInvitationAccountGroup(controller)
            let link = try AccountInvitationLink(sharedText: text)
            _ = try await controller.createInvitationRequest(link: link)
            invitationLinkText = ""
            invitationMessageKey = "account.invitation.request-sent"
            try await loadInvitations(controller)
        }
    }

    func refreshInvitations() async {
        guard invitationSupported, !invitationBusy, let controller else { return }
        await invitationTask { [self] in
            try await prepareInvitationAccountGroup(controller)
            try await loadInvitations(controller)
        }
    }

    func acceptInvitation(_ item: MobileAccountInvitationItem) async {
        guard invitationSupported, !invitationBusy, let controller else { return }
        await invitationTask { [self] in
            try await prepareInvitationAccountGroup(controller)
            _ = try await controller.acceptInvitation(requestID: item.id)
            invitationMessageKey = "account.invitation.accepted"
            try await loadInvitations(controller)
        }
    }

    func rejectInvitation(_ item: MobileAccountInvitationItem) async {
        guard invitationSupported, !invitationBusy, let controller else { return }
        await invitationTask { [self] in
            try await prepareInvitationAccountGroup(controller)
            _ = try await controller.transitionInvitation(item.checkpoint, action: .reject)
            invitationMessageKey = "account.invitation.rejected"
            try await loadInvitations(controller)
        }
    }

    func cancelInvitation(_ item: MobileAccountInvitationItem) async {
        guard invitationSupported, !invitationBusy, let controller else { return }
        await invitationTask { [self] in
            try await prepareInvitationAccountGroup(controller)
            _ = try await controller.transitionInvitation(item.checkpoint, action: .cancel)
            invitationMessageKey = "account.invitation.cancelled"
            try await loadInvitations(controller)
        }
    }

    private func prepareInvitationAccountGroup(_ controller: AccountSessionController) async throws {
        guard await controller.supportsFirstDeviceEnrollment() else { return }
        switch try await controller.discoverAccountGroup() {
        case .absent:
            let ticket = try await controller.prepareFirstDeviceJoin()
            _ = try await controller.confirmFirstDeviceJoin(attemptID: ticket)
            await group?.load()
        case .present(let metadata):
            _ = try await controller.syncGroup(groupID: metadata.groupID)
        }
    }

    private func loadInvitations(_ controller: AccountSessionController) async throws {
        let link = try? await controller.invitationShareLink()
        invitationShareURL = link?.shareURL.absoluteString
        invitationInbox = try await controller.invitationInbox().map(MobileAccountInvitationItem.init)
        invitationOutbox = try await controller.invitationOutbox().map(MobileAccountInvitationItem.init)
    }

    private func copyInvitationURL(_ url: URL) -> Bool {
        let text = url.absoluteString
        copyDisplayedInvitationLink(text)
        return true
    }

    func copyDisplayedInvitationLink(_ text: String) {
        ExplicitApprovalCodeCopy.copyInvitationLink(text)
    }

    private func invitationTask(_ action: @escaping @MainActor () async throws -> Void) async {
        guard invitationOperation == nil else { return }
        invitationBusy = true; invitationMessageKey = nil
        let task = Task { [self] in
            do { try await action() }
            catch is CancellationError {}
            catch AccountInvitationLinkError.invalidLink { invitationMessageKey = "account.invitation.invalid-link" }
            catch AccountSessionControllerError.needsSignIn { invitationMessageKey = "account.invitation.signed-out" }
            catch AccountSessionControllerError.secureStorage { invitationMessageKey = "account.error.secure-store" }
            catch AccountFirstDeviceEnrollmentError.approvalRequired { invitationMessageKey = "account.invitation.approval-required" }
            catch AccountFirstDeviceEnrollmentError.secureStorage { invitationMessageKey = "account.error.secure-store" }
            catch AccountInvitationError.conflict { invitationMessageKey = "account.invitation.setup-required" }
            catch AccountServiceError.unavailable { invitationMessageKey = "account.invitation.unavailable" }
            catch { invitationMessageKey = "account.invitation.error" }
            invitationBusy = false; invitationOperation = nil
        }
        invitationOperation = task
        await task.value
    }
}

enum MobileAccountDeletionActivity { case idle, authenticating, submitting }

struct MobileAccountInvitationItem: Identifiable, Equatable {
    let id: String
    let titleKey: String
    let subtitleKey: String
    let state: AccountInvitationState
    let checkpoint: AccountInvitationCheckpoint

    init(_ record: AccountInvitationRecord) {
        id = record.checkpoint.requestID
        state = record.checkpoint.state
        checkpoint = record.checkpoint
        titleKey = record.request.request.sender.accountID == record.pair?.target.accountID
            ? "account.invitation.sent-title" : "account.invitation.received-title"
        switch record.checkpoint.state {
        case .requested: subtitleKey = "account.invitation.state.requested"
        case .selected: subtitleKey = "account.invitation.state.selected"
        case .active: subtitleKey = "account.invitation.state.active"
        case .rejected: subtitleKey = "account.invitation.state.rejected"
        case .cancelled: subtitleKey = "account.invitation.state.cancelled"
        case .expired: subtitleKey = "account.invitation.state.expired"
        case .revoked: subtitleKey = "account.invitation.state.revoked"
        }
    }

    var canAccept: Bool { state == .requested || state == .selected }
    var canReject: Bool { state == .requested || state == .selected }
    var canCancel: Bool { state == .requested || state == .selected }
}
