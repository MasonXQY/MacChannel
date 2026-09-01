import AppKit
import MacChannelCore
import SwiftUI

@MainActor
protocol SoftwareUpdateSnapshotProviding: AnyObject {
    var softwareUpdateSnapshot: SoftwareUpdateSnapshot { get }
    func softwareUpdateSnapshots() -> AsyncStream<SoftwareUpdateSnapshot>
}

extension SparkleUpdateController: SoftwareUpdateSnapshotProviding {
    var softwareUpdateSnapshot: SoftwareUpdateSnapshot { snapshot }
    func softwareUpdateSnapshots() -> AsyncStream<SoftwareUpdateSnapshot> { snapshots() }
}

@MainActor
final class AppSurfaceController: NSObject, NSPopoverDelegate {
    static let historyLimit = 200
    static let liveHistoryLimit = historyLimit

    let fanPanel: DeviceFanPanel
    let transferModel: TransferSurfaceModel
    let pairingModel: PairingSurfaceModel
    let settingsModel: SettingsSurfaceModel
    let updateService: any SoftwareUpdateServicing

    private let transferService: any TransferSurfaceServicing
    private let pairingService: any PairingSurfaceServicing
    private let settingsService: any DeviceSettingsServicing
    private let directorySelector: any DirectorySelecting
    private let onRetryRuntime: () -> Void
    private let now: () -> Date

    private var activePopover: NSPopover?
    private weak var focusAnchor: NSView?
    private var deviceNames: [DeviceID: String] = [:]
    private var presence: [DeviceID: DeviceAvailability] = [:]
    private var previousSamples: [TransferID: (date: Date, completedBytes: Int64)] = [:]
    private var transferTokens: [TransferID: StatusItemDragToken] = [:]
    private var latestSnapshots: [TransferID: TransferSnapshot] = [:]
    private var lastLiveItems: [TransferID: TransferSurfaceItem] = [:]
    private var persistedHistory: [TransferID: TransferSurfaceItem] = [:]
    private var liveTerminalHistory: [TransferID: TransferSurfaceItem] = [:]
    private weak var statusController: StatusItemController?
    private var deviceTask: Task<Void, Never>?
    private var transferTask: Task<Void, Never>?
    private var pairingTask: Task<Void, Never>?
    private var pendingPeerTask: Task<Void, Never>?
    private var pairedDeviceTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var softwareUpdateTask: Task<Void, Never>?

    init(
        fanPanel: DeviceFanPanel = DeviceFanPanel(),
        transferService: any TransferSurfaceServicing,
        pairingService: any PairingSurfaceServicing,
        settingsService: any DeviceSettingsServicing,
        directorySelector: any DirectorySelecting,
        transferModel: TransferSurfaceModel = TransferSurfaceModel(),
        pairingModel: PairingSurfaceModel = PairingSurfaceModel(),
        settingsModel: SettingsSurfaceModel = SettingsSurfaceModel(),
        updateService: (any SoftwareUpdateServicing)? = nil,
        onRetryRuntime: @escaping () -> Void = {},
        now: @escaping () -> Date = Date.init
    ) {
        self.fanPanel = fanPanel
        self.transferService = transferService
        self.pairingService = pairingService
        self.settingsService = settingsService
        self.directorySelector = directorySelector
        self.transferModel = transferModel
        self.pairingModel = pairingModel
        self.settingsModel = settingsModel
        self.updateService = updateService ?? InactiveSoftwareUpdateService()
        self.onRetryRuntime = onRetryRuntime
        self.now = now
    }

    func bind(to controller: StatusItemController) {
        statusController = controller
        controller.updateDeviceNames(deviceNames)
        if let updates = updateService as? any SoftwareUpdateSnapshotProviding {
            updateSoftwareUpdate(updates.softwareUpdateSnapshot)
            observeSoftwareUpdates(updates)
        } else {
            updateSoftwareUpdate(settingsModel.updateSnapshot)
        }
        let previousTransferStarted = controller.onTransferStarted
        controller.onTransferStarted = { [weak self] id, token in
            if let self {
                transferTokens[id] = token
                if let latest = latestSnapshots[id] {
                    updateStatusItem(with: [latest])
                }
            }
            previousTransferStarted?(id, token)
        }
        controller.onPresentDeviceFan = { [weak self, weak controller] request in
            guard let self,
                  let anchor = controller?.nativeButton ?? controller?.button
            else {
                request.cancel()
                return
            }
            fanPanel.present(request: request, relativeTo: anchor)
        }
        controller.onDismissDeviceFan = { [weak self] token in
            _ = self?.fanPanel.dismiss(token: token)
        }
        controller.onShowTransfers = { [weak self, weak controller] in
            guard let self,
                  let anchor = controller?.nativeButton ?? controller?.button
            else { return }
            showTransfers(relativeTo: anchor)
        }
        controller.onShowPairing = { [weak self, weak controller] in
            guard let self,
                  let anchor = controller?.nativeButton ?? controller?.button
            else { return }
            showPairing(relativeTo: anchor)
        }
        controller.onShowSettings = { [weak self, weak controller] in
            guard let self,
                  let anchor = controller?.nativeButton ?? controller?.button
            else { return }
            showSettings(relativeTo: anchor)
        }
    }

