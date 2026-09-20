import SwiftUI

struct MobileAccountGroupSection: View {
    let model: MobileAccountGroupModel

    var body: some View {
        Group {
            if model.phase != .disabled {
                Section("account.group.title") {
                    content
                    if let key = model.messageKey {
                        Text(LocalizedStringKey(key)).foregroundStyle(.secondary)
                            .accessibilityIdentifier("account-group-error")
                    }
                }
            }
        }
        .confirmationDialog("account.group.confirm.title", isPresented: confirmationPresented,
                            titleVisibility: .visible, presenting: model.confirmationID) { attemptID in
            Button("account.group.join") { model.confirmJoin(attemptID: attemptID) }
                .accessibilityIdentifier("account-group-confirm")
            Button("account.cancel", role: .cancel) { model.dismissConfirmation(attemptID: attemptID) }
                .accessibilityIdentifier("account-group-cancel")
        } message: { _ in
            Text("account.group.confirm.message")
        }
        .textCase(nil)
    }

    private var confirmationPresented: Binding<Bool> {
        let attemptID = model.confirmationID
        return Binding(get: { model.phase == .awaitingConfirmation }, set: { presented in
            if !presented, let attemptID {
                // Schedule passive dismissal separately from synchronous acceptance,
                // scoped to this presentation. Native UI tests cover callback ordering.
                Task { @MainActor in
                    await Task.yield()
                    model.dismissConfirmation(attemptID: attemptID)
                }
            }
        })
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .disabled: EmptyView()
        case .idle, .checking, .preparing, .joining:
            ProgressView(LocalizedStringKey(model.phase == .joining ? "account.group.joining" : "account.group.checking"))
                .frame(minHeight: 44).accessibilityIdentifier("account-group-progress")
        case .ready, .awaitingConfirmation:
            action("account.group.join", id: "account-group-join") { await model.prepareJoin() }
                .disabled(model.phase == .awaitingConfirmation)
        case .joined:
            Text("account.group.joined").accessibilityIdentifier("account-group-joined")
            refresh
        case .approvalRequired:
            Text("account.group.approval-required").accessibilityIdentifier("account-group-approval")
            refresh
        case .removed:
            Text("account.group.removed").accessibilityIdentifier("account-group-removed")
            refresh
        case .unavailable, .secureStorageError:
            action("account.retry", id: "account-group-retry") { await model.load() }
        }
    }

    private var refresh: some View {
        action("account.group.refresh", id: "account-group-refresh") { await model.load() }
    }

    private func action(_ title: String, id: String, perform: @escaping @MainActor () async -> Void) -> some View {
        Button(LocalizedStringKey(title)) { Task { await perform() } }
            .frame(minHeight: 44).disabled(model.isBusy).accessibilityIdentifier(id)
    }
}
