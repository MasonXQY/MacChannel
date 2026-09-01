import XCTest

@testable import MacChannelCore
@testable import MacChannelAppKit

final class SoftwareUpdateTests: XCTestCase {
    func testInstalledVersionUsesBundleValuesAndFallsBackWithoutCrashing() {
        XCTAssertEqual(
            InstalledAppVersion(info: [
                "CFBundleShortVersionString": "1.2.0",
                "CFBundleVersion": "13",
            ]).localizedText,
            "Mac 通道 1.2.0（13）"
        )
        XCTAssertEqual(InstalledAppVersion(info: [:]).localizedText, "Mac 通道，版本未知")
    }

    func testUpdatePhasesProvideLocalizedStatusAndAvailability() {
        XCTAssertEqual(SoftwareUpdatePhase.idle.statusText, "每天自动检查一次，是否安装由你决定。")
        XCTAssertEqual(SoftwareUpdatePhase.checking.statusText, "正在检查更新…")
        XCTAssertEqual(SoftwareUpdatePhase.upToDate.statusText, "当前已是最新版本。")
        XCTAssertEqual(SoftwareUpdatePhase.available(version: "1.2.1").statusText, "发现新版本 1.2.1。")
        XCTAssertEqual(SoftwareUpdatePhase.failed.statusText, "暂时无法检查更新，请稍后重试。")
        XCTAssertTrue(SoftwareUpdatePhase.available(version: "1.2.1").hasAvailableUpdate)
        XCTAssertTrue(SoftwareUpdatePhase.downloading.hasAvailableUpdate)
        XCTAssertTrue(SoftwareUpdatePhase.installDeferred.hasAvailableUpdate)
        XCTAssertFalse(SoftwareUpdatePhase.securityFailure.hasAvailableUpdate)
    }

