import AuthenticationServices
import MacChannelCore
import SwiftUI

struct MobileAccountView: View {
    let model: MobileAccountModel
    @State private var confirmsSignOut = false
    @State private var deletionWindow: UIWindow?
    @State private var confirmationID: UUID?
    @State private var invitationLocalMessageKey: String?
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
            if model.phase == .signedIn, model.invitationSupported {
                invitationSection
            }
            if model.deletionSupported, model.phase == .signedIn || model.deletionStatus != nil {
                deletionSection
            }
        }
        .background(AccountDeletionWindowAnchor(window: $deletionWindow).frame(width: 0, height: 0))
        .navigationTitle("account.title")
        .task {
            if model.phase == .loading || model.phase == .disabled {
                await model.load()
            }
        }
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

    private var invitationSection: some View {
        Section("account.invitation.title") {
            if model.invitationBusy {
                ProgressView("account.invitation.working")
            }
            Button("account.invitation.copy-link") { Task { await model.copyInvitationLink() } }
                .accessibilityIdentifier("account-invitation-copy")
            if let shareURL = model.invitationShareURL {
                VStack(alignment: .leading, spacing: 8) {
                    Text("account.invitation.current-link")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(shareURL)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .accessibilityIdentifier("account-invitation-share-url")
                    Button("account.invitation.copy-displayed-link") {
                        invitationLocalMessageKey = copyDisplayedInvitationLink(shareURL)
                    }
                    .accessibilityIdentifier("account-invitation-copy-displayed")
                    if let url = URL(string: shareURL) {
                        ShareLink("account.invitation.share-link", item: url)
                            .accessibilityIdentifier("account-invitation-share")
                    }
                }
            }
            Button("account.invitation.rotate-link") { Task { await model.rotateInvitationLink() } }
                .accessibilityIdentifier("account-invitation-rotate")
            TextField("account.invitation.paste-placeholder", text: Binding(
                get: { model.invitationLinkText },
                set: { model.invitationLinkText = $0 }))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("account-invitation-link")
            Button("account.invitation.request") { Task { await model.requestConnectionFromTypedLink() } }
                .disabled(model.invitationLinkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("account-invitation-request")
            if !model.invitationInbox.isEmpty {
                ForEach(model.invitationInbox) { item in
                    invitationRow(item, incoming: true)
                }
            }
            if !model.invitationOutbox.isEmpty {
                ForEach(model.invitationOutbox) { item in
                    invitationRow(item, incoming: false)
                }
            }
            Button("account.group.refresh") { Task { await model.refreshInvitations() } }
                .accessibilityIdentifier("account-invitation-refresh")
            if let key = model.invitationMessageKey {
                Text(LocalizedStringKey(key)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("account-invitation-status")
            }
            if let key = invitationLocalMessageKey {
                Text(LocalizedStringKey(key)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("account-invitation-local-status")
            }
        }
    }

    private func copyDisplayedInvitationLink(_ text: String) -> String {
        model.copyDisplayedInvitationLink(text)
        return "account.invitation.copied"
    }

    private func invitationRow(_ item: MobileAccountInvitationItem, incoming: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(incoming ? "account.invitation.received-title" : "account.invitation.sent-title"))
            Text(LocalizedStringKey(item.subtitleKey)).foregroundStyle(.secondary)
            HStack {
                if incoming, item.canAccept {
                    Button("account.invitation.accept") { Task { await model.acceptInvitation(item) } }
                }
                if incoming, item.canReject {
                    Button("account.invitation.reject", role: .destructive) { Task { await model.rejectInvitation(item) } }
                }
                if !incoming, item.canCancel {
                    Button("account.invitation.cancel", role: .destructive) { Task { await model.cancelInvitation(item) } }
                }
            }
            .buttonStyle(.borderless)
        }
        .accessibilityIdentifier(incoming ? "account-invitation-inbox-row" : "account-invitation-outbox-row")
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
