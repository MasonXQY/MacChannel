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

private actor ReceiveEventObservation {
    nonisolated let generation: Int
    private var stream: RuntimeReceiveEventStream?
    private var streamWaiters: [CheckedContinuation<RuntimeReceiveEventStream, Never>] = []

    init(generation: Int) {
        self.generation = generation
    }

    func install(_ stream: RuntimeReceiveEventStream) {
        self.stream = stream
        let waiters = streamWaiters
        streamWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume(returning: stream) }
    }

    func drainAndCancel() async -> [TransferReceiveResult] {
        let stream: RuntimeReceiveEventStream
        if let installed = self.stream {
            stream = installed
        } else {
            stream = await withCheckedContinuation { streamWaiters.append($0) }
        }
        return await stream.drainAndCancel()
    }
}

@MainActor
private final class ApplicationReceiveDirectoryResolver: ReceiveDirectoryResolving {
    private var snapshot: SettingsSurfaceSnapshot?
    private var configurationUnavailable = false
    private var waiters: [UUID: CheckedContinuation<SettingsSurfaceSnapshot?, Never>] = [:]

    func configure(
        initialSnapshot: SettingsSurfaceSnapshot?,
        waitForSnapshot: Bool
    ) {
        if let initialSnapshot {
            update(initialSnapshot)
        } else if waitForSnapshot {
            snapshot = nil
            configurationUnavailable = false
        } else {
            update(SettingsSurfaceSnapshot(defaultDirectory: nil, devices: []))
        }
    }

    func update(_ snapshot: SettingsSurfaceSnapshot) {
        self.snapshot = snapshot
        configurationUnavailable = false
        let currentWaiters = waiters.values
        waiters.removeAll(keepingCapacity: false)
        currentWaiters.forEach { $0.resume(returning: snapshot) }
    }

    func markConfigurationUnavailable() {
        guard snapshot == nil else { return }
        configurationUnavailable = true
        let currentWaiters = waiters.values
        waiters.removeAll(keepingCapacity: false)
        currentWaiters.forEach { $0.resume(returning: nil) }
    }

    func currentReceiveDirectory(for source: DeviceID?) async -> URL? {
        guard let snapshot = await resolvedSnapshot() else { return nil }
        if let source,
           let override = snapshot.devices.first(where: { $0.id == source })?.directory
        {
            return override.standardizedFileURL
        }
        return SettingsReceiveDirectoryPresentation.directory(
            defaultDirectory: snapshot.defaultDirectory
        )
    }

    private func resolvedSnapshot() async -> SettingsSurfaceSnapshot? {
        if let snapshot { return snapshot }
        if configurationUnavailable { return nil }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let snapshot {
                    continuation.resume(returning: snapshot)
                } else if configurationUnavailable {
                    continuation.resume(returning: nil)
                } else if Task.isCancelled {
                    continuation.resume(returning: nil)
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.waiters.removeValue(forKey: id)?.resume(returning: nil)
            }
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
    private let receiveDirectoryResolver = ApplicationReceiveDirectoryResolver()
    private let transferSurfacePresentation: ((TransferSurfaceSection) -> Void)?
    private let beforeReceiveResultRecord: (@MainActor (TransferReceiveResult) async -> Void)?
    private let statusItemControllerFactory: (AppContainer) -> StatusItemController
    private let recentReceiveStore = RecentReceiveStore()
    private var receiveEventTask: Task<Void, Never>?
    private var receiveEventObservation: ReceiveEventObservation?
    private var pendingReceiveEventDrain: ReceiveEventDrain?
    private var receiveEventDrainGeneration = 0
    private var receiveEventObservationGeneration = 0
    private var containerReplacementGeneration = 0
    private var receiveEventDeduplicationIDs: [Int: Set<TransferID>] = [:]
    private(set) var observedReceiveEventCount = 0

    private struct ReceiveEventDrain {
        let generation: Int
        let task: Task<Void, Never>
    }

    var hasUnreadReceive: Bool { statusItemController?.hasUnreadReceive ?? false }
    var recentReceiveSnapshot: RecentReceiveSnapshot { recentReceiveStore.snapshot }
    var receiveEventDeduplicationCount: Int {
        receiveEventDeduplicationIDs.values.reduce(0) { $0 + $1.count }
    }

    init(
        initialContainer: AppContainer,
        initialStatus: AppRuntimeStatus,
        runtimeHost: AppRuntimeHost?,
        receiveNotificationController: ReceiveNotificationController = ReceiveNotificationController(),
        transferSurfacePresentation: ((TransferSurfaceSection) -> Void)? = nil,
        beforeReceiveResultRecord: (@MainActor (TransferReceiveResult) async -> Void)? = nil,
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
        self.transferSurfacePresentation = transferSurfacePresentation
        self.beforeReceiveResultRecord = beforeReceiveResultRecord
        self.statusItemControllerFactory = statusItemControllerFactory
        receiveNotificationController.setReceiveDirectoryResolver(receiveDirectoryResolver)
        receiveDirectoryResolver.configure(
            initialSnapshot: initialContainer.initialSettingsSnapshot,
            waitForSnapshot: initialContainer.receiveDirectoryConfigurationPending
                || initialContainer.settingsSnapshots != nil
        )
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
                    self.updateReceiveDirectoryAvailability(for: status)
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
            notificationService: receiveNotificationController,
            transferSurfacePresentation: transferSurfacePresentation,
            onRetryRuntime: { [weak runtimeHost] in
                Task { await runtimeHost?.bootstrap() }
            }
        )
        receiveDirectoryResolver.configure(
            initialSnapshot: container.initialSettingsSnapshot,
            waitForSnapshot: container.receiveDirectoryConfigurationPending
                || container.settingsSnapshots != nil
        )
        surfaces.onSettingsSnapshot = { [weak receiveDirectoryResolver] snapshot in
            receiveDirectoryResolver?.update(snapshot)
        }
        if let initialSettingsSnapshot = container.initialSettingsSnapshot {
            surfaces.updateSettings(initialSettingsSnapshot)
        }
        statusController.onRetryRuntime = { [weak runtimeHost] in
            Task { await runtimeHost?.bootstrap() }
        }
        surfaces.bind(to: statusController)
        let showReceiveHistory = statusController.onShowReceiveHistory
        statusController.bindRecentReceives(recentReceiveStore)
        statusController.onRevealRecentReceive = { [weak self] summary in
            Task { @MainActor [weak self] in
                await self?.revealRecentReceive(summary)
            }
        }
        statusController.onShowReceiveHistory = { [weak self] in
            self?.recentReceiveStore.acknowledgeAll()
            showReceiveHistory?()
        }
        receiveNotificationController.onReceiveOpened = { [weak self] transferID in
            self?.recentReceiveStore.acknowledge(transferID)
        }
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
        surfaces.observeReceiveNotifications()
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
        receiveEventObservationGeneration += 1
        let generation = receiveEventObservationGeneration
        let observation = ReceiveEventObservation(generation: generation)
        receiveEventObservation = observation
        receiveEventTask = Task { [weak self] in
            let events = await makeEvents()
            await observation.install(events)
            for await result in events {
                guard let self else { break }
                await beforeReceiveResultRecord?(result)
                recordReceiveResult(result, generation: generation)
                let sourceAcknowledgedRecording = await events.markRecorded(result)
                if sourceAcknowledgedRecording {
                    releaseReceiveEventDeduplication(result, generation: generation)
                }
                guard !Task.isCancelled else { break }
                await receiveNotificationController.notify(receive: result)
            }
            await events.cancel()
        }
    }