    func observe(_ directory: DeviceDirectory) {
        deviceTask?.cancel()
        deviceTask = Task { [weak self] in
            let updates = await directory.devices()
            for await devices in updates {
                guard !Task.isCancelled else { return }
                self?.updatePresence(devices)
            }
        }
    }

    func observeTransferSnapshots(
        _ snapshots: @escaping @Sendable () async -> AsyncStream<[TransferSnapshot]>
    ) {
        transferTask?.cancel()
        transferTask = Task { [weak self] in
            let updates = await snapshots()
            for await snapshots in updates {
                guard !Task.isCancelled else { return }
                self?.updateTransferSnapshots(snapshots)
            }
        }
    }

    func observePairingStates(_ states: AsyncStream<PairingState>) {
        pairingTask?.cancel()
        pairingTask = Task { [weak self] in
            for await state in states {
                guard !Task.isCancelled else { return }
                self?.updatePairingState(state)
            }
        }
    }

    func observeSettings(
        _ snapshots: @escaping @Sendable () async -> AsyncStream<SettingsSurfaceSnapshot>
    ) {
        pairedDeviceTask?.cancel()
        pairedDeviceTask = Task { [weak self] in
            let updates = await snapshots()
            for await snapshot in updates {
                guard !Task.isCancelled else { return }
                self?.updateSettings(snapshot)
            }
        }
    }

    func observeTransferHistory(
        _ history: @escaping @Sendable () async -> AsyncStream<[TransferSurfaceItem]>
    ) {
        historyTask?.cancel()
        historyTask = Task { [weak self] in
            let updates = await history()
            for await items in updates {
                guard !Task.isCancelled else { return }
                self?.updateHistoryItems(items)
            }
        }
    }

    func updatePresence(_ devices: [DeviceSummary]) {
        let online = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        presence = online.mapValues(\.availability)
        for device in devices where !device.displayName.isEmpty {
            deviceNames[device.id] = device.displayName
        }
        statusController?.updateDeviceNames(deviceNames)
        settingsModel.devices = settingsModel.devices.map { setting in
            var updated = setting
            updated.availability = online[setting.id]?.availability ?? .offline
            if updated.displayName.isEmpty,
               let discoveredName = online[setting.id]?.displayName,
               !discoveredName.isEmpty
            {
                updated.displayName = discoveredName
            }
            return updated
        }
    }

    func updateDeviceSettings(_ settings: [DeviceSetting]) {
        settingsModel.devices = settings.map { setting in
            var updated = setting
            updated.availability = presence[setting.id] ?? .offline
            return updated
        }
        for setting in settings where !setting.displayName.isEmpty {
            deviceNames[setting.id] = setting.displayName
        }
        statusController?.updateDeviceNames(deviceNames)
    }

    func updateSettings(_ snapshot: SettingsSurfaceSnapshot) {
        settingsModel.localDisplayName = snapshot.localDisplayName
        settingsModel.defaultDirectory = snapshot.defaultDirectory
        settingsModel.autoReceive = snapshot.autoReceive
        settingsModel.launchAtLogin = snapshot.launchAtLogin
        updateDeviceSettings(snapshot.devices)
        if case let .confirmed(peer) = pairingModel.state,
           !snapshot.devices.contains(where: { $0.id == peer.id })
        {
            pairingModel.resetToIdle()
        }
    }

    func updateRuntimeStatus(_ status: AppRuntimeStatus) {
        settingsModel.runtimeStatus = status
    }

