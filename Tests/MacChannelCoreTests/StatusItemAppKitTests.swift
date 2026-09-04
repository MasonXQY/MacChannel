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
        XCTAssertEqual(button.accessibilityLabel(), "DropMesh 文件传输")
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
        XCTAssertEqual(button.title, "")
        XCTAssertTrue(button.image?.isTemplate == true)
        XCTAssertEqual(button.preferredWidth, 30)
        XCTAssertTrue(button.showsTransferProgressIndicator)
        XCTAssertEqual(button.accessibilityValue() as? String, "正在传输，42%")
        XCTAssertNil(
            button.contentTintColor,
            "transfer icons must keep the menu bar's automatic contrasting tint"
        )
    }

    @MainActor
    func testTransferProgressUsesCompactGreenBarWithoutCollidingWithUnreadDot() throws {
        let button = StatusItemButton(frame: NSRect(x: 0, y: 0, width: 30, height: 24))
        button.phase = .transferring(progress: 0.51)
        button.hasUnreadReceive = true

        XCTAssertTrue(button.showsTransferProgressIndicator)
        XCTAssertEqual(button.transferProgressTrackRect.width, 14)
        XCTAssertEqual(button.transferProgressTrackRect.height, 2)
        XCTAssertEqual(button.transferProgressFillRect.width, 7.14, accuracy: 0.001)
        XCTAssertTrue(
            button.transferProgressTrackRect.intersection(button.receiveIndicatorRect).isEmpty
        )

        for name: NSAppearance.Name in [.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var actual: NSColor?
            var expected: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                actual = button.transferProgressIndicatorColor.usingColorSpace(.sRGB)
                expected = NSColor.systemGreen.usingColorSpace(.sRGB)
            }
            let resolvedActual = try XCTUnwrap(actual)
            let resolvedExpected = try XCTUnwrap(expected)
            XCTAssertEqual(resolvedActual.redComponent, resolvedExpected.redComponent, accuracy: 0.001)
            XCTAssertEqual(resolvedActual.greenComponent, resolvedExpected.greenComponent, accuracy: 0.001)
            XCTAssertEqual(resolvedActual.blueComponent, resolvedExpected.blueComponent, accuracy: 0.001)
            XCTAssertEqual(resolvedActual.alphaComponent, resolvedExpected.alphaComponent, accuracy: 0.001)
        }
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
    func testClipboardMenuReadsOnlyAfterExplicitActionAndPresentsSortedOnlineDevices() throws {
        _ = NSApplication.shared
        let preparer = RecordingClipboardTransferPreparer(
            prepared: PreparedClipboardTransfer(
                urls: [URL(fileURLWithPath: "/tmp/clipboard.txt")],
                ownedTemporaryURLs: []
            )
        )
        let desk = DeviceID(rawValue: UUID())
        let studio = DeviceID(rawValue: UUID())
        let menu = RecordingStatusItemDeviceMenuPresenter()
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [
                DeviceSummary(id: studio, displayName: "Studio Mac", availability: .lan),
                DeviceSummary(id: desk, displayName: "Desk Mac", availability: .internet),
                DeviceSummary(
                    id: DeviceID(rawValue: UUID()),
                    displayName: "Offline Mac",
                    availability: .offline
                ),
            ],
            transferCoordinator: RecordingTransferCoordinator(),
            clipboardPreparer: preparer,
            deviceMenuPresenter: menu
        )

        XCTAssertEqual(preparer.prepareCount, 0)
        controller.prepareToOpenStatusMenu()
        controller.setUnreadReceive(true)
        controller.updateDeviceNames([desk: "Desk Mac"])
        XCTAssertEqual(preparer.prepareCount, 0)

        let clipboardItem = try XCTUnwrap(
            controller.statusMenu.items.first { $0.title == "发送剪贴板…" }
        )
        let fileItemIndex = try XCTUnwrap(
            controller.statusMenu.items.firstIndex { $0.title == "发送文件…" }
        )
        let clipboardItemIndex = try XCTUnwrap(
            controller.statusMenu.items.firstIndex { $0.title == "发送剪贴板…" }
        )
        XCTAssertEqual(clipboardItemIndex, fileItemIndex + 1)
        XCTAssertEqual(clipboardItem.keyEquivalent, "c")
        XCTAssertEqual(clipboardItem.keyEquivalentModifierMask, [.command, .shift])

        XCTAssertTrue(
            NSApp.sendAction(
                try XCTUnwrap(clipboardItem.action),
                to: clipboardItem.target,
                from: clipboardItem
            )
        )

        XCTAssertEqual(preparer.prepareCount, 1)
        XCTAssertEqual(menu.presentCount, 1)
        XCTAssertEqual(menu.presentedDevices.map(\.id), [desk, studio])
    }

    @MainActor
    func testClipboardSendReportsEmptyClipboardWithoutPresentingTargetPicker() {
        let preparer = RecordingClipboardTransferPreparer(
            failure: ClipboardTransferPreparationError.noSupportedContent
        )
        let menu = RecordingStatusItemDeviceMenuPresenter()
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [],
            transferCoordinator: RecordingTransferCoordinator(),
            clipboardPreparer: preparer,
            deviceMenuPresenter: menu
        )
        var announcements: [String] = []
        controller.onAnnouncement = { announcements.append($0) }

        controller.performClipboardSend()

        XCTAssertEqual(preparer.prepareCount, 1)
        XCTAssertEqual(menu.presentCount, 0)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(announcements, ["剪贴板中没有可发送的内容。"])
    }

    @MainActor
    func testClipboardSendReportsPreparationFailureWithoutPresentingTargetPicker() {
        let preparer = RecordingClipboardTransferPreparer(
            failure: ClipboardPreparationTestError.failed
        )
        let menu = RecordingStatusItemDeviceMenuPresenter()
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [],
            transferCoordinator: RecordingTransferCoordinator(),
            clipboardPreparer: preparer,
            deviceMenuPresenter: menu
        )
        var announcements: [String] = []
        controller.onAnnouncement = { announcements.append($0) }

        controller.performClipboardSend()

        XCTAssertEqual(preparer.prepareCount, 1)
        XCTAssertEqual(menu.presentCount, 0)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(announcements, ["无法准备剪贴板内容，请重试。"])
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
    func testRecentReceiveMenuRevealsSelectedBatchWithoutClearingOthers() throws {
        let button = StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24))
        let controller = StatusItemController(
            button: button,
            devices: [],
            transferCoordinator: RecordingTransferCoordinator()
        )
        let store = RecentReceiveStore()
        controller.bindRecentReceives(store)
        let first = receiveResult(named: "first.pdf")
        let second = receiveResult(named: "second.pdf")
        store.record(first, sourceName: "Mac mini")
        store.record(second, sourceName: "Mason")
        var selected: RecentReceiveSummary?
        controller.onRevealRecentReceive = { selected = $0 }

        XCTAssertTrue(controller.hasUnreadReceive)
        XCTAssertTrue(button.showsReceiveIndicator)
        XCTAssertTrue((button.accessibilityValue() as? String)?.contains("有新接收文件") == true)

        controller.prepareToOpenStatusMenu()

        XCTAssertTrue(controller.hasUnreadReceive)
        let item = try XCTUnwrap(controller.statusMenu.items.first { $0.title == "second.pdf" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertEqual(selected?.id, second.transferID)
        XCTAssertTrue(store.hasUnread)
    }

    @MainActor
    func testRecentReceiveMenuUsesFiveNewestFixedSlotsAndShowsOverflow() throws {
        let controller = makeController()
        let store = RecentReceiveStore()
        controller.bindRecentReceives(store)
        let results = (0..<6).map { receiveResult(named: "file-\($0).pdf") }

        for result in results {
            store.record(result, sourceName: "Mason")
        }

        XCTAssertEqual(
            controller.statusMenu.items.filter { $0.title.hasPrefix("file-") }.map(\.title),
            ["file-5.pdf", "file-4.pdf", "file-3.pdf", "file-2.pdf", "file-1.pdf"]
        )
        XCTAssertEqual(controller.statusMenu.items.first { $0.title == "另有 1 个新接收项目…" }?.isHidden, false)
        XCTAssertEqual(controller.statusMenu.items.first { $0.title == "刚刚收到" }?.isHidden, false)
    }

    @MainActor
    func testRealMenuTrackingFreezesRowsAndDefersMutationUntilNextNeedsUpdate()
        async throws
    {
        let controller = makeController()
        let store = RecentReceiveStore()
        controller.bindRecentReceives(store)
        let first = TransferReceiveResult(
            transferID: TransferID(rawValue: UUID()),
            receivedURLs: [URL(fileURLWithPath: "/tmp/Downloads/first.pdf")],
            completedAt: Date(timeIntervalSince1970: 1_000)
        )
        let second = TransferReceiveResult(
            transferID: TransferID(rawValue: UUID()),
            receivedURLs: [URL(fileURLWithPath: "/tmp/Downloads/second.pdf")],
            completedAt: Date(timeIntervalSince1970: 2_000)
        )
        store.record(first, sourceName: "First Mac")
        var selected: [TransferID] = []
        let delegate = RecordingForwardingMenuDelegate(forwardingTo: controller)
        controller.statusMenu.delegate = delegate
        controller.onRevealRecentReceive = {
            selected.append($0.id)
            delegate.recordAction()
        }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 80),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        let firstTracking = expectation(description: "first real menu tracking closes")

        let firstTrackingTimer = MainActorTimerTarget(after: 0.05) {
            guard let visibleRow = controller.statusMenu.items.first(where: {
                $0.representedObject as? String == first.transferID.rawValue.uuidString
            }) else {
                XCTFail("expected the frozen first receive row")
                controller.statusMenu.cancelTracking()
                firstTracking.fulfill()
                return
            }
            let frozenTitle = visibleRow.title
            store.record(second, sourceName: "Second Mac")
            XCTAssertEqual(visibleRow.title, frozenTitle)
            XCTAssertNil(
                controller.statusMenu.items.first {
                    $0.representedObject as? String == second.transferID.rawValue.uuidString
                }
            )
            guard let action = visibleRow.action else {
                XCTFail("expected a stable receive-row action")
                controller.statusMenu.cancelTracking()
                firstTracking.fulfill()
                return
            }
            XCTAssertTrue(
                NSApp.sendAction(
                    action,
                    to: visibleRow.target,
                    from: visibleRow
                )
            )
            controller.statusMenu.cancelTracking()
            firstTracking.fulfill()
        }
        firstTrackingTimer.schedule()
        controller.statusMenu.popUp(
            positioning: nil,
            at: NSPoint(x: host.bounds.midX, y: host.bounds.midY),
            in: host
        )
        await fulfillment(of: [firstTracking], timeout: 1)

        XCTAssertEqual(selected, [first.transferID])
        XCTAssertEqual(
            Array(delegate.events.prefix(4)),
            [.needsUpdate, .willOpen, .action, .didClose]
        )
        XCTAssertNil(
            controller.statusMenu.items.first {
                $0.representedObject as? String == second.transferID.rawValue.uuidString
            }
        )
        let closeTurn = expectation(description: "didClose next-turn state clear")
        DispatchQueue.main.async { closeTurn.fulfill() }
        await fulfillment(of: [closeTurn], timeout: 1)
        XCTAssertNil(
            controller.statusMenu.items.first {
                $0.representedObject as? String == second.transferID.rawValue.uuidString
            }
        )

        let secondVisibility = MainActorValue(false)
        let secondTracking = expectation(description: "second real menu tracking closes")
        let secondTrackingTimer = MainActorTimerTarget(after: 0.05) {
            secondVisibility.value = controller.statusMenu.items.contains {
                $0.representedObject as? String == second.transferID.rawValue.uuidString
            }
            controller.statusMenu.cancelTracking()
            secondTracking.fulfill()
        }
        secondTrackingTimer.schedule()
        controller.statusMenu.popUp(
            positioning: nil,
            at: NSPoint(x: host.bounds.midX, y: host.bounds.midY),
            in: host
        )
        await fulfillment(of: [secondTracking], timeout: 1)

        XCTAssertTrue(secondVisibility.value)
        XCTAssertEqual(
            Array(delegate.events.suffix(3)),
            [.needsUpdate, .willOpen, .didClose]
        )
    }

    @MainActor
    @available(macOS 14.4, *)
    func testRecentReceiveRowsShowSourceSubtitleAndKeepAccessibleActionLabel() throws {
        let controller = makeController()
        let store = RecentReceiveStore()
        controller.bindRecentReceives(store)
        let named = receiveResult(named: "report.pdf")
        let unknown = receiveResult(named: "report.pdf")

        store.record(named, sourceName: "Studio Mac", completedAt: Date(timeIntervalSince1970: 2))
        store.record(unknown, sourceName: "", completedAt: Date(timeIntervalSince1970: 1))

        let rows = controller.statusMenu.items.filter { $0.title == "report.pdf" }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.subtitle), ["Studio Mac", "其他设备"])
        XCTAssertEqual(
            rows.map { $0.accessibilityLabel() },
            [
                "来自Studio Mac的report.pdf，在 Finder 中显示",
                "来自其他设备的report.pdf，在 Finder 中显示",
            ]
        )
    }

    func testRecentReceiveRowUsesVisibleSourceFallbackWithoutSubtitleSupport() {
        let text = RecentReceiveMenuText(
            primaryTitle: "report.pdf",
            sourceName: "Studio Mac",
            supportsSubtitle: false
        )

        XCTAssertEqual(text.title, "report.pdf — Studio Mac")
        XCTAssertNil(text.subtitle)
    }

    @MainActor
    func testRecentReceiveHistoryItemAcknowledgesAllEntriesBeforeEmittingCallback() throws {
        let controller = makeController()
        let store = RecentReceiveStore()
        controller.bindRecentReceives(store)
        store.record(receiveResult(named: "report.pdf"), sourceName: "Mason")
        store.record(receiveResult(named: "photo.jpg"), sourceName: "Mason")
        var historyShown = 0
        var wasAcknowledgedWhenHistoryWasShown: Bool?
        controller.onShowReceiveHistory = {
            historyShown += 1
            wasAcknowledgedWhenHistoryWasShown = !store.hasUnread
        }

        let item = try XCTUnwrap(
            controller.statusMenu.items.first { $0.title == "查看全部历史…" }
        )
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertEqual(historyShown, 1)
        XCTAssertEqual(wasAcknowledgedWhenHistoryWasShown, true)
        XCTAssertFalse(store.hasUnread)
    }

    @MainActor
    func testReceiveIndicatorUsesResolvableSystemGreenInLightAndDarkAppearances() throws {
        let button = StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24))
        button.hasUnreadReceive = true
        XCTAssertTrue(button.showsReceiveIndicator)

        for name: NSAppearance.Name in [.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var resolved: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                resolved = button.receiveIndicatorColor.usingColorSpace(.sRGB)
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

        let phases: [StatusItemPhase] = [.idle, .ready, .transferring(progress: 0.42)]
        for phase in phases {
            button.phase = phase
            let updateRect = button.updateIndicatorRect
            let receiveRect = button.receiveIndicatorRect
            XCTAssertTrue(
                updateRect.intersection(receiveRect).isEmpty,
                "indicator rectangles overlap during \(phase)"
            )
            XCTAssertEqual(updateRect.width, 4)
            XCTAssertEqual(receiveRect.width, 6)
        }
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
    func testClipboardSendWithNoOnlineDeviceDiscardsOwnedTemporaryContent() throws {
        let prepared = try ownedClipboardTransfer()
        defer { prepared.discardTemporaryFiles() }
        let preparer = RecordingClipboardTransferPreparer(prepared: prepared)
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
            clipboardPreparer: preparer,
            deviceMenuPresenter: menu
        )
        var announcements: [String] = []
        controller.onAnnouncement = { announcements.append($0) }

        controller.performClipboardSend()

        XCTAssertEqual(preparer.prepareCount, 1)
        XCTAssertEqual(menu.presentCount, 0)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.urls[0].path))
        XCTAssertEqual(announcements, ["没有在线设备。"])
    }

    @MainActor
    func testClipboardSendWithInvalidPreparedURLsDiscardsOwnedTemporaryContent() throws {
        let ownedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatusItemAppKitTests-\(UUID().uuidString).txt")
        try Data("clipboard".utf8).write(to: ownedURL)
        let cleanup = RecordingRemovalFileManager()
        let prepared = PreparedClipboardTransfer(
            urls: [],
            ownedTemporaryURLs: [ownedURL],
            cleanup: { cleanup.removeOwnedFile(at: ownedURL) }
        )
        defer { prepared.discardTemporaryFiles() }
        let menu = RecordingStatusItemDeviceMenuPresenter()
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [],
            transferCoordinator: RecordingTransferCoordinator(),
            clipboardPreparer: RecordingClipboardTransferPreparer(prepared: prepared),
            deviceMenuPresenter: menu
        )
        var announcements: [String] = []
        controller.onAnnouncement = { announcements.append($0) }

        controller.performClipboardSend()

        XCTAssertEqual(menu.presentCount, 0)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedURL.path))
        XCTAssertEqual(announcements, ["所选内容无法发送。"])
    }

    @MainActor
    func testClipboardSendWithExistingTransferDiscardsOwnedTemporaryContent() throws {
        let target = DeviceID(rawValue: UUID())
        let prepared = try ownedClipboardTransfer()
        defer { prepared.discardTemporaryFiles() }
        let preparer = RecordingClipboardTransferPreparer(prepared: prepared)
        let menu = RecordingStatusItemDeviceMenuPresenter()
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [DeviceSummary(id: target, displayName: "Desk Mac", availability: .lan)],
            transferCoordinator: RecordingTransferCoordinator(),
            filePicker: StubStatusItemFilePicker(result: [URL(fileURLWithPath: "/tmp/file.txt")]),
            clipboardPreparer: preparer,
            deviceMenuPresenter: menu
        )
        var announcements: [String] = []
        controller.onAnnouncement = { announcements.append($0) }

        controller.performKeyboardSend()
        XCTAssertTrue(try XCTUnwrap(menu.select)(target))
        controller.performClipboardSend()

        XCTAssertEqual(preparer.prepareCount, 1)
        XCTAssertEqual(menu.presentCount, 1)
        XCTAssertEqual(controller.phase, .transferring(progress: 0))
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.urls[0].path))
        XCTAssertEqual(announcements, ["已有传输正在进行。"])
    }

    @MainActor
    func testCancelledClipboardTargetSelectionDiscardsOwnedTemporaryContent() throws {
        let target = DeviceID(rawValue: UUID())
        let prepared = try ownedClipboardTransfer()
        defer { prepared.discardTemporaryFiles() }
        let menu = RecordingStatusItemDeviceMenuPresenter()
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [DeviceSummary(id: target, displayName: "Desk Mac", availability: .lan)],
            transferCoordinator: RecordingTransferCoordinator(),
            clipboardPreparer: RecordingClipboardTransferPreparer(prepared: prepared),
            deviceMenuPresenter: menu
        )

        controller.performClipboardSend()
        try XCTUnwrap(menu.cancel)()

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.urls[0].path))
    }

    @MainActor
    func testClipboardTargetSelectionUsesExistingTransferCoordinatorAndRetainsTemporaryContent() async throws {
        let transfer = RecordingTransferCoordinator()
        let target = DeviceID(rawValue: UUID())
        let prepared = try ownedClipboardTransfer()
        defer { prepared.discardTemporaryFiles() }
        let menu = RecordingStatusItemDeviceMenuPresenter()
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [DeviceSummary(id: target, displayName: "Desk Mac", availability: .lan)],
            transferCoordinator: transfer,
            clipboardPreparer: RecordingClipboardTransferPreparer(prepared: prepared),
            deviceMenuPresenter: menu
        )

        controller.performClipboardSend()
        XCTAssertTrue(try XCTUnwrap(menu.select)(target))
        for _ in 0..<100 where await transfer.sentCount() == 0 {
            await Task.yield()
        }

        let sends = await transfer.sentItems()
        XCTAssertEqual(sends.first?.0, prepared.urls)
        XCTAssertEqual(sends.first?.1, target)
        XCTAssertEqual(controller.phase, .transferring(progress: 0))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: prepared.urls[0].path),
            "Task 4 owns terminal-state cleanup after a transfer has started."
        )
    }

    @MainActor
    func testCompletedClipboardTransferDiscardsOwnedContentOnlyAfterMatchingTerminalCallback() async throws {
        let target = DeviceID(rawValue: UUID())
        let fileManager = RecordingRemovalFileManager()
        let prepared = try ownedClipboardTransfer(fileManager: fileManager)
        defer { prepared.discardTemporaryFiles() }
        let transfer = RecordingTransferCoordinator()
        let menu = RecordingStatusItemDeviceMenuPresenter()
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [DeviceSummary(id: target, displayName: "Desk Mac", availability: .lan)],
            transferCoordinator: transfer,
            clipboardPreparer: RecordingClipboardTransferPreparer(prepared: prepared),
            deviceMenuPresenter: menu
        )
        var startedToken: StatusItemDragToken?
        controller.onTransferStarted = { _, token in startedToken = token }

        controller.performClipboardSend()
        XCTAssertTrue(try XCTUnwrap(menu.select)(target))
        for _ in 0..<100 where await transfer.sentCount() == 0 || startedToken == nil {
            await Task.yield()
        }
        let token = try XCTUnwrap(startedToken)

        XCTAssertEqual(fileManager.removeCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.urls[0].path))

        controller.completeTransfer(token: token)
        controller.completeTransfer(token: token)

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(fileManager.removeCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.urls[0].path))
    }

    @MainActor
    func testLateTerminalCallbackForOldClipboardTokenDoesNotDiscardNewOwnership() async throws {
        let target = DeviceID(rawValue: UUID())
        let firstFileManager = RecordingRemovalFileManager()
        let secondFileManager = RecordingRemovalFileManager()
        let first = try ownedClipboardTransfer(fileManager: firstFileManager)
        let second = try ownedClipboardTransfer(fileManager: secondFileManager)
        defer {
            first.discardTemporaryFiles()
            second.discardTemporaryFiles()
        }
        let transfer = RecordingTransferCoordinator()
        let menu = RecordingStatusItemDeviceMenuPresenter()
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [DeviceSummary(id: target, displayName: "Desk Mac", availability: .lan)],
            transferCoordinator: transfer,
            clipboardPreparer: SequencedClipboardTransferPreparer(prepared: [first, second]),
            deviceMenuPresenter: menu
        )
        var startedTokens: [StatusItemDragToken] = []
        controller.onTransferStarted = { _, token in startedTokens.append(token) }

        controller.performClipboardSend()
        XCTAssertTrue(try XCTUnwrap(menu.select)(target))
        for _ in 0..<100 where startedTokens.count < 1 {
            await Task.yield()
        }
        let firstToken = try XCTUnwrap(startedTokens.first)
        controller.completeTransfer(token: firstToken)

        controller.performClipboardSend()
        XCTAssertTrue(try XCTUnwrap(menu.select)(target))
        for _ in 0..<100 where startedTokens.count < 2 {
            await Task.yield()
        }
        let secondToken = try XCTUnwrap(startedTokens.last)

        XCTAssertEqual(firstFileManager.removeCount, 1)
        XCTAssertEqual(secondFileManager.removeCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.urls[0].path))

        controller.completeTransfer(token: firstToken)

        XCTAssertEqual(secondFileManager.removeCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.urls[0].path))

        controller.completeTransfer(token: secondToken)
        controller.completeTransfer(token: secondToken)

        XCTAssertEqual(secondFileManager.removeCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.urls[0].path))
    }

    @MainActor
    func testCompletedClipboardTransferNeverDeletesCopiedSourceURLs() async throws {
        let target = DeviceID(rawValue: UUID())
        let fileManager = RecordingRemovalFileManager()
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatusItemAppKitTests-copied-\(UUID().uuidString).txt")
        try Data("copied source".utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let prepared = PreparedClipboardTransfer(
            urls: [sourceURL],
            ownedTemporaryURLs: []
        )
        let transfer = RecordingTransferCoordinator()
        let menu = RecordingStatusItemDeviceMenuPresenter()
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [DeviceSummary(id: target, displayName: "Desk Mac", availability: .lan)],
            transferCoordinator: transfer,
            clipboardPreparer: RecordingClipboardTransferPreparer(prepared: prepared),
            deviceMenuPresenter: menu
        )
        var startedToken: StatusItemDragToken?
        controller.onTransferStarted = { _, token in startedToken = token }

        controller.performClipboardSend()
        XCTAssertTrue(try XCTUnwrap(menu.select)(target))
        for _ in 0..<100 where startedToken == nil {
            await Task.yield()
        }

        controller.completeTransfer(token: try XCTUnwrap(startedToken))

        XCTAssertEqual(fileManager.removeCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    @MainActor
    func testClipboardTargetThatGoesOfflineCanBeCancelledAndDiscardsOwnedTemporaryContent() throws {
        let online = DeviceID(rawValue: UUID())
        let unavailable = DeviceID(rawValue: UUID())
        let prepared = try ownedClipboardTransfer()
        defer { prepared.discardTemporaryFiles() }
        let menu = RecordingStatusItemDeviceMenuPresenter()
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [DeviceSummary(id: online, displayName: "Desk Mac", availability: .lan)],
            transferCoordinator: RecordingTransferCoordinator(),
            clipboardPreparer: RecordingClipboardTransferPreparer(prepared: prepared),
            deviceMenuPresenter: menu
        )
        var announcements: [String] = []
        controller.onAnnouncement = { announcements.append($0) }

        controller.performClipboardSend()
        XCTAssertFalse(try XCTUnwrap(menu.select)(unavailable))
        try XCTUnwrap(menu.cancel)()

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.urls[0].path))
        XCTAssertEqual(announcements, ["目标设备已离线，请重新选择。"])
    }

    @MainActor
    func testReplacingPendingClipboardPickerWithClipboardDrainsOnlyOldOwnership() throws {
        let target = DeviceID(rawValue: UUID())
        let firstFileManager = RecordingRemovalFileManager()
        let secondFileManager = RecordingRemovalFileManager()
        let first = try ownedClipboardTransfer(fileManager: firstFileManager)
        let second = try ownedClipboardTransfer(fileManager: secondFileManager)
        defer {
            first.discardTemporaryFiles()
            second.discardTemporaryFiles()
        }
        let menu = RecordingStatusItemDeviceMenuPresenter()
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [DeviceSummary(id: target, displayName: "Desk Mac", availability: .lan)],
            transferCoordinator: RecordingTransferCoordinator(),
            clipboardPreparer: SequencedClipboardTransferPreparer(prepared: [first, second]),
            deviceMenuPresenter: menu
        )
        var dismissedTokens: [StatusItemDragToken] = []
        controller.onDismissDeviceFan = { dismissedTokens.append($0) }

        controller.performClipboardSend()
        let oldSelect = try XCTUnwrap(menu.selectionHistory.first)
        let oldCancel = try XCTUnwrap(menu.cancellationHistory.first)
        controller.performClipboardSend()

        XCTAssertEqual(menu.presentCount, 2)
        XCTAssertEqual(firstFileManager.removeCount, 1)
        XCTAssertEqual(secondFileManager.removeCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.urls[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.urls[0].path))
        XCTAssertEqual(dismissedTokens.count, 1)

        XCTAssertFalse(oldSelect(target))
        oldCancel()

        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(firstFileManager.removeCount, 1)
        XCTAssertEqual(secondFileManager.removeCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.urls[0].path))

        try XCTUnwrap(menu.cancel)()
        XCTAssertEqual(secondFileManager.removeCount, 1)
    }

    @MainActor
    func testReplacingPendingClipboardPickerWithFilePickerDrainsOldOwnership() throws {
        let target = DeviceID(rawValue: UUID())
        let fileManager = RecordingRemovalFileManager()
        let prepared = try ownedClipboardTransfer(fileManager: fileManager)
        defer { prepared.discardTemporaryFiles() }
        let menu = RecordingStatusItemDeviceMenuPresenter()
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [DeviceSummary(id: target, displayName: "Desk Mac", availability: .lan)],
            transferCoordinator: RecordingTransferCoordinator(),
            filePicker: StubStatusItemFilePicker(result: [URL(fileURLWithPath: "/tmp/file.txt")]),
            clipboardPreparer: RecordingClipboardTransferPreparer(prepared: prepared),
            deviceMenuPresenter: menu
        )

        controller.performClipboardSend()
        let oldSelect = try XCTUnwrap(menu.selectionHistory.first)
        let oldCancel = try XCTUnwrap(menu.cancellationHistory.first)
        controller.performKeyboardSend()

        XCTAssertEqual(menu.presentCount, 2)
        XCTAssertEqual(fileManager.removeCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.urls[0].path))

        XCTAssertFalse(oldSelect(target))
        oldCancel()
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(fileManager.removeCount, 1)

        try XCTUnwrap(menu.cancel)()
    }

    @MainActor
    func testReplacingPendingClipboardPickerWithDragIntentDrainsOldOwnership() throws {
        let target = DeviceID(rawValue: UUID())
        let fileManager = RecordingRemovalFileManager()
        let prepared = try ownedClipboardTransfer(fileManager: fileManager)
        defer { prepared.discardTemporaryFiles() }
        let menu = RecordingStatusItemDeviceMenuPresenter()
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [DeviceSummary(id: target, displayName: "Desk Mac", availability: .lan)],
            transferCoordinator: RecordingTransferCoordinator(),
            clipboardPreparer: RecordingClipboardTransferPreparer(prepared: prepared),
            deviceMenuPresenter: menu
        )
        var requests: [DeviceFanRequest] = []
        controller.onPresentDeviceFan = { requests.append($0) }

        controller.performClipboardSend()
        let oldSelect = try XCTUnwrap(menu.selectionHistory.first)
        let oldCancel = try XCTUnwrap(menu.cancellationHistory.first)
        let dragToken = try XCTUnwrap(
            controller.beginDrop(
                try DropIntent(items: [.fileURL(URL(fileURLWithPath: "/tmp/drag.txt"))])
            )
        )

        XCTAssertEqual(fileManager.removeCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.urls[0].path))
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.token, dragToken)

        XCTAssertFalse(oldSelect(target))
        oldCancel()
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(fileManager.removeCount, 1)

        requests[0].cancel()
    }

    @MainActor
    func testInvalidatingPendingClipboardPickerDismissesAndDrainsOwnershipExactlyOnce() throws {
        let target = DeviceID(rawValue: UUID())
        let fileManager = RecordingRemovalFileManager()
        let prepared = try ownedClipboardTransfer(fileManager: fileManager)
        defer { prepared.discardTemporaryFiles() }
        let menu = RecordingStatusItemDeviceMenuPresenter()
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [DeviceSummary(id: target, displayName: "Desk Mac", availability: .lan)],
            transferCoordinator: RecordingTransferCoordinator(),
            clipboardPreparer: RecordingClipboardTransferPreparer(prepared: prepared),
            deviceMenuPresenter: menu
        )
        var dismissedTokens: [StatusItemDragToken] = []
        controller.onDismissDeviceFan = { dismissedTokens.append($0) }

        controller.performClipboardSend()
        let oldSelect = try XCTUnwrap(menu.select)
        let oldCancel = try XCTUnwrap(menu.cancel)
        controller.invalidate()
        controller.invalidate()

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(dismissedTokens.count, 1)
        XCTAssertEqual(fileManager.removeCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.urls[0].path))

        XCTAssertFalse(oldSelect(target))
        oldCancel()
        XCTAssertEqual(fileManager.removeCount, 1)
        XCTAssertEqual(dismissedTokens.count, 1)
    }

    @MainActor
    func testInvalidatingActiveClipboardTransferWaitsForMatchingTerminalCallback() async throws {
        let target = DeviceID(rawValue: UUID())
        let fileManager = RecordingRemovalFileManager()
        let prepared = try ownedClipboardTransfer(fileManager: fileManager)
        defer { prepared.discardTemporaryFiles() }
        let transfer = RecordingTransferCoordinator()
        let menu = RecordingStatusItemDeviceMenuPresenter()
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [DeviceSummary(id: target, displayName: "Desk Mac", availability: .lan)],
            transferCoordinator: transfer,
            clipboardPreparer: RecordingClipboardTransferPreparer(prepared: prepared),
            deviceMenuPresenter: menu
        )
        var startedToken: StatusItemDragToken?
        controller.onTransferStarted = { _, token in startedToken = token }

        controller.performClipboardSend()
        XCTAssertTrue(try XCTUnwrap(menu.select)(target))
        for _ in 0..<100 where await transfer.sentCount() == 0 || startedToken == nil {
            await Task.yield()
        }

        controller.invalidate()
        controller.invalidate()

        XCTAssertEqual(fileManager.removeCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.urls[0].path))

        controller.completeTransfer(token: try XCTUnwrap(startedToken))
        controller.completeTransfer(token: try XCTUnwrap(startedToken))

        XCTAssertEqual(fileManager.removeCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.urls[0].path))
    }

    @MainActor
    func testInvalidationDuringClipboardAdmissionKeepsSourceUntilCoordinatorReadsItEvenAfterControllerRelease()
        async throws
    {
        let target = DeviceID(rawValue: UUID())
        let fileManager = RecordingRemovalFileManager()
        let prepared = try ownedClipboardTransfer(fileManager: fileManager)
        defer { prepared.discardTemporaryFiles() }
        let transfer = BlockingBeforeReadTransferCoordinator()
        let menu = RecordingStatusItemDeviceMenuPresenter()
        var controller: StatusItemController? = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [DeviceSummary(id: target, displayName: "Desk Mac", availability: .lan)],
            transferCoordinator: transfer,
            clipboardPreparer: RecordingClipboardTransferPreparer(prepared: prepared),
            deviceMenuPresenter: menu
        )

        controller?.performClipboardSend()
        XCTAssertTrue(try XCTUnwrap(menu.select)(target))
        await transfer.waitUntilBlockedBeforeRead()

        controller?.invalidate()
        controller = nil

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: prepared.urls[0].path),
            "admission still needs to read the generated source"
        )
        XCTAssertEqual(fileManager.removeCount, 0)

        await transfer.allowRead()
        let received = try await transfer.waitForRead()
        XCTAssertEqual(received, Data("clipboard".utf8))
        for _ in 0..<100 where FileManager.default.fileExists(atPath: prepared.urls[0].path) {
            await Task.yield()
        }

        XCTAssertEqual(fileManager.removeCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.urls[0].path))
    }

    @MainActor
    func testClipboardCoordinatorRejectionDiscardsOwnedContentExactlyOnce() async throws {
        let target = DeviceID(rawValue: UUID())
        let fileManager = RecordingRemovalFileManager()
        let prepared = try ownedClipboardTransfer(fileManager: fileManager)
        defer { prepared.discardTemporaryFiles() }
        let menu = RecordingStatusItemDeviceMenuPresenter()
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [DeviceSummary(id: target, displayName: "Desk Mac", availability: .lan)],
            transferCoordinator: FailingTransferCoordinator(),
            clipboardPreparer: RecordingClipboardTransferPreparer(prepared: prepared),
            deviceMenuPresenter: menu
        )

        controller.performClipboardSend()
        let staleSelect = try XCTUnwrap(menu.select)
        let staleCancel = try XCTUnwrap(menu.cancel)
        XCTAssertTrue(staleSelect(target))
        for _ in 0..<100 where controller.phase != .idle {
            await Task.yield()
        }

        XCTAssertEqual(fileManager.removeCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.urls[0].path))
        XCTAssertFalse(staleSelect(target))
        staleCancel()
        XCTAssertEqual(fileManager.removeCount, 1)
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
        XCTAssertEqual(nativeButton.accessibilityLabel(), "DropMesh 文件传输")
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

    @MainActor
    private func makeController() -> StatusItemController {
        StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [],
            transferCoordinator: RecordingTransferCoordinator()
        )
    }

    @MainActor
    private func ownedClipboardTransfer(
        fileManager: RecordingRemovalFileManager = RecordingRemovalFileManager()
    ) throws -> PreparedClipboardTransfer {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatusItemAppKitTests-\(UUID().uuidString).txt")
        try Data("clipboard".utf8).write(to: url)
        return PreparedClipboardTransfer(
            urls: [url],
            ownedTemporaryURLs: [url],
            cleanup: { fileManager.removeOwnedFile(at: url) }
        )
    }

    private func receiveResult(named name: String) -> TransferReceiveResult {
        TransferReceiveResult(
            transferID: TransferID(rawValue: UUID()),
            receivedURLs: [URL(fileURLWithPath: "/tmp/Downloads/\(name)")]
        )
    }
}

