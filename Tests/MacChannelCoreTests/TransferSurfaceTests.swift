import AppKit
import XCTest

@testable import MacChannelAppKit
@testable import MacChannelCore

final class TransferSurfaceTests: XCTestCase {
    func testFailedTransferExplainsReceiverMustBeConnected() {
        let item = TransferSurfaceItem(
            snapshot: TransferSnapshot(
                id: TransferID(rawValue: UUID()),
                peer: DeviceID(rawValue: UUID()),
                phase: .failed,
                completedBytes: 0,
                totalBytes: 10,
                route: .lan
            ),
            peerName: "书房 Mac",
            displayName: "文件.txt",
            bytesPerSecond: nil,
            estimatedTimeRemaining: nil,
            outputURL: nil,
            updatedAt: Date()
        )

        XCTAssertEqual(
            item.failureHelpText,
            "请确认对方 Mac 通道已打开并显示“安全服务已连接”，然后重试。"
        )
    }

    @MainActor
    func testUnavailableShellServicesDeclareThatActionsAreDisabled() {
        XCTAssertFalse(UnavailablePairingSurfaceService().isAvailable)
        XCTAssertFalse(UnavailableDeviceSettingsService().isAvailable)
    }

    func testPairingInputKeepsSixASCIIDigitsAndRequiresExactLength() {
        XCTAssertEqual(PairingCodeInput.sanitize("12a３4-56789"), "124567")
        XCTAssertFalse(PairingCodeInput.isComplete("12345"))
        XCTAssertTrue(PairingCodeInput.isComplete("123456"))
        XCTAssertEqual(PairingCodeInput.spaced("123456"), "1 2 3 4 5 6")
    }

    @MainActor
    func testJoinerMovesToWaitingStateAndStartsAutomaticApprovalWait() async {
        let host = DeviceSummary(
            id: DeviceID(rawValue: UUID()),
            displayName: "书房 Mac",
            availability: .internet
        )
        let service = HostApprovalPairingSurfaceService(peer: host)
        let model = PairingSurfaceModel(entryCode: "123456")

        await model.join(using: service)

        XCTAssertEqual(model.state, .awaitingHostApproval(host))
        XCTAssertNil(model.actionError)
        for _ in 0..<100 where service.waitCount == 0 { await Task.yield() }
        XCTAssertEqual(service.waitCount, 1)
    }

    @MainActor
    func testHostApprovalAndRejectionCallTheirExplicitServiceActions() async {
        let joiner = DeviceSummary(
            id: DeviceID(rawValue: UUID()),
            displayName: "客厅 Mac",
            availability: .internet
        )
        let service = HostApprovalPairingSurfaceService(peer: joiner)
        let model = PairingSurfaceModel(state: .approvalRequested(joiner))

        await model.approve(using: service)
        XCTAssertEqual(service.approvalCount, 1)

        model.state = .approvalRequested(joiner)
        await model.reject(using: service)
        XCTAssertEqual(service.rejectionCount, 1)
        XCTAssertEqual(model.state, .idle)
    }

    @MainActor
    func testClosingConfirmedPairingClearsCompletedPresentation() async {
        let peer = DeviceSummary(
            id: DeviceID(rawValue: UUID()),
            displayName: "书房 Mac",
            availability: .internet
        )
        let service = HostApprovalPairingSurfaceService(peer: peer)
        let model = PairingSurfaceModel(
            state: .confirmed(peer),
            hostedCode: "123456",
            entryCode: "654321",
            pendingPeer: peer,
            actionError: "旧提示"
        )

        let didClose = await model.cancel(using: service)

        XCTAssertTrue(didClose)
        XCTAssertEqual(model.state, .idle)
        XCTAssertNil(model.hostedCode)
        XCTAssertTrue(model.entryCode.isEmpty)
        XCTAssertNil(model.pendingPeer)
        XCTAssertNil(model.actionError)
    }

    @MainActor
    func testConfirmedPairingDoesNotInventAnAuthoritativeSettingsDevice() {
        let peer = DeviceSummary(
            id: DeviceID(rawValue: UUID()),
            displayName: "书房 Mac",
            availability: .internet
        )
        let pairing = PairingSurfaceModel()
        let settings = SettingsSurfaceModel()
        let surfaces = AppSurfaceController(
            transferService: NativeTransferSurfaceService(
                coordinator: SurfaceTransferCoordinator()
            ),
            pairingService: HostApprovalPairingSurfaceService(peer: peer),
            settingsService: UnavailableDeviceSettingsService(),
            directorySelector: NativeDirectorySelector(),
            pairingModel: pairing,
            settingsModel: settings
        )

        surfaces.updatePairingState(.confirmed(peer))

        XCTAssertEqual(pairing.state, .confirmed(peer))
        XCTAssertTrue(settings.devices.isEmpty)
    }

    @MainActor
    func testAuthoritativeDeviceRemovalClearsMatchingPairingSuccess() {
        let peer = DeviceSummary(
            id: DeviceID(rawValue: UUID()),
            displayName: "书房 Mac",
            availability: .offline
        )
        let pairing = PairingSurfaceModel(state: .confirmed(peer))
        let settings = SettingsSurfaceModel(devices: [DeviceSetting(device: peer)])
        let surfaces = AppSurfaceController(
            transferService: NativeTransferSurfaceService(
                coordinator: SurfaceTransferCoordinator()
            ),
            pairingService: HostApprovalPairingSurfaceService(peer: peer),
            settingsService: UnavailableDeviceSettingsService(),
            directorySelector: NativeDirectorySelector(),
            pairingModel: pairing,
            settingsModel: settings
        )

        surfaces.updateSettings(
            SettingsSurfaceSnapshot(
                localDisplayName: "本机",
                defaultDirectory: nil,
                autoReceive: true,
                launchAtLogin: false,
                devices: []
            )
        )

        XCTAssertTrue(settings.devices.isEmpty)
        XCTAssertEqual(pairing.state, .idle)
    }

    @MainActor
    func testLoginItemRegistrationFailureRollsBackVisibleSetting() async {
        let loginItems = StubLoginItemRegistration(error: SurfaceActionFailure.expected)
        let service = RecordingEssentialSettingsService()
        let model = SettingsSurfaceModel(launchAtLogin: false)

        await model.updateLaunchAtLogin(true, loginItems: loginItems, using: service)

        XCTAssertFalse(model.launchAtLogin)
        XCTAssertNil(service.launchAtLogin)
        XCTAssertEqual(
            model.actionError,
            "无法设置登录时启动，请在系统设置中允许后重试。"
        )
    }

    @MainActor
    func testSettingsExposeInstalledVersionAndManualUpdateAction() {
        let updates = RecordingSoftwareUpdateService()
        let snapshot = SoftwareUpdateSnapshot.fixtureUpToDate
        let model = SettingsSurfaceModel(updateSnapshot: snapshot)

        XCTAssertEqual(
            model.updateSnapshot.installedVersion.localizedText,
            "Mac 通道 1.2.0（13）"
        )
        model.performUpdateAction(using: updates)
        XCTAssertEqual(updates.checkCount, 1)
        XCTAssertEqual(updates.showCount, 0)

        model.updateSnapshot = SoftwareUpdateSnapshot(
            installedVersion: snapshot.installedVersion,
            phase: .available(version: "1.2.1"),
            canCheck: true,
            lastCheckedAt: snapshot.lastCheckedAt
        )
        model.performUpdateAction(using: updates)
        XCTAssertEqual(updates.checkCount, 1)
        XCTAssertEqual(updates.showCount, 1)

        model.updateSnapshot = SoftwareUpdateSnapshot(
            installedVersion: snapshot.installedVersion,
            phase: .available(version: "1.2.1"),
            canCheck: false,
            lastCheckedAt: snapshot.lastCheckedAt
        )
        model.performUpdateAction(using: updates)
        XCTAssertEqual(updates.checkCount, 1)
        XCTAssertEqual(updates.showCount, 1)
    }

