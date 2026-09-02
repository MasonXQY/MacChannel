import AppKit
import XCTest
@testable import MacChannelAppKit
@testable import MacChannelCore

final class StatusItemAppKitTests: XCTestCase {
    @MainActor
    func testButtonRegistersFileURLsAndExposesTextualAccessibleState() {
        let button = StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24))

        XCTAssertTrue(button.registeredDraggedTypes.contains(.fileURL))
        XCTAssertTrue(button.image?.isTemplate == true)
        XCTAssertNil(
            button.contentTintColor,
            "idle template icons must let the menu bar choose a contrasting tint"
        )
        XCTAssertEqual(button.accessibilityRole(), .button)
        XCTAssertEqual(button.accessibilityLabel(), "Mac 通道文件传输")
        XCTAssertTrue(button.acceptsFirstResponder)
        XCTAssertEqual(button.focusRingType, .default)

        button.phase = .ready
        XCTAssertEqual(button.title, "准备发送")
        XCTAssertEqual(button.accessibilityValue() as? String, "准备发送，可选择接收设备")
        XCTAssertNil(
            button.contentTintColor,
            "ready template icons must also remain legible over dark menu bars"
        )

        button.phase = .transferring(progress: 0.42)
        XCTAssertEqual(button.title, "42%")
        XCTAssertEqual(button.accessibilityValue() as? String, "正在传输，42%")
        XCTAssertNil(
            button.contentTintColor,
            "transfer icons must keep the menu bar's automatic contrasting tint"
        )
    }

    @MainActor
    func testControllerMenuProvidesKeyboardSendFallback() {
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [],
            transferCoordinator: RecordingTransferCoordinator()
        )

        let sendItem = controller.statusMenu.items.first { $0.title == "发送文件…" }
        XCTAssertEqual(sendItem?.keyEquivalent, "s")
        XCTAssertEqual(sendItem?.keyEquivalentModifierMask, [.command, .shift])
    }

    @MainActor
    func testAvailableUpdateAddsAccessibleMenuActionAndIndicator() throws {
        _ = NSApplication.shared
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [],
            transferCoordinator: RecordingTransferCoordinator()
        )
        var opened = 0

        controller.setUpdateAvailable(true, action: { opened += 1 })

        let item = controller.statusMenu.items.first { $0.title == "有新版本可用" }
        XCTAssertFalse(item?.isHidden ?? true)
        let action = try XCTUnwrap(item?.action)
        XCTAssertTrue(NSApp.sendAction(action, to: item?.target, from: item))
        XCTAssertEqual(opened, 1)
        XCTAssertTrue(controller.button.updateAvailable)
        XCTAssertTrue(controller.button.showsUpdateIndicator)
        XCTAssertTrue(controller.button.updateActionEnabled)
        XCTAssertTrue(
            (controller.button.accessibilityValue() as? String)?.contains("有新版本") == true
        )

        controller.button.phase = .ready
        XCTAssertFalse(controller.button.showsUpdateIndicator)
        XCTAssertTrue(
            (controller.button.accessibilityValue() as? String)?.contains("有新版本") == true
        )

        controller.setUpdateAvailable(true, action: nil)
        XCTAssertFalse(item?.isEnabled ?? true)
        XCTAssertFalse(controller.button.updateActionEnabled)
        XCTAssertTrue(
            (controller.button.accessibilityValue() as? String)?
                .contains("暂时无法查看") == true
        )

        controller.setUpdateAvailable(false, action: nil)
        XCTAssertTrue(item?.isHidden ?? false)
        XCTAssertFalse(controller.button.updateAvailable)
    }

    @MainActor
    func testReceiveIndicatorAppearsAndOpeningMenuClearsIt() {
        let button = StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24))
        let controller = StatusItemController(
            button: button,
            devices: [],
            transferCoordinator: RecordingTransferCoordinator()
        )

        controller.setUnreadReceive(true)

        XCTAssertTrue(controller.hasUnreadReceive)
        XCTAssertTrue(button.showsReceiveIndicator)
        XCTAssertTrue((button.accessibilityValue() as? String)?.contains("有新接收文件") == true)

        controller.prepareToOpenStatusMenu()

        XCTAssertFalse(controller.hasUnreadReceive)
        XCTAssertFalse(button.showsReceiveIndicator)
    }

    @MainActor
    func testReceiveIndicatorUsesResolvableSystemGreenInLightAndDarkAppearances() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("App/StatusItemButton.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("NSColor.systemGreen"))

        for name: NSAppearance.Name in [.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var resolved: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                resolved = NSColor.systemGreen.usingColorSpace(.sRGB)
            }
            let color = try XCTUnwrap(
                resolved,
                "system green did not resolve for \(name.rawValue)"
            )
            XCTAssertEqual(color.alphaComponent, CGFloat(1), accuracy: CGFloat(0.001))
        }
    }

    @MainActor
    func testUpdateAndReceiveIndicatorsUseDistinctRectanglesWhenBothAreActive() throws {
        let button = StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24))

        button.updateAvailable = true
        button.hasUnreadReceive = true

        XCTAssertNotEqual(
            try XCTUnwrap(button.updateIndicatorRect),
            try XCTUnwrap(button.receiveIndicatorRect)
        )
        XCTAssertLessThan(
            try XCTUnwrap(button.updateIndicatorRect).minY,
            try XCTUnwrap(button.receiveIndicatorRect).minY
        )
        XCTAssertEqual(try XCTUnwrap(button.updateIndicatorRect).width, 4)
        XCTAssertEqual(try XCTUnwrap(button.receiveIndicatorRect).width, 6)
        XCTAssertTrue((button.accessibilityValue() as? String)?.contains("有新版本") == true)
        XCTAssertTrue((button.accessibilityValue() as? String)?.contains("有新接收文件") == true)
    }

    @MainActor
    func testUnavailableUpdateMenuSurvivesAutoValidationAndRestoresItsAction() throws {
        _ = NSApplication.shared
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [],
            transferCoordinator: RecordingTransferCoordinator()
        )
        let item = try XCTUnwrap(
            controller.statusMenu.items.first { $0.title == "有新版本可用" }
        )

        controller.setUpdateAvailable(true, action: nil)
        controller.statusMenu.update()

        XCTAssertFalse(item.isHidden)
        XCTAssertFalse(item.isEnabled)
        XCTAssertNil(item.action)
        XCTAssertNil(item.target)
        XCTAssertTrue(item.accessibilityHelp()?.contains("暂时不可用") == true)

        var opened = 0
        controller.setUpdateAvailable(true, action: { opened += 1 })
        controller.statusMenu.update()

        XCTAssertTrue(item.isEnabled)
        let action = try XCTUnwrap(item.action)
        XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item))
        XCTAssertEqual(opened, 1)
    }

    @MainActor
    func testUpdateIndicatorUsesResolvableSystemAccentInLightAndDarkAppearances() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("App/StatusItemButton.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("NSColor.controlAccentColor"))

        for name: NSAppearance.Name in [.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var resolved: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                resolved = NSColor.controlAccentColor.usingColorSpace(.sRGB)
            }
            let color = try XCTUnwrap(
                resolved,
                "accent color did not resolve for \(name.rawValue)"
            )
            XCTAssertEqual(color.alphaComponent, CGFloat(1), accuracy: CGFloat(0.001))
        }
    }

    @MainActor
    func testKeyboardFilePickerPresentsOnlineDevicesAndUsesOneShotSend() async throws {
        let transfer = RecordingTransferCoordinator()
        let online = DeviceID(rawValue: UUID())
        let offline = DeviceID(rawValue: UUID())
        let file = URL(fileURLWithPath: "/tmp/keyboard.txt")
        let picker = StubStatusItemFilePicker(result: [file])
        let menu = RecordingStatusItemDeviceMenuPresenter()
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [
                DeviceSummary(id: offline, displayName: "Offline Mac", availability: .offline),
                DeviceSummary(id: online, displayName: "Desk Mac", availability: .lan),
            ],
            transferCoordinator: transfer,
            filePicker: picker,
            deviceMenuPresenter: menu
        )

        controller.performKeyboardSend()

        XCTAssertEqual(picker.chooseCount, 1)
        XCTAssertEqual(menu.presentedDevices.map(\.id), [online])
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertTrue(try XCTUnwrap(menu.select)(online))
        XCTAssertFalse(try XCTUnwrap(menu.select)(online))

        for _ in 0..<100 where await transfer.sentCount() == 0 {
            await Task.yield()
        }
        let sends = await transfer.sentItems()
        XCTAssertEqual(sends.count, 1)
        XCTAssertEqual(sends.first?.0, [file])
        XCTAssertEqual(sends.first?.1, online)
    }

    @MainActor
    func testSavedPairingNameFillsBlankDiscoveryNameInSendMenu() throws {
        let target = DeviceID(rawValue: UUID())
        let picker = StubStatusItemFilePicker(
            result: [URL(fileURLWithPath: "/tmp/named-device.txt")]
        )
        let menu = RecordingStatusItemDeviceMenuPresenter()
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [DeviceSummary(id: target, displayName: "", availability: .lan)],
            transferCoordinator: RecordingTransferCoordinator(),
            filePicker: picker,
            deviceMenuPresenter: menu
        )
        let surfaces = AppSurfaceController(
            transferService: NativeTransferSurfaceService(
                coordinator: RecordingTransferCoordinator()
            ),
            pairingService: UnavailablePairingSurfaceService(),
            settingsService: UnavailableDeviceSettingsService(),
            directorySelector: NativeDirectorySelector()
        )
        surfaces.bind(to: controller)
        surfaces.updateDeviceSettings([
            DeviceSetting(
                device: DeviceSummary(
                    id: target,
                    displayName: "书房 Mac",
                    availability: .offline
                )
            )
        ])

        controller.performKeyboardSend()

        XCTAssertEqual(try XCTUnwrap(menu.presentedDevices.first).displayName, "书房 Mac")
    }

    @MainActor
    func testKeyboardFilePickerWithNoOnlineDeviceReturnsIdleAndAnnounces() {
        let picker = StubStatusItemFilePicker(
            result: [URL(fileURLWithPath: "/tmp/keyboard.txt")]
        )
        let menu = RecordingStatusItemDeviceMenuPresenter()
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [
                DeviceSummary(
                    id: DeviceID(rawValue: UUID()),
                    displayName: "Offline Mac",
                    availability: .offline
                )
            ],
            transferCoordinator: RecordingTransferCoordinator(),
            filePicker: picker,
            deviceMenuPresenter: menu
        )
        var announcements: [String] = []
        controller.onAnnouncement = { announcements.append($0) }

        controller.performKeyboardSend()

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(menu.presentCount, 0)
        XCTAssertEqual(announcements, ["没有在线设备。"])
    }

    @MainActor
    func testDraggedFileWithNoOnlineDeviceNeverEntersReadyOrPresentsEmptyFan() throws {
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [
                DeviceSummary(
                    id: DeviceID(rawValue: UUID()),
                    displayName: "Offline Mac",
                    availability: .offline
                )
            ],
            transferCoordinator: RecordingTransferCoordinator()
        )
        var requests: [DeviceFanRequest] = []
        var announcements: [String] = []
        controller.onPresentDeviceFan = { requests.append($0) }
        controller.onAnnouncement = { announcements.append($0) }

        let token = controller.beginDrop(
            try DropIntent(items: [.fileURL(URL(fileURLWithPath: "/tmp/no-target.txt"))])
        )

        XCTAssertNil(token)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(announcements, ["没有在线接收设备，请先完成配对并确认对方 Mac 已启动。"])
    }

    @MainActor
    func testFailedSendReturnsIdleAndAnnouncesActionableError() async throws {
        let target = DeviceID(rawValue: UUID())
        let menu = RecordingStatusItemDeviceMenuPresenter()
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [DeviceSummary(id: target, displayName: "书房 Mac", availability: .lan)],
            transferCoordinator: FailingTransferCoordinator(),
            filePicker: StubStatusItemFilePicker(
                result: [URL(fileURLWithPath: "/tmp/a")]
            ),
            deviceMenuPresenter: menu
        )
        var announcements: [String] = []
        controller.onAnnouncement = { announcements.append($0) }

        controller.performKeyboardSend()
        XCTAssertTrue(try XCTUnwrap(menu.select)(target))
        for _ in 0..<100 where controller.phase != .idle {
            await Task.yield()
        }

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(announcements, ["无法开始传输，请检查连接和设备状态。"])
    }

    @MainActor
    func testInstalledSystemStatusButtonOwnsKeyboardAndAccessibilitySemantics() throws {
        _ = NSApplication.shared
        let controller = StatusItemController(
            deviceDirectory: DeviceDirectory(trust: DeviceTrust(trustedIDs: [])),
            transferCoordinator: RecordingTransferCoordinator()
        )
        defer { controller.invalidate() }

        let nativeButton = try XCTUnwrap(controller.nativeButton)
        XCTAssertTrue(nativeButton.target === controller)
        XCTAssertNotNil(nativeButton.action)
        XCTAssertTrue(nativeButton.isAccessibilityElement())
        XCTAssertEqual(nativeButton.accessibilityRole(), .button)
        XCTAssertEqual(nativeButton.accessibilityLabel(), "Mac 通道文件传输")
        XCTAssertEqual(nativeButton.accessibilityValue() as? String, "空闲")
        XCTAssertFalse(controller.button.isAccessibilityElement())
        XCTAssertEqual(nativeButton.focusRingType, .default)

        controller.setUpdateAvailable(true, action: {})
        XCTAssertTrue(
            (nativeButton.accessibilityValue() as? String)?.contains("有新版本可用") == true
        )
    }

    @MainActor
    func testControllerRejectsStaleFanCallbacksAndSendsCurrentDropOnce() async throws {
        let transfer = RecordingTransferCoordinator()
        let target = DeviceID(rawValue: UUID())
        let devices = [DeviceSummary(id: target, displayName: "Desk Mac", availability: .lan)]
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: devices,
            transferCoordinator: transfer
        )
        var requests: [DeviceFanRequest] = []
        var startedTransfer: (TransferID, StatusItemDragToken)?
        controller.onPresentDeviceFan = { requests.append($0) }
        controller.onTransferStarted = { startedTransfer = ($0, $1) }

        _ = controller.beginDrop(
            try DropIntent(items: [.fileURL(URL(fileURLWithPath: "/tmp/first"))])
        )
        _ = controller.beginDrop(
            try DropIntent(items: [.fileURL(URL(fileURLWithPath: "/tmp/current"))])
        )
        XCTAssertEqual(requests.count, 2)

        XCTAssertFalse(requests[0].select(target))
        requests[0].cancel()
        XCTAssertEqual(controller.phase, .ready)

        XCTAssertTrue(requests[1].select(target))
        XCTAssertFalse(requests[1].select(target))

        for _ in 0..<100 where await transfer.sentCount() == 0 {
            await Task.yield()
        }
        let sends = await transfer.sentItems()
        XCTAssertEqual(sends.count, 1)
        XCTAssertEqual(sends.first?.0, [URL(fileURLWithPath: "/tmp/current")])
        XCTAssertEqual(sends.first?.1, target)
        XCTAssertNotNil(startedTransfer)
        XCTAssertEqual(controller.phase, .transferring(progress: 0))

        let token = try XCTUnwrap(startedTransfer?.1)
        controller.updateTransferProgress(0.42, token: token)
        XCTAssertEqual(controller.phase, .transferring(progress: 0.42))
        controller.completeTransfer(token: token)
        XCTAssertEqual(controller.phase, .idle)
    }

    @MainActor
    func testButtonExitDefersCancellationWhenFanTakesOverDrag() throws {
        let target = DeviceID(rawValue: UUID())
        let scheduler = ManualDragRegionScheduler()
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [DeviceSummary(id: target, displayName: "Desk Mac", availability: .lan)],
            transferCoordinator: RecordingTransferCoordinator(),
            dragRegionSchedule: scheduler.schedule
        )
        var request: DeviceFanRequest?
        controller.onPresentDeviceFan = { request = $0 }
        let fingerprint = StatusItemDragFingerprint(
            sequenceNumber: 7,
            pasteboardChangeCount: 11
        )
        let token = try XCTUnwrap(
            controller.beginDrop(
                try DropIntent(items: [.fileURL(URL(fileURLWithPath: "/tmp/a"))]),
                fingerprint: fingerprint
            )
        )

        XCTAssertTrue(controller.dragExitedButton(token, fingerprint: fingerprint))
        XCTAssertEqual(request?.dragEntered(fingerprint), true)
        scheduler.advance(by: .milliseconds(120), includingCancelled: true)

        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(request?.select(target), true)
        XCTAssertEqual(controller.phase, .transferring(progress: 0))
    }

    @MainActor
    func testFanSelectionSynchronouslyRejectsUnavailableTarget() async throws {
        let transfer = RecordingTransferCoordinator()
        let target = DeviceID(rawValue: UUID())
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [
                DeviceSummary(
                    id: DeviceID(rawValue: UUID()),
                    displayName: "Online Mac",
                    availability: .lan
                )
            ],
            transferCoordinator: transfer
        )
        var request: DeviceFanRequest?
        var announcements: [String] = []
        var dismissals = 0
        controller.onPresentDeviceFan = { request = $0 }
        controller.onAnnouncement = { announcements.append($0) }
        controller.onDismissDeviceFan = { _ in dismissals += 1 }
        _ = controller.beginDrop(
            try DropIntent(items: [.fileURL(URL(fileURLWithPath: "/tmp/a"))])
        )

        XCTAssertEqual(request?.select(target), false)
        request?.cancel()
        request?.cancel()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(announcements, ["目标设备已离线，请重新选择。"])
        XCTAssertEqual(dismissals, 1)
        let sentCount = await transfer.sentCount()
        XCTAssertEqual(sentCount, 0)
    }

    @MainActor
    func testButtonExitOutsideFanCancelsAfterGraceExpires() throws {
        let scheduler = ManualDragRegionScheduler()
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [
                DeviceSummary(
                    id: DeviceID(rawValue: UUID()),
                    displayName: "Online Mac",
                    availability: .lan
                )
            ],
            transferCoordinator: RecordingTransferCoordinator(),
            dragRegionSchedule: scheduler.schedule
        )
        let fingerprint = StatusItemDragFingerprint(
            sequenceNumber: 8,
            pasteboardChangeCount: 12
        )
        let token = try XCTUnwrap(
            controller.beginDrop(
                try DropIntent(items: [.fileURL(URL(fileURLWithPath: "/tmp/a"))]),
                fingerprint: fingerprint
            )
        )

        XCTAssertTrue(controller.dragExitedButton(token, fingerprint: fingerprint))
        XCTAssertEqual(controller.phase, .ready)
        scheduler.advance(by: .milliseconds(119), includingCancelled: true)
        XCTAssertEqual(controller.phase, .ready)
        scheduler.advance(by: .milliseconds(1), includingCancelled: true)

        XCTAssertEqual(controller.phase, .idle)
    }

    @MainActor
    func testFanExitThenIconReentryReusesPhysicalDragToken() throws {
        let scheduler = ManualDragRegionScheduler()
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [
                DeviceSummary(
                    id: DeviceID(rawValue: UUID()),
                    displayName: "Online Mac",
                    availability: .lan
                )
            ],
            transferCoordinator: RecordingTransferCoordinator(),
            dragRegionSchedule: scheduler.schedule
        )
        let intent = try DropIntent(
            items: [.fileURL(URL(fileURLWithPath: "/tmp/a"))]
        )
        let fingerprint = StatusItemDragFingerprint(
            sequenceNumber: 9,
            pasteboardChangeCount: 13
        )
        var request: DeviceFanRequest?
        controller.onPresentDeviceFan = { request = $0 }
        let token = try XCTUnwrap(
            controller.beginDrop(intent, fingerprint: fingerprint)
        )
        XCTAssertEqual(request?.dragEntered(fingerprint), true)
        XCTAssertTrue(controller.dragExitedButton(token, fingerprint: fingerprint))
        XCTAssertEqual(request?.dragExited(fingerprint), true)

        let reenteredToken = controller.dragEnteredButton(intent, fingerprint: fingerprint)
        scheduler.advance(by: .milliseconds(120), includingCancelled: true)

        XCTAssertEqual(reenteredToken, token)
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(request?.dragExited(fingerprint), false)
    }
}

