import Foundation
import MacChannelAppKit
import MacChannelCore

@MainActor
package final class AppStoreUpdateController: SoftwareUpdateControlling {
    private let appStoreURL: URL?
    private let openURL: (URL) -> Bool
    private var continuations: [
        UUID: AsyncStream<SoftwareUpdateSnapshot>.Continuation
    ] = [:]

    package private(set) var softwareUpdateSnapshot: SoftwareUpdateSnapshot

    package var isAvailable: Bool { appStoreURL != nil }

    package init(
        appStoreURL: URL?,
        installedVersion: InstalledAppVersion,
        openURL: @escaping (URL) -> Bool
    ) {
        let validURL = appStoreURL.flatMap { url -> URL? in
            url.scheme?.lowercased() == "macappstore" ? url : nil
        }
        self.appStoreURL = validURL
        self.openURL = openURL
        softwareUpdateSnapshot = SoftwareUpdateSnapshot(
            installedVersion: installedVersion,
            phase: validURL == nil ? .failed : .managedByAppStore,
            canCheck: validURL != nil,
            lastCheckedAt: nil
        )
    }

    package func checkForUpdates() {
        openAppStore()
    }

    package func showAvailableUpdate() {
        openAppStore()
    }

    package func start() {}

    package func stop() {
        continuations.values.forEach { $0.finish() }
        continuations.removeAll()
    }

    package func observeTransfers(
        _ snapshots: @escaping @Sendable () async -> AsyncStream<[TransferSnapshot]>,
        onReady: @escaping @MainActor () -> Void
    ) {
        onReady()
    }

    package func softwareUpdateSnapshots() -> AsyncStream<SoftwareUpdateSnapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.yield(softwareUpdateSnapshot)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.continuations[id] = nil
                }
            }
        }
    }

    private func openAppStore() {
        guard let appStoreURL else { return }
        guard openURL(appStoreURL) else {
            publishFailure()
            return
        }
    }

    private func publishFailure() {
        softwareUpdateSnapshot = SoftwareUpdateSnapshot(
            installedVersion: softwareUpdateSnapshot.installedVersion,
            phase: .failed,
            canCheck: true,
            lastCheckedAt: softwareUpdateSnapshot.lastCheckedAt
        )
        continuations.values.forEach { $0.yield(softwareUpdateSnapshot) }
    }
}
