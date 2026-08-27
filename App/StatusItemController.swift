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
}

@MainActor
final class StatusItemController: NSObject {
    let button: StatusItemButton
    let statusMenu: NSMenu
    var onPresentDeviceFan: ((DeviceFanRequest) -> Void)?
    var onDismissDeviceFan: ((StatusItemDragToken) -> Void)?
    var onTransferStarted: ((TransferID, StatusItemDragToken) -> Void)?
    var onAnnouncement: ((String) -> Void)?
    var onShowTransfers: (() -> Void)?
    var onShowPairing: (() -> Void)?
    var onShowSettings: (() -> Void)?

    var phase: StatusItemPhase { state.phase }
    var nativeButton: NSStatusBarButton? { statusItem?.button }

    private let transferCoordinator: any TransferCoordinating
    private let filePicker: any StatusItemFilePicking
    private let deviceMenuPresenter: any StatusItemDeviceMenuPresenting
    private var state = StatusItemDropStateMachine()
    private var devices: [DeviceSummary]
    private var currentFanToken: StatusItemDragToken?
    private var activeSelectionToken: StatusItemDragToken?
    private var announcedOfflineToken: StatusItemDragToken?
    private var dragRegionSession: DragRegionSession!
    private var statusItem: NSStatusItem?
    private var deviceTask: Task<Void, Never>?
    private var runtimeStatus: AppRuntimeStatus?
    private var runtimeStatusItem: NSMenuItem?

    init(
        button: StatusItemButton,
        devices: [DeviceSummary],
        transferCoordinator: any TransferCoordinating,
        filePicker: (any StatusItemFilePicking)? = nil,
        deviceMenuPresenter: (any StatusItemDeviceMenuPresenting)? = nil,
        dragRegionSchedule: DragRegionSchedule? = nil
    ) {
        self.button = button
        self.devices = devices
        self.transferCoordinator = transferCoordinator
        self.filePicker = filePicker ?? NativeStatusItemFilePicker()
        self.deviceMenuPresenter = deviceMenuPresenter ?? NativeStatusItemDeviceMenuPresenter()
        statusMenu = NSMenu(title: "MacChannel")
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
        let staleFan = currentFanToken
        guard let token = state.begin(intent: intent) else { return nil }
        dragRegionSession.begin(token: token, fingerprint: fingerprint, in: .icon)
        currentFanToken = token
        activeSelectionToken = token
        announcedOfflineToken = nil
        renderPhase()

        if let staleFan {
            onDismissDeviceFan?(staleFan)
        }
        onPresentDeviceFan?(
            DeviceFanRequest(
                token: token,
                intent: intent,
                devices: devices.filter { $0.availability != .offline },
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
        let phaseBefore = state.phase
        state.cancelDrag(token: token)
        guard state.phase != phaseBefore else { return }
        dragRegionSession.invalidate(token: token)
        if currentFanToken == token {
            currentFanToken = nil
        }
        if activeSelectionToken == token {
            activeSelectionToken = nil
            announcedOfflineToken = nil
        }
        onDismissDeviceFan?(token)
        renderPhase()
    }

    func updateTransferProgress(_ progress: Double, token: StatusItemDragToken) {
        state.updateProgress(token: token, progress: progress)
        renderPhase()
    }

    func completeTransfer(token: StatusItemDragToken) {
        state.finishTransfer(token: token)
        renderPhase()
    }

    func performKeyboardSend() {
        guard let urls = filePicker.chooseFiles() else { return }
        guard let intent = try? DropIntent(items: urls.map(DropItem.fileURL)) else {
            announce("所选项目无法发送。")
            return
        }

        let onlineDevices = devices
            .filter { $0.availability != .offline }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        guard !onlineDevices.isEmpty else {
            announce("没有在线设备。")
            return
        }

        let staleFan = currentFanToken
        guard let token = state.begin(intent: intent) else {
            announce("已有传输正在进行。")
            return
        }
        if let staleFan {
            dragRegionSession.invalidate(token: staleFan)
            onDismissDeviceFan?(staleFan)
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
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    func setRuntimeStatus(_ status: AppRuntimeStatus) {
        runtimeStatus = status
        runtimeStatusItem?.title = status.localizedText
        runtimeStatusItem?.image = NSImage(
            systemSymbolName: status.symbolName,
            accessibilityDescription: status.localizedText
        )
        renderPhase()
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

        dragRegionSession.invalidate(token: token)
        currentFanToken = nil
        activeSelectionToken = nil
        announcedOfflineToken = nil
        onDismissDeviceFan?(token)
        renderPhase()

        Task { [weak self, transferCoordinator, claim] in
            do {
                let transferID = try await transferCoordinator.send(
                    items: claim.urls,
                    to: claim.target
                )
                self?.onTransferStarted?(transferID, token)
            } catch {
                self?.announce("无法开始传输，请检查连接和设备状态。")
                self?.completeTransfer(token: token)
            }
        }
        return true
    }

    private func dragEnteredFan(
        _ token: StatusItemDragToken,
        fingerprint: StatusItemDragFingerprint
    ) -> Bool {
        guard currentFanToken == token, state.phase == .ready else { return false }
        return dragRegionSession.enter(.fan, token: token, fingerprint: fingerprint)
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
        let initialRuntimeStatus = runtimeStatus ?? .loading
        let runtime = NSMenuItem(title: initialRuntimeStatus.localizedText, action: nil, keyEquivalent: "")
        runtime.isEnabled = false
        runtime.image = NSImage(
            systemSymbolName: initialRuntimeStatus.symbolName,
            accessibilityDescription: initialRuntimeStatus.localizedText
        )
        runtimeStatusItem = runtime
        statusMenu.addItem(runtime)
        statusMenu.addItem(.separator())

        let send = NSMenuItem(
            title: "发送文件…",
            action: #selector(chooseFiles(_:)),
            keyEquivalent: "s"
        )
        send.keyEquivalentModifierMask = [.command, .shift]
        send.target = self
        statusMenu.addItem(send)
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
        statusMenu.addItem(.separator())

        let quit = NSMenuItem(
            title: "退出 Mac 通道",
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
        host.setAccessibilityLabel("Mac 通道文件传输")
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
                self?.devices = devices
            }
        }
    }

    private func renderPhase() {
        button.phase = state.phase
        let accessibilityValue = if let runtimeStatus {
            "\(state.phase.localizedAccessibilityValue)，\(runtimeStatus.localizedText)"
        } else {
            state.phase.localizedAccessibilityValue
        }
        button.setAccessibilityValue(accessibilityValue)
        nativeButton?.setAccessibilityValue(accessibilityValue)
        nativeButton?.toolTip = accessibilityValue
        statusItem?.length = button.preferredWidth
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
        statusMenu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.maxY + 2),
            in: button
        )
    }

    @objc private func chooseFiles(_ sender: Any?) {
        performKeyboardSend()
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
}

private extension AppRuntimeStatus {
    var symbolName: String {
        switch self {
        case .loading: "hourglass"
        case .ready: "checkmark.shield"
        case .offline: "network.slash"
        case .error: "exclamationmark.triangle"
        }
    }
}
