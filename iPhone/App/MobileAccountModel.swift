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
    private let loadController: @Sendable () async throws -> AccountSessionController?
    private let apple: any MobileAppleAuthorizing
    private var controller: AccountSessionController?
    private var operation: Task<Void, Never>?
    private var operationID: UUID?
    private var attemptID: UUID?

    init(loadController: @escaping @Sendable () async throws -> AccountSessionController?,
         apple: any MobileAppleAuthorizing) {
        self.loadController = loadController
        self.apple = apple
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
        phase = .loading; messageKey = nil
        do {
            let loaded = try await loadController()
            guard let loaded else { controller = nil; phase = .disabled; return }
            controller = loaded
            await loaded.restore()
            apply(await loaded.snapshot())
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
            try Task.checkCancellation()
            attemptID = attempt.id
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
            apply(await controller.snapshot())
        } catch is CancellationError {
            apply(await controller.snapshot())
        } catch {
            let snapshot = await controller.snapshot()
            if Task.isCancelled { apply(snapshot) }
            else { fail(error, snapshot: snapshot) }
        }
    }

    func cancel() {
        guard phase != .signingIn, phase != .signingOut else { return }
        operation?.cancel()
        apple.cancel()
        if let attemptID, let controller { Task { await controller.cancelLogin(attemptID: attemptID) } }
        attemptID = nil
    }

    func signOut() async {
        guard operation == nil, let controller else { return }
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
