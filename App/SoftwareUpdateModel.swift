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
        guard let shortVersion, let build else { return L10n.text(.updateVersionUnknown) }
        return L10n.text(.updateVersion, shortVersion, build)
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
            L10n.text(.updateAutomaticExplanation)
        case .checking:
            L10n.text(.updateChecking)
        case .upToDate:
            L10n.text(.updateUpToDate)
        case let .available(version):
            L10n.text(.updateVersionAvailable, String(version))
        case .downloading:
            L10n.text(.updateDownloading)
        case .installDeferred:
            L10n.text(.updateDeferred)
        case .managedByAppStore:
            L10n.text(.updateStoreManaged)
        case .failed:
            L10n.text(.updateCheckFailed)
        case .securityFailure:
            L10n.text(.updateSecurityFailure)
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
        guard let lastCheckedAt else { return L10n.text(.updateNeverChecked) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.language.localeIdentifier())
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
