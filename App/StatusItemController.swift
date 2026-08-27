import AppKit
import MacChannelCore

@MainActor
struct DeviceFanRequest {
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

    var phase: StatusItemPhase { state.phase }
    var nativeButton: NSStatusBarButton? { statusItem?.button }

    private let transferCoordinator: any TransferCoordinating
    private let filePicker: any StatusItemFilePicking
    private let deviceMenuPresenter: any StatusItemDeviceMenuPresenting
    private var state = StatusItemDropStateMachine()
    private var devices: [DeviceSummary]
    private var currentFanToken: StatusItemDragToken?
    private var dragRegionSession: DragRegionSession!
    private var statusItem: NSStatusItem?
    private var deviceTask: Task<Void, Never>?

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
        renderPhase()

        if let staleFan {
            onDismissDeviceFan?(staleFan)
        }
        onPresentDeviceFan?(
            DeviceFanRequest(
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
            announce("The selected items cannot be sent.")
            return
        }

        let onlineDevices = devices
            .filter { $0.availability != .offline }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        guard !onlineDevices.isEmpty else {
            announce("No online devices available.")
            return
        }

        let staleFan = currentFanToken
        guard let token = state.begin(intent: intent) else {
            announce("A transfer is already active.")
            return
        }
        if let staleFan {
            dragRegionSession.invalidate(token: staleFan)
            onDismissDeviceFan?(staleFan)
        }
        currentFanToken = nil
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

    private func selectTarget(_ device: DeviceID, token: StatusItemDragToken) -> Bool {
        guard devices.contains(where: {
            $0.id == device && $0.availability != .offline
        }), let claim = state.claimDrop(token: token, target: device)
        else { return false }

        dragRegionSession.invalidate(token: token)
        currentFanToken = nil
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
                // Transfer surfaces added in the next task own user-facing errors.
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
        let send = NSMenuItem(
            title: "Send Files…",
            action: #selector(chooseFiles(_:)),
            keyEquivalent: "s"
        )
        send.keyEquivalentModifierMask = [.command, .shift]
        send.target = self
        statusMenu.addItem(send)
        statusMenu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit MacChannel",
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
        host.setAccessibilityLabel("MacChannel file transfer")
        host.setAccessibilityHelp(
            "Open the status menu, or drag local files here to choose a device."
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
        nativeButton?.setAccessibilityValue(state.phase.presentation.accessibilityValue)
        nativeButton?.toolTip = state.phase.presentation.accessibilityValue
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
}
