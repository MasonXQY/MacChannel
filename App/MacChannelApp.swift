import AppKit
import Foundation
import MacChannelCore
import Network

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
protocol SoftwareUpdateLaunchControlling: AnyObject {
    func observeTransfers(
        _ snapshots: @escaping @Sendable () async -> AsyncStream<[TransferSnapshot]>,
        onReady: @escaping @MainActor () -> Void
    )
    func start()
}

extension SparkleUpdateController: SoftwareUpdateLaunchControlling {}

@MainActor
final class SoftwareUpdateLaunchCoordinator {
    typealias TransferSnapshots = @Sendable () async -> AsyncStream<[TransferSnapshot]>

    private let controller: any SoftwareUpdateLaunchControlling
    private var hasStarted = false

    init(controller: any SoftwareUpdateLaunchControlling) {
        self.controller = controller
    }

    func prepare(
        transfers: TransferSnapshots?,
        afterStart: @escaping @MainActor () -> Void = {}
    ) {
        controller.observeTransfers(transfers ?? Self.knownEmptyTransfers) { [weak self] in
            guard let self else { return }
            if !hasStarted {
                hasStarted = true
                controller.start()
            }
            afterStart()
        }
    }

    private static func knownEmptyTransfers() async -> AsyncStream<[TransferSnapshot]> {
        AsyncStream { continuation in
            continuation.yield([])
            continuation.finish()
        }
    }
}

@MainActor
final class MacChannelApplicationDelegate: NSObject, NSApplicationDelegate {
    private var container: AppContainer
    private let initialStatus: AppRuntimeStatus
    private let runtimeHost: AppRuntimeHost?
    private var statusItemController: StatusItemController?
    private var surfaceController: AppSurfaceController?
    private var bootstrapTask: Task<Void, Never>?
    private var terminationPending = false
    private var runtimeShutdownComplete = false
    private var productionLaunchDiagnostics: ProductionLaunchDiagnostics?
    private var networkMonitor: NWPathMonitor?
    private var networkWasAvailable = false
    private let updateController = SparkleUpdateController()
    private lazy var updateLaunch = SoftwareUpdateLaunchCoordinator(controller: updateController)
    private let receiveNotificationController: ReceiveNotificationController
    private let statusItemControllerFactory: (AppContainer) -> StatusItemController
    private var receiveEventTask: Task<Void, Never>?
    private var pendingReceiveEventDrain: ReceiveEventDrain?
    private var receiveEventDrainGeneration = 0
    private var containerReplacementGeneration = 0

    private struct ReceiveEventDrain {
        let generation: Int
        let task: Task<Void, Never>
    }

    var hasUnreadReceive: Bool { statusItemController?.hasUnreadReceive ?? false }

