import AppKit
import XCTest
@testable import MacChannelAppKit
@testable import MacChannelCore

final class DeviceFanLayoutTests: XCTestCase {
    func testSixTargetsRemainOnScreenAndDoNotOverlap() {
        let screen = CGRect(x: 0, y: 0, width: 1_000, height: 900)
        let frames = DeviceFanLayout.frames(
            count: 6,
            anchor: CGPoint(x: 900, y: 890),
            screen: screen
        )

        XCTAssertEqual(frames.count, 6)
        XCTAssertTrue(frames.allSatisfy(screen.contains))
        XCTAssertFalse(frames.hasOverlaps)
        XCTAssertTrue(frames.allSatisfy { $0.width >= 40 && $0.height >= 40 })
    }

    func testFanClampsToEveryScreenEdgeWithoutChangingTargetOrder() {
        let screen = CGRect(x: -500, y: -300, width: 700, height: 500)

        for anchor in [
            CGPoint(x: screen.minX, y: screen.minY),
            CGPoint(x: screen.maxX, y: screen.minY),
            CGPoint(x: screen.minX, y: screen.maxY),
            CGPoint(x: screen.maxX, y: screen.maxY),
        ] {
            let frames = DeviceFanLayout.frames(count: 6, anchor: anchor, screen: screen)
            XCTAssertEqual(frames.count, 6)
            XCTAssertTrue(frames.allSatisfy(screen.contains))
            XCTAssertFalse(frames.hasOverlaps)
            XCTAssertEqual(frames.map(\.minX), frames.map(\.minX).sorted())
        }
    }