    func updateSoftwareUpdate(_ snapshot: SoftwareUpdateSnapshot) {
        settingsModel.updateSnapshot = snapshot
        statusController?.setUpdateAvailable(
            snapshot.phase.hasAvailableUpdate,
            action: snapshot.canShowUpdate
                ? { [weak self] in self?.updateService.showAvailableUpdate() }
                : nil
        )
    }

    func updateTransferSnapshots(_ snapshots: [TransferSnapshot]) {
        let timestamp = now()
        let incoming = snapshots.map { snapshot in
            let itemTimestamp: Date
            if let previous = lastLiveItems[snapshot.id], previous.snapshot == snapshot {
                itemTimestamp = previous.updatedAt
            } else if let persisted = persistedHistory[snapshot.id], persisted.snapshot == snapshot {
                itemTimestamp = persisted.updatedAt
            } else if let terminal = liveTerminalHistory[snapshot.id], terminal.snapshot == snapshot {
                itemTimestamp = terminal.updatedAt
            } else {
                itemTimestamp = timestamp
            }
            let speed = speed(for: snapshot, at: timestamp)
            let remaining = speed.flatMap { speed -> TimeInterval? in
                guard speed > 0 else { return nil }
                return Double(max(snapshot.totalBytes - snapshot.completedBytes, 0)) / speed
            }
            return TransferSurfaceItem(
                snapshot: snapshot,
                peerName: persistedHistory[snapshot.id]?.peerName
                    ?? deviceNames[snapshot.peer]
                    ?? "未知设备",
                displayName: persistedHistory[snapshot.id]?.displayName
                    ?? liveTerminalHistory[snapshot.id]?.displayName
                    ?? "文件传输",
                bytesPerSecond: speed,
                estimatedTimeRemaining: remaining,
                outputURL: persistedHistory[snapshot.id]?.outputURL
                    ?? liveTerminalHistory[snapshot.id]?.outputURL,
                updatedAt: itemTimestamp
            )
        }
        let terminal: Set<TransferPhase> = [.completed, .failed, .cancelled]
        let items = incoming.map { item -> TransferSurfaceItem in
            if let live = liveTerminalHistory[item.id],
               terminal.contains(live.snapshot.phase),
               !terminal.contains(item.snapshot.phase)
            {
                return merge(persisted: persistedHistory[item.id], live: live)
            }
            if let persisted = persistedHistory[item.id],
               terminal.contains(persisted.snapshot.phase),
               !terminal.contains(item.snapshot.phase)
            {
                return merge(persisted: persisted, live: item)
            }
            return item
        }
        latestSnapshots = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.snapshot) })
        lastLiveItems = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        transferModel.active = items.filter { !terminal.contains($0.snapshot.phase) }
        let activeIDs = Set(transferModel.active.map(\.id))
        previousSamples = previousSamples.filter { activeIDs.contains($0.key) }
        for item in items where terminal.contains(item.snapshot.phase) {
            liveTerminalHistory[item.id] = item
        }
        if liveTerminalHistory.count > Self.liveHistoryLimit {
            liveTerminalHistory = Dictionary(
                uniqueKeysWithValues: liveTerminalHistory.values
                    .sorted { $0.updatedAt > $1.updatedAt }
                    .prefix(Self.liveHistoryLimit)
                    .map { ($0.id, $0) }
            )
        }
        rebuildHistory()
        updateStatusItem(with: snapshots)
    }

    func updateHistory(_ records: [TransferHistoryRecord]) {
        replacePersistedHistory(records.map { record in
            TransferSurfaceItem(
                snapshot: TransferSnapshot(
                    id: record.id,
                    peer: record.peer,
                    phase: record.phase,
                    completedBytes: Int64(clamping: record.completedBytes),
                    totalBytes: Int64(clamping: record.aggregateSize),
                    route: record.route
                ),
                peerName: deviceNames[record.peer] ?? "未知设备",
                displayName: record.displayFilename,
                bytesPerSecond: nil,
                estimatedTimeRemaining: nil,
                outputURL: nil,
                updatedAt: record.updatedAt
            )
        })
    }

    func updateHistoryItems(_ items: [TransferSurfaceItem]) {
        replacePersistedHistory(items)
    }

    func updatePairingState(_ state: PairingState, hostedCode: String? = nil) {
        pairingModel.state = state
        if let hostedCode {
            pairingModel.hostedCode = PairingCodeInput.sanitize(hostedCode)
        } else {
            switch state {
            case .idle, .confirmed, .failed:
                pairingModel.hostedCode = nil
            case .displayingCode, .joining, .approvalRequested, .awaitingHostApproval,
                .committing, .awaitingFingerprint:
                break
            }
        }
        if case let .confirmed(device) = state, !device.displayName.isEmpty {
            deviceNames[device.id] = device.displayName
            statusController?.updateDeviceNames([device.id: device.displayName])
        }
        switch state {
        case let .approvalRequested(peer), let .awaitingHostApproval(peer),
            let .committing(peer):
            pendingPeerTask?.cancel()
            pendingPeerTask = nil
            pairingModel.pendingPeer = peer
        case .awaitingFingerprint:
            pendingPeerTask?.cancel()
            pairingModel.pendingPeer = nil
            pendingPeerTask = Task { [weak self, pairingService] in
                let peer = await pairingService.pendingPeer()
                guard !Task.isCancelled,
                      case .awaitingFingerprint = self?.pairingModel.state
                else { return }
                self?.pairingModel.pendingPeer = peer
            }
        case .idle, .displayingCode, .joining, .confirmed, .failed:
            pendingPeerTask?.cancel()
            pendingPeerTask = nil
            pairingModel.pendingPeer = nil
        }
    }

    func closeActiveSurface() {
        activePopover?.performClose(nil)
    }

    func invalidate() {
        deviceTask?.cancel()
        deviceTask = nil
        transferTask?.cancel()
        transferTask = nil
        pairingTask?.cancel()
        pairingTask = nil
        pendingPeerTask?.cancel()
        pendingPeerTask = nil
        pairedDeviceTask?.cancel()
        pairedDeviceTask = nil
        historyTask?.cancel()
        softwareUpdateTask?.cancel()
        historyTask = nil
        softwareUpdateTask = nil
        transferTokens.removeAll()
        latestSnapshots.removeAll()
        lastLiveItems.removeAll()
        previousSamples.removeAll()
        persistedHistory.removeAll()
        liveTerminalHistory.removeAll()
        statusController = nil
        closeActiveSurface()
        if let token = fanPanel.presentedToken {
            _ = fanPanel.dismiss(token: token)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        activePopover = nil
        restoreFocus()
    }

    private func showTransfers(relativeTo anchor: NSView) {
        let popover = configuredPopover()
        popover.contentViewController = NSHostingController(
            rootView: TransferPopover(
                model: transferModel,
                service: transferService,
                onDismiss: { [weak self] in self?.closeActiveSurface() }
            )
        )
        show(popover, relativeTo: anchor)
    }

    private func showPairing(relativeTo anchor: NSView) {
        let popover = configuredPopover()
        popover.contentViewController = NSHostingController(
            rootView: PairingView(
                model: pairingModel,
                service: pairingService,
                onDismiss: { [weak self] in self?.closeActiveSurface() }
            )
        )
        show(popover, relativeTo: anchor)
    }

    private func showSettings(relativeTo anchor: NSView) {
        let popover = configuredPopover()
        popover.contentViewController = NSHostingController(
            rootView: SettingsView(
                model: settingsModel,
                service: settingsService,
                directorySelector: directorySelector,
                updateService: updateService,
                onRetryRuntime: onRetryRuntime,
                onDismiss: { [weak self] in self?.closeActiveSurface() }
            )
        )
        show(popover, relativeTo: anchor)
    }

    private func configuredPopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        return popover
    }

    private func show(_ popover: NSPopover, relativeTo anchor: NSView) {
        if let activePopover {
            activePopover.delegate = nil
            activePopover.performClose(nil)
        }
        activePopover = popover
        focusAnchor = anchor
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    private func restoreFocus() {
        guard let focusAnchor else { return }
        _ = focusAnchor.window?.makeFirstResponder(focusAnchor)
        NSAccessibility.post(element: focusAnchor, notification: .focusedUIElementChanged)
        self.focusAnchor = nil
    }

    private func speed(for snapshot: TransferSnapshot, at timestamp: Date) -> Double? {
        defer {
            previousSamples[snapshot.id] = (timestamp, snapshot.completedBytes)
        }
        guard let previous = previousSamples[snapshot.id],
              snapshot.completedBytes >= previous.completedBytes
        else { return nil }
        let interval = timestamp.timeIntervalSince(previous.date)
        guard interval > 0 else { return nil }
        return Double(snapshot.completedBytes - previous.completedBytes) / interval
    }

    private func replacePersistedHistory(_ items: [TransferSurfaceItem]) {
        persistedHistory = Dictionary(
            uniqueKeysWithValues: sortedHistory(items).prefix(Self.historyLimit).map { ($0.id, $0) }
        )
        rebuildHistory()
    }

    private func rebuildHistory() {
        let activeIDs = Set(transferModel.active.map(\.id))
        let ids = Set(persistedHistory.keys).union(liveTerminalHistory.keys)
        let merged: [TransferSurfaceItem] = ids.compactMap { id -> TransferSurfaceItem? in
            guard !activeIDs.contains(id) else { return nil }
            switch (persistedHistory[id], liveTerminalHistory[id]) {
            case let (persisted?, live?):
                return merge(persisted: persisted, live: live)
            case let (persisted?, nil):
                return persisted
            case let (nil, live?):
                return live
            case (nil, nil):
                return nil
            }
        }
        transferModel.history = Array(sortedHistory(merged).prefix(Self.historyLimit))
    }

    private func merge(
        persisted: TransferSurfaceItem?,
        live: TransferSurfaceItem
    ) -> TransferSurfaceItem {
        guard let persisted else { return live }
        let preferred = preferredSnapshot(persisted: persisted, live: live)
        return TransferSurfaceItem(
            snapshot: preferred.snapshot,
            peerName: persisted.peerName.isEmpty ? live.peerName : persisted.peerName,
            displayName: persisted.displayName.isEmpty ? live.displayName : persisted.displayName,
            bytesPerSecond: preferred.source == .live ? live.bytesPerSecond : persisted.bytesPerSecond,
            estimatedTimeRemaining: preferred.source == .live
                ? live.estimatedTimeRemaining
                : persisted.estimatedTimeRemaining,
            outputURL: persisted.outputURL ?? live.outputURL,
            updatedAt: max(persisted.updatedAt, live.updatedAt)
        )
    }

    private enum SnapshotPreference: Equatable { case persisted, live }

    private func preferredSnapshot(
        persisted: TransferSurfaceItem,
        live: TransferSurfaceItem
    ) -> (snapshot: TransferSnapshot, source: SnapshotPreference) {
        let terminal: Set<TransferPhase> = [.completed, .failed, .cancelled]
        let persistedTerminal = terminal.contains(persisted.snapshot.phase)
        let liveTerminal = terminal.contains(live.snapshot.phase)
        if persistedTerminal != liveTerminal {
            return persistedTerminal
                ? (persisted.snapshot, .persisted)
                : (live.snapshot, .live)
        }
        if persisted.updatedAt != live.updatedAt {
            return persisted.updatedAt > live.updatedAt
                ? (persisted.snapshot, .persisted)
                : (live.snapshot, .live)
        }
        return persisted.snapshot.completedBytes >= live.snapshot.completedBytes
            ? (persisted.snapshot, .persisted)
            : (live.snapshot, .live)
    }

    private func sortedHistory(_ items: [TransferSurfaceItem]) -> [TransferSurfaceItem] {
        items.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
        }
    }

    private func updateStatusItem(with snapshots: [TransferSnapshot]) {
        guard let statusController else { return }
        for snapshot in snapshots {
            guard let token = transferTokens[snapshot.id] else { continue }
            switch snapshot.phase {
            case .completed, .failed, .cancelled:
                statusController.completeTransfer(token: token)
                transferTokens.removeValue(forKey: snapshot.id)
            case .preparing, .connecting, .transferring, .paused, .verifying, .cancelling:
                let progress = snapshot.totalBytes > 0
                    ? Double(snapshot.completedBytes) / Double(snapshot.totalBytes)
                    : 0
                statusController.updateTransferProgress(progress, token: token)
            }
        }
    }

    private func observeSoftwareUpdates(_ updates: any SoftwareUpdateSnapshotProviding) {
        softwareUpdateTask?.cancel()
        softwareUpdateTask = Task { [weak self, weak updates] in
            guard let updates else { return }
            for await snapshot in updates.softwareUpdateSnapshots() {
                guard !Task.isCancelled else { return }
                self?.updateSoftwareUpdate(snapshot)
            }
        }
    }
}

@MainActor
private final class InactiveSoftwareUpdateService: SoftwareUpdateServicing {
    let isAvailable = false

    func checkForUpdates() {}
    func showAvailableUpdate() {}
}
