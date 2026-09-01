import Foundation

struct InstalledAppVersion: Equatable, Sendable {
    let shortVersion: String?
    let build: String?

    init(info: [String: Any]) {
        shortVersion = info["CFBundleShortVersionString"] as? String
        build = info["CFBundleVersion"] as? String
    }

    init(bundle: Bundle = .main) {
        self.init(info: bundle.infoDictionary ?? [:])
    }

    var localizedText: String {
        guard let shortVersion, let build else { return "Mac 通道，版本未知" }
        return "Mac 通道 \(shortVersion)（\(build)）"
    }
}

enum SoftwareUpdatePhase: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case available(version: String)
    case downloading
    case installDeferred
    case failed
    case securityFailure

    var statusText: String {
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
        case .failed:
            "暂时无法检查更新，请稍后重试。"
        case .securityFailure:
            "无法验证更新的安全性。"
        }
    }

    var hasAvailableUpdate: Bool {
        switch self {
        case .available, .downloading, .installDeferred:
            true
        case .idle, .checking, .upToDate, .failed, .securityFailure:
            false
        }
    }
}

struct SoftwareUpdateSnapshot: Equatable, Sendable {
    let installedVersion: InstalledAppVersion
    let phase: SoftwareUpdatePhase
    let canCheck: Bool
    let lastCheckedAt: Date?

    func lastCheckedText(timeZone: TimeZone = .current) -> String {
        guard let lastCheckedAt else { return "尚未检查" }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.timeZone = timeZone
        return formatter.string(from: lastCheckedAt)
    }
}

@MainActor
protocol SoftwareUpdateServicing: AnyObject {
    var isAvailable: Bool { get }
    func checkForUpdates()
    func showAvailableUpdate()
}
