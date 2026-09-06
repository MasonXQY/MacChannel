import AppKit
import Foundation
import MacChannelCore

@MainActor
final class LocalNetworkActivationStore {
    static let key = "appStoreLocalNetworkActivated"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var isActivated: Bool { defaults.bool(forKey: Self.key) }
    func activate() { defaults.set(true, forKey: Self.key) }
}

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
    private var browserState: BonjourLifecycleState = .stopped
    private var advertiserState: BonjourLifecycleState = .stopped
    private var observationTasks: [Task<Void, Never>] = []
    private var observationGeneration: UInt = 0

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
        browserState = browser
        advertiserState = advertiser
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

    func observe(
        browser: AsyncStream<BonjourLifecycleState>,
        advertiser: AsyncStream<BonjourLifecycleState>
    ) {
        invalidateObservation()
        observationGeneration &+= 1
        let generation = observationGeneration
        observationTasks = [
            Task { [weak self] in
                for await state in browser {
                    guard let self, self.observationGeneration == generation else { return }
                    self.update(browser: state, advertiser: self.advertiserState)
                }
            },
            Task { [weak self] in
                for await state in advertiser {
                    guard let self, self.observationGeneration == generation else { return }
                    self.update(browser: self.browserState, advertiser: state)
                }
            },
        ]
    }

    func invalidateObservation() {
        observationGeneration &+= 1
        observationTasks.forEach { $0.cancel() }
        observationTasks.removeAll()
    }
}
