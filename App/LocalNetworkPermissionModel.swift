import AppKit
import Foundation
import MacChannelCore

@MainActor
final class LocalNetworkPermissionModel: ObservableObject {
    enum Capability: Equatable {
        case available
        case unavailable
    }

    @Published private(set) var capability: Capability = .available
    private let retryHandler: () -> Void
    private let stateProvider: (() -> (BonjourLifecycleState, BonjourLifecycleState))?
    private let openURL: (URL) -> Bool

    init(
        retry: @escaping () -> Void = {},
        stateProvider: (() -> (BonjourLifecycleState, BonjourLifecycleState))? = nil,
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        retryHandler = retry
        self.stateProvider = stateProvider
        self.openURL = openURL
    }

    var guidanceText: String? {
        capability == .unavailable
            ? "局域网访问未允许。公网连接、设置和历史仍可使用。"
            : nil
    }

    func update(browser: BonjourLifecycleState, advertiser: BonjourLifecycleState) {
        capability = [browser, advertiser].contains { state in
            if case .failed("policy_denied") = state { return true }
            return false
        } ? .unavailable : .available
    }

    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") else { return }
        _ = openURL(url)
    }

    func retry() {
        retryHandler()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.refresh()
        }
    }

    func refresh() {
        guard let state = stateProvider?() else { return }
        update(browser: state.0, advertiser: state.1)
    }
}