    func testSnapshotFormatsLastCheckedTimeWithInjectedTimeZone() {
        let snapshot = SoftwareUpdateSnapshot(
            installedVersion: InstalledAppVersion(info: [:]),
            phase: .upToDate,
            canCheck: true,
            lastCheckedAt: Date(timeIntervalSince1970: 0)
        )
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        XCTAssertEqual(snapshot.lastCheckedText(timeZone: TimeZone(secondsFromGMT: 0)!), formatter.string(from: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(
            SoftwareUpdateSnapshot(
                installedVersion: InstalledAppVersion(info: [:]),
                phase: .idle,
                canCheck: true,
                lastCheckedAt: nil
            ).lastCheckedText(timeZone: .current),
            "尚未检查"
        )
    }

    @MainActor
    func testServiceProtocolCanBeImplementedByAnAvailableUpdater() {
        let service = UpdateServiceStub()
        XCTAssertTrue(service.isAvailable)
        service.checkForUpdates()
        service.showAvailableUpdate()
        XCTAssertEqual(service.checkCount, 1)
        XCTAssertEqual(service.showCount, 1)
    }

    @MainActor
    func testInstallationWaitsForLastActiveTransferAndRunsOnce() {
        let gate = UpdateInstallationGate()
        var installs = 0
        gate.updateTransfers([snapshot(phase: .transferring)])

        XCTAssertTrue(gate.postponeRelaunch { installs += 1 })
        XCTAssertEqual(installs, 0)

        gate.updateTransfers([snapshot(phase: .completed)])
        gate.updateTransfers([snapshot(phase: .completed)])
        XCTAssertEqual(installs, 1)
    }

    @MainActor
    func testPostponeRelaunchReturnsFalseWithoutActiveTransfers() {
        let gate = UpdateInstallationGate()
        var installs = 0

        XCTAssertFalse(gate.postponeRelaunch { installs += 1 })
        XCTAssertEqual(installs, 0)
    }

    @MainActor
    func testDuplicatePostponeKeepsOnlyFirstInstallCallback() {
        let gate = UpdateInstallationGate()
        var firstInstalls = 0
        var duplicateInstalls = 0
        gate.updateTransfers([snapshot(phase: .transferring)])

        XCTAssertTrue(gate.postponeRelaunch { firstInstalls += 1 })
        XCTAssertTrue(gate.postponeRelaunch { duplicateInstalls += 1 })
        gate.updateTransfers([snapshot(phase: .completed)])

        XCTAssertEqual(firstInstalls, 1)
        XCTAssertEqual(duplicateInstalls, 0)
    }

    @MainActor
    func testCancellingPendingInstallPreventsTerminalTransferFromInvokingIt() {
        let gate = UpdateInstallationGate()
        var installs = 0
        gate.updateTransfers([snapshot(phase: .transferring)])
        XCTAssertTrue(gate.postponeRelaunch { installs += 1 })

        gate.cancelPendingInstall()
        gate.updateTransfers([snapshot(phase: .completed)])

        XCTAssertEqual(installs, 0)
    }

    @MainActor
    func testAllNonterminalTransferPhasesPostponeRelaunch() {
        let activePhases: [TransferPhase] = [
            .preparing,
            .connecting,
            .transferring,
            .paused,
            .verifying,
            .cancelling,
        ]

        for phase in activePhases {
            let gate = UpdateInstallationGate()
            var installs = 0
            gate.updateTransfers([snapshot(phase: phase)])

            XCTAssertTrue(gate.postponeRelaunch { installs += 1 }, "Expected \(phase) to remain active")
            XCTAssertEqual(installs, 0)
        }
    }

    @MainActor
    func testAllTerminalTransferPhasesReleasePendingInstall() {
        let terminalPhases: [TransferPhase] = [.completed, .failed, .cancelled]

        for phase in terminalPhases {
            let gate = UpdateInstallationGate()
            var installs = 0
            gate.updateTransfers([snapshot(phase: .transferring)])
            XCTAssertTrue(gate.postponeRelaunch { installs += 1 })

            gate.updateTransfers([snapshot(phase: phase)])

            XCTAssertEqual(installs, 1, "Expected \(phase) to release the install")
        }
    }

    @MainActor
    func testPendingInstallWaitsUntilEveryTransferIsTerminal() {
        let gate = UpdateInstallationGate()
        let first = TransferID(rawValue: UUID())
        let second = TransferID(rawValue: UUID())
        var installs = 0
        gate.updateTransfers([
            snapshot(id: first, phase: .transferring),
            snapshot(id: second, phase: .paused),
        ])
        XCTAssertTrue(gate.postponeRelaunch { installs += 1 })

        gate.updateTransfers([
            snapshot(id: first, phase: .completed),
            snapshot(id: second, phase: .verifying),
        ])
        XCTAssertEqual(installs, 0)

        gate.updateTransfers([
            snapshot(id: first, phase: .completed),
            snapshot(id: second, phase: .cancelled),
        ])
        XCTAssertEqual(installs, 1)
    }

    @MainActor
    func testInstallCallbackCanReenterGateWithoutRunningAgain() {
        let gate = UpdateInstallationGate()
        var installs = 0
        var nestedPostponeResult: Bool?
        gate.updateTransfers([snapshot(phase: .transferring)])
        XCTAssertTrue(gate.postponeRelaunch {
            installs += 1
            gate.updateTransfers([])
            nestedPostponeResult = gate.postponeRelaunch { installs += 1 }
        })

        gate.updateTransfers([])
        gate.updateTransfers([])

        XCTAssertEqual(installs, 1)
        XCTAssertEqual(nestedPostponeResult, false)
    }

    private func snapshot(
        id: TransferID = TransferID(rawValue: UUID()),
        phase: TransferPhase
    ) -> TransferSnapshot {
        TransferSnapshot(
            id: id,
            peer: DeviceID(rawValue: UUID()),
            phase: phase,
            completedBytes: 0,
            totalBytes: 1,
            route: .lan
        )
    }
}

@MainActor
private final class UpdateServiceStub: SoftwareUpdateServicing {
    let isAvailable = true
    private(set) var checkCount = 0
    private(set) var showCount = 0

    func checkForUpdates() { checkCount += 1 }
    func showAvailableUpdate() { showCount += 1 }
}
