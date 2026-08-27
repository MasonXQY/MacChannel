import AppKit
import XCTest
@testable import MacChannelAppKit
@testable import MacChannelCore

final class TransferSurfaceTests: XCTestCase {
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

    func testFingerprintPresentationRequiresExplicitCrossDeviceHumanCheck() {
        let peer = DeviceSummary(
            id: DeviceID(rawValue: UUID()),
            displayName: "书房 Mac",
            availability: .internet
        )
        let presentation = PairingFingerprintPresentation(
            peer: peer,
            fingerprint: "ABCD EFGH"
        )
        XCTAssertTrue(presentation.canConfirm)
        XCTAssertEqual(presentation.peerText, "正在配对：书房 Mac")
        XCTAssertEqual(presentation.statusText, "等待你在另一台 Mac 上人工核对")
        XCTAssertEqual(presentation.statusSymbol, "person.2.badge.key")

        let unavailable = PairingFingerprintPresentation(peer: nil, fingerprint: "")
        XCTAssertFalse(unavailable.canConfirm)
        XCTAssertEqual(unavailable.peerText, "尚未确认对端设备身份")
        XCTAssertEqual(unavailable.statusText, "尚未生成安全指纹")
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
                defaultDirectory: defaultDirectory,
                devices: [persisted]
            )
        )

        XCTAssertEqual(model.defaultDirectory, defaultDirectory)
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
            completedSnapshot(id: id, peer: peer),
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
            completedSnapshot(id: id, peer: peer),
        ])
        surfaces.updateHistoryItems([
            completedHistoryItem(
                id: id,
                peer: peer,
                displayName: "照片.zip",
                outputURL: output
            ),
        ])
        surfaces.updateTransferSnapshots([
            TransferSnapshot(
                id: TransferID(rawValue: UUID()),
                peer: DeviceID(rawValue: UUID()),
                phase: .transferring,
                completedBytes: 1,
                totalBytes: 10,
                route: .relay
            ),
        ])

        let merged = try XCTUnwrap(model.history.first { $0.id == id })
        XCTAssertEqual(merged.displayName, "照片.zip")
        XCTAssertEqual(merged.outputURL, output)
        XCTAssertTrue(merged.canShowInFinder)
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

        for _ in 0..<125 {
            let id = TransferID(rawValue: UUID())
            ids.append(id)
            surfaces.updateTransferSnapshots([
                completedSnapshot(id: id, peer: DeviceID(rawValue: UUID())),
            ])
        }

        XCTAssertEqual(model.history.count, AppSurfaceController.liveHistoryLimit)
        XCTAssertFalse(model.history.contains { $0.id == ids[0] })
        XCTAssertTrue(model.history.contains { $0.id == ids[124] })
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
        transferModel: TransferSurfaceModel
    ) -> AppSurfaceController {
        AppSurfaceController(
            transferService: NativeTransferSurfaceService(
                coordinator: SurfaceTransferCoordinator()
            ),
            pairingService: UnavailablePairingSurfaceService(),
            settingsService: UnavailableDeviceSettingsService(),
            directorySelector: NativeDirectorySelector(),
            transferModel: transferModel
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
private final class PendingPeerPairingService: PairingSurfaceServicing {
    let isAvailable = true
    let peer: DeviceSummary

    init(peer: DeviceSummary) {
        self.peer = peer
    }

    func createCode() async -> String? { nil }
    func join(code: String) async -> PairingJoinResult? { nil }
    func confirmFingerprint(_ fingerprint: String) async {}
    func cancel() {}
    func pendingPeer() async -> DeviceSummary? { peer }
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
