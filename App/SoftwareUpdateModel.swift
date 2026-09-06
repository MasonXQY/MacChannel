import Foundation
import MacChannelCore

package struct InstalledAppVersion: Equatable, Sendable {
    package let shortVersion: String?
    package let build: String?

    package init(info: [String: Any]) {
        shortVersion = info["CFBundleShortVersionString"] as? String
        build = info["CFBundleVersion"] as? String
    }

    package init(bundle: Bundle = .main) {
        self.init(info: bundle.infoDictionary ?? [:])
    }

    package var localizedText: String {
        guard let shortVersion, let build else { return "DropMesh，版本未知" }
        return "DropMesh \(shortVersion)（\(build)）"
    }
}

package enum SoftwareUpdatePhase: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case available(version: String)
    case downloading
    case installDeferred
    case managedByAppStore
    case failed
    case securityFailure

    package var statusText: String {
        switch self {
        case .idle:
            "每天自动检查一次，是否安装由你决定。"
        case .checking:
            "正在检查更新…"
        case .upToDate:
            "当前已是最新版本。"
        case let .available(version):
            "发现新版本 \(version)。"
        case .downloading:
            "正在下载更新…"
        case .installDeferred:
            "更新已下载，将在退出后安装。"
        case .managedByAppStore:
            "更新由 Mac App Store 管理。"
        case .failed:
            "暂时无法检查更新，请稍后重试。"
        case .securityFailure:
            "无法验证更新的安全性。"
        }
    }

    package var hasAvailableUpdate: Bool {
        switch self {
        case .available, .downloading, .installDeferred, .managedByAppStore:
            true
        case .idle, .checking, .upToDate, .failed, .securityFailure:
            false
        }
    }
}

package struct SoftwareUpdateSnapshot: Equatable, Sendable {
    package let installedVersion: InstalledAppVersion
    package let phase: SoftwareUpdatePhase
    package let canCheck: Bool
    package let lastCheckedAt: Date?

    package init(
        installedVersion: InstalledAppVersion,
        phase: SoftwareUpdatePhase,
        canCheck: Bool,
        lastCheckedAt: Date?
    ) {
        self.installedVersion = installedVersion
        self.phase = phase
        self.canCheck = canCheck
        self.lastCheckedAt = lastCheckedAt
    }

    package var canShowUpdate: Bool {
        phase.hasAvailableUpdate && canCheck
    }

    package func lastCheckedText(timeZone: TimeZone = .current) -> String {
        guard let lastCheckedAt else { return "尚未检查" }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.timeZone = timeZone
        return formatter.string(from: lastCheckedAt)
    }
}

@MainActor
package protocol SoftwareUpdateServicing: AnyObject {
    var isAvailable: Bool { get }
    func checkForUpdates()
    func showAvailableUpdate()
}

@MainActor
package protocol SoftwareUpdateSnapshotProviding: AnyObject {
    var softwareUpdateSnapshot: SoftwareUpdateSnapshot { get }
    func softwareUpdateSnapshots() -> AsyncStream<SoftwareUpdateSnapshot>
}

@MainActor
package protocol SoftwareUpdateLaunchControlling: AnyObject {
    func observeTransfers(
        _ snapshots: @escaping @Sendable () async -> AsyncStream<[TransferSnapshot]>,
        onReady: @escaping @MainActor () -> Void
    )
    func start()
}

@MainActor
package protocol SoftwareUpdateControlling:
    SoftwareUpdateServicing,
    SoftwareUpdateSnapshotProviding,
    SoftwareUpdateLaunchControlling
{
    func stop()
}