    init(
        initialContainer: AppContainer,
        initialStatus: AppRuntimeStatus,
        runtimeHost: AppRuntimeHost?,
        receiveNotificationController: ReceiveNotificationController = ReceiveNotificationController(),
        statusItemControllerFactory: @escaping (AppContainer) -> StatusItemController = { container in
            StatusItemController(
                deviceDirectory: container.deviceDirectory,
                transferCoordinator: container.transferCoordinator
            )
        }
    ) {
        container = initialContainer
        self.initialStatus = initialStatus
        self.runtimeHost = runtimeHost
        self.receiveNotificationController = receiveNotificationController
        self.statusItemControllerFactory = statusItemControllerFactory
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        install(container, status: initialStatus)
        Task { [weak self] in
            await self?.receiveNotificationController.prepare()
        }
        if let runtimeHost {
            runtimeHost.onChange = { [weak self] status, container in
                guard let self else { return }
                if let container {
                    containerReplacementGeneration += 1
                    let generation = containerReplacementGeneration
                    Task { [weak self] in
                        guard let self else { return }
                        let installed = await self.replace(
                            container,
                            status: status,
                            generation: generation
                        )
                        guard installed else { return }
                        self.updateLaunch.prepare(transfers: container.transferSnapshots) { [weak self] in
                            self?.completeProductionLaunchTestIfRequested(
                                status: status,
                                container: container
                            )
                        }
                    }
                } else {
                    self.statusItemController?.setRuntimeStatus(status)
                    self.surfaceController?.updateRuntimeStatus(status)
                    if case .startupError = status {
                        self.updateLaunch.prepare(transfers: nil)
                    }
                }
            }
            bootstrapTask = Task { await runtimeHost.bootstrap() }
            NSWorkspace.shared.notificationCenter.addObserver(
                self,
                selector: #selector(workspaceDidWake),
                name: NSWorkspace.didWakeNotification,
                object: nil
            )
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                guard path.status == .satisfied else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let shouldReconnect = !self.networkWasAvailable
                    self.networkWasAvailable = true
                    if shouldReconnect { await runtimeHost.reconnectPublicService() }
                }
            }
            monitor.start(queue: DispatchQueue(label: "app.macchannel.network-monitor"))
            networkMonitor = monitor
        } else {
            updateLaunch.prepare(transfers: nil) { [weak self] in
                self?.completeLaunchSmokeTestIfRequested()
            }
        }
    }

    private func install(_ container: AppContainer, status: AppRuntimeStatus) {
        self.container = container
        surfaceController?.invalidate()
        statusItemController?.invalidate()
        let statusController = statusItemControllerFactory(container)
        let surfaces = AppSurfaceController(
            transferService: NativeTransferSurfaceService(
                coordinator: container.transferCoordinator
            ),
            pairingService: container.pairingSurfaceService,
            settingsService: container.settingsSurfaceService,
            directorySelector: container.directorySelector,
            updateService: updateController,
            onRetryRuntime: { [weak runtimeHost] in
                Task { await runtimeHost?.bootstrap() }
            }
        )
        statusController.onRetryRuntime = { [weak runtimeHost] in
            Task { await runtimeHost?.bootstrap() }
        }
        surfaces.bind(to: statusController)
        statusController.setRuntimeStatus(status)
        surfaces.updateRuntimeStatus(status)
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
        observeReceiveEvents(from: container)
    }

    @discardableResult
    func replace(_ container: AppContainer, status: AppRuntimeStatus) async -> Bool {
        containerReplacementGeneration += 1
        return await replace(
            container,
            status: status,
            generation: containerReplacementGeneration
        )
    }

    private func replace(
        _ container: AppContainer,
        status: AppRuntimeStatus,
        generation: Int
    ) async -> Bool {
        await drainReceiveEventObservation()
        guard generation == containerReplacementGeneration else { return false }
        install(container, status: status)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        containerReplacementGeneration += 1
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        networkMonitor?.cancel()
        networkMonitor = nil
        bootstrapTask?.cancel()
        beginReceiveEventDrain()
        updateController.stop()
        surfaceController?.invalidate()
        statusItemController?.invalidate()
    }

    @objc private func workspaceDidWake() {
        guard let runtimeHost else { return }
        Task { await runtimeHost.reconnectPublicService() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !runtimeShutdownComplete else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        containerReplacementGeneration += 1
        bootstrapTask?.cancel()
        let receiveDrain = beginReceiveEventDrain()
        let runtimeShutdownTask = runtimeHost.map { runtimeHost in
            Task { await runtimeHost.shutdown() }
        }
        guard receiveDrain != nil || runtimeShutdownTask != nil else {
            runtimeShutdownComplete = true
            return .terminateNow
        }
        Task {
            if let receiveDrain {
                await receiveDrain.task.value
                finishReceiveEventDrain(receiveDrain)
            }
            await runtimeShutdownTask?.value
            runtimeShutdownComplete = true
            self.finishProductionLaunchTestIfRequested()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func observeReceiveEvents(from container: AppContainer) {
        guard let makeEvents = container.receiveEvents else { return }
        receiveEventTask = Task { [weak self] in
            let events = await makeEvents()
            for await result in events {
                guard !Task.isCancelled, let self else { return }
                statusItemController?.setUnreadReceive(true)
                await receiveNotificationController.notify(receive: result)
            }
        }
    }

    @discardableResult
    private func beginReceiveEventDrain() -> ReceiveEventDrain? {
        guard let observerTask = receiveEventTask else { return pendingReceiveEventDrain }
        observerTask.cancel()
        self.receiveEventTask = nil
        receiveEventDrainGeneration += 1
        let priorDrainTask = pendingReceiveEventDrain?.task
        let drain = ReceiveEventDrain(
            generation: receiveEventDrainGeneration,
            task: Task {
                await priorDrainTask?.value
                await observerTask.value
            }
        )
        pendingReceiveEventDrain = drain
        return drain
    }

    private func drainReceiveEventObservation() async {
        guard let drain = beginReceiveEventDrain() else { return }
        await drain.task.value
        finishReceiveEventDrain(drain)
    }

    private func finishReceiveEventDrain(_ drain: ReceiveEventDrain) {
        guard pendingReceiveEventDrain?.generation == drain.generation else { return }
        pendingReceiveEventDrain = nil
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
        case .loading, .startupError, .error: return
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