private actor RecordingTransferCoordinator: TransferCoordinating {
    private var sends: [([URL], DeviceID)] = []

    func send(items: [URL], to device: DeviceID) async throws -> TransferID {
        sends.append((items, device))
        return TransferID(rawValue: UUID())
    }

    func pause(_ id: TransferID) async {}
    func resume(_ id: TransferID) async throws {}
    func cancel(_ id: TransferID) async -> TransferCancellationResult { .requested }

    func sentCount() -> Int { sends.count }
    func sentItems() -> [([URL], DeviceID)] { sends }
}

private actor FailingTransferCoordinator: TransferCoordinating {
    func send(items: [URL], to device: DeviceID) async throws -> TransferID {
        throw MacChannelError.connectionFailed
    }

    func pause(_ id: TransferID) async {}
    func resume(_ id: TransferID) async throws {}
    func cancel(_ id: TransferID) async -> TransferCancellationResult { .tooLate }
}

@MainActor
private final class StubStatusItemFilePicker: StatusItemFilePicking {
    let result: [URL]?
    private(set) var chooseCount = 0

    init(result: [URL]?) {
        self.result = result
    }

    func chooseFiles() -> [URL]? {
        chooseCount += 1
        return result
    }
}

@MainActor
private final class RecordingStatusItemDeviceMenuPresenter: StatusItemDeviceMenuPresenting {
    private(set) var presentCount = 0
    private(set) var presentedDevices: [DeviceSummary] = []
    private(set) var select: ((DeviceID) -> Bool)?
    private(set) var cancel: (() -> Void)?

    func present(
        devices: [DeviceSummary],
        anchor: NSView,
        select: @escaping (DeviceID) -> Bool,
        cancel: @escaping () -> Void
    ) {
        presentCount += 1
        presentedDevices = devices
        self.select = select
        self.cancel = cancel
    }
}
