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
    private(set) var pairedDevices: [DeviceSummary] = []
    private(set) var serviceState: MobileRuntimeState = .inactive
    var serviceFailure: MobileRuntimeFailure? { explicitFailure ?? runtimeFailure }
    private var explicitFailure: MobileRuntimeFailure?
    private var runtimeFailure: MobileRuntimeFailure?
    private(set) var removalState: MobileRemovalState = .idle
    var pairing: PairingModel?
    private let loadSession: @Sendable () async throws -> any MobileAppSession
    private var session: (any MobileAppSession)?
    private var desiredForeground: Bool?
    private var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var observationTask: Task<Void, Never>?
    private var lifecycleTasks: [UUID: Task<Void, Never>] = [:]
    private var removalTask: Task<Void, Never>?
    private var revokedIDs: Set<DeviceID> = []
    private var refreshTask: Task<Void, Never>?
    private var refreshPending = false
    private var closed = false

    init(loadSession: @escaping @Sendable () async throws -> any MobileAppSession) {
        self.loadSession = loadSession
    }
    deinit { observationTask?.cancel() }

    func bootstrap(initialPhase: ScenePhase = .inactive) async {
        if desiredForeground == nil { desiredForeground = initialPhase == .active }
        if let bootstrapTask { await bootstrapTask.value; return }
        guard !closed, bootstrapState == .idle || bootstrapState == .failed else { return }
        bootstrapState = .loading
        bootstrapError = nil
        let loader = loadSession
        let task = Task { [weak self] in
            do {
                let session = try await loader()
                guard let self else { return }
                self.session = session
                guard !self.closed else { await session.stopForeground(); return }
                self.observationTask = Task { [weak self] in
                    await session.observe { [weak self] in await self?.refreshDevices() }
                }
                await self.refreshDevices()
                self.bootstrapState = .ready
                self.reconcileScene()
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

    /// Record the event directly, before any task or bootstrap suspension.
    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active: desiredForeground = true
        case .background: desiredForeground = false
        case .inactive: return
        @unknown default: return
        }
        reconcileScene()
    }
    private func reconcileScene() {
        guard !closed, let session, let foreground = desiredForeground else { return }
        let id = UUID()
        let pairing = pairing
        lifecycleTasks[id] = Task { [weak self] in
            if foreground {
                guard self?.desiredForeground == true else {
                    self?.lifecycleTasks[id] = nil
                    return
                }
                do { try await session.startForeground() }
                catch { self?.explicitFailure = .network }
            } else {
                async let network: Void = session.stopForeground()
                async let pair: Void = pairing?.handleBackground() ?? ()
                _ = await (network, pair)
            }
            await self?.refreshDevices()
            self?.lifecycleTasks[id] = nil
        }
    }
    func waitForLifecycle() async {
        while !lifecycleTasks.isEmpty {
            for task in Array(lifecycleTasks.values) { await task.value }
        }
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
                let snapshot = await session.snapshot()
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
        runtimeFailure = snapshot.failure
        let reachable = Dictionary(snapshot.reachable.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
        pairedDevices = snapshot.trustedIDs.subtracting(revokedIDs).filter { $0 != snapshot.localID }.map { id in
            DeviceSummary(id: id, displayName: snapshot.names[id] ?? "",
                availability: reachable[id]?.availability ?? .offline)
        }.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
    }
    func isEligible(_ id: DeviceID) -> Bool {
        desiredForeground == true && serviceState == .online &&
            pairedDevices.contains { $0.id == id && $0.availability != .offline }
    }
    func retryConnection() {
        guard desiredForeground == true, let session else { return }
        let id = UUID()
        lifecycleTasks[id] = Task { [weak self] in
            await session.retryConnection()
            do { try await session.refreshTrust(); self?.explicitFailure = nil }
            catch { self?.explicitFailure = .network }
            await self?.refreshDevices()
            self?.lifecycleTasks[id] = nil
        }
    }
    func removeDevice(_ id: DeviceID) {
        guard removalTask == nil, removalState != .saveFailed,
              pairedDevices.contains(where: { $0.id == id }), let session else { return }
        removalState = .removing
        revokedIDs.insert(id)
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
    func close() async {
        closed = true
        desiredForeground = false
        observationTask?.cancel()
        async let stop: Void = session?.stopForeground() ?? ()
        async let pair: Void = pairing?.handleBackground() ?? ()
        await bootstrapTask?.value
        await waitForLifecycle()
        await removalTask?.value
        await observationTask?.value
        await refreshTask?.value
        _ = await (stop, pair)
        observationTask = nil
    }
}