@MainActor
private final class RecordingForwardingMenuDelegate: NSObject, NSMenuDelegate {
    enum Event: Equatable {
        case needsUpdate
        case willOpen
        case action
        case didClose
    }

    private weak var forwardingDelegate: (any NSMenuDelegate)?
    private(set) var events: [Event] = []

    init(forwardingTo delegate: any NSMenuDelegate) {
        forwardingDelegate = delegate
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        events.append(.needsUpdate)
        forwardingDelegate?.menuNeedsUpdate?(menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        events.append(.willOpen)
        forwardingDelegate?.menuWillOpen?(menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        events.append(.didClose)
        forwardingDelegate?.menuDidClose?(menu)
    }

    func recordAction() {
        events.append(.action)
    }
}

@MainActor
private final class MainActorTimerTarget: NSObject {
    private let interval: TimeInterval
    private let action: @MainActor () -> Void
    private var timer: Timer?

    init(after interval: TimeInterval, action: @escaping @MainActor () -> Void) {
        self.interval = interval
        self.action = action
    }

    func schedule() {
        let timer = Timer(
            timeInterval: interval,
            target: self,
            selector: #selector(fire(_:)),
            userInfo: nil,
            repeats: false
        )
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func fire(_ timer: Timer) {
        self.timer = nil
        action()
    }
}

@MainActor
private final class MainActorValue<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
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

private actor BlockingBeforeReadTransferCoordinator: TransferCoordinating {
    private let gate = BlockingClipboardAdmissionGate()

    func send(items: [URL], to device: DeviceID) async throws -> TransferID {
        _ = device
        let source = try XCTUnwrap(items.first)
        await gate.blockBeforeRead()
        do {
            let data = try Data(contentsOf: source)
            await gate.finish(with: .success(data))
            return TransferID(rawValue: UUID())
        } catch {
            await gate.finish(with: .failure(error))
            throw error
        }
    }

    func pause(_ id: TransferID) async {}
    func resume(_ id: TransferID) async throws {}
    func cancel(_ id: TransferID) async -> TransferCancellationResult { .requested }

    func waitUntilBlockedBeforeRead() async {
        await gate.waitUntilBlocked()
    }

    func allowRead() async {
        await gate.allowRead()
    }

    func waitForRead() async throws -> Data {
        try await gate.waitForResult().get()
    }
}

private actor BlockingClipboardAdmissionGate {
    private var isBlocked = false
    private var mayRead = false
    private var result: Result<Data, any Error>?
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    private var resultWaiters: [CheckedContinuation<Result<Data, any Error>, Never>] = []

    func blockBeforeRead() async {
        isBlocked = true
        let waiters = blockedWaiters
        blockedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !mayRead else { return }
        await withCheckedContinuation { readWaiters.append($0) }
    }

    func waitUntilBlocked() async {
        guard !isBlocked else { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }

    func allowRead() {
        mayRead = true
        let waiters = readWaiters
        readWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func finish(with result: Result<Data, any Error>) {
        self.result = result
        let waiters = resultWaiters
        resultWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: result) }
    }

    func waitForResult() async -> Result<Data, any Error> {
        if let result { return result }
        return await withCheckedContinuation { resultWaiters.append($0) }
    }
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

private enum ClipboardPreparationTestError: Error {
    case failed
}

@MainActor
private final class RecordingClipboardTransferPreparer: ClipboardTransferPreparing {
    private let prepared: PreparedClipboardTransfer?
    private let failure: (any Error)?
    private(set) var prepareCount = 0

    init(prepared: PreparedClipboardTransfer) {
        self.prepared = prepared
        failure = nil
    }

    init(failure: any Error) {
        prepared = nil
        self.failure = failure
    }

    func prepare() throws -> PreparedClipboardTransfer {
        prepareCount += 1
        if let failure { throw failure }
        return prepared!
    }
}

@MainActor
private final class SequencedClipboardTransferPreparer: ClipboardTransferPreparing {
    private var prepared: [PreparedClipboardTransfer]

    init(prepared: [PreparedClipboardTransfer]) {
        self.prepared = prepared
    }

    func prepare() throws -> PreparedClipboardTransfer {
        guard !prepared.isEmpty else { throw ClipboardPreparationTestError.failed }
        return prepared.removeFirst()
    }
}

@MainActor
private final class RecordingRemovalFileManager {
    private(set) var removeCount = 0

    func removeOwnedFile(at url: URL) -> Bool {
        removeCount += 1
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return true
        } catch {
            return false
        }
    }
}

@MainActor
private final class RecordingStatusItemDeviceMenuPresenter: StatusItemDeviceMenuPresenting {
    private(set) var presentCount = 0
    private(set) var presentedDevices: [DeviceSummary] = []
    private(set) var select: ((DeviceID) -> Bool)?
    private(set) var cancel: (() -> Void)?
    private(set) var selectionHistory: [(DeviceID) -> Bool] = []
    private(set) var cancellationHistory: [() -> Void] = []

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
        selectionHistory.append(select)
        cancellationHistory.append(cancel)
    }
}
