import MacChannelCore
import SwiftUI
import UIKit

/// Synthetic account dependencies; renders the shipping Settings and account views.
struct MobileAccountEvidenceHost: View {
    @State private var settings: MobileSettingsModel
    private let dark = ProcessInfo.processInfo.arguments.contains("-account-evidence-dark")

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let state = arguments.firstIndex(of: "-account-evidence-state")
            .flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "signed-out"
        let loader: @Sendable () async throws -> AccountSessionController? = {
            if state.hasPrefix("group-") {
                let fixture = try AccountGroupEvidenceFixture()
                switch state {
                case "group-joined": try await fixture.seed([fixture.event()], pinned: true)
                case "group-approval":
                    try await fixture.seed([fixture.event(identity: AccountGroupEvidenceFixture.syntheticIdentity())])
                case "group-error": await fixture.service.fail("discover")
                case "group-removed":
                    let anchor = try fixture.event()
                    try await fixture.seed([anchor, fixture.event(previous: anchor)], pinned: true)
                default: break
                }
                return fixture.controller()
            }
            if state == "disabled" { return nil }
            if state == "unavailable" { throw AccountSessionControllerError.unavailable }
            if state == "storage-error" { throw AccountSessionControllerError.secureStorage }
            let identity = AccountSessionIdentity(accountID: UUID(), sessionID: UUID(),
                deviceID: UUID(), audience: "com.example.account-evidence")
            let binding = try AccountSessionBinding(deviceID: identity.deviceID,
                audience: identity.audience, origin: URL(string: "https://account-evidence.invalid")!)
            let service = AccountEvidenceService(identity: identity)
            let tokens = AccountSessionTokens(identity: identity,
                accessToken: String(repeating: "A", count: 43),
                refreshToken: String(repeating: "B", count: 42) + "A",
                accessExpiresAt: Date().addingTimeInterval(600),
                refreshExpiresAt: Date().addingTimeInterval(1200))
            let record = state == "signed-in" ? try AccountStoredSession(binding: binding, tokens: tokens) : nil
            return AccountSessionController(service: service,
                storage: AccountEvidenceStorage(record: record), binding: binding)
        }
        _settings = State(initialValue: MobileSettingsModel(session: InertMobileSession(),
            accountAuthorizer: AccountEvidenceAuthorizer(), loadAccountController: loader))
    }

    var body: some View {
        NavigationStack { MobileSettingsView(model: settings) }
            .preferredColorScheme(dark ? .dark : .light)
    }
}

private actor AccountEvidenceStorage: AccountSessionStorage {
    var record: AccountStoredSession?
    init(record: AccountStoredSession?) { self.record = record }
    func load() -> AccountStoredSession? { record }
    func save(_ record: AccountStoredSession) { self.record = record }
    func remove() { record = nil }
}

private struct AccountEvidenceService: AccountSessionService {
    let identity: AccountSessionIdentity
    func challenge() -> AccountLoginChallenge {
        .init(challengeID: String(repeating: "A", count: 43), nonce: String(repeating: "B", count: 42) + "A",
              expiresAt: Date().addingTimeInterval(60))
    }
    func complete(challengeID: String, code: String, identityToken: String) throws -> AccountSessionTokens {
        throw AccountServiceError.unavailable
    }
    func status(accessToken: String) -> AccountSessionIdentity { identity }
    func refresh(refreshToken: String) throws -> AccountSessionTokens { throw AccountServiceError.unavailable }
    func logout(accessToken: String) {}
}

@MainActor
private final class AccountEvidenceAuthorizer: MobileAppleAuthorizing {
    func authorize(attempt: AccountLoginAttempt, anchor: UIWindow) throws -> MobileAppleCredential {
        // No real Apple prompt/account is touched by visual acceptance.
        throw CancellationError()
    }
    func cancel() {}
}
