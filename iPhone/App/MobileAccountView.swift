import AuthenticationServices
import SwiftUI
import UIKit

struct MobileAccountView: View {
    let model: MobileAccountModel
    @State private var confirmsSignOut = false
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
                MobileAccountGroupSection(model: group)
            }
        }
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
