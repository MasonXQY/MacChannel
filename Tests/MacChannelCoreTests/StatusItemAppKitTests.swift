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
        let prepared = PreparedClipboardTransfer(urls: [], ownedTemporaryURLs: [ownedURL])
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
            ownedTemporaryURLs: [],
            fileManager: fileManager
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
    func testInvalidatingAcceptedClipboardTransferDrainsRetainedOwnershipExactlyOnce() async throws {
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

        controller.performClipboardSend()
        XCTAssertTrue(try XCTUnwrap(menu.select)(target))
        for _ in 0..<100 where await transfer.sentCount() == 0 {
            await Task.yield()
        }

        controller.invalidate()
        controller.invalidate()

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
        fileManager: FileManager = .default
    ) throws -> PreparedClipboardTransfer {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatusItemAppKitTests-\(UUID().uuidString).txt")
        try Data("clipboard".utf8).write(to: url)
        return PreparedClipboardTransfer(
            urls: [url],
            ownedTemporaryURLs: [url],
            fileManager: fileManager
        )
    }

    private func receiveResult(named name: String) -> TransferReceiveResult {
        TransferReceiveResult(
            transferID: TransferID(rawValue: UUID()),
            receivedURLs: [URL(fileURLWithPath: "/tmp/Downloads/\(name)")]
        )
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

private final class RecordingRemovalFileManager: FileManager {
    private(set) var removeCount = 0

    override func removeItem(at URL: URL) throws {
        removeCount += 1
        try super.removeItem(at: URL)
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
