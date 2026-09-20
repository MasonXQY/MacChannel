import AuthenticationServices
import MacChannelCore
import SwiftUI
import UIKit

struct MobileAccountView: View {
    let model: MobileAccountModel
    @State private var confirmsSignOut = false
    @State private var deletionWindow: UIWindow?
    @State private var confirmationID: UUID?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        List {
            Section {
                Text("account.explanation.optional").foregroundStyle(.secondary)
                Text("account.explanation.not-connected").foregroundStyle(.secondary)
            }
            Section {
                content
                if let messageKey = model.messageKey {
                    Text(LocalizedStringKey(messageKey)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("account-status")
                }
            }
            if model.phase == .signedIn, let group = model.group {
                MobileAccountGroupSection(model: group, approvals: model.approvals)
            }
            if model.deletionSupported, model.phase == .signedIn || model.deletionStatus != nil {
                deletionSection
            }
        }
        .background(AccountDeletionWindowAnchor(window: $deletionWindow).frame(width: 0, height: 0))
        .navigationTitle("account.title")
        .task { if model.phase == .loading { await model.load() } }
        .task(id: model.group.map(ObjectIdentifier.init)) {
            if model.phase == .signedIn, let group = model.group { await group.load() }
        }
        .onDisappear { model.cancel() }
        .confirmationDialog("account.sign-out.confirm.title", isPresented: $confirmsSignOut,
                            titleVisibility: .visible) {
            Button("account.sign-out", role: .destructive) { Task { await model.signOut() } }
                .accessibilityIdentifier("account-sign-out-confirm")
            Button("account.cancel", role: .cancel) {}
        }
        .confirmationDialog("account.delete.confirm.title", isPresented: Binding(
            get: { confirmationID != nil }, set: { if !$0 { confirmationID = nil } }), titleVisibility: .visible) {
            Button("account.delete.confirm.action", role: .destructive) {
                guard let id = model.deletionConfirmationID else { return }
                confirmationID = nil
                Task { await model.confirmDeletion(id: id, anchor: deletionWindow) }
            }
            .accessibilityIdentifier("account-delete-confirm")
            Button("account.cancel", role: .cancel) { model.cancelDeletionConfirmation() }
        } message: { Text("account.delete.confirm.message") }
    }

    private func requestDeletion() {
        model.requestDeletionConfirmation()
        confirmationID = model.deletionConfirmationID
    }

    private var deletionSection: some View {
        Section("account.delete.title") {
            if model.deletionActivity != .idle {
                ProgressView(model.deletionActivity == .authenticating ? "account.delete.verifying" : "account.delete.submitting")
                if model.deletionActivity == .authenticating {
                    Button("account.cancel") { model.cancel() }
                }
            } else {
                if let status = model.deletionStatus {
                    Text(LocalizedStringKey(deletionStatusKey(status)))
                        .accessibilityIdentifier("account-delete-status")
                    if status == .completedManualRevocationRequired {
                        Link("account.delete.manual-help", destination: URL(string: "https://account.apple.com")!)
                            .accessibilityIdentifier("account-delete-manual-help")
                    }
                    if !status.isCompleted || model.phase == .secureStorageError {
                        Button("account.delete.check-status") { Task { await model.refreshDeletion() } }
                    }
                    if !status.isCompleted {
                        Button("account.delete.retry", role: .destructive, action: requestDeletion)
                    }
                }
                if model.phase == .signedIn, model.deletionStatus == nil || model.deletionStatus?.isCompleted == true {
                    Button("account.delete.action", role: .destructive, action: requestDeletion)
                        .accessibilityIdentifier("account-delete")
                }
            }
            if let key = model.deletionMessageKey {
                Text(LocalizedStringKey(key)).foregroundStyle(.secondary)
            }
        }
    }

    private func deletionStatusKey(_ status: MacChannelCore.AccountDeletionStatus) -> String {
        switch status {
        case .submitting: "account.delete.uncertain"
        case .pending: "account.delete.pending"
        case .retrying: "account.delete.retrying"
        case .completed: "account.delete.completed"
        case .completedManualRevocationRequired: "account.delete.manual-required"
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .signedIn:
            Text("account.status.signed-in").accessibilityIdentifier("account-status")
            Button("account.sign-out", role: .destructive) { confirmsSignOut = true }
                .accessibilityIdentifier("account-sign-out")
        case .unavailable, .secureStorageError:
            Button("account.retry") { Task { await model.load() } }
                .frame(minHeight: 44).accessibilityIdentifier("account-retry")
        case .loading, .awaitingApple, .signingIn, .signingOut:
            ProgressView().frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("account-status")
            if model.phase == .awaitingApple {
                Button("account.cancel") { model.cancel() }.frame(minHeight: 44)
            }
        case .signedOut:
            NativeAppleSignInButton(model: model, colorScheme: colorScheme)
                .id(colorScheme)
                .frame(minHeight: 44).accessibilityIdentifier("account-sign-in")
        case .disabled:
            EmptyView()
        }
    }
}

private struct AccountDeletionWindowAnchor: UIViewRepresentable {
    @Binding var window: UIWindow?
    func makeUIView(context: Context) -> Anchor {
        let view = Anchor(); view.changed = { window = $0 }; return view
    }
    func updateUIView(_ view: Anchor, context: Context) { view.changed = { window = $0 } }
    final class Anchor: UIView {
        var changed: ((UIWindow?) -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); changed?(window) }
    }
}

private struct NativeAppleSignInButton: UIViewRepresentable {
    let model: MobileAccountModel
    let colorScheme: ColorScheme
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(type: .signIn,
            style: colorScheme == .dark ? .white : .black)
        button.addTarget(context.coordinator, action: #selector(Coordinator.signIn(_:)), for: .touchUpInside)
        button.accessibilityLabel = String(localized: "account.sign-in.accessibility")
        return button
    }
    func updateUIView(_ view: ASAuthorizationAppleIDButton, context: Context) {}
    @MainActor final class Coordinator: NSObject {
        let model: MobileAccountModel
        init(model: MobileAccountModel) { self.model = model }
        @objc func signIn(_ sender: UIView) { Task { await model.signIn(anchor: sender.window) } }
    }
}
