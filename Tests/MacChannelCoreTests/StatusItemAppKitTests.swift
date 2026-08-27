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

        requests[0].select(target)
        requests[0].cancel()
        XCTAssertEqual(controller.phase, .ready)

        requests[1].select(target)
        requests[1].select(target)

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
    func testButtonExitDefersCancellationWhenFanTakesOverDrag() async throws {
        let target = DeviceID(rawValue: UUID())
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [DeviceSummary(id: target, displayName: "Desk Mac", availability: .lan)],
            transferCoordinator: RecordingTransferCoordinator()
        )
        var request: DeviceFanRequest?
        controller.onPresentDeviceFan = { request = $0 }
        let token = try XCTUnwrap(
            controller.beginDrop(
                try DropIntent(items: [.fileURL(URL(fileURLWithPath: "/tmp/a"))])
            )
        )

        controller.dragExitedButton(token)
        request?.dragEntered()
        await Task.yield()

        XCTAssertEqual(controller.phase, .ready)
        request?.select(target)
        XCTAssertEqual(controller.phase, .transferring(progress: 0))
    }

    @MainActor
    func testButtonExitOutsideFanCancelsOnNextMainActorTurn() async throws {
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [],
            transferCoordinator: RecordingTransferCoordinator()
        )
        let token = try XCTUnwrap(
            controller.beginDrop(
                try DropIntent(items: [.fileURL(URL(fileURLWithPath: "/tmp/a"))])
            )
        )

        controller.dragExitedButton(token)
        for _ in 0..<10 where controller.phase != .idle {
            await Task.yield()
        }

        XCTAssertEqual(controller.phase, .idle)
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