    func testHitTestReturnsOnlyTheTargetContainingTheDropPoint() throws {
        let frames = DeviceFanLayout.frames(
            count: 3,
            anchor: CGPoint(x: 300, y: 500),
            screen: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        for (index, frame) in frames.enumerated() {
            XCTAssertEqual(DeviceFanLayout.hitTest(frame.center, in: frames), index)
        }
        let first = try XCTUnwrap(frames.first)
        XCTAssertNil(
            DeviceFanLayout.hitTest(
                CGPoint(x: first.minX - 1, y: first.midY),
                in: frames
            )
        )
    }

    func testMoreTargetExpandsAllDevicesWithoutEndingDropSession() {
        let devices = makeDevices(count: 8)
        XCTAssertEqual(DeviceFanTargets.collapsed(devices).count, 6)
        XCTAssertEqual(DeviceFanTargets.collapsed(devices).prefix(5).compactMap(\.deviceID), devices.prefix(5).map(\.id))
        XCTAssertEqual(DeviceFanTargets.collapsed(devices).last, .more(hiddenCount: 3))
        XCTAssertEqual(DeviceFanTargets.expanded(devices).compactMap(\.deviceID), devices.map(\.id))

        var session = DeviceFanDropSession(
            fingerprint: StatusItemDragFingerprint(
                sequenceNumber: 4,
                pasteboardChangeCount: 9
            )
        )
        XCTAssertEqual(session.hover(.more(hiddenCount: 3)), .expandRequested)
        XCTAssertFalse(session.hasPerformedDrop)
        XCTAssertEqual(session.hover(.device(devices[7])), .target(devices[7].id))
    }

    @MainActor
    func testPerformReturnsExactSelectionResultAndCallsSelectionOnce() {
        let device = makeDevices(count: 1)[0]
        let fingerprint = StatusItemDragFingerprint(
            sequenceNumber: 7,
            pasteboardChangeCount: 11
        )
        var session = DeviceFanDropSession(fingerprint: fingerprint)
        _ = session.hover(.device(device))
        var calls = 0

        var cancellations = 0
        XCTAssertFalse(
            session.perform(
                fingerprint: fingerprint,
                select: { selected in
                calls += 1
                XCTAssertEqual(selected, device.id)
                return false
                },
                cancel: { cancellations += 1 }
            )
        )
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(cancellations, 1)
        XCTAssertFalse(
            session.perform(
                fingerprint: fingerprint,
                select: { _ in
                    calls += 1
                    return true
                },
                cancel: { cancellations += 1 }
            )
        )
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(cancellations, 1)
    }

    func testBackgroundDropCancelsCurrentPhysicalSession() {
        let fingerprint = StatusItemDragFingerprint(
            sequenceNumber: 8,
            pasteboardChangeCount: 12
        )
        var session = DeviceFanDropSession(fingerprint: fingerprint)
        var selections = 0
        var cancellations = 0

        XCTAssertFalse(
            session.perform(
                fingerprint: fingerprint,
                select: { _ in selections += 1; return true },
                cancel: { cancellations += 1 }
            )
        )
        XCTAssertEqual(selections, 0)
        XCTAssertEqual(cancellations, 1)
        XCTAssertTrue(session.hasPerformedDrop)
    }

    func testInvalidFinalDropCancelsCurrentPhysicalSessionOnce() {
        let fingerprint = StatusItemDragFingerprint(
            sequenceNumber: 9,
            pasteboardChangeCount: 13
        )
        var session = DeviceFanDropSession(fingerprint: fingerprint)
        var cancellations = 0

        session.rejectInvalidDrop { cancellations += 1 }
        session.rejectInvalidDrop { cancellations += 1 }

        XCTAssertTrue(session.hasPerformedDrop)
        XCTAssertEqual(cancellations, 1)
    }

    func testDeviceAndMoreTargetsExposeTextualAccessibilitySemantics() {
        let device = DeviceSummary(
            id: DeviceID(rawValue: UUID()),
            displayName: "书房 Mac",
            availability: .lan
        )

        let target = DeviceFanTarget.device(device)
        XCTAssertEqual(target.title, "书房 Mac")
        XCTAssertEqual(target.statusText, "局域网在线")
        XCTAssertEqual(target.symbolName, "desktopcomputer")
        XCTAssertEqual(target.accessibilityLabel, "发送到书房 Mac，局域网在线")
        XCTAssertEqual(target.accessibilityHelp, "松开发送")

        let more = DeviceFanTarget.more(hiddenCount: 3)
        XCTAssertEqual(more.title, "更多")
        XCTAssertEqual(more.statusText, "另外 3 台设备")
        XCTAssertEqual(more.accessibilityLabel, "更多，另外 3 台设备")
    }

    @MainActor
    func testPanelIsBorderlessNonactivatingAndDoesNotStealKeyFocus() {
        let panel = DeviceFanPanel()

        XCTAssertTrue(panel.styleMask.contains(.borderless))
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertEqual(panel.level, .statusBar)
    }

    @MainActor
    func testPanelPresentsBelowAnchorAndIgnoresStaleDismissal() throws {
        var state = StatusItemDropStateMachine()
        let intent = try DropIntent(
            items: [.fileURL(URL(fileURLWithPath: "/tmp/drop.txt"))]
        )
        let firstToken = try XCTUnwrap(state.begin(intent: intent))
        let secondToken = try XCTUnwrap(state.begin(intent: intent))
        let devices = makeDevices(count: 8)
        let fingerprint = StatusItemDragFingerprint(
            sequenceNumber: 12,
            pasteboardChangeCount: 18
        )
        let request = DeviceFanRequest(
            token: secondToken,
            intent: intent,
            devices: devices,
            fingerprint: fingerprint,
            dragEntered: { $0 == fingerprint },
            dragExited: { $0 == fingerprint },
            select: { _ in true },
            cancel: {}
        )
        let panel = DeviceFanPanel()
        let anchor = CGRect(x: 880, y: 870, width: 30, height: 24)
        let screen = CGRect(x: 0, y: 0, width: 1_000, height: 900)

        panel.prepare(request: request, anchor: anchor, screen: screen)

        XCTAssertEqual(panel.presentedToken, secondToken)
        XCTAssertLessThanOrEqual(panel.frame.maxY, anchor.minY)
        XCTAssertTrue(screen.contains(panel.frame))
        XCTAssertEqual(panel.visibleTargets.count, 6)
        XCTAssertFalse(panel.dismiss(token: firstToken))
        XCTAssertEqual(panel.presentedToken, secondToken)
        XCTAssertTrue(panel.dismiss(token: secondToken))
        XCTAssertNil(panel.presentedToken)
    }

    @MainActor
    func testPanelMoreExpansionRetainsTokenAndUsesScrollingStrip() throws {
        var state = StatusItemDropStateMachine()
        let intent = try DropIntent(
            items: [.fileURL(URL(fileURLWithPath: "/tmp/drop.txt"))]
        )
        let token = try XCTUnwrap(state.begin(intent: intent))
        let devices = makeDevices(count: 10)
        let request = DeviceFanRequest(
            token: token,
            intent: intent,
            devices: devices,
            fingerprint: StatusItemDragFingerprint(
                sequenceNumber: 19,
                pasteboardChangeCount: 23
            ),
            dragEntered: { _ in true },
            dragExited: { _ in true },
            select: { _ in true },
            cancel: {}
        )
        let panel = DeviceFanPanel()
        panel.prepare(
            request: request,
            anchor: CGRect(x: 380, y: 670, width: 30, height: 24),
            screen: CGRect(x: 0, y: 0, width: 800, height: 700)
        )
        let originalDestination = try XCTUnwrap(panel.dropDestinationIdentity)

        panel.expandMore()

        XCTAssertEqual(panel.presentedToken, token)
        XCTAssertEqual(panel.visibleTargets.compactMap(\.deviceID), devices.map(\.id))
        XCTAssertTrue(panel.usesHorizontalScroller)
        XCTAssertGreaterThan(panel.contentStripWidth, panel.frame.width)
        XCTAssertEqual(panel.dropDestinationIdentity, originalDestination)
    }

    @MainActor
    func testApplicationSurfaceBindingConnectsFanPresentationAndTokenDismissal() throws {
        let button = StatusItemButton(frame: NSRect(x: 20, y: 20, width: 72, height: 24))
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 200, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(button)
        let target = makeDevices(count: 1)[0]
        let controller = StatusItemController(
            button: button,
            devices: [target],
            transferCoordinator: SurfaceFanTransferCoordinator()
        )
        let fanPanel = DeviceFanPanel()
        let surfaces = AppSurfaceController(
            fanPanel: fanPanel,
            transferService: NativeTransferSurfaceService(
                coordinator: SurfaceFanTransferCoordinator()
            ),
            pairingService: UnavailablePairingSurfaceService(),
            settingsService: UnavailableDeviceSettingsService(),
            directorySelector: NativeDirectorySelector()
        )
        surfaces.bind(to: controller)

        let token = try XCTUnwrap(
            controller.beginDrop(
                try DropIntent(items: [.fileURL(URL(fileURLWithPath: "/tmp/a"))])
            )
        )
        XCTAssertEqual(fanPanel.presentedToken, token)

        controller.cancelDrag(token)
        XCTAssertNil(fanPanel.presentedToken)
    }

    private func makeDevices(count: Int) -> [DeviceSummary] {
        (0..<count).map { index in
            DeviceSummary(
                id: DeviceID(rawValue: UUID()),
                displayName: "Mac \(index + 1)",
                availability: index.isMultiple(of: 2) ? .lan : .internet
            )
        }
    }
}

private actor SurfaceFanTransferCoordinator: TransferCoordinating {
    func send(items: [URL], to device: DeviceID) async throws -> TransferID {
        TransferID(rawValue: UUID())
    }

    func pause(_ id: TransferID) async {}
    func resume(_ id: TransferID) async throws {}
    func cancel(_ id: TransferID) async -> TransferCancellationResult { .requested }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

private extension [CGRect] {
    var hasOverlaps: Bool {
        for first in indices {
            for second in indices where first < second && self[first].intersects(self[second]) {
                return true
            }
        }
        return false
    }
}