    @MainActor
    func testSurfaceBindingPropagatesLiveUpdatesAndRejectsStaleOrPostInvalidationEvents()
        async throws
    {
        _ = NSApplication.shared
        let initial = SoftwareUpdateSnapshot.fixtureUpToDate
        let unavailable = SoftwareUpdateSnapshot.fixture(
            phase: .available(version: "1.2.1"),
            canCheck: false
        )
        let available = SoftwareUpdateSnapshot.fixture(
            phase: .available(version: "1.2.1"),
            canCheck: true
        )
        let downloading = SoftwareUpdateSnapshot.fixture(phase: .downloading, canCheck: false)
        let deferred = SoftwareUpdateSnapshot.fixture(phase: .installDeferred, canCheck: true)
        let updates = ControllableSoftwareUpdateService(snapshot: initial)
        let settings = SettingsSurfaceModel(updateSnapshot: .fixtureUpToDate)
        let surfaces = AppSurfaceController(
            transferService: NativeTransferSurfaceService(
                coordinator: SurfaceTransferCoordinator()
            ),
            pairingService: UnavailablePairingSurfaceService(),
            settingsService: UnavailableDeviceSettingsService(),
            directorySelector: NativeDirectorySelector(),
            settingsModel: settings,
            updateService: updates
        )
        let firstController = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [],
            transferCoordinator: SurfaceTransferCoordinator()
        )

        surfaces.bind(to: firstController)
        await drainMainActorTasks()
        XCTAssertEqual(updates.subscriptionCount, 1)
        XCTAssertEqual(settings.updateSnapshot, initial)

        updates.publish(unavailable)
        await drainMainActorTasks()
        XCTAssertEqual(settings.updateSnapshot, unavailable)
        let firstItem = try XCTUnwrap(
            firstController.statusMenu.items.first { $0.title == "有新版本可用" }
        )
        XCTAssertFalse(firstItem.isHidden)
        XCTAssertFalse(firstItem.isEnabled)
        XCTAssertFalse(firstController.button.updateActionEnabled)
        XCTAssertTrue(
            (firstController.button.accessibilityValue() as? String)?
                .contains("暂时无法查看") == true
        )
        XCTAssertEqual(updates.showCount, 0)

        updates.publish(available)
        await drainMainActorTasks()
        XCTAssertTrue(firstItem.isEnabled)
        let availableAction = try XCTUnwrap(firstItem.action)
        XCTAssertTrue(NSApp.sendAction(availableAction, to: firstItem.target, from: firstItem))
        XCTAssertEqual(updates.showCount, 1)

        updates.publish(downloading)
        await drainMainActorTasks()
        XCTAssertFalse(firstItem.isEnabled)

