import AppKit
import MacChannelCore

@MainActor
struct DeviceFanRequest {
    let token: StatusItemDragToken
    let intent: DropIntent
    let devices: [DeviceSummary]
    let fingerprint: StatusItemDragFingerprint
    let dragEntered: @MainActor (StatusItemDragFingerprint) -> Bool
    let dragExited: @MainActor (StatusItemDragFingerprint) -> Bool
    let select: @MainActor (DeviceID) -> Bool
    let cancel: @MainActor () -> Void
    let announce: @MainActor (String) -> Void
}

struct RecentReceiveMenuText: Equatable {
    let title: String
    let subtitle: String?

    init(primaryTitle: String, sourceName: String, supportsSubtitle: Bool) {
        if supportsSubtitle {
            title = primaryTitle
            subtitle = sourceName
        } else {
            title = "\(primaryTitle) — \(sourceName)"
            subtitle = nil
        }
    }
}

@MainActor
private final class PreparedContentOwnershipLease {
    private enum State {
        case awaitingSelection
        case admissionInFlight(cleanupRequested: Bool)
        case activeTransfer
        case cleanupPending
        case released
    }

    private var state: State = .awaitingSelection
    private var cleanup: (@MainActor @Sendable () -> Bool)?

    init(cleanup: @escaping @MainActor @Sendable () -> Bool) {
        self.cleanup = cleanup
    }

    deinit {
        if let cleanup {
            Task { @MainActor in _ = cleanup() }
        }
    }

    var isReleased: Bool {
        if case .released = state { return true }
        return false
    }

    func beginAdmission() -> Bool {
        guard case .awaitingSelection = state else { return false }
        state = .admissionInFlight(cleanupRequested: false)
        return true
    }

    func cancelSelection() {
        guard case .awaitingSelection = state else { return }
        releasePreparedContent()
    }

    func requestInvalidationCleanup() -> Bool {
        switch state {
        case .awaitingSelection:
            releasePreparedContent()
            return false
        case .admissionInFlight:
            state = .admissionInFlight(cleanupRequested: true)
            return true
        case .activeTransfer:
            return false
        case .cleanupPending:
            releasePreparedContent()
            return false
        case .released:
            return false
        }
    }

    func admissionSucceeded(controllerIsAlive: Bool) {
        guard case .admissionInFlight(let cleanupRequested) = state else { return }
        if cleanupRequested || !controllerIsAlive {
            releasePreparedContent()
        } else {
            state = .activeTransfer
        }
    }

    func admissionFailed() {
        guard case .admissionInFlight = state else { return }
        releasePreparedContent()
    }

    func completeTransfer() {
        switch state {
        case .activeTransfer, .cleanupPending:
            releasePreparedContent()
        case .awaitingSelection, .admissionInFlight, .released:
            return
        }
    }

