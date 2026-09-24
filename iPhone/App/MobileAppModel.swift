import DropMeshMobileRuntime
import Foundation
import MacChannelCore
import Observation
import SwiftUI

enum MobileBootstrapState: Equatable { case idle, loading, ready, failed }
enum MobileRemovalState: Equatable { case idle, removing, saveFailed, failed, saved }

@MainActor @Observable
final class MobileAppModel {
    private(set) var bootstrapState: MobileBootstrapState = .idle
    private(set) var bootstrapError: String?
    private(set) var identityRecoveryAvailable = false
    private(set) var identityRecoveryConfirmationPresented = false
    private(set) var identityRecoveryConfirmationID: UUID?
    private(set) var identityRecoveryInProgress = false
    private(set) var pairedDevices: [DeviceSummary] = []
    private(set) var manualPeerIDs: Set<DeviceID> = []
    private(set) var accountConfigurationUnavailable = false
    private(set) var serviceState: MobileRuntimeState = .inactive
    private(set) var trustSyncState: PresenceTrustSyncState = .idle
    var serviceFailure: MobileRuntimeFailure? { explicitFailure ?? lifecycleFailure ?? runtimeFailure }
    private var explicitFailure: MobileRuntimeFailure?
    private var lifecycleFailure: MobileRuntimeFailure?
    private var runtimeFailure: MobileRuntimeFailure?
    private(set) var removalState: MobileRemovalState = .idle
    private(set) var renamingDeviceID: DeviceID?
    private(set) var renameFailureKey: String?
    var pairing: PairingModel?
    private(set) var send: MobileSendModel?
    private(set) var history: MobileHistoryModel?
    private(set) var settings: MobileSettingsModel?
    let pendingShares: MobilePendingShareModel
    private let loadSession: @Sendable () async throws -> any MobileAppSession
    private let recoverOrphanedIdentity: @Sendable () async throws -> Void
    private var session: (any MobileAppSession)?
    private var desiredForeground: Bool?
    private var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var observationTask: Task<Void, Never>?
    private var lifecycleTasks: [UUID: Task<Void, Never>] = [:]
    private var lifecycleRequest = UUID()
    private var retryRecoveryRequest: UUID?
    private var acceptedIdentityRecoveryID: UUID?
    private var retryCommandReturned = false
    private var removalTask: Task<Void, Never>?
    private var revokedIDs: Set<DeviceID> = []
    private var refreshTask: Task<Void, Never>?
    private var refreshPending = false
    private var closed = false

    init(pendingShares: MobilePendingShareModel? = nil,
         loadSession: @escaping @Sendable () async throws -> any MobileAppSession,
         recoverOrphanedIdentity: @escaping @Sendable () async throws -> Void = {
             throw MobileIdentityRecoveryError.conditionChanged
         }) {
        self.pendingShares = pendingShares ?? MobilePendingShareModel()
        self.loadSession = loadSession
        self.recoverOrphanedIdentity = recoverOrphanedIdentity
    }
    deinit { observationTask?.cancel() }

    func bootstrap(initialPhase: ScenePhase = .inactive) async {
        if desiredForeground == nil { desiredForeground = initialPhase == .active }
        if let bootstrapTask { await bootstrapTask.value; return }
        guard !closed, bootstrapState == .idle || bootstrapState == .failed else { return }
        bootstrapState = .loading
        bootstrapError = nil
        identityRecoveryAvailable = false
        let loader = loadSession
        let task = Task { [weak self] in
            do {
                let session = try await loader()
                guard let self else { return }
                self.session = session
                guard !self.closed else { await session.stopForeground(); return }
                self.send = MobileSendModel(session: session)
                self.history = MobileHistoryModel(session: session)
                self.settings = MobileSettingsModel(session: session)
                self.send?.setForeground(self.desiredForeground == true)
                self.observationTask = Task { [weak self] in
                    await session.observe { [weak self] in await self?.refreshDevices() }
                }
                await self.refreshDevices()
                await self.history?.refresh()
                self.bootstrapState = .ready
                self.reconcileScene()
            } catch MobileIdentityRecoveryError.orphanedInstallation {
                self?.bootstrapState = .failed
                self?.bootstrapError = String(localized: "identity.recovery.explanation")
                self?.identityRecoveryAvailable = true
            } catch {
                self?.bootstrapState = .failed
                self?.bootstrapError = String(localized: "bootstrap.error")
            }
        }
        bootstrapTask = task
        await task.value
        bootstrapTask = nil
    }
    func retryBootstrap() async { await bootstrap() }

