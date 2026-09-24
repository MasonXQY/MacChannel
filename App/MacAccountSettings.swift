import AppKit
import MacChannelCore
import SwiftUI

@MainActor
final class MacAccountSettingsModel: ObservableObject {
    @Published private(set) var snapshot = AccountSessionSnapshot(phase: .signedOut, identity: nil)
    @Published private(set) var isWorking = false
    @Published private(set) var messageKey: LocalizedKey?

    private let controller: AccountSessionController?
    private var observer: Task<Void, Never>?
    private var login: Task<Void, Never>?

    init(controller: AccountSessionController?) {
        self.controller = controller
        guard let controller else { return }
        observer = Task { [weak self] in
            let changes = await controller.runtimeChanges()
            await self?.refresh()
            for await _ in changes {
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    deinit {
        observer?.cancel()
        login?.cancel()
    }

    var isAvailable: Bool { controller != nil }

    func signIn() {
        guard let controller, login == nil else { return }
        messageKey = nil
        isWorking = true
        login = Task { [weak self] in
            guard let self else { return }
            var handoff: AccountWebLoginAttempt?
            defer {
                isWorking = false
                login = nil
            }
            do {
                let value = try await controller.beginWebLogin()
                handoff = value
                guard NSWorkspace.shared.open(value.authorizationURL) else {
                    await controller.cancelWebLogin(attemptID: value.attemptID)
                    messageKey = .accountBrowserFailed
                    await refresh()
                    return
                }
                messageKey = .accountFinishInBrowser
                while !Task.isCancelled, Date() < value.expiresAt {
                    try await Task.sleep(for: .seconds(1))
                    do {
                        if try await controller.pollWebLogin(attemptID: value.attemptID) != nil {
                            messageKey = .accountSignedInHelp
                            await refresh()
                            return
                        }
                    } catch AccountSessionControllerError.unavailable {
                        continue
                    }
                }
                guard !Task.isCancelled else { throw CancellationError() }
                await controller.cancelWebLogin(attemptID: value.attemptID)
                messageKey = .accountLoginExpired
                await refresh()
            } catch is CancellationError {
                if let handoff { await controller.cancelWebLogin(attemptID: handoff.attemptID) }
                await refresh()
            } catch {
                messageKey = .accountLoginFailed
                await refresh()
            }
        }
    }

    func cancelSignIn() {
        login?.cancel()
    }

    func signOut() {
        guard let controller, !isWorking else { return }
        isWorking = true
        messageKey = nil
        Task { [weak self] in
            guard let self else { return }
            defer { isWorking = false }
            do {
                try await controller.logout()
                await refresh()
            } catch {
                messageKey = .accountSignOutFailed
                await refresh()
            }
        }
    }

    private func refresh() async {
        guard let controller else { return }
        snapshot = await controller.snapshot()
    }
}

struct MacAccountSettingsSection: View {
    @ObservedObject var model: MacAccountSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.isAvailable {
                Text(L10n.text(.accountUnavailable))
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: statusIcon)
                        .foregroundStyle(statusColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(statusTitle)
                            .font(.body.weight(.medium))
                        Text(L10n.text(statusHelpKey))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    action
                }
                .frame(minHeight: 48)
                if let messageKey = model.messageKey {
                    Text(L10n.text(messageKey))
                        .font(.caption)
                        .foregroundStyle(messageKey == .accountSignedInHelp ? Color.secondary : Color.orange)
                }
            }
        }
    }

    @ViewBuilder private var action: some View {
        switch model.snapshot.phase {
        case .signedIn, .refreshing:
            Button(L10n.text(.accountSignOut), action: model.signOut)
                .disabled(model.isWorking)
        case .preparingLogin, .awaitingApple, .signingIn:
            Button(L10n.text(.commonCancel), action: model.cancelSignIn)
        default:
            Button(L10n.text(.accountSignIn), action: model.signIn)
                .disabled(model.isWorking)
        }
    }

    private var statusTitle: String {
        switch model.snapshot.phase {
        case .signedIn, .refreshing: L10n.text(.accountSignedIn)
        case .preparingLogin, .awaitingApple, .signingIn: L10n.text(.accountSigningIn)
        case .secureStorageError: L10n.text(.accountStorageError)
        case .unavailable: L10n.text(.accountUnavailable)
        default: L10n.text(.accountSignedOut)
        }
    }

    private var statusHelpKey: LocalizedKey {
        switch model.snapshot.phase {
        case .signedIn, .refreshing: .accountSignedInHelp
        case .preparingLogin, .awaitingApple, .signingIn: .accountFinishInBrowser
        default: .accountSignedOutHelp
        }
    }

    private var statusIcon: String {
        switch model.snapshot.phase {
        case .signedIn, .refreshing: "person.crop.circle.badge.checkmark"
        case .preparingLogin, .awaitingApple, .signingIn: "safari"
        case .secureStorageError, .unavailable: "exclamationmark.triangle"
        default: "person.crop.circle"
        }
    }

    private var statusColor: Color {
        switch model.snapshot.phase {
        case .signedIn, .refreshing: .green
        case .secureStorageError, .unavailable: .orange
        default: .secondary
        }
    }
}
