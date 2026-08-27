import AppKit
import MacChannelCore

@MainActor
struct DeviceFanRequest {
    let intent: DropIntent
    let devices: [DeviceSummary]
    let dragEntered: @MainActor () -> Void
    let dragExited: @MainActor () -> Void
    let select: @MainActor (DeviceID) -> Void
    let cancel: @MainActor () -> Void
}

@MainActor
final class StatusItemController: NSObject {
    let button: StatusItemButton
    let statusMenu: NSMenu
    var onPresentDeviceFan: ((DeviceFanRequest) -> Void)?
    var onDismissDeviceFan: ((StatusItemDragToken) -> Void)?
    var onTransferStarted: ((TransferID, StatusItemDragToken) -> Void)?

    var phase: StatusItemPhase { state.phase }
    var nativeButton: NSStatusBarButton? { statusItem?.button }

    private let transferCoordinator: any TransferCoordinating
    private var state = StatusItemDropStateMachine()
    private var devices: [DeviceSummary]
    private var currentFanToken: StatusItemDragToken?
    private var fanDragToken: StatusItemDragToken?
    private var deferredExitTask: Task<Void, Never>?
    private var statusItem: NSStatusItem?
    private var deviceTask: Task<Void, Never>?

    init(
        button: StatusItemButton,
        devices: [DeviceSummary],
        transferCoordinator: any TransferCoordinating
    ) {
        self.button = button
        self.devices = devices
        self.transferCoordinator = transferCoordinator
        statusMenu = NSMenu(title: "MacChannel")
        super.init()
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
    func beginDrop(_ intent: DropIntent) -> StatusItemDragToken? {
        let staleFan = currentFanToken
        guard let token = state.begin(intent: intent) else { return nil }
        deferredExitTask?.cancel()
        fanDragToken = nil
        currentFanToken = token
        renderPhase()

        if let staleFan {
            onDismissDeviceFan?(staleFan)
        }
        onPresentDeviceFan?(
            DeviceFanRequest(
                intent: intent,
                devices: devices.filter { $0.availability != .offline },
                dragEntered: { [weak self] in
                    self?.dragEnteredFan(token)
                },
                dragExited: { [weak self] in
                    self?.dragExitedFan(token)
                },
                select: { [weak self] device in
                    self?.selectTarget(device, token: token)
                },
                cancel: { [weak self] in
                    self?.cancelDrag(token)
                }
            )
        )
        return token
    }

    func dragExitedButton(_ token: StatusItemDragToken) {
        deferredExitTask?.cancel()
        deferredExitTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.cancelAfterRegionExit(token)
        }
    }

    func cancelDrag(_ token: StatusItemDragToken) {
        let phaseBefore = state.phase
        state.cancelDrag(token: token)
        guard state.phase != phaseBefore else { return }
        deferredExitTask?.cancel()
        deferredExitTask = nil
        fanDragToken = nil
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

    func invalidate() {
        deferredExitTask?.cancel()
        deviceTask?.cancel()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    private func selectTarget(_ device: DeviceID, token: StatusItemDragToken) {
        guard devices.contains(where: {
            $0.id == device && $0.availability != .offline
        }), let claim = state.claimDrop(token: token, target: device)
        else { return }

        deferredExitTask?.cancel()
        deferredExitTask = nil
        fanDragToken = nil
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
    }

    private func dragEnteredFan(_ token: StatusItemDragToken) {
        guard currentFanToken == token, state.phase == .ready else { return }
        deferredExitTask?.cancel()
        deferredExitTask = nil
        fanDragToken = token
    }

    private func dragExitedFan(_ token: StatusItemDragToken) {
        guard fanDragToken == token else { return }
        fanDragToken = nil
        dragExitedButton(token)
    }

    private func cancelAfterRegionExit(_ token: StatusItemDragToken) {
        guard fanDragToken != token else { return }
        deferredExitTask = nil
        cancelDrag(token)
    }

    private func configureButton() {
        button.target = self
        button.action = #selector(showStatusMenu(_:))
        button.onDragEntered = { [weak self] intent in self?.beginDrop(intent) }
        button.onDragCancelled = { [weak self] token in self?.dragExitedButton(token) }
        button.onDropOutside = { [weak self] token in self?.cancelDrag(token) }
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

    @objc private func showStatusMenu(_ sender: Any?) {
        statusMenu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.maxY + 2),
            in: button
        )
    }

    @objc private func chooseFiles(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK,
              let intent = try? DropIntent(items: panel.urls.map(DropItem.fileURL))
        else { return }
        beginDrop(intent)
    }
}