    @discardableResult
    private func beginReceiveEventDrain() -> ReceiveEventDrain? {
        let observerTask = receiveEventTask
        let observation = receiveEventObservation
        guard observerTask != nil else { return pendingReceiveEventDrain }
        self.receiveEventTask = nil
        receiveEventObservation = nil
        receiveEventDrainGeneration += 1
        let priorDrainTask = pendingReceiveEventDrain?.task
        let drain = ReceiveEventDrain(
            generation: receiveEventDrainGeneration,
            task: Task {
                await priorDrainTask?.value
                if let observation {
                    let drained = await observation.drainAndCancel()
                    for result in drained {
                        recordReceiveResult(result, generation: observation.generation)
                    }
                }
                observerTask?.cancel()
                await observerTask?.value
                if let observation {
                    retireReceiveEventDeduplication(generation: observation.generation)
                }
            }
        )
        pendingReceiveEventDrain = drain
        return drain
    }

    private func recordReceiveResult(_ result: TransferReceiveResult, generation: Int) {
        var ids = receiveEventDeduplicationIDs[generation] ?? []
        guard ids.insert(result.transferID).inserted else { return }
        receiveEventDeduplicationIDs[generation] = ids
        observedReceiveEventCount += 1
        let sourceName = statusItemController?.sourceDisplayName(for: result.source) ?? "其他设备"
        recentReceiveStore.record(result, sourceName: sourceName)
    }

    private func releaseReceiveEventDeduplication(
        _ result: TransferReceiveResult,
        generation: Int
    ) {
        guard var ids = receiveEventDeduplicationIDs[generation] else { return }
        ids.remove(result.transferID)
        if ids.isEmpty {
            receiveEventDeduplicationIDs.removeValue(forKey: generation)
        } else {
            receiveEventDeduplicationIDs[generation] = ids
        }
    }

    private func retireReceiveEventDeduplication(generation: Int) {
        receiveEventDeduplicationIDs.removeValue(forKey: generation)
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

    func prepareStatusMenuForTesting() {
        statusItemController?.prepareToOpenStatusMenu()
    }

    func updateReceiveDirectoryAvailability(for status: AppRuntimeStatus) {
        if case .loading = status,
           container.receiveDirectoryConfigurationPending
        {
            receiveDirectoryResolver.configure(initialSnapshot: nil, waitForSnapshot: true)
        } else if case .startupError = status {
            receiveDirectoryResolver.markConfigurationUnavailable()
        }
    }

    func revealRecentReceiveForTesting(_ transferID: TransferID) async {
        guard let summary = recentReceiveStore.snapshot.visible.first(where: { $0.id == transferID })
        else { return }
        await revealRecentReceive(summary)
    }

    private func revealRecentReceive(_ summary: RecentReceiveSummary) async {
        let revealed = await receiveNotificationController.reveal(
            summary.receivedURLs,
            source: summary.source
        )
        recentReceiveStore.acknowledge(summary.id)
        if !revealed {
            statusItemController?.reportReceiveRevealFailure()
        }
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