        let secondController = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [],
            transferCoordinator: SurfaceTransferCoordinator()
        )
        surfaces.bind(to: secondController)
        await drainMainActorTasks()
        XCTAssertEqual(updates.subscriptionCount, 2)
        XCTAssertEqual(updates.terminationCount, 1)
        XCTAssertEqual(settings.updateSnapshot, downloading)

        updates.yieldStale(available, subscription: 0)
        await drainMainActorTasks()
        XCTAssertEqual(settings.updateSnapshot, downloading)

        updates.publish(deferred)
        await drainMainActorTasks()
        XCTAssertEqual(settings.updateSnapshot, deferred)
        let secondItem = try XCTUnwrap(
            secondController.statusMenu.items.first { $0.title == "有新版本可用" }
        )
        XCTAssertTrue(secondItem.isEnabled)

        surfaces.invalidate()
        await drainMainActorTasks()
        XCTAssertEqual(updates.terminationCount, 2)
        updates.yieldStale(initial, subscription: 1)
        await drainMainActorTasks()
        XCTAssertEqual(settings.updateSnapshot, deferred)
        XCTAssertFalse(secondItem.isHidden)
        XCTAssertTrue(secondItem.isEnabled)
    }

    @MainActor
    func testMenuBarSurfacesUseTransientPopovers() {
        XCTAssertEqual(AppSurfaceController.standardPopoverBehavior, .transient)
    }

    @MainActor
    func testDeniedNotificationPermissionOffersSystemSettingsAction() async {
        let notifications = RecordingReceiveNotificationService(state: .denied)
        let settings = SettingsSurfaceModel()
        let surfaces = AppSurfaceController(
            transferService: NativeTransferSurfaceService(
                coordinator: SurfaceTransferCoordinator()
            ),
            pairingService: UnavailablePairingSurfaceService(),
            settingsService: UnavailableDeviceSettingsService(),
            directorySelector: NativeDirectorySelector(),
            settingsModel: settings,
            notificationService: notifications
        )

        surfaces.observeReceiveNotifications()
        await drainMainActorTasks()

        XCTAssertEqual(settings.receiveNotificationSnapshot.authorizationState, .denied)
        settings.openNotificationSettings()
        XCTAssertEqual(notifications.openSettingsCount, 1)
    }

    @MainActor
    func testRefreshingNotificationPermissionUpdatesSettingsAfterSystemChanges() async {
        let notifications = RecordingReceiveNotificationService(state: .denied)
        let settings = SettingsSurfaceModel()
        let surfaces = AppSurfaceController(
            transferService: NativeTransferSurfaceService(
                coordinator: SurfaceTransferCoordinator()
            ),
            pairingService: UnavailablePairingSurfaceService(),
            settingsService: UnavailableDeviceSettingsService(),
            directorySelector: NativeDirectorySelector(),
            settingsModel: settings,
            notificationService: notifications
        )

        surfaces.observeReceiveNotifications()
        await drainMainActorTasks()
        XCTAssertEqual(settings.receiveNotificationSnapshot.authorizationState, .denied)

        notifications.setState(.authorized)
        await surfaces.refreshReceiveNotifications()
        await drainMainActorTasks()
        XCTAssertEqual(settings.receiveNotificationSnapshot.authorizationState, .authorized)

        notifications.setState(.denied)
        await surfaces.refreshReceiveNotifications()
        await drainMainActorTasks()
        XCTAssertEqual(settings.receiveNotificationSnapshot.authorizationState, .denied)
        XCTAssertEqual(notifications.refreshCount, 2)
    }

    @MainActor
    func testInvalidatingSurfaceCancelsInFlightNotificationRefresh() async {
        let notifications = SuspendingReceiveNotificationService()
        let surfaces = AppSurfaceController(
            transferService: NativeTransferSurfaceService(
                coordinator: SurfaceTransferCoordinator()
            ),
            pairingService: UnavailablePairingSurfaceService(),
            settingsService: UnavailableDeviceSettingsService(),
            directorySelector: NativeDirectorySelector(),
            notificationService: notifications
        )

        let refresh = Task { @MainActor in
            await surfaces.refreshReceiveNotifications()
        }
        await notifications.waitForRefreshes(1)

        surfaces.invalidate()
        notifications.resumeRefresh(at: 0)
        await refresh.value

        XCTAssertEqual(notifications.cancelledRefreshes, [0])
    }

    @MainActor
    func testNewNotificationRefreshCancelsEarlierInFlightRefresh() async {
        let notifications = SuspendingReceiveNotificationService()
        let surfaces = AppSurfaceController(
            transferService: NativeTransferSurfaceService(
                coordinator: SurfaceTransferCoordinator()
            ),
            pairingService: UnavailablePairingSurfaceService(),
            settingsService: UnavailableDeviceSettingsService(),
            directorySelector: NativeDirectorySelector(),
            notificationService: notifications
        )

        let olderRefresh = Task { @MainActor in
            await surfaces.refreshReceiveNotifications()
        }
        await notifications.waitForRefreshes(1)
        let newerRefresh = Task { @MainActor in
            await surfaces.refreshReceiveNotifications()
        }
        await notifications.waitForRefreshes(2)

        notifications.resumeRefresh(at: 1)
        await newerRefresh.value
        notifications.resumeRefresh(at: 0)
        await olderRefresh.value

        XCTAssertEqual(notifications.cancelledRefreshes, [0])
    }

    @MainActor
    func testInvalidatingAndReobservingReceiveNotificationsRejectsOldSubscriptionEvents() async {
        let notifications = RecordingReceiveNotificationService(state: .authorized)
        let surfaces = AppSurfaceController(
            transferService: NativeTransferSurfaceService(
                coordinator: SurfaceTransferCoordinator()
            ),
            pairingService: UnavailablePairingSurfaceService(),
            settingsService: UnavailableDeviceSettingsService(),
            directorySelector: NativeDirectorySelector(),
            notificationService: notifications
        )
        let firstController = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [],
            transferCoordinator: SurfaceTransferCoordinator()
        )

        surfaces.bind(to: firstController)
        surfaces.observeReceiveNotifications()
        await drainMainActorTasks()
        XCTAssertEqual(notifications.subscriptionCount, 1)

        surfaces.invalidate()
        await drainMainActorTasks()
        XCTAssertEqual(notifications.terminationCount, 1)

        let secondController = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [],
            transferCoordinator: SurfaceTransferCoordinator()
        )
        surfaces.bind(to: secondController)
        surfaces.observeReceiveNotifications()
        await drainMainActorTasks()
        XCTAssertEqual(notifications.subscriptionCount, 2)

        notifications.yield(.denied, subscription: 0)
        await drainMainActorTasks()
        XCTAssertEqual(
            surfaces.settingsModel.receiveNotificationSnapshot.authorizationState,
            .authorized
        )

        notifications.yield(.denied, subscription: 1)
        await drainMainActorTasks()
        XCTAssertEqual(
            surfaces.settingsModel.receiveNotificationSnapshot.authorizationState,
            .denied
        )
    }

    func testSettingsSourceContainsNativeReceiveNotificationStatusWithoutToggle() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settings = try String(
            contentsOf: root.appendingPathComponent("App/SettingsView.swift"),
            encoding: .utf8
        )

        for label in ["接收通知", "已允许", "未允许", "打开系统设置"] {
            XCTAssertTrue(settings.contains(label), "missing visible notification label: \(label)")
        }
        XCTAssertFalse(settings.contains("Toggle(\"接收通知\""))
    }

    func testSettingsSourceContainsIndependentNativeSoftwareUpdateSection() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settings = try String(
            contentsOf: root.appendingPathComponent("App/SettingsView.swift"),
            encoding: .utf8
        )

        for required in [
            "软件更新",
            "检查更新",
            "最近检查：",
            "Text(presentation.guidanceText)",
            ".foregroundStyle(.orange)",
        ] {
            XCTAssertTrue(settings.contains(required), "missing update UI contract: \(required)")
        }
        XCTAssertTrue(settings.contains(".frame(minHeight: 40)"))
        XCTAssertTrue(settings.contains("SoftwareUpdateSection"))
        let updateModel = try String(
            contentsOf: root.appendingPathComponent("App/SoftwareUpdateModel.swift"),
            encoding: .utf8
        )
        XCTAssertEqual(
            (settings + updateModel)
                .components(separatedBy: "每天自动检查一次，是否安装由你决定。").count - 1,
            1
        )
        XCTAssertFalse(settings.contains("尚未检查更新"))
    }

    func testIdleUpdatePresentationShowsGuidanceOnceWithARealLastCheckedValue() {
        let snapshot = SoftwareUpdateSnapshot.fixture(
            phase: .idle,
            canCheck: true,
            lastCheckedAt: Date(timeIntervalSince1970: 2_000)
        )

        let presentation = SoftwareUpdateSectionPresentation(
            snapshot: snapshot,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertNil(presentation.statusText)
        XCTAssertEqual(presentation.guidanceText, SoftwareUpdatePhase.idle.statusText)
        XCTAssertNotEqual(presentation.lastCheckedText, "尚未检查")
        XCTAssertFalse(presentation.lastCheckedText.contains("尚未检查更新"))
    }

    func testOrdinaryPairingAndSettingsSourcesContainNoExpertNetworkOrFingerprintControls() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let pairing = try String(
            contentsOf: root.appendingPathComponent("App/PairingView.swift"),
            encoding: .utf8
        )
        let settings = try String(
            contentsOf: root.appendingPathComponent("App/SettingsView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(pairing.contains("指纹"))
        for forbidden in ["Tailscale", "连接方式", "安全中继地址", "rendezvousURL"] {
            XCTAssertFalse(settings.contains(forbidden), "unexpected ordinary setting: \(forbidden)")
        }
    }

    func testPairingSuccessCopyStatesTheLocalGuaranteeAndRemoteCheck() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let pairing = try String(
            contentsOf: root.appendingPathComponent("App/PairingView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(pairing.contains("本机已信任"))
        XCTAssertTrue(pairing.contains("请确认另一台 Mac 也显示配对成功"))
        XCTAssertFalse(pairing.contains("已与 \\(device.displayName) 建立信任"))
    }

    func testUnavailableSettingsOffersActionableRuntimeRecovery() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settings = try String(
            contentsOf: root.appendingPathComponent("App/SettingsView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(settings.contains("switch model.runtimeStatus"))
        XCTAssertTrue(settings.contains("正在启动 Mac 通道"))
        XCTAssertTrue(settings.contains("重试启动"))
    }

    @MainActor
    func testSettingsRenameFailureDoesNotCommitAndPublishesActionableError() async {
        let id = DeviceID(rawValue: UUID())
        let announcer = RecordingAccessibilityAnnouncer()
        let model = SettingsSurfaceModel(
            devices: [
                DeviceSetting(
                    device: DeviceSummary(id: id, displayName: "原名称", availability: .lan)
                )
            ],
            announcer: announcer
        )
        let service = FailingSettingsSurfaceService()

        await model.rename(id, to: "新名称", using: service)

        XCTAssertEqual(model.devices[0].displayName, "原名称")
        XCTAssertEqual(model.actionError, "无法保存设备名称，请稍后重试。")
        XCTAssertEqual(announcer.messages, ["无法保存设备名称，请稍后重试。"])
    }

    @MainActor
    func testSettingsDirectoryAndPolicyFailuresRollBack() async {
        let id = DeviceID(rawValue: UUID())
        let originalDirectory = URL(fileURLWithPath: "/tmp/original")
        let model = SettingsSurfaceModel(devices: [
            DeviceSetting(
                device: DeviceSummary(id: id, displayName: "Mac", availability: .lan),
                autoAccept: true,
                maximumBytes: 10_000_000,
                directory: originalDirectory
            )
        ])
        let service = FailingSettingsSurfaceService()

        await model.updatePolicy(
            id,
            autoAccept: false,
            maximumBytes: 20_000_000,
            using: service
        )
        await model.updateDirectory(
            URL(fileURLWithPath: "/tmp/new"),
            for: id,
            using: service
        )

        XCTAssertTrue(model.devices[0].autoAccept)
        XCTAssertEqual(model.devices[0].maximumMegabytes, "10")
        XCTAssertEqual(model.devices[0].directory, originalDirectory)
        XCTAssertEqual(model.actionError, "无法保存接收目录，请确认目录仍可访问后重试。")
    }

    @MainActor
    func testEssentialSettingsCommitAndFailuresRollBack() async {
        let model = SettingsSurfaceModel(
            localDisplayName: "原名称",
            autoReceive: true,
            launchAtLogin: false
        )
        let service = RecordingEssentialSettingsService()
        let loginItems = StubLoginItemRegistration()

        await model.updateLocalDisplayName("  工作室 Mac  ", using: service)
        await model.updateAutoReceive(false, using: service)
        await model.updateLaunchAtLogin(true, loginItems: loginItems, using: service)

        XCTAssertEqual(model.localDisplayName, "工作室 Mac")
        XCTAssertFalse(model.autoReceive)
        XCTAssertTrue(model.launchAtLogin)
        XCTAssertEqual(service.localDisplayName, "工作室 Mac")
        XCTAssertEqual(service.autoReceive, false)
        XCTAssertEqual(service.launchAtLogin, true)

        service.shouldFail = true
        await model.updateLocalDisplayName("失败名称", using: service)
        await model.updateAutoReceive(true, using: service)
        await model.updateLaunchAtLogin(false, loginItems: loginItems, using: service)

        XCTAssertEqual(model.localDisplayName, "工作室 Mac")
        XCTAssertFalse(model.autoReceive)
        XCTAssertTrue(model.launchAtLogin)
        XCTAssertEqual(model.actionError, "无法保存登录启动设置，请稍后重试。")
    }

    func testEstablishedInternetRouteUsesPlainChineseLabel() {
        let direct = TransferSurfaceItem(
            snapshot: TransferSnapshot(
                id: TransferID(rawValue: UUID()),
                peer: DeviceID(rawValue: UUID()),
                phase: .transferring,
                completedBytes: 1,
                totalBytes: 2,
                route: .directInternet
            ),
            peerName: "Mac",
            displayName: "文件",
            bytesPerSecond: nil,
            estimatedTimeRemaining: nil,
            outputURL: nil,
            updatedAt: Date()
        )
        XCTAssertEqual(direct.routeText, "互联网直连")
        XCTAssertEqual(direct.routeSymbol, "network")
    }

    @MainActor
    func testPairingFailureKeepsIdleStateAndPublishesActionableError() async {
        let announcer = RecordingAccessibilityAnnouncer()
        let model = PairingSurfaceModel(entryCode: "123456", announcer: announcer)

        await model.join(using: FailingPairingSurfaceService())

        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(model.entryCode, "123456")
        XCTAssertEqual(model.actionError, "无法验证配对码，请检查网络后重试。")
        XCTAssertEqual(announcer.messages, ["无法验证配对码，请检查网络后重试。"])
    }

    @MainActor
    func testCommittedSecurityChangesHydrateUIAndAnnouncePersistenceWarnings() async {
        let peer = DeviceSummary(
            id: DeviceID(rawValue: UUID()),
            displayName: "书房 Mac",
            availability: .lan
        )
        let settingsAnnouncer = RecordingAccessibilityAnnouncer()
        let settings = SettingsSurfaceModel(
            devices: [DeviceSetting(device: peer)],
            announcer: settingsAnnouncer
        )
        await settings.revoke(peer.id, using: WarningSettingsSurfaceService())

        XCTAssertTrue(settings.devices.isEmpty)
        XCTAssertEqual(settings.actionError, WarningSettingsSurfaceService.warning)
        XCTAssertEqual(settingsAnnouncer.messages, [WarningSettingsSurfaceService.warning])

        let pairingAnnouncer = RecordingAccessibilityAnnouncer()
        let pairing = PairingSurfaceModel(
            state: .approvalRequested(peer),
            pendingPeer: peer,
            announcer: pairingAnnouncer
        )
        await pairing.approve(using: WarningPairingSurfaceService(peer: peer))

        XCTAssertEqual(pairing.state, .committing(peer))
        XCTAssertEqual(pairing.actionError, WarningPairingSurfaceService.warning)
        XCTAssertEqual(pairingAnnouncer.messages, [WarningPairingSurfaceService.warning])
    }

    @MainActor
    func testResumeFailurePublishesVisibleTransferError() async {
        let announcer = RecordingAccessibilityAnnouncer()
        let model = TransferSurfaceModel(announcer: announcer)
        let id = TransferID(rawValue: UUID())

        await model.resume(id, using: FailingTransferSurfaceService())

        XCTAssertEqual(model.actionError, "无法继续传输，请检查设备连接后重试。")
        XCTAssertEqual(announcer.messages, ["无法继续传输，请检查设备连接后重试。"])
    }

    func testTransferPresentationShowsTextAndIconForRoutePhaseSpeedAndETA() {
        let snapshot = TransferSnapshot(
            id: TransferID(rawValue: UUID()),
            peer: DeviceID(rawValue: UUID()),
            phase: .transferring,
            completedBytes: 500,
            totalBytes: 1_000,
            route: .relay
        )
        let item = TransferSurfaceItem(
            snapshot: snapshot,
            peerName: "书房 Mac",
            displayName: "照片.zip",
            bytesPerSecond: 1_500_000,
            estimatedTimeRemaining: 90,
            outputURL: nil,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(item.progress, 0.5)
        XCTAssertEqual(item.phaseText, "传输中")
        XCTAssertEqual(item.phaseSymbol, "arrow.up.arrow.down.circle")
        XCTAssertEqual(item.routeText, "加密中继")
        XCTAssertEqual(item.routeSymbol, "lock.shield")
        XCTAssertEqual(item.speedText, "1.5 MB/秒")
        XCTAssertEqual(item.etaText, "剩余 1分30秒")
        XCTAssertTrue(item.canPause)
        XCTAssertFalse(item.canResume)
        XCTAssertTrue(item.canCancel)
        XCTAssertFalse(item.canShowInFinder)
    }

    func testCompletedTransferOffersFinderAndNeverOffersPauseOrCancel() {
        let item = TransferSurfaceItem(
            snapshot: TransferSnapshot(
                id: TransferID(rawValue: UUID()),
                peer: DeviceID(rawValue: UUID()),
                phase: .completed,
                completedBytes: 10,
                totalBytes: 10,
                route: .lan
            ),
            peerName: "办公室 Mac",
            displayName: "报告.pdf",
            bytesPerSecond: nil,
            estimatedTimeRemaining: nil,
            outputURL: URL(fileURLWithPath: "/tmp/报告.pdf"),
            updatedAt: Date()
        )

        XCTAssertEqual(item.phaseText, "已完成")
        XCTAssertEqual(item.routeText, "局域网直连")
        XCTAssertFalse(item.canPause)
        XCTAssertFalse(item.canResume)
        XCTAssertFalse(item.canCancel)
        XCTAssertTrue(item.canShowInFinder)
        XCTAssertFalse(item.showsLiveMetrics)
    }

    func testFailedTransferDoesNotOfferAResumeActionThatCannotRun() {
        let item = TransferSurfaceItem(
            snapshot: TransferSnapshot(
                id: TransferID(rawValue: UUID()),
                peer: DeviceID(rawValue: UUID()),
                phase: .failed,
                completedBytes: 5,
                totalBytes: 10,
                route: .relay
            ),
            peerName: "办公室 Mac",
            displayName: "失败.bin",
            bytesPerSecond: nil,
            estimatedTimeRemaining: nil,
            outputURL: nil,
            updatedAt: Date()
        )

        XCTAssertFalse(item.canResume)
        XCTAssertFalse(item.canCancel)
    }

    func testSettingsSizeLimitConvertsOnlyPositiveFiniteMegabytes() {
        XCTAssertNil(SettingsSizeLimit.bytes(megabytes: ""))
        XCTAssertNil(SettingsSizeLimit.bytes(megabytes: "0"))
        XCTAssertNil(SettingsSizeLimit.bytes(megabytes: "-1"))
        XCTAssertNil(SettingsSizeLimit.bytes(megabytes: "nan"))
        XCTAssertEqual(SettingsSizeLimit.bytes(megabytes: "100"), 100_000_000)
        XCTAssertEqual(SettingsSizeLimit.bytes(megabytes: " 100 "), 100_000_000)
        XCTAssertEqual(SettingsSizeLimit.bytes(megabytes: "1.25"), 1_250_000)
        XCTAssertEqual(
            SettingsSizeLimit.bytes(megabytes: "18446744073709.55"),
            18_446_744_073_709_550_000
        )
        XCTAssertEqual(
            SettingsSizeLimit.bytes(megabytes: "18446744073709.551615"),
            UInt64.max
        )
        XCTAssertNil(SettingsSizeLimit.bytes(megabytes: "18446744073709.551616"))
        XCTAssertNil(SettingsSizeLimit.bytes(megabytes: "1abc"))
        XCTAssertNil(SettingsSizeLimit.bytes(megabytes: "1.2.3"))
        XCTAssertNil(SettingsSizeLimit.bytes(megabytes: "1,25"))
        XCTAssertEqual(SettingsSizeLimit.megabytes(bytes: 1_500_000_000), "1500")
        XCTAssertEqual(SettingsSizeLimit.megabytes(bytes: 1_250_000), "1.25")
        XCTAssertTrue(SettingsSizeLimit.isValidInput(""))
        XCTAssertTrue(SettingsSizeLimit.isValidInput("100"))
        XCTAssertTrue(SettingsSizeLimit.isValidInput(" 100 "))
        XCTAssertFalse(SettingsSizeLimit.isValidInput("abc"))
        XCTAssertFalse(SettingsSizeLimit.isValidInput("0"))
        XCTAssertFalse(SettingsSizeLimit.isValidInput("18446744073709.551616"))
        XCTAssertFalse(SettingsSizeLimit.isValidInput("1abc"))
        XCTAssertFalse(SettingsSizeLimit.isValidInput("1.2.3"))
        XCTAssertFalse(SettingsSizeLimit.isValidInput("1,25"))
    }

    @MainActor
    func testStatusMenuProvidesChineseKeyboardAccessibleSurfaceEntries() {
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [],
            transferCoordinator: SurfaceTransferCoordinator()
        )

        let titles = controller.statusMenu.items.map(\.title)
        XCTAssertTrue(titles.contains("传输与历史"))
        XCTAssertTrue(titles.contains("配对设备"))
        XCTAssertTrue(titles.contains("设置"))
        XCTAssertEqual(
            controller.statusMenu.items.first { $0.title == "传输与历史" }?.keyEquivalent,
            "t"
        )
    }

    @MainActor
    func testPresenceUpdatesPreserveOfflineSettingsAndOwnerApprovedName() {
        let id = DeviceID(rawValue: UUID())
        let model = SettingsSurfaceModel(
            devices: [
                DeviceSetting(
                    device: DeviceSummary(
                        id: id,
                        displayName: "书房 Mac",
                        availability: .offline
                    ),
                    autoAccept: false,
                    maximumBytes: 100_000_000,
                    directory: URL(fileURLWithPath: "/tmp/书房")
                )
            ]
        )
        let surfaces = AppSurfaceController(
            transferService: NativeTransferSurfaceService(
                coordinator: SurfaceTransferCoordinator()
            ),
            pairingService: UnavailablePairingSurfaceService(),
            settingsService: UnavailableDeviceSettingsService(),
            directorySelector: NativeDirectorySelector(),
            settingsModel: model
        )

        surfaces.updatePresence([
            DeviceSummary(id: id, displayName: "", availability: .lan)
        ])
        XCTAssertEqual(model.devices[0].displayName, "书房 Mac")
        XCTAssertEqual(model.devices[0].availability, .lan)
        XCTAssertFalse(model.devices[0].autoAccept)
        XCTAssertEqual(model.devices[0].maximumMegabytes, "100")
        XCTAssertEqual(model.devices[0].directory, URL(fileURLWithPath: "/tmp/书房"))

        surfaces.updatePresence([])
        XCTAssertEqual(model.devices.count, 1)
        XCTAssertEqual(model.devices[0].availability, .offline)
        XCTAssertEqual(model.devices[0].displayName, "书房 Mac")
    }

    @MainActor
    func testPersistedDeviceSettingsHydrateAllPolicyAndDirectoryFields() {
        let device = DeviceSummary(
            id: DeviceID(rawValue: UUID()),
            displayName: "离线 Mac",
            availability: .offline
        )
        let persisted = DeviceSetting(
            device: device,
            autoAccept: false,
            maximumBytes: 750_000_000,
            directory: URL(fileURLWithPath: "/tmp/专用")
        )
        let model = SettingsSurfaceModel()
        let surfaces = AppSurfaceController(
            transferService: NativeTransferSurfaceService(
                coordinator: SurfaceTransferCoordinator()
            ),
            pairingService: UnavailablePairingSurfaceService(),
            settingsService: UnavailableDeviceSettingsService(),
            directorySelector: NativeDirectorySelector(),
            settingsModel: model
        )

        let defaultDirectory = URL(fileURLWithPath: "/tmp/默认")
        surfaces.updateSettings(
            SettingsSurfaceSnapshot(
                localDisplayName: "工作室 Mac",
                defaultDirectory: defaultDirectory,
                autoReceive: false,
                launchAtLogin: true,
                devices: [persisted]
            )
        )

        XCTAssertEqual(model.localDisplayName, "工作室 Mac")
        XCTAssertEqual(model.defaultDirectory, defaultDirectory)
        XCTAssertFalse(model.autoReceive)
        XCTAssertTrue(model.launchAtLogin)
        XCTAssertEqual(model.devices, [persisted])
    }

    @MainActor
    func testHistoryPresentationRetainsCompletedOutputForFinderAction() {
        let url = URL(fileURLWithPath: "/tmp/完成.txt")
        let item = TransferSurfaceItem(
            snapshot: TransferSnapshot(
                id: TransferID(rawValue: UUID()),
                peer: DeviceID(rawValue: UUID()),
                phase: .completed,
                completedBytes: 4,
                totalBytes: 4,
                route: .lan
            ),
            peerName: "书房 Mac",
            displayName: "完成.txt",
            bytesPerSecond: nil,
            estimatedTimeRemaining: nil,
            outputURL: url,
            updatedAt: Date()
        )
        let model = TransferSurfaceModel()
        let surfaces = AppSurfaceController(
            transferService: NativeTransferSurfaceService(
                coordinator: SurfaceTransferCoordinator()
            ),
            pairingService: UnavailablePairingSurfaceService(),
            settingsService: UnavailableDeviceSettingsService(),
            directorySelector: NativeDirectorySelector(),
            transferModel: model
        )

        surfaces.updateHistoryItems([item])

        XCTAssertEqual(model.history.first?.outputURL, url)
        XCTAssertEqual(model.history.first?.displayName, "完成.txt")
        XCTAssertTrue(model.history.first?.canShowInFinder == true)
    }

    @MainActor
    func testLiveTerminalSnapshotCannotOverwritePersistedFinderMetadata() throws {
        let id = TransferID(rawValue: UUID())
        let peer = DeviceID(rawValue: UUID())
        let output = URL(fileURLWithPath: "/tmp/最终报告.pdf")
        let persisted = completedHistoryItem(
            id: id,
            peer: peer,
            displayName: "最终报告.pdf",
            outputURL: output
        )
        let model = TransferSurfaceModel()
        let surfaces = makeSurfaces(transferModel: model)

        surfaces.updateHistoryItems([persisted])
        surfaces.updateTransferSnapshots([
            completedSnapshot(id: id, peer: peer)
        ])

        let merged = try XCTUnwrap(model.history.first { $0.id == id })
        XCTAssertEqual(merged.displayName, "最终报告.pdf")
        XCTAssertEqual(merged.outputURL, output)
        XCTAssertTrue(merged.canShowInFinder)
    }

    @MainActor
    func testPersistedHistoryWinsRegardlessOfArrivalOrderAndUnrelatedSnapshots() throws {
        let id = TransferID(rawValue: UUID())
        let peer = DeviceID(rawValue: UUID())
        let output = URL(fileURLWithPath: "/tmp/照片.zip")
        let model = TransferSurfaceModel()
        let surfaces = makeSurfaces(transferModel: model)

        surfaces.updateTransferSnapshots([
            completedSnapshot(id: id, peer: peer)
        ])
        surfaces.updateHistoryItems([
            completedHistoryItem(
                id: id,
                peer: peer,
                displayName: "照片.zip",
                outputURL: output
            )
        ])
        surfaces.updateTransferSnapshots([
            TransferSnapshot(
                id: TransferID(rawValue: UUID()),
                peer: DeviceID(rawValue: UUID()),
                phase: .transferring,
                completedBytes: 1,
                totalBytes: 10,
                route: .relay
            )
        ])

        let merged = try XCTUnwrap(model.history.first { $0.id == id })
        XCTAssertEqual(merged.displayName, "照片.zip")
        XCTAssertEqual(merged.outputURL, output)
        XCTAssertTrue(merged.canShowInFinder)
    }

    @MainActor
    func testStalePersistedHistoryCannotRegressLiveCompletedSnapshot() throws {
        let id = TransferID(rawValue: UUID())
        let peer = DeviceID(rawValue: UUID())
        let model = TransferSurfaceModel()
        var timestamp: TimeInterval = 2_000
        let surfaces = makeSurfaces(
            transferModel: model, now: { Date(timeIntervalSince1970: timestamp) })

        surfaces.updateTransferSnapshots([completedSnapshot(id: id, peer: peer)])
        timestamp = 1_000
        surfaces.updateHistoryItems([
            historyItem(
                id: id, peer: peer, phase: .transferring, completed: 5,
                updatedAt: Date(timeIntervalSince1970: 1_000))
        ])

        let item = try XCTUnwrap(model.history.first { $0.id == id })
        XCTAssertEqual(item.snapshot.phase, .completed)
        XCTAssertEqual(item.snapshot.completedBytes, 10)
        XCTAssertFalse(item.canResume)
        XCTAssertFalse(item.canCancel)
    }

    @MainActor
    func testStaleLiveSnapshotCannotRegressPersistedCompletedHistory() throws {
        let id = TransferID(rawValue: UUID())
        let peer = DeviceID(rawValue: UUID())
        let model = TransferSurfaceModel()
        let timestamp: TimeInterval = 1_000
        let surfaces = makeSurfaces(
            transferModel: model, now: { Date(timeIntervalSince1970: timestamp) })

        surfaces.updateHistoryItems([
            historyItem(
                id: id, peer: peer, phase: .completed, completed: 10,
                updatedAt: Date(timeIntervalSince1970: 2_000))
        ])
        surfaces.updateTransferSnapshots([
            TransferSnapshot(
                id: id, peer: peer, phase: .transferring, completedBytes: 5, totalBytes: 10,
                route: .relay)
        ])

        XCTAssertTrue(model.active.isEmpty)
        let item = try XCTUnwrap(model.history.first { $0.id == id })
        XCTAssertEqual(item.snapshot.phase, .completed)
        XCTAssertFalse(item.canResume)
        XCTAssertFalse(item.canCancel)
    }

    @MainActor
    func testMergedHistoryIsDeterministicallyCapped() {
        let model = TransferSurfaceModel()
        let surfaces = makeSurfaces(transferModel: model)
        let peer = DeviceID(rawValue: UUID())
        let items = (0..<240).map { index in
            historyItem(
                id: TransferID(rawValue: UUID()),
                peer: peer,
                phase: .completed,
                completed: 10,
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        surfaces.updateHistoryItems(items)

        XCTAssertEqual(model.history.count, AppSurfaceController.historyLimit)
        XCTAssertEqual(model.history.first?.updatedAt, Date(timeIntervalSince1970: 239))
        XCTAssertEqual(model.history.last?.updatedAt, Date(timeIntervalSince1970: 40))
    }

    @MainActor
    func testLiveTerminalHistoryIsBoundedForLongRunningMenuBarProcess() {
        let model = TransferSurfaceModel()
        var timestamp: TimeInterval = 1_000
        let surfaces = AppSurfaceController(
            transferService: NativeTransferSurfaceService(
                coordinator: SurfaceTransferCoordinator()
            ),
            pairingService: UnavailablePairingSurfaceService(),
            settingsService: UnavailableDeviceSettingsService(),
            directorySelector: NativeDirectorySelector(),
            transferModel: model,
            now: {
                defer { timestamp += 1 }
                return Date(timeIntervalSince1970: timestamp)
            }
        )
        var ids: [TransferID] = []

        for _ in 0..<225 {
            let id = TransferID(rawValue: UUID())
            ids.append(id)
            surfaces.updateTransferSnapshots([
                completedSnapshot(id: id, peer: DeviceID(rawValue: UUID()))
            ])
        }

        XCTAssertEqual(model.history.count, AppSurfaceController.liveHistoryLimit)
        XCTAssertFalse(model.history.contains { $0.id == ids[0] })
        XCTAssertTrue(model.history.contains { $0.id == ids[224] })
    }

    @MainActor
    func testUnchangedTerminalSnapshotsKeepTimestampWhenUnrelatedTransferProgresses() throws {
        let first = TransferID(rawValue: UUID())
        let second = TransferID(rawValue: UUID())
        let active = TransferID(rawValue: UUID())
        let peer = DeviceID(rawValue: UUID())
        let model = TransferSurfaceModel()
        var timestamp: TimeInterval = 1_000
        let surfaces = makeSurfaces(
            transferModel: model,
            now: { Date(timeIntervalSince1970: timestamp) }
        )

        surfaces.updateTransferSnapshots([completedSnapshot(id: first, peer: peer)])
        timestamp = 2_000
        surfaces.updateTransferSnapshots([
            completedSnapshot(id: first, peer: peer),
            completedSnapshot(id: second, peer: peer),
        ])
        timestamp = 3_000
        surfaces.updateTransferSnapshots([
            completedSnapshot(id: first, peer: peer),
            completedSnapshot(id: second, peer: peer),
            TransferSnapshot(
                id: active,
                peer: peer,
                phase: .transferring,
                completedBytes: 5,
                totalBytes: 10,
                route: .relay
            ),
        ])

        XCTAssertEqual(model.history.map(\.id), [second, first])
        XCTAssertEqual(
            try XCTUnwrap(model.history.first { $0.id == first }).updatedAt,
            Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertEqual(
            try XCTUnwrap(model.history.first { $0.id == second }).updatedAt,
            Date(timeIntervalSince1970: 2_000)
        )
    }

    @MainActor
    func testHostPairingStateHydratesPendingPeerIdentity() async throws {
        let peer = DeviceSummary(
            id: DeviceID(rawValue: UUID()),
            displayName: "客厅 Mac",
            availability: .internet
        )
        let model = PairingSurfaceModel()
        let surfaces = AppSurfaceController(
            transferService: NativeTransferSurfaceService(
                coordinator: SurfaceTransferCoordinator()
            ),
            pairingService: PendingPeerPairingService(peer: peer),
            settingsService: UnavailableDeviceSettingsService(),
            directorySelector: NativeDirectorySelector(),
            pairingModel: model
        )

        surfaces.updatePairingState(
            .awaitingFingerprint(local: "ABCD EFGH", remote: "ABCD EFGH")
        )
        for _ in 0..<100 where model.pendingPeer == nil {
            await Task.yield()
        }

        XCTAssertEqual(model.pendingPeer, peer)
    }

    @MainActor
    func testDisplayingPairingStateDoesNotEraseGeneratedCode() {
        let model = PairingSurfaceModel(
            state: .idle,
            hostedCode: "123456"
        )
        let surfaces = AppSurfaceController(
            transferService: NativeTransferSurfaceService(
                coordinator: SurfaceTransferCoordinator()
            ),
            pairingService: UnavailablePairingSurfaceService(),
            settingsService: UnavailableDeviceSettingsService(),
            directorySelector: NativeDirectorySelector(),
            pairingModel: model
        )

        surfaces.updatePairingState(
            .displayingCode(expiresAt: Date().addingTimeInterval(300))
        )

        XCTAssertEqual(model.hostedCode, "123456")
    }

    @MainActor
    func testSurfaceBindingCorrelatesSnapshotsBackToStatusItemToken() async throws {
        let target = DeviceID(rawValue: UUID())
        let transferID = TransferID(rawValue: UUID())
        let coordinator = CorrelatedSurfaceTransferCoordinator(id: transferID)
        let picker = SurfaceFilePicker()
        let menu = SurfaceDeviceMenu()
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [
                DeviceSummary(id: target, displayName: "书房 Mac", availability: .lan)
            ],
            transferCoordinator: coordinator,
            filePicker: picker,
            deviceMenuPresenter: menu
        )
        let surfaces = AppSurfaceController(
            transferService: NativeTransferSurfaceService(coordinator: coordinator),
            pairingService: UnavailablePairingSurfaceService(),
            settingsService: UnavailableDeviceSettingsService(),
            directorySelector: NativeDirectorySelector()
        )
        surfaces.bind(to: controller)

        controller.performKeyboardSend()
        XCTAssertTrue(try XCTUnwrap(menu.select)(target))
        for _ in 0..<100 where await coordinator.sendCount() == 0 {
            await Task.yield()
        }

        surfaces.updateTransferSnapshots([
            TransferSnapshot(
                id: transferID,
                peer: target,
                phase: .transferring,
                completedBytes: 25,
                totalBytes: 100,
                route: .lan
            )
        ])
        XCTAssertEqual(controller.phase, .transferring(progress: 0.25))

        surfaces.updateTransferSnapshots([
            TransferSnapshot(
                id: transferID,
                peer: target,
                phase: .completed,
                completedBytes: 100,
                totalBytes: 100,
                route: .lan
            )
        ])
        XCTAssertEqual(controller.phase, .idle)
    }

    @MainActor
    func testSnapshotPublishedBeforeSendReturnStillCompletesStatusItem() async throws {
        let target = DeviceID(rawValue: UUID())
        let transferID = TransferID(rawValue: UUID())
        let coordinator = CorrelatedSurfaceTransferCoordinator(id: transferID)
        let menu = SurfaceDeviceMenu()
        let controller = StatusItemController(
            button: StatusItemButton(frame: NSRect(x: 0, y: 0, width: 72, height: 24)),
            devices: [DeviceSummary(id: target, displayName: "书房 Mac", availability: .lan)],
            transferCoordinator: coordinator,
            filePicker: SurfaceFilePicker(),
            deviceMenuPresenter: menu
        )
        let surfaces = AppSurfaceController(
            transferService: NativeTransferSurfaceService(coordinator: coordinator),
            pairingService: UnavailablePairingSurfaceService(),
            settingsService: UnavailableDeviceSettingsService(),
            directorySelector: NativeDirectorySelector()
        )
        surfaces.bind(to: controller)
        surfaces.updateTransferSnapshots([
            TransferSnapshot(
                id: transferID,
                peer: target,
                phase: .completed,
                completedBytes: 100,
                totalBytes: 100,
                route: .lan
            )
        ])

        controller.performKeyboardSend()
        XCTAssertTrue(try XCTUnwrap(menu.select)(target))
        for _ in 0..<100 where await coordinator.sendCount() == 0 {
            await Task.yield()
        }
        for _ in 0..<100 where controller.phase != .idle {
            await Task.yield()
        }

        XCTAssertEqual(controller.phase, .idle)
    }

    @MainActor
    private func makeSurfaces(
        transferModel: TransferSurfaceModel,
        now: @escaping () -> Date = Date.init
    ) -> AppSurfaceController {
        AppSurfaceController(
            transferService: NativeTransferSurfaceService(
                coordinator: SurfaceTransferCoordinator()
            ),
            pairingService: UnavailablePairingSurfaceService(),
            settingsService: UnavailableDeviceSettingsService(),
            directorySelector: NativeDirectorySelector(),
            transferModel: transferModel,
            now: now
        )
    }

    private func historyItem(
        id: TransferID,
        peer: DeviceID,
        phase: TransferPhase,
        completed: Int64,
        updatedAt: Date
    ) -> TransferSurfaceItem {
        TransferSurfaceItem(
            snapshot: TransferSnapshot(
                id: id,
                peer: peer,
                phase: phase,
                completedBytes: completed,
                totalBytes: 10,
                route: .lan
            ),
            peerName: "Mac",
            displayName: "文件",
            bytesPerSecond: nil,
            estimatedTimeRemaining: nil,
            outputURL: phase == .completed ? URL(fileURLWithPath: "/tmp/file") : nil,
            updatedAt: updatedAt
        )
    }

    private func completedSnapshot(
        id: TransferID,
        peer: DeviceID
    ) -> TransferSnapshot {
        TransferSnapshot(
            id: id,
            peer: peer,
            phase: .completed,
            completedBytes: 10,
            totalBytes: 10,
            route: .lan
        )
    }

    private func completedHistoryItem(
        id: TransferID,
        peer: DeviceID,
        displayName: String,
        outputURL: URL
    ) -> TransferSurfaceItem {
        TransferSurfaceItem(
            snapshot: completedSnapshot(id: id, peer: peer),
            peerName: "书房 Mac",
            displayName: displayName,
            bytesPerSecond: nil,
            estimatedTimeRemaining: nil,
            outputURL: outputURL,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    @MainActor
    private func drainMainActorTasks() async {
        for _ in 0..<10 {
            await Task.yield()
        }
    }
}

private actor SurfaceTransferCoordinator: TransferCoordinating {
    func send(items: [URL], to device: DeviceID) async throws -> TransferID {
        TransferID(rawValue: UUID())
    }

    func pause(_ id: TransferID) async {}
    func resume(_ id: TransferID) async throws {}
    func cancel(_ id: TransferID) async -> TransferCancellationResult { .requested }
}

private actor CorrelatedSurfaceTransferCoordinator: TransferCoordinating {
    let id: TransferID
    private var sends = 0

    init(id: TransferID) {
        self.id = id
    }

    func send(items: [URL], to device: DeviceID) async throws -> TransferID {
        sends += 1
        return id
    }

    func pause(_ id: TransferID) async {}
    func resume(_ id: TransferID) async throws {}
    func cancel(_ id: TransferID) async -> TransferCancellationResult { .requested }
    func sendCount() -> Int { sends }
}

@MainActor
private final class RecordingSoftwareUpdateService: SoftwareUpdateServicing {
    let isAvailable = true
    private(set) var checkCount = 0
    private(set) var showCount = 0

    func checkForUpdates() { checkCount += 1 }
    func showAvailableUpdate() { showCount += 1 }
}

@MainActor
private final class ControllableSoftwareUpdateService:
    SoftwareUpdateServicing,
    SoftwareUpdateSnapshotProviding
{
    let isAvailable = true
    private(set) var checkCount = 0
    private(set) var showCount = 0
    private(set) var subscriptionCount = 0
    private(set) var terminationCount = 0
    private var continuations: [AsyncStream<SoftwareUpdateSnapshot>.Continuation] = []
    var softwareUpdateSnapshot: SoftwareUpdateSnapshot

    init(snapshot: SoftwareUpdateSnapshot) {
        softwareUpdateSnapshot = snapshot
    }

    func checkForUpdates() { checkCount += 1 }
    func showAvailableUpdate() { showCount += 1 }

    func softwareUpdateSnapshots() -> AsyncStream<SoftwareUpdateSnapshot> {
        subscriptionCount += 1
        return AsyncStream { continuation in
            continuations.append(continuation)
            continuation.yield(softwareUpdateSnapshot)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.terminationCount += 1
                }
            }
        }
    }

    func publish(_ snapshot: SoftwareUpdateSnapshot) {
        softwareUpdateSnapshot = snapshot
        continuations.last?.yield(snapshot)
    }

    func yieldStale(_ snapshot: SoftwareUpdateSnapshot, subscription: Int) {
        continuations[subscription].yield(snapshot)
    }
}

@MainActor
private final class RecordingReceiveNotificationService: ReceiveNotificationServicing {
    private var snapshot: ReceiveNotificationSnapshot
    private(set) var openSettingsCount = 0
    private(set) var subscriptionCount = 0
    private(set) var terminationCount = 0
    private(set) var refreshCount = 0
    private var continuations: [AsyncStream<ReceiveNotificationSnapshot>.Continuation] = []

    init(state: ReceiveNotificationAuthorizationState) {
        snapshot = ReceiveNotificationSnapshot(authorizationState: state)
    }

    func receiveNotificationSnapshots() -> AsyncStream<ReceiveNotificationSnapshot> {
        subscriptionCount += 1
        return AsyncStream { continuation in
            continuations.append(continuation)
            continuation.yield(snapshot)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.terminationCount += 1
                }
            }
        }
    }

    func refreshReceiveNotifications() async {
        refreshCount += 1
        continuations.last?.yield(snapshot)
    }

    func setState(_ state: ReceiveNotificationAuthorizationState) {
        snapshot = ReceiveNotificationSnapshot(authorizationState: state)
    }

    func yield(_ state: ReceiveNotificationAuthorizationState, subscription: Int) {
        continuations[subscription].yield(ReceiveNotificationSnapshot(authorizationState: state))
    }

    func openSystemSettings() {
        openSettingsCount += 1
    }
}

@MainActor
private final class SuspendingReceiveNotificationService: ReceiveNotificationServicing {
    private(set) var cancelledRefreshes: [Int] = []
    private var pendingRefreshes: [CheckedContinuation<Void, Never>?] = []

    func receiveNotificationSnapshots() -> AsyncStream<ReceiveNotificationSnapshot> {
        AsyncStream { continuation in
            continuation.yield(ReceiveNotificationSnapshot(authorizationState: .notDetermined))
        }
    }

    func refreshReceiveNotifications() async {
        let index = pendingRefreshes.count
        await withCheckedContinuation { continuation in
            pendingRefreshes.append(continuation)
        }
        if Task.isCancelled {
            cancelledRefreshes.append(index)
        }
    }

    func waitForRefreshes(_ count: Int) async {
        for _ in 0..<100 where pendingRefreshes.count < count {
            await Task.yield()
        }
        XCTAssertEqual(pendingRefreshes.count, count)
    }

    func resumeRefresh(at index: Int) {
        let continuation = pendingRefreshes[index]
        pendingRefreshes[index] = nil
        continuation?.resume()
    }

    func openSystemSettings() {}
}

private extension SoftwareUpdateSnapshot {
    static var fixtureUpToDate: SoftwareUpdateSnapshot {
        SoftwareUpdateSnapshot(
            installedVersion: InstalledAppVersion(info: [
                "CFBundleShortVersionString": "1.2.0",
                "CFBundleVersion": "13",
            ]),
            phase: .upToDate,
            canCheck: true,
            lastCheckedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    static func fixture(
        phase: SoftwareUpdatePhase,
        canCheck: Bool,
        lastCheckedAt: Date = Date(timeIntervalSince1970: 2_000)
    ) -> SoftwareUpdateSnapshot {
        SoftwareUpdateSnapshot(
            installedVersion: fixtureUpToDate.installedVersion,
            phase: phase,
            canCheck: canCheck,
            lastCheckedAt: lastCheckedAt
        )
    }
}

@MainActor
private final class PendingPeerPairingService: PairingSurfaceServicing {
    let isAvailable = true
    let peer: DeviceSummary

    init(peer: DeviceSummary) {
        self.peer = peer
    }

    func createCode() async throws -> String { throw SurfaceActionFailure.expected }
    func join(code: String) async throws -> PairingJoinResult {
        throw SurfaceActionFailure.expected
    }
    func cancel() async throws {}
    func pendingPeer() async -> DeviceSummary? { peer }
}

@MainActor
private final class HostApprovalPairingSurfaceService: PairingSurfaceServicing {
    let isAvailable = true
    let peer: DeviceSummary
    private(set) var approvalCount = 0
    private(set) var rejectionCount = 0
    private(set) var waitCount = 0

    init(peer: DeviceSummary) { self.peer = peer }

    func createCode() async throws -> String { "123456" }
    func join(code: String) async throws -> PairingJoinResult {
        PairingJoinResult(
            sessionID: PairingSessionID(),
            peer: peer,
            fingerprint: "internal",
            hostEphemeralPublicKey: Data(),
            joiningEphemeralPublicKey: Data()
        )
    }
    func approve() async throws -> SurfaceActionResult {
        approvalCount += 1
        return .committed
    }
    func reject() async throws { rejectionCount += 1 }
    func awaitHostApproval() async throws -> SurfaceActionResult {
        waitCount += 1
        try await Task.sleep(for: .seconds(60))
        return .committed
    }
    func cancel() async throws {}
}

@MainActor
private final class FailingPairingSurfaceService: PairingSurfaceServicing {
    let isAvailable = true
    func createCode() async throws -> String { throw SurfaceActionFailure.expected }
    func join(code: String) async throws -> PairingJoinResult {
        throw SurfaceActionFailure.expected
    }
    func cancel() async throws { throw SurfaceActionFailure.expected }
}

@MainActor
private final class WarningPairingSurfaceService: PairingSurfaceServicing {
    static let warning = "设备信任已建立，但本地信任记录未保存；请检查存储权限后重启确认。"
    let isAvailable = true
    let peer: DeviceSummary

    init(peer: DeviceSummary) { self.peer = peer }

    func createCode() async throws -> String { "123456" }
    func join(code: String) async throws -> PairingJoinResult {
        throw SurfaceActionFailure.expected
    }
    func approve() async throws -> SurfaceActionResult {
        .committedWithWarning(Self.warning)
    }
    func cancel() async throws {}
    func pendingPeer() async -> DeviceSummary? { peer }
}

@MainActor
private final class FailingSettingsSurfaceService: DeviceSettingsServicing {
    let isAvailable = true
    func rename(_ id: DeviceID, to displayName: String) async throws {
        throw SurfaceActionFailure.expected
    }
    func revoke(_ id: DeviceID) async throws -> SurfaceActionResult {
        throw SurfaceActionFailure.expected
    }
    func updateReceivePolicy(_ id: DeviceID, autoAccept: Bool, maximumBytes: UInt64?) async throws {
        throw SurfaceActionFailure.expected
    }
    func updateDefaultDirectory(_ directory: URL) async throws {
        throw SurfaceActionFailure.expected
    }
    func updateDirectory(_ directory: URL?, for id: DeviceID) async throws {
        throw SurfaceActionFailure.expected
    }
}

@MainActor
private final class WarningSettingsSurfaceService: DeviceSettingsServicing {
    static let warning = "设备信任已撤销，但部分本地记录未保存；请检查存储权限后重启确认。"
    let isAvailable = true
    func rename(_ id: DeviceID, to displayName: String) async throws {}
    func revoke(_ id: DeviceID) async throws -> SurfaceActionResult {
        .committedWithWarning(Self.warning)
    }
    func updateReceivePolicy(_ id: DeviceID, autoAccept: Bool, maximumBytes: UInt64?) async throws {
    }
    func updateDefaultDirectory(_ directory: URL) async throws {}
    func updateDirectory(_ directory: URL?, for id: DeviceID) async throws {}
}

@MainActor
private final class RecordingEssentialSettingsService: DeviceSettingsServicing {
    let isAvailable = true
    var shouldFail = false
    private(set) var localDisplayName: String?
    private(set) var autoReceive: Bool?
    private(set) var launchAtLogin: Bool?

    func rename(_ id: DeviceID, to displayName: String) async throws {}
    func revoke(_ id: DeviceID) async throws -> SurfaceActionResult { .committed }
    func updateReceivePolicy(_ id: DeviceID, autoAccept: Bool, maximumBytes: UInt64?) async throws {}
    func updateDefaultDirectory(_ directory: URL) async throws {}
    func updateDirectory(_ directory: URL?, for id: DeviceID) async throws {}
    func updateLocalDisplayName(_ name: String) async throws {
        if shouldFail { throw SurfaceActionFailure.expected }
        localDisplayName = name
    }
    func updateAutoReceive(_ enabled: Bool) async throws {
        if shouldFail { throw SurfaceActionFailure.expected }
        autoReceive = enabled
    }
    func updateLaunchAtLogin(_ enabled: Bool) async throws {
        if shouldFail { throw SurfaceActionFailure.expected }
        launchAtLogin = enabled
    }
}

@MainActor
private final class StubLoginItemRegistration: LoginItemRegistering {
    let error: Error?
    init(error: Error? = nil) { self.error = error }
    func setEnabled(_ enabled: Bool) throws {
        if let error { throw error }
    }
}

@MainActor
private final class FailingTransferSurfaceService: TransferSurfaceServicing {
    func pause(_ id: TransferID) async throws { throw SurfaceActionFailure.expected }
    func resume(_ id: TransferID) async throws { throw SurfaceActionFailure.expected }
    func cancel(_ id: TransferID) async throws { throw SurfaceActionFailure.expected }
    func showInFinder(_ url: URL) {}
}

private enum SurfaceActionFailure: Error { case expected }

@MainActor
private final class RecordingAccessibilityAnnouncer: AccessibilityAnnouncing {
    private(set) var messages: [String] = []
    func announce(_ message: String) { messages.append(message) }
}

@MainActor
private final class SurfaceFilePicker: StatusItemFilePicking {
    func chooseFiles() -> [URL]? {
        [URL(fileURLWithPath: "/tmp/a")]
    }
}

@MainActor
private final class SurfaceDeviceMenu: StatusItemDeviceMenuPresenting {
    var select: ((DeviceID) -> Bool)?

    func present(
        devices: [DeviceSummary],
        anchor: NSView,
        select: @escaping (DeviceID) -> Bool,
        cancel: @escaping () -> Void
    ) {
        self.select = select
    }
}