    func requestIdentityRecovery() {
        guard identityRecoveryAvailable, !identityRecoveryInProgress else { return }
        identityRecoveryConfirmationID = UUID()
        identityRecoveryConfirmationPresented = true
    }

    func cancelIdentityRecovery(_ confirmationID: UUID? = nil) {
        guard confirmationID == nil || confirmationID == identityRecoveryConfirmationID else { return }
        identityRecoveryConfirmationID = nil
        identityRecoveryConfirmationPresented = false
    }

    func identityRecoveryPresentationDismissed(_ confirmationID: UUID) {
        Task { @MainActor [weak self] in
            // SwiftUI can dismiss an alert before invoking its affirmative action.
            await Task.yield()
            self?.cancelIdentityRecovery(confirmationID)
        }
    }

    func acceptIdentityRecovery(_ confirmationID: UUID) -> UUID? {
        guard identityRecoveryAvailable, identityRecoveryConfirmationID == confirmationID,
              !identityRecoveryInProgress else { return nil }
        identityRecoveryConfirmationID = nil
        identityRecoveryConfirmationPresented = false
        identityRecoveryInProgress = true
        acceptedIdentityRecoveryID = confirmationID
        return confirmationID
    }

    func confirmIdentityRecovery() async {
        guard let confirmationID = identityRecoveryConfirmationID,
              let operationID = acceptIdentityRecovery(confirmationID) else { return }
        await performAcceptedIdentityRecovery(operationID)
    }

    func performAcceptedIdentityRecovery(_ operationID: UUID) async {
        guard identityRecoveryInProgress, acceptedIdentityRecoveryID == operationID else { return }
        acceptedIdentityRecoveryID = nil
        do {
            try await recoverOrphanedIdentity()
            identityRecoveryAvailable = false
            bootstrapState = .failed
            identityRecoveryInProgress = false
            await bootstrap()
        } catch {
            identityRecoveryAvailable = false
            identityRecoveryInProgress = false
            bootstrapState = .failed
            bootstrapError = String(localized: "identity.recovery.failed")
        }
    }