    private func releasePreparedContent() {
        guard let cleanup else {
            state = .released
            return
        }
        if cleanup() {
            self.cleanup = nil
            state = .released
        } else {
            state = .cleanupPending
        }
    }
}

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    let button: StatusItemButton
    let statusMenu: NSMenu
    var onPresentDeviceFan: ((DeviceFanRequest) -> Void)?
    var onDismissDeviceFan: ((StatusItemDragToken) -> Void)?
    var onTransferStarted: ((TransferID, StatusItemDragToken) -> Void)?
    var onAnnouncement: ((String) -> Void)?
    var onShowTransfers: (() -> Void)?
    var onShowPairing: (() -> Void)?
    var onShowSettings: (() -> Void)?
    var onRetryRuntime: (() -> Void)?
    var onAcknowledgeReceive: (() -> Void)?
    var onRevealRecentReceive: ((RecentReceiveSummary) -> Void)?
    var onShowReceiveHistory: (() -> Void)?

    var phase: StatusItemPhase { state.phase }
    var nativeButton: NSStatusBarButton? { statusItem?.button }
    var hasUnreadReceive: Bool { button.hasUnreadReceive }

    private let transferCoordinator: any TransferCoordinating
    private let filePicker: any StatusItemFilePicking
    private let clipboardPreparer: any ClipboardTransferPreparing
    private let deviceMenuPresenter: any StatusItemDeviceMenuPresenting
    private var state = StatusItemDropStateMachine()
    private var devices: [DeviceSummary]
    private var preferredDeviceNames: [DeviceID: String]
    private var currentFanToken: StatusItemDragToken?
    private var activeSelectionToken: StatusItemDragToken?
    private var announcedOfflineToken: StatusItemDragToken?
    private var dragRegionSession: DragRegionSession!
    private var statusItem: NSStatusItem?
    private var deviceTask: Task<Void, Never>?
    private var runtimeStatus: AppRuntimeStatus?
    private var runtimeStatusItem: NSMenuItem?
    private var runtimeRetryItem: NSMenuItem?
    private var availableUpdateItem: NSMenuItem?
    private var availableUpdateAction: (() -> Void)?
    private var recentReceiveStore: RecentReceiveStore?
    private var recentReceiveHeadingItem: NSMenuItem?
    private var recentReceiveItems: [NSMenuItem] = []
    private var recentReceiveOverflowItem: NSMenuItem?
    private var recentReceiveHistoryItem: NSMenuItem?
    private var recentReceiveSeparatorItem: NSMenuItem?
    private var visibleRecentReceives: [RecentReceiveSummary] = []
    private var latestRecentReceiveSnapshot = RecentReceiveSnapshot(visible: [], overflowCount: 0)
    private var isStatusMenuTracking = false
    private var statusMenuTrackingGeneration = 0
    private var preparedContentLeases: [StatusItemDragToken: PreparedContentOwnershipLease] = [:]
    private var sendAdmissionTasks: [StatusItemDragToken: Task<Void, Never>] = [:]

    init(
        button: StatusItemButton,
        devices: [DeviceSummary],
        transferCoordinator: any TransferCoordinating,
        filePicker: (any StatusItemFilePicking)? = nil,
        clipboardPreparer: (any ClipboardTransferPreparing)? = nil,
        deviceMenuPresenter: (any StatusItemDeviceMenuPresenting)? = nil,
        dragRegionSchedule: DragRegionSchedule? = nil
    ) {
        self.button = button
        preferredDeviceNames = Dictionary(
            uniqueKeysWithValues: devices.compactMap { device in
                let name = device.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? nil : (device.id, name)
            }
        )
        self.devices = devices.map { device in
            let name = device.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return device.replacingDisplayName(name)
        }
        self.transferCoordinator = transferCoordinator
        self.filePicker = filePicker ?? NativeStatusItemFilePicker()
        self.clipboardPreparer = clipboardPreparer ?? NativeClipboardTransferPreparer()
        self.deviceMenuPresenter = deviceMenuPresenter ?? NativeStatusItemDeviceMenuPresenter()
        statusMenu = NSMenu(title: "DropMesh")
        super.init()
        dragRegionSession = if let dragRegionSchedule {
            DragRegionSession(schedule: dragRegionSchedule)
        } else {
            DragRegionSession()
        }
        dragRegionSession.onExpired = { [weak self] token in
            self?.cancelDrag(token)
        }
        configureMenu()
        configureButton()
        renderPhase()
    }

    convenience init(
        deviceDirectory: DeviceDirectory,
        transferCoordinator: any TransferCoordinating
    ) {
        let statusItem = NSStatusBar.system.statusItem(withLength: 30)
        let button = StatusItemButton(
            frame: NSRect(x: 0, y: 0, width: 30, height: NSStatusBar.system.thickness)
        )
        self.init(button: button, devices: [], transferCoordinator: transferCoordinator)
        self.statusItem = statusItem
        installButton(in: statusItem)
        observe(deviceDirectory)
    }

    @discardableResult
    func beginDrop(
        _ intent: DropIntent,
        fingerprint: StatusItemDragFingerprint = StatusItemDragFingerprint(
            sequenceNumber: 0,
            pasteboardChangeCount: 0
        )
    ) -> StatusItemDragToken? {
        let onlineDevices = devices.filter { $0.availability != .offline }
        guard !onlineDevices.isEmpty else {
            announce("没有在线接收设备，请先完成配对并确认对方 Mac 已启动。")
            return nil
        }
        replacePendingSelection()
        guard let token = state.begin(intent: intent) else { return nil }
        dragRegionSession.begin(token: token, fingerprint: fingerprint, in: .icon)
        currentFanToken = token
        activeSelectionToken = token
        announcedOfflineToken = nil
        renderPhase()

        onPresentDeviceFan?(
            DeviceFanRequest(
                token: token,
                intent: intent,
                devices: onlineDevices,
                fingerprint: fingerprint,
                dragEntered: { [weak self] observedFingerprint in
                    self?.dragEnteredFan(token, fingerprint: observedFingerprint) ?? false
                },
                dragExited: { [weak self] observedFingerprint in
                    self?.dragExitedFan(token, fingerprint: observedFingerprint) ?? false
                },
                select: { [weak self] device in
                    self?.selectTarget(device, token: token) ?? false
                },
                cancel: { [weak self] in
                    self?.cancelDrag(token)
                },
                announce: { [weak self] message in
                    self?.announce(message)
                }
            )
        )
        return token
    }

    @discardableResult
    func dragEnteredButton(
        _ intent: DropIntent,
        fingerprint: StatusItemDragFingerprint
    ) -> StatusItemDragToken? {
        if let token = currentFanToken,
           state.phase == .ready,
           dragRegionSession.enter(.icon, token: token, fingerprint: fingerprint)
        {
            return token
        }
        return beginDrop(intent, fingerprint: fingerprint)
    }

    @discardableResult
    func dragExitedButton(
        _ token: StatusItemDragToken,
        fingerprint: StatusItemDragFingerprint
    ) -> Bool {
        dragRegionSession.exit(.icon, token: token, fingerprint: fingerprint)
    }

    func cancelDrag(_ token: StatusItemDragToken) {
        terminatePendingSelection(token)
    }

    func updateTransferProgress(_ progress: Double, token: StatusItemDragToken) {
        state.updateProgress(token: token, progress: progress)
        renderPhase()
    }

    func completeTransfer(token: StatusItemDragToken) {
        if let lease = preparedContentLeases[token] {
            lease.completeTransfer()
            removeReleasedLease(lease, for: token)
        }
        state.finishTransfer(token: token)
        renderPhase()
    }

    func performKeyboardSend() {
        guard let urls = filePicker.chooseFiles() else { return }
        presentKeyboardSend(urls: urls)
    }

    func performClipboardSend() {
        let prepared: PreparedClipboardTransfer
        do {
            prepared = try clipboardPreparer.prepare()
        } catch ClipboardTransferPreparationError.noSupportedContent {
            announce("剪贴板中没有可发送的内容。")
            return
        } catch {
            announce("无法准备剪贴板内容，请重试。")
            return
        }

        presentKeyboardSend(
            urls: prepared.urls,
            cleanup: { prepared.discardTemporaryFiles() }
        )
    }

    private func presentKeyboardSend(
        urls: [URL],
        cleanup: (@MainActor @Sendable () -> Bool)? = nil
    ) {
        guard let intent = try? DropIntent(items: urls.map(DropItem.fileURL)) else {
            _ = cleanup?()
            announce("所选内容无法发送。")
            return
        }

        let onlineDevices = devices
            .filter { $0.availability != .offline }
            .sorted {
                $0.userFacingDisplayName.localizedStandardCompare($1.userFacingDisplayName)
                    == .orderedAscending
        }
        guard !onlineDevices.isEmpty else {
            _ = cleanup?()
            announce("没有在线设备。")
            return
        }

        replacePendingSelection()
        guard let token = state.begin(intent: intent) else {
            _ = cleanup?()
            announce("已有传输正在进行。")
            return
        }
        if let cleanup {
            preparedContentLeases[token] = PreparedContentOwnershipLease(cleanup: cleanup)
        }
        currentFanToken = nil
        activeSelectionToken = token
        announcedOfflineToken = nil
        renderPhase()

        deviceMenuPresenter.present(
            devices: onlineDevices,
            anchor: nativeButton ?? button,
            select: { [weak self] device in
                self?.selectTarget(device, token: token) ?? false
            },
            cancel: { [weak self] in
                self?.cancelDrag(token)
            }
        )
    }

    func invalidate() {
        deviceTask?.cancel()
        if let token = activeSelectionToken ?? currentFanToken {
            terminatePendingSelection(token)
        }
        requestAdmissionCleanupForInvalidation()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    func setUnreadReceive(_ unread: Bool) {
        button.hasUnreadReceive = unread
        renderPhase()
    }

    func prepareToOpenStatusMenu() {
        guard !isStatusMenuTracking else { return }
        menuNeedsUpdate(statusMenu)
    }

    func bindRecentReceives(_ store: RecentReceiveStore) {
        recentReceiveStore = store
        store.onChange = { [weak self] snapshot in
            self?.receiveSnapshotDidChange(snapshot)
        }
        receiveSnapshotDidChange(store.snapshot)
    }

    func sourceDisplayName(for source: DeviceID?) -> String {
        guard let source else { return "其他设备" }
        return preferredDeviceNames[source]
            ?? devices.first(where: { $0.id == source })?.userFacingDisplayName
            ?? "其他设备"
    }

    func reportReceiveRevealFailure() {
        announce("找不到接收文件或接收文件夹。")
    }

    func setRuntimeStatus(_ status: AppRuntimeStatus) {
        runtimeStatus = status
        runtimeStatusItem?.title = status.localizedText
        runtimeStatusItem?.image = NSImage(
            systemSymbolName: status.symbolName,
            accessibilityDescription: status.localizedText
        )
        runtimeRetryItem?.isHidden = !status.canRetry
        runtimeRetryItem?.isEnabled = status.canRetry
        renderPhase()
    }

    func setUpdateAvailable(_ available: Bool, action: (() -> Void)?) {
        availableUpdateAction = available ? action : nil
        availableUpdateItem?.action = availableUpdateAction == nil
            ? nil
            : #selector(showAvailableUpdate(_:))
        availableUpdateItem?.target = availableUpdateAction == nil ? nil : self
        availableUpdateItem?.isHidden = !available
        availableUpdateItem?.isEnabled = availableUpdateAction != nil
        availableUpdateItem?.setAccessibilityHelp(
            available && action == nil
                ? "更新窗口暂时不可用，请稍后再试。"
                : "打开软件更新窗口"
        )
        button.updateActionEnabled = available && action != nil
        button.updateAvailable = available
        renderPhase()
    }

    func updateDeviceNames(_ names: [DeviceID: String]) {
        for (id, rawName) in names {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                preferredDeviceNames[id] = name
            }
        }
        devices = resolvedDevices(devices)
    }

    private func selectTarget(_ device: DeviceID, token: StatusItemDragToken) -> Bool {
        guard devices.contains(where: { $0.id == device && $0.availability != .offline }) else {
            if activeSelectionToken == token, announcedOfflineToken != token {
                announcedOfflineToken = token
                announce("目标设备已离线，请重新选择。")
            }
            return false
        }
        guard let claim = state.claimDrop(token: token, target: device) else { return false }
        let lease = preparedContentLeases[token]
        guard lease?.beginAdmission() ?? true else { return false }

        dragRegionSession.invalidate(token: token)
        currentFanToken = nil
        activeSelectionToken = nil
        announcedOfflineToken = nil
        onDismissDeviceFan?(token)
        renderPhase()

        let admissionTask = Task { [weak self, transferCoordinator, claim, lease] in
            do {
                let transferID = try await transferCoordinator.send(
                    items: claim.urls,
                    to: claim.target
                )
                guard let self else {
                    lease?.admissionSucceeded(controllerIsAlive: false)
                    return
                }
                sendAdmissionTasks.removeValue(forKey: token)
                lease?.admissionSucceeded(controllerIsAlive: true)
                if let lease { removeReleasedLease(lease, for: token) }
                onTransferStarted?(transferID, token)
            } catch {
                guard let self else {
                    lease?.admissionFailed()
                    return
                }
                sendAdmissionTasks.removeValue(forKey: token)
                lease?.admissionFailed()
                if let lease { removeReleasedLease(lease, for: token) }
                announce("无法开始传输，请检查连接和设备状态。")
                state.finishTransfer(token: token)
                renderPhase()
            }
        }
        sendAdmissionTasks[token] = admissionTask
        return true
    }

    private func dragEnteredFan(
        _ token: StatusItemDragToken,
        fingerprint: StatusItemDragFingerprint
    ) -> Bool {
        guard currentFanToken == token, state.phase == .ready else { return false }
        return dragRegionSession.enter(.fan, token: token, fingerprint: fingerprint)
    }

    private func removeReleasedLease(
        _ lease: PreparedContentOwnershipLease,
        for token: StatusItemDragToken
    ) {
        guard lease.isReleased, preparedContentLeases[token] === lease else { return }
        preparedContentLeases.removeValue(forKey: token)
    }

    private func requestAdmissionCleanupForInvalidation() {
        for token in Array(sendAdmissionTasks.keys) {
            if let lease = preparedContentLeases[token],
               lease.requestInvalidationCleanup()
            {
                sendAdmissionTasks[token]?.cancel()
                removeReleasedLease(lease, for: token)
            } else {
                sendAdmissionTasks[token]?.cancel()
            }
        }
        for (token, lease) in Array(preparedContentLeases) {
            guard sendAdmissionTasks[token] == nil else { continue }
            _ = lease.requestInvalidationCleanup()
            removeReleasedLease(lease, for: token)
        }
    }

    private func replacePendingSelection() {
        guard let token = activeSelectionToken ?? currentFanToken else { return }
        terminatePendingSelection(token)
    }

    private func terminatePendingSelection(_ token: StatusItemDragToken) {
        guard activeSelectionToken == token || currentFanToken == token else { return }

        state.cancelDrag(token: token)
        dragRegionSession.invalidate(token: token)
        if currentFanToken == token {
            currentFanToken = nil
        }
        if activeSelectionToken == token {
            activeSelectionToken = nil
            announcedOfflineToken = nil
        }
        if let lease = preparedContentLeases[token] {
            lease.cancelSelection()
            removeReleasedLease(lease, for: token)
        }
        onDismissDeviceFan?(token)
        renderPhase()
    }

    private func dragExitedFan(
        _ token: StatusItemDragToken,
        fingerprint: StatusItemDragFingerprint
    ) -> Bool {
        dragRegionSession.exit(.fan, token: token, fingerprint: fingerprint)
    }

    private func configureButton() {
        button.target = self
        button.action = #selector(showStatusMenu(_:))
        button.onDragEntered = { [weak self] intent, fingerprint in
            self?.dragEnteredButton(intent, fingerprint: fingerprint)
        }
        button.onDragCancelled = { [weak self] token, fingerprint in
            self?.dragExitedButton(token, fingerprint: fingerprint)
        }
        button.onDropOutside = { [weak self] token, _ in self?.cancelDrag(token) }
    }

    private func configureMenu() {
        statusMenu.delegate = self
        let initialRuntimeStatus = runtimeStatus ?? .loading
        let runtime = NSMenuItem(title: initialRuntimeStatus.localizedText, action: nil, keyEquivalent: "")
        runtime.isEnabled = false
        runtime.image = NSImage(
            systemSymbolName: initialRuntimeStatus.symbolName,
            accessibilityDescription: initialRuntimeStatus.localizedText
        )
        runtimeStatusItem = runtime
        statusMenu.addItem(runtime)

        let retry = NSMenuItem(
            title: "重试启动",
            action: #selector(retryRuntime(_:)),
            keyEquivalent: ""
        )
        retry.target = self
        retry.isHidden = !initialRuntimeStatus.canRetry
        retry.isEnabled = initialRuntimeStatus.canRetry
        runtimeRetryItem = retry
        statusMenu.addItem(retry)
        statusMenu.addItem(.separator())

        let recentHeading = NSMenuItem(title: "刚刚收到", action: nil, keyEquivalent: "")
        recentHeading.isEnabled = false
        recentHeading.isHidden = true
        recentReceiveHeadingItem = recentHeading
        statusMenu.addItem(recentHeading)

        recentReceiveItems = (0..<RecentReceiveStore.maximumVisibleCount).map { _ in
            let item = NSMenuItem(
                title: "",
                action: #selector(revealRecentReceive(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.isHidden = true
            item.image = NSImage(
                systemSymbolName: "tray.and.arrow.down",
                accessibilityDescription: "在 Finder 中显示"
            )
            statusMenu.addItem(item)
            return item
        }

        let recentOverflow = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        recentOverflow.isEnabled = false
        recentOverflow.isHidden = true
        recentReceiveOverflowItem = recentOverflow
        statusMenu.addItem(recentOverflow)

        let recentHistory = NSMenuItem(
            title: "查看全部历史…",
            action: #selector(showReceiveHistory(_:)),
            keyEquivalent: ""
        )
        recentHistory.target = self
        recentHistory.isHidden = true
        recentReceiveHistoryItem = recentHistory
        statusMenu.addItem(recentHistory)

        let recentSeparator = NSMenuItem.separator()
        recentSeparator.isHidden = true
        recentReceiveSeparatorItem = recentSeparator
        statusMenu.addItem(recentSeparator)

        let send = NSMenuItem(
            title: "发送文件…",
            action: #selector(chooseFiles(_:)),
            keyEquivalent: "s"
        )
        send.keyEquivalentModifierMask = [.command, .shift]
        send.target = self
        statusMenu.addItem(send)

        let clipboard = NSMenuItem(
            title: "发送剪贴板…",
            action: #selector(chooseClipboard(_:)),
            keyEquivalent: "c"
        )
        clipboard.keyEquivalentModifierMask = [.command, .shift]
        clipboard.target = self
        statusMenu.addItem(clipboard)
        statusMenu.addItem(.separator())

        let transfers = NSMenuItem(
            title: "传输与历史",
            action: #selector(showTransfers(_:)),
            keyEquivalent: "t"
        )
        transfers.keyEquivalentModifierMask = [.command, .shift]
        transfers.target = self
        statusMenu.addItem(transfers)

        let pairing = NSMenuItem(
            title: "配对设备",
            action: #selector(showPairing(_:)),
            keyEquivalent: "p"
        )
        pairing.keyEquivalentModifierMask = [.command, .shift]
        pairing.target = self
        statusMenu.addItem(pairing)

        let settings = NSMenuItem(
            title: "设置",
            action: #selector(showSettings(_:)),
            keyEquivalent: ","
        )
        settings.keyEquivalentModifierMask = [.command]
        settings.target = self
        statusMenu.addItem(settings)

        let availableUpdate = NSMenuItem(
            title: "有新版本可用",
            action: nil,
            keyEquivalent: ""
        )
        availableUpdate.isHidden = true
        availableUpdate.isEnabled = false
        availableUpdate.image = NSImage(
            systemSymbolName: "arrow.down.circle",
            accessibilityDescription: "有新版本可用"
        )
        availableUpdate.setAccessibilityLabel("有新版本可用")
        availableUpdateItem = availableUpdate
        statusMenu.addItem(availableUpdate)
        statusMenu.addItem(.separator())

        let quit = NSMenuItem(
            title: "退出 DropMesh",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApplication.shared
        statusMenu.addItem(quit)
    }

    private func installButton(in statusItem: NSStatusItem) {
        guard let host = statusItem.button else { return }
        host.title = ""
        host.image = nil
        host.target = self
        host.action = #selector(showStatusMenu(_:))
        host.focusRingType = .default
        host.setAccessibilityElement(true)
        host.setAccessibilityRole(.button)
        host.setAccessibilityLabel("DropMesh 文件传输")
        host.setAccessibilityHelp(
            "打开状态菜单，或将本地文件拖到这里选择接收设备。"
        )
        button.setAccessibilityElement(false)
        button.frame = host.bounds
        button.autoresizingMask = [.width, .height]
        host.addSubview(button)
        renderPhase()
    }

    private func observe(_ directory: DeviceDirectory) {
        deviceTask = Task { [weak self] in
            let updates = await directory.devices()
            for await devices in updates {
                guard !Task.isCancelled else { return }
                self?.replaceDiscoveredDevices(devices)
            }
        }
    }

    private func replaceDiscoveredDevices(_ discovered: [DeviceSummary]) {
        devices = resolvedDevices(discovered)
    }

    private func resolvedDevices(_ discovered: [DeviceSummary]) -> [DeviceSummary] {
        discovered.map { device in
            let discoveredName = device.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !discoveredName.isEmpty {
                preferredDeviceNames[device.id] = discoveredName
            }
            return device.replacingDisplayName(
                preferredDeviceNames[device.id] ?? discoveredName
            )
        }
    }

    private func renderPhase() {
        button.phase = state.phase
        var accessibilityParts = [state.phase.localizedAccessibilityValue]
        if let runtimeStatus { accessibilityParts.append(runtimeStatus.localizedText) }
        if button.updateAvailable {
            accessibilityParts.append(
                button.updateActionEnabled
                    ? "有新版本可用"
                    : "有新版本可用，暂时无法查看"
            )
        }
        if button.hasUnreadReceive { accessibilityParts.append("有新接收文件") }
        let accessibilityValue = accessibilityParts.joined(separator: "，")
        button.setAccessibilityValue(accessibilityValue)
        nativeButton?.setAccessibilityValue(accessibilityValue)
        nativeButton?.toolTip = accessibilityValue
        statusItem?.length = button.preferredWidth
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        guard !isStatusMenuTracking else { return }
        applyRecentReceiveSnapshot(latestRecentReceiveSnapshot)
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        statusMenuTrackingGeneration &+= 1
        isStatusMenuTracking = true
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        let generation = statusMenuTrackingGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, statusMenuTrackingGeneration == generation else { return }
            isStatusMenuTracking = false
        }
    }

    private func receiveSnapshotDidChange(_ snapshot: RecentReceiveSnapshot) {
        latestRecentReceiveSnapshot = snapshot
        setUnreadReceive(snapshot.hasUnread)
        guard !isStatusMenuTracking else { return }
        applyRecentReceiveSnapshot(snapshot)
    }

    private func applyRecentReceiveSnapshot(_ snapshot: RecentReceiveSnapshot) {
        visibleRecentReceives = snapshot.visible
        let hasUnread = snapshot.hasUnread
        recentReceiveHeadingItem?.isHidden = !hasUnread
        recentReceiveHistoryItem?.isHidden = !hasUnread
        recentReceiveSeparatorItem?.isHidden = !hasUnread

        for (index, item) in recentReceiveItems.enumerated() {
            guard snapshot.visible.indices.contains(index) else {
                item.isHidden = true
                item.representedObject = nil
                continue
            }
            let summary = snapshot.visible[index]
            let supportsSubtitle: Bool
            if #available(macOS 14.4, *) {
                supportsSubtitle = true
            } else {
                supportsSubtitle = false
            }
            let text = RecentReceiveMenuText(
                primaryTitle: summary.title,
                sourceName: summary.sourceName,
                supportsSubtitle: supportsSubtitle
            )
            item.title = text.title
            if #available(macOS 14.4, *) {
                item.subtitle = text.subtitle ?? ""
            }
            item.representedObject = summary.id.rawValue.uuidString
            item.setAccessibilityLabel(
                "来自\(summary.sourceName)的\(summary.title)，在 Finder 中显示"
            )
            item.isHidden = false
        }

        if snapshot.overflowCount > 0 {
            recentReceiveOverflowItem?.title = "另有 \(snapshot.overflowCount) 个新接收项目…"
            recentReceiveOverflowItem?.isHidden = false
        } else {
            recentReceiveOverflowItem?.isHidden = true
        }
    }

    private func announce(_ message: String) {
        onAnnouncement?(message)
        NSAccessibility.post(
            element: nativeButton ?? button,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    @objc private func showStatusMenu(_ sender: Any?) {
        prepareToOpenStatusMenu()
        statusMenu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.maxY + 2),
            in: button
        )
    }

    @objc private func revealRecentReceive(_ sender: NSMenuItem) {
        guard let rawID = sender.representedObject as? String,
              let uuid = UUID(uuidString: rawID),
              let summary = visibleRecentReceives.first(where: {
                  $0.id == TransferID(rawValue: uuid)
              })
        else { return }
        onRevealRecentReceive?(summary)
    }

    @objc private func showReceiveHistory(_ sender: NSMenuItem) {
        recentReceiveStore?.acknowledgeAll()
        onShowReceiveHistory?()
    }

    @objc private func chooseFiles(_ sender: Any?) {
        performKeyboardSend()
    }

    @objc private func chooseClipboard(_ sender: Any?) {
        performClipboardSend()
    }

    @objc private func showTransfers(_ sender: Any?) {
        onShowTransfers?()
    }

    @objc private func showPairing(_ sender: Any?) {
        onShowPairing?()
    }

    @objc private func showSettings(_ sender: Any?) {
        onShowSettings?()
    }

    @objc private func showAvailableUpdate(_ sender: Any?) {
        availableUpdateAction?()
    }

    @objc private func retryRuntime(_ sender: Any?) {
        onRetryRuntime?()
    }
}

private extension AppRuntimeStatus {
    var canRetry: Bool {
        if case let .startupError(_, canRetry) = self { return canRetry }
        return false
    }

    var symbolName: String {
        switch self {
        case .loading: "hourglass"
        case .ready: "checkmark.shield"
        case .offline: "network.slash"
        case .startupError: "exclamationmark.triangle"
        case .error: "exclamationmark.triangle"
        }
    }
}
