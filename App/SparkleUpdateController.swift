import Foundation
import MacChannelCore
import Sparkle

@MainActor
protocol UpdateDriving: AnyObject {
    var canCheckForUpdates: Bool { get }
    func checkForUpdates()
}

@MainActor
protocol UpdateAvailabilityDriving: AnyObject {
    func canCheckForUpdatesUpdates() -> AsyncStream<Bool>
}

@MainActor
final class SparkleUpdateController: NSObject, SoftwareUpdateServicing {
    private static let sparkleErrorDomain = "SUSparkleErrorDomain"
    private static let noUpdateError = 1001
    private static let installationCancelledError = 4007
    private static let securityErrorCodes: Set<Int> = [
        1,    // missing or invalid public signing key
        2,    // insufficient signing
        3,    // insecure feed URL
        1000, // invalid or unverifiable appcast
        1002, // appcast error
        3001, // archive signature error
        3002, // update validation error
        4006, // downgrade attempt
        4009, // invalid update
    ]

    private let installedVersion: InstalledAppVersion
    private let now: () -> Date
    private let injectedDriver: (any UpdateDriving)?
    private let installationGate: UpdateInstallationGate
    private var continuations: [UUID: AsyncStream<SoftwareUpdateSnapshot>.Continuation] = [:]
    private var transferObservationTask: Task<Void, Never>?
    private var transferObservationID: UUID?
    private var availabilityObservationTask: Task<Void, Never>?
    private var updaterAvailabilityObservation: NSKeyValueObservation?
    private var availabilityObservationID: UUID?
    private var manualCheckInProgress = false
    private var hasStarted = false

    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: self
    )

    private(set) var snapshot: SoftwareUpdateSnapshot

    var isAvailable: Bool { true }

    override convenience init() {
        self.init(
            driver: nil,
            installedVersion: InstalledAppVersion(),
            installationGate: UpdateInstallationGate(),
            now: Date.init
        )
    }

    convenience init(
        driver: any UpdateDriving,
        installedVersion: InstalledAppVersion,
        now: @escaping () -> Date = Date.init
    ) {
        self.init(
            driver: driver,
            installedVersion: installedVersion,
            installationGate: UpdateInstallationGate(),
            now: now
        )
    }

    private init(
        driver: (any UpdateDriving)?,
        installedVersion: InstalledAppVersion,
        installationGate: UpdateInstallationGate,
        now: @escaping () -> Date
    ) {
        injectedDriver = driver
        self.installedVersion = installedVersion
        self.installationGate = installationGate
        self.now = now
        snapshot = SoftwareUpdateSnapshot(
            installedVersion: installedVersion,
            phase: .idle,
            canCheck: driver?.canCheckForUpdates ?? false,
            lastCheckedAt: nil
        )
        super.init()
        if let availabilityDriver = driver as? any UpdateAvailabilityDriving {
            observeAvailability(availabilityDriver.canCheckForUpdatesUpdates())
        }
    }

    func start() {
        guard !hasStarted, injectedDriver == nil else { return }
        hasStarted = true
        observeUpdaterAvailability()
        updaterController.startUpdater()
        publish(phase: snapshot.phase, canCheck: updaterController.updater.canCheckForUpdates)
    }

    func stop() {
        transferObservationTask?.cancel()
        transferObservationTask = nil
        transferObservationID = nil
        availabilityObservationTask?.cancel()
        availabilityObservationTask = nil
        updaterAvailabilityObservation?.invalidate()
        updaterAvailabilityObservation = nil
        availabilityObservationID = nil
        installationGate.cancelPendingInstall()
        manualCheckInProgress = false
        continuations.values.forEach { $0.finish() }
        continuations.removeAll()
    }

    func snapshots() -> AsyncStream<SoftwareUpdateSnapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.yield(snapshot)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.continuations[id] = nil
                }
            }
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else {
            publish(phase: snapshot.phase, canCheck: false)
            return
        }
        manualCheckInProgress = true
        publish(phase: .checking, canCheck: false)
        performForegroundCheck()
    }

    func showAvailableUpdate() {
        guard canCheckForUpdates else {
            publish(phase: snapshot.phase, canCheck: false)
            return
        }
        manualCheckInProgress = true
        if !snapshot.phase.hasAvailableUpdate {
            publish(phase: .checking, canCheck: false)
        }
        performForegroundCheck()
    }

    func observeTransfers(
        _ snapshots: @escaping @Sendable () async -> AsyncStream<[TransferSnapshot]>,
        onReady: @escaping @MainActor () -> Void = {}
    ) {
        transferObservationTask?.cancel()
        let observationID = UUID()
        transferObservationID = observationID
        transferObservationTask = Task { [weak self] in
            let updates = await snapshots()
            var iterator = updates.makeAsyncIterator()
            var isFirstSnapshot = true
            while let snapshots = await iterator.next() {
                guard !Task.isCancelled,
                      self?.transferObservationID == observationID
                else { return }
                self?.installationGate.updateTransfers(snapshots)
                if isFirstSnapshot {
                    isFirstSnapshot = false
                    onReady()
                }
            }
        }
    }

    func postponeRelaunch(untilInvoking install: @escaping () -> Void) -> Bool {
        let postponed = installationGate.postponeRelaunch(untilInvoking: install)
        if postponed {
            publish(phase: .installDeferred)
        }
        return postponed
    }

    func didFindUpdate(version: String) {
        publish(phase: .available(version: version), lastCheckedAt: now())
    }

    func didNotFindUpdate(userInitiated: Bool) {
        _ = userInitiated
        manualCheckInProgress = false
        publish(phase: .upToDate, lastCheckedAt: now())
    }

    func didDownloadUpdate() {
        publish(phase: .downloading)
    }

    func didAbort(with error: Error) {
        didAbort(with: error, userInitiated: manualCheckInProgress)
    }

    func didAbort(with error: Error, userInitiated: Bool) {
        manualCheckInProgress = false
        let error = error as NSError
        let phase: SoftwareUpdatePhase
        if isSparkleError(error, code: Self.noUpdateError) {
            phase = .upToDate
        } else if isSparkleError(error, code: Self.installationCancelledError) {
            installationGate.cancelPendingInstall()
            phase = .idle
        } else if isSecurityFailure(error) {
            phase = .securityFailure
        } else {
            phase = userInitiated ? .failed : .idle
        }
        publish(phase: phase, lastCheckedAt: now())
    }

    func didFinishUpdateCycle(canCheck: Bool) {
        manualCheckInProgress = false
        publish(phase: snapshot.phase, canCheck: canCheck)
    }

    private var canCheckForUpdates: Bool {
        if let injectedDriver {
            return injectedDriver.canCheckForUpdates
        }
        return updaterController.updater.canCheckForUpdates
    }

    private func performForegroundCheck() {
        if let injectedDriver {
            injectedDriver.checkForUpdates()
        } else {
            updaterController.checkForUpdates(nil)
        }
    }

    private func observeAvailability(_ updates: AsyncStream<Bool>) {
        availabilityObservationTask?.cancel()
        let observationID = UUID()
        availabilityObservationID = observationID
        availabilityObservationTask = Task { [weak self] in
            for await canCheck in updates {
                guard !Task.isCancelled,
                      self?.availabilityObservationID == observationID
                else { return }
                self?.publish(phase: self?.snapshot.phase ?? .idle, canCheck: canCheck)
            }
        }
    }

    private func observeUpdaterAvailability() {
        updaterAvailabilityObservation?.invalidate()
        let observationID = UUID()
        availabilityObservationID = observationID
        updaterAvailabilityObservation = updaterController.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] _, change in
            guard let canCheck = change.newValue else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      self.availabilityObservationID == observationID
                else { return }
                self.publish(phase: self.snapshot.phase, canCheck: canCheck)
            }
        }
    }

    private func publish(
        phase: SoftwareUpdatePhase,
        canCheck: Bool? = nil,
        lastCheckedAt: Date? = nil
    ) {
        snapshot = SoftwareUpdateSnapshot(
            installedVersion: installedVersion,
            phase: phase,
            canCheck: canCheck ?? canCheckForUpdates,
            lastCheckedAt: lastCheckedAt ?? snapshot.lastCheckedAt
        )
        continuations.values.forEach { $0.yield(snapshot) }
    }

    private func isSecurityFailure(_ rootError: NSError) -> Bool {
        var error: NSError? = rootError
        var visited = Set<ObjectIdentifier>()
        while let current = error, visited.insert(ObjectIdentifier(current)).inserted {
            if current.domain == Self.sparkleErrorDomain,
               Self.securityErrorCodes.contains(current.code)
            {
                return true
            }
            error = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    private func isSparkleError(_ error: NSError, code: Int) -> Bool {
        error.domain == Self.sparkleErrorDomain && error.code == code
    }
}

extension SparkleUpdateController: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        didFindUpdate(version: item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        let initiated = (error as NSError).userInfo[SPUNoUpdateFoundUserInitiatedKey] as? Bool
            ?? manualCheckInProgress
        didNotFindUpdate(userInitiated: initiated)
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        didDownloadUpdate()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        didAbort(with: error)
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        didFinishUpdateCycle(canCheck: updater.canCheckForUpdates)
    }

    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        postponeRelaunch(untilInvoking: installHandler)
    }
}

extension SparkleUpdateController: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        if !state.userInitiated {
            didFindUpdate(version: update.displayVersionString)
        }
    }
}