    /// Record the event directly, before any task or bootstrap suspension.
    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active: desiredForeground = true
        case .background:
            desiredForeground = false
            trustSyncState = .idle
            retryRecoveryRequest = nil
            retryCommandReturned = false
        case .inactive: return
        @unknown default: return
        }
        send?.setForeground(desiredForeground == true)
        reconcileScene()
    }
    private func reconcileScene() {
        guard !closed, let session, let foreground = desiredForeground else { return }
        let id = UUID()
        lifecycleRequest = id
        let pairing = pairing
        let send = send
        lifecycleTasks[id] = Task { [weak self] in
            if foreground {
                guard self?.desiredForeground == true else {
                    self?.lifecycleTasks[id] = nil
                    return
                }
                do {
                    try await session.startForeground()
                    if self?.lifecycleRequest == id, self?.closed == false {
                        self?.lifecycleFailure = nil
                    }
                } catch {
                    // Background retires a runtime start. A late completion has no
                    // authority over diagnostics belonging to the current scene.
                    if self?.lifecycleRequest == id, self?.closed == false,
                       self?.desiredForeground == true,
                       (error as? MobileRuntimeError) != .interrupted {
                        self?.lifecycleFailure = .network
                    }
                }
            } else {
                async let network: Void = session.stopForeground()
                async let pair: Void = pairing?.handleBackground() ?? ()
                async let importing: Void = send?.cancelAndWait() ?? ()
                _ = await (network, pair, importing)
            }
            await self?.refreshDevices()
            if foreground, self?.desiredForeground == true {
                await self?.history?.refresh()
                await self?.pendingShares.refresh()
            }
            self?.lifecycleTasks[id] = nil
        }
    }
    func waitForLifecycle() async {
        while !lifecycleTasks.isEmpty {
            for task in Array(lifecycleTasks.values) { await task.value }
        }
    }
    func prepareInvitationFromOpenURL(_ url: URL) async -> Bool {
        let text = url.absoluteString
        guard (try? AccountInvitationLink(sharedText: text)) != nil else { return false }
        await bootstrap(initialPhase: .active)
        guard let account = settings?.account else { return false }
        await account.load()
        account.invitationLinkText = text
        return true
    }
    func presentPairing() {
        guard pairing == nil, let session else { return }
        pairing = PairingModel(makeAttempt: { try await session.makePairingAttempt() },
            refreshDevices: { [weak self] in await self?.didSavePairing() })
    }
    private func didSavePairing() async {
        guard let session else { return }
        if case let .paired(peer) = pairing?.phase { await session.rememberConfirmedPeer(peer) }
        do { try await session.refreshTrust(); explicitFailure = nil }
        catch { explicitFailure = .network }
        await refreshDevices()
    }
    func dismissPairingIfAllowed() {
        guard pairing?.mayDismiss == true else { return }
        pairing = nil
    }
    func refreshDevices() async {
        guard !closed, let session else { return }
        refreshPending = true
        if let refreshTask { await refreshTask.value; return }
        let task = Task { [weak self] in
            while self?.refreshPending == true {
                self?.refreshPending = false
                let request = self?.lifecycleRequest
                let snapshot = await session.snapshot()
                guard self?.lifecycleRequest == request else {
                    self?.refreshPending = true
                    continue
                }
                self?.apply(snapshot)
            }
            self?.refreshTask = nil
        }
        refreshTask = task
        await task.value
    }
    private func apply(_ snapshot: MobileAppSnapshot) {
        guard !closed else { return }
        serviceState = snapshot.state
        trustSyncState = desiredForeground == true ? snapshot.trustSyncState : .idle
        runtimeFailure = snapshot.failure
        manualPeerIDs = snapshot.trustedIDs
        accountConfigurationUnavailable = snapshot.accountConfigurationUnavailable
        history?.update(snapshot)
        settings?.update(snapshot)
        var sendSnapshot = snapshot
        sendSnapshot.trustedIDs.subtract(revokedIDs)
        sendSnapshot.effectivePeerIDs = snapshot.sendablePeerIDs.subtracting(revokedIDs)
        send?.update(sendSnapshot, blockedIDs: revokedIDs)
        if retryRecoveryRequest != nil, retryCommandReturned,
           desiredForeground == true, snapshot.state == .online {
            lifecycleFailure = nil
            retryRecoveryRequest = nil
            retryCommandReturned = false
        }
        let reachable = Dictionary(snapshot.reachable.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
        pairedDevices = snapshot.trustedIDs.union(snapshot.sendablePeerIDs).subtracting(revokedIDs).filter { $0 != snapshot.localID }.map { id in
            DeviceSummary(id: id, displayName: snapshot.names[id] ?? reachable[id]?.displayName ?? "",
                availability: snapshot.sendablePeerIDs.contains(id) ? reachable[id]?.availability ?? .offline : .offline)
        }.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
        if case let .paired(peer) = pairing?.phase,
           !snapshot.trustedIDs.subtracting(revokedIDs).contains(peer.id) {
            pairing = nil
        }
    }
    func presentation(for device: DeviceSummary) -> PeerConnectionPresentation {
        .resolve(authenticated: desiredForeground == true && serviceState == .online,
                 sync: trustSyncState, availability: device.availability)
    }
    func currentDevice(_ previous: DeviceSummary) -> DeviceSummary {
        pairedDevices.first(where: { $0.id == previous.id }) ??
            DeviceSummary(id: previous.id, displayName: previous.displayName, availability: .offline)
    }
    func isEligible(_ id: DeviceID) -> Bool {
        desiredForeground == true && serviceState == .online &&
            pairedDevices.contains { $0.id == id && $0.availability != .offline }
    }
    func retryConnection() {
        guard desiredForeground == true, let session else { return }
        let id = UUID()
        retryRecoveryRequest = id
        retryCommandReturned = false
        lifecycleTasks[id] = Task { [weak self] in
            await session.retryConnection()
            if self?.retryRecoveryRequest == id, self?.desiredForeground == true,
               self?.closed == false {
                self?.retryCommandReturned = true
            }
            do { try await session.refreshTrust(); self?.explicitFailure = nil }
            catch { self?.explicitFailure = .network }
            await self?.refreshDevices()
            self?.lifecycleTasks[id] = nil
        }
    }
    func retryTrustSave() {
        guard let session else { return }
        let id = UUID()
        lifecycleTasks[id] = Task { [weak self] in
            do { try await session.refreshTrust(); self?.explicitFailure = nil }
            catch { self?.explicitFailure = .trustPersistence }
            await self?.refreshDevices()
            self?.lifecycleTasks[id] = nil
        }
    }
    func removeDevice(_ id: DeviceID) {
        guard removalTask == nil, removalState != .saveFailed,
              manualPeerIDs.contains(id), pairedDevices.contains(where: { $0.id == id }), let session else { return }
        removalState = .removing
        revokedIDs.insert(id)
        if case let .paired(peer) = pairing?.phase, peer.id == id { pairing = nil }
        send?.revokeLocally(id)
        pairedDevices.removeAll { $0.id == id }
        removalTask = Task { [self] in
            do { try await session.revoke(id) }
            catch {
                revokedIDs.remove(id)
                removalState = .failed
                await refreshDevices()
                removalTask = nil
                return
            }
            await saveRemoval(using: session)
            removalTask = nil
        }
    }
    func retryRemovalSave() {
        guard removalTask == nil, removalState == .saveFailed, let session else { return }
        removalState = .removing
        removalTask = Task { [self] in
            await saveRemoval(using: session)
            removalTask = nil
        }
    }
    private func saveRemoval(using session: any MobileAppSession) async {
        async let refresh: Void = refreshAfterRemoval(session)
        do { try await session.persistTrust(); removalState = .saved }
        catch { removalState = .saveFailed }
        await refresh
        await refreshDevices()
        if removalState == .saved {
            revokedIDs.removeAll()
            await refreshDevices()
        }
    }
    private func refreshAfterRemoval(_ session: any MobileAppSession) async {
        do { try await session.refreshTrust(); explicitFailure = nil }
        catch { explicitFailure = .network }
    }
    func waitForRemoval() async { await removalTask?.value }
    func renameDevice(_ id: DeviceID, name: String) async -> Bool {
        guard renamingDeviceID == nil, pairedDevices.contains(where: { $0.id == id }), let session else { return false }
        renamingDeviceID = id
        renameFailureKey = nil
        do {
            try await session.renamePeer(id: id, name: name)
            await refreshDevices()
            renamingDeviceID = nil
            return true
        } catch {
            renameFailureKey = "devices.rename.failed"
            renamingDeviceID = nil
            return false
        }
    }
    func close() async {
        closed = true
        desiredForeground = false
        send?.setForeground(false)
        history?.close()
        retryRecoveryRequest = nil
        retryCommandReturned = false
        observationTask?.cancel()
        async let stop: Void = session?.stopForeground() ?? ()
        async let pair: Void = pairing?.handleBackground() ?? ()
        async let importing: Void = send?.cancelAndWait() ?? ()
        await bootstrapTask?.value
        await waitForLifecycle()
        await removalTask?.value
        await observationTask?.value
        await refreshTask?.value
        _ = await (stop, pair, importing)
        observationTask = nil
    }
}
