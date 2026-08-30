import AppKit
import Foundation

@MainActor
public enum MacChannelApplication {
    public static func run() {
        let application = NSApplication.shared
        let mode = AppLaunchMode.resolve()
        let delegate: MacChannelApplicationDelegate
        switch mode {
        case .localShell:
            delegate = MacChannelApplicationDelegate(
                initialContainer: .localShell(),
                initialStatus: .offline("本地测试模式；网络服务未启动。"),
                runtimeHost: nil
            )
        case .production:
            let builder: any AppRuntimeBuilding
            do {
                builder = try ProductionAppRuntimeBuilder()
            } catch {
                builder = FailedProductionRuntimeBuilder()
            }
            delegate = MacChannelApplicationDelegate(
                initialContainer: .loadingShell(),
                initialStatus: .loading,
                runtimeHost: AppRuntimeHost(builder: builder)
            )
        }
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

@MainActor
private final class MacChannelApplicationDelegate: NSObject, NSApplicationDelegate {
    private var container: AppContainer
    private let initialStatus: AppRuntimeStatus
    private let runtimeHost: AppRuntimeHost?
    private var statusItemController: StatusItemController?
    private var surfaceController: AppSurfaceController?
    private var bootstrapTask: Task<Void, Never>?
    private var terminationPending = false
    private var runtimeShutdownComplete = false
    private var productionLaunchDiagnostics: ProductionLaunchDiagnostics?

    init(
        initialContainer: AppContainer,
        initialStatus: AppRuntimeStatus,
        runtimeHost: AppRuntimeHost?
    ) {
        container = initialContainer
        self.initialStatus = initialStatus
        self.runtimeHost = runtimeHost
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        install(container, status: initialStatus)
        guard let runtimeHost else {
            completeLaunchSmokeTestIfRequested()
            return
        }
        runtimeHost.onChange = { [weak self] status, container in
            guard let self else { return }
            if let container {
                self.container = container
                self.install(container, status: status)
                self.completeProductionLaunchTestIfRequested(status: status, container: container)
            } else {
                self.statusItemController?.setRuntimeStatus(status)
            }
        }
        bootstrapTask = Task { await runtimeHost.bootstrap() }
    }

    private func install(_ container: AppContainer, status: AppRuntimeStatus) {
        surfaceController?.invalidate()
        statusItemController?.invalidate()
        let statusController = StatusItemController(
            deviceDirectory: container.deviceDirectory,
            transferCoordinator: container.transferCoordinator
        )
        let surfaces = AppSurfaceController(
            transferService: NativeTransferSurfaceService(
                coordinator: container.transferCoordinator
            ),
            pairingService: container.pairingSurfaceService,
            settingsService: container.settingsSurfaceService,
            directorySelector: container.directorySelector
        )
        surfaces.bind(to: statusController)
        statusController.setRuntimeStatus(status)
        surfaces.observe(container.deviceDirectory)
        if let transferSnapshots = container.transferSnapshots {
            surfaces.observeTransferSnapshots(transferSnapshots)
        }
        if let pairingStates = container.pairingStates {
            surfaces.observePairingStates(pairingStates)
        }
        if let settingsSnapshots = container.settingsSnapshots {
            surfaces.observeSettings(settingsSnapshots)
        }
        if let transferHistory = container.transferHistory {
            surfaces.observeTransferHistory(transferHistory)
        }
        statusItemController = statusController
        surfaceController = surfaces
    }

    func applicationWillTerminate(_ notification: Notification) {
        bootstrapTask?.cancel()
        surfaceController?.invalidate()
        statusItemController?.invalidate()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let runtimeHost else { return .terminateNow }
        guard !runtimeShutdownComplete else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        bootstrapTask?.cancel()
        Task {
            await runtimeHost.shutdown()
            self.finishProductionLaunchTestIfRequested()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func completeLaunchSmokeTestIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--smoke-test"),
              arguments.indices.contains(flag + 1),
              NSApplication.shared.activationPolicy() == .accessory,
              statusItemController != nil
        else { return }

        let marker = URL(fileURLWithPath: arguments[flag + 1])
        try? Data("ready accessory\n".utf8).write(to: marker, options: .atomic)
        DispatchQueue.main.async {
            NSApplication.shared.terminate(nil)
        }
    }

    private func completeProductionLaunchTestIfRequested(
        status: AppRuntimeStatus,
        container: AppContainer
    ) {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--production-launch-test"),
              arguments.indices.contains(flag + 1),
              container.runtimeIdentityID != nil,
              status != .loading,
              NSApplication.shared.activationPolicy() == .accessory,
              statusItemController != nil
        else { return }
        let statusName: String
        switch status {
        case .ready: statusName = "ready"
        case .offline: statusName = "offline"
        case .loading, .error: return
        }
        productionLaunchDiagnostics = ProductionLaunchDiagnostics(
            marker: URL(fileURLWithPath: arguments[flag + 1]),
            status: statusName,
            identityID: container.runtimeIdentityID!.rawValue.uuidString.lowercased(),
            settingsAvailable: container.settingsSurfaceService.isAvailable,
            statusInstalled: statusItemController != nil
        )
        guard let runtimeHost else { return }
        Task {
            await runtimeHost.shutdown()
            self.runtimeShutdownComplete = true
            self.finishProductionLaunchTestIfRequested()
            NSApplication.shared.terminate(nil)
        }
    }

    private func finishProductionLaunchTestIfRequested() {
        guard let diagnostics = productionLaunchDiagnostics else { return }
        let object: [String: Any] = [
            "identityID": diagnostics.identityID,
            "runtimeStatus": diagnostics.status,
            "settingsAvailable": diagnostics.settingsAvailable,
            "shutdownComplete": true,
            "statusInstalled": diagnostics.statusInstalled,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            try? data.write(to: diagnostics.marker, options: .atomic)
        }
    }
}

private struct ProductionLaunchDiagnostics {
    let marker: URL
    let status: String
    let identityID: String
    let settingsAvailable: Bool
    let statusInstalled: Bool
}

@MainActor
private final class FailedProductionRuntimeBuilder: AppRuntimeBuilding {
    func build() async throws -> AppRuntimeLaunch {
        throw ProductionRuntimeError.insecureRendezvousURL
    }
}
