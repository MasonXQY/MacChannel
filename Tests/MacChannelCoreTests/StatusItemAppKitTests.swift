import AppKit
import XCTest
@testable import MacChannelAppKit
@testable import MacChannelCore

final class StatusItemAppKitTests: XCTestCase {
    @MainActor
    func testButtonRegistersFileURLsAndExposesTextualAccessibleState() {
        let button = StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24))

        XCTAssertTrue(button.registeredDraggedTypes.contains(.fileURL))
        XCTAssertEqual(button.accessibilityRole(), .button)
        XCTAssertEqual(button.accessibilityLabel(), "MacChannel file transfer")
        XCTAssertTrue(button.acceptsFirstResponder)
        XCTAssertEqual(button.focusRingType, .default)

        button.phase = .ready
        XCTAssertEqual(button.title, "Ready")
        XCTAssertEqual(button.accessibilityValue() as? String, "Ready to choose a device")

        button.phase = .transferring(progress: 0.42)
        XCTAssertEqual(button.title, "42%")
        XCTAssertEqual(button.accessibilityValue() as? String, "Transferring, 42 percent")
    }

    @MainActor
    func testControllerMenuProvidesKeyboardSendFallback() {
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [],
            transferCoordinator: RecordingTransferCoordinator()
        )

        let sendItem = controller.statusMenu.items.first { $0.title == "Send Files…" }
        XCTAssertEqual(sendItem?.keyEquivalent, "s")
        XCTAssertEqual(sendItem?.keyEquivalentModifierMask, [.command, .shift])
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
        XCTAssertEqual(announcements, ["No online devices available."])
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
        XCTAssertEqual(nativeButton.accessibilityLabel(), "MacChannel file transfer")
        XCTAssertEqual(nativeButton.accessibilityValue() as? String, "Idle")
        XCTAssertFalse(controller.button.isAccessibilityElement())
        XCTAssertEqual(nativeButton.focusRingType, .default)
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
    func testFanSelectionSynchronouslyRejectsOfflineTarget() async throws {
        let transfer = RecordingTransferCoordinator()
        let target = DeviceID(rawValue: UUID())
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [DeviceSummary(id: target, displayName: "Desk Mac", availability: .offline)],
            transferCoordinator: transfer
        )
        var request: DeviceFanRequest?
        controller.onPresentDeviceFan = { request = $0 }
        _ = controller.beginDrop(
            try DropIntent(items: [.fileURL(URL(fileURLWithPath: "/tmp/a"))])
        )

        XCTAssertEqual(request?.select(target), false)
        XCTAssertEqual(controller.phase, .ready)
        let sentCount = await transfer.sentCount()
        XCTAssertEqual(sentCount, 0)
    }

    @MainActor
    func testButtonExitOutsideFanCancelsAfterGraceExpires() throws {
        let scheduler = ManualDragRegionScheduler()
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [],
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
            devices: [],
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
