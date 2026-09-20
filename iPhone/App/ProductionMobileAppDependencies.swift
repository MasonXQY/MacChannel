import DropMeshMobileRuntime
import Foundation
import MacChannelCore
import UIKit

/// Concrete production assembly is excluded from the inert test application.
actor ProductionMobileAppDependencies: MobileAppSession {
    private let context: MobileIdentityContext<KeychainStore>
    private let runtime: MobileForegroundRuntime
    private var names: MobilePeerNames
    private let durableTrust: MobileDurableTrust
    private let discoveryPreference: MobileDiscoveryPreference
    private var discoveryEnabled: Bool
    private var cachedAccountController: AccountSessionController?
    private var cachedAccountLifecycle: AccountForegroundLifecycle?
    private var accountForegroundRequested = false

    static func load() async throws -> ProductionMobileAppDependencies {
        let manager = FileManager.default
        guard let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let documents = manager.urls(for: .documentDirectory, in: .userDomainMask).first
        else { throw CocoaError(.fileNoSuchFile) }
        // Actor-independent async assembly keeps synchronous filesystem setup off MainActor.
        let context = try await MobileIdentityContext.load(
            layout: MobileStorageLayout(applicationSupport: support, documents: documents),
            secrets: KeychainStore(policy: MobileIdentityPolicy.policy))
        try await MobileImportStager(directory: context.layout.stagingDirectory).recoverAbandonedImports()
        let dependencies = try ProductionMobileAppDependencies(context: context)
        await dependencies.applyInitialDiscoveryPreference()
        return dependencies
    }
    private init(context: MobileIdentityContext<KeychainStore>) throws {
        self.context = context
        durableTrust = MobileDurableTrust(repository: context.repository,
            persistedState: { await context.persistedTrustState() })
        runtime = try MobileForegroundRuntime(context: context)
        discoveryPreference = MobileDiscoveryPreference(
            url: context.layout.stateDirectory.appendingPathComponent("local-discovery.json"))
        discoveryEnabled = try discoveryPreference.load()
        names = MobilePeerNames(url: context.layout.stateDirectory.appendingPathComponent("peer-display-names.json"))
    }
    func snapshot() async -> MobileAppSnapshot {
        let current = await runtime.currentSnapshot()
        let trustedIDs = await durableTrust.trustedIDs()
        return MobileAppSnapshot(state: current.state, trustSyncState: current.trustSyncState, localID: context.identity.id,
            trustedIDs: trustedIDs, reachable: current.devices,
            names: names.values, failure: current.failure, transfers: current.transfers,
            receivedCompletionIDs: current.received.map(\.transferID),
            localNetworkAvailable: current.localNetworkAvailable, localDiscoveryEnabled: discoveryEnabled,
            historyAvailabilityFailure: current.historyAvailabilityFailure)
    }
    func observe(_ changed: @escaping @Sendable () async -> Void) async {
        let runtime = runtime
        let repository = context.repository
        let context = context
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in await runtime.snapshots() {
                    guard !Task.isCancelled else { break }
                    await changed()
                }
            }
            group.addTask {
                for await _ in await repository.updates() {
                    guard !Task.isCancelled else { break }
                    await changed()
                }
            }
            group.addTask {
                for await _ in await context.persistedTrustUpdates() {
                    guard !Task.isCancelled else { break }
                    await changed()
                }
            }
            await group.waitForAll()
        }
    }
    func startForeground() async throws {
        accountForegroundRequested = true
        try await runtime.startForeground()
        guard accountForegroundRequested else { return }
        // Account configuration failure must not disable the manual plane.
        if let lifecycle = try? await accountLifecycle(), accountForegroundRequested {
            await lifecycle.start()
        }
    }
    func stopForeground() async {
        accountForegroundRequested = false
        await cachedAccountLifecycle?.stop()
        await runtime.stopForeground()
    }
    func refreshTrust() async throws { try await runtime.refreshTrust() }
    func retryConnection() async { await runtime.retryConnection() }
    func send(items: [URL], to device: DeviceID) async throws -> TransferID {
        try await runtime.send(items: items, to: device)
    }
    func pause(_ id: TransferID) async throws { try await runtime.pause(id) }
    func resume(_ id: TransferID) async throws { try await runtime.resume(id) }
    func cancel(_ id: TransferID) async -> TransferCancellationResult { await runtime.cancel(id) }
    private func applyInitialDiscoveryPreference() async {
        await runtime.setLocalDiscoveryEnabled(discoveryEnabled)
    }
    func history(limit: Int) async throws -> [MobileHistoryEntry] {
        try await runtime.history(limit: limit).map(MobileHistoryEntry.init)
    }
    func availableReceivedURL(for id: TransferID) async -> URL? {
        await runtime.availableReceivedURL(for: id)
    }
    func setLocalDiscoveryEnabled(_ enabled: Bool) async throws {
        try discoveryPreference.save(enabled)
        discoveryEnabled = enabled
        await runtime.setLocalDiscoveryEnabled(enabled)
    }
    func accountController() async throws -> AccountSessionController? {
        if let cachedAccountController { return cachedAccountController }
        guard let configuration = try MobileAccountConfiguration.load() else { return nil }
        let service = try AccountServiceClient(identity: context.identity, origin: configuration.origin,
                                               audience: configuration.audience)
        let binding = try AccountSessionBinding(deviceID: context.identity.id.rawValue,
            audience: configuration.audience, origin: configuration.origin)
        if configuration.groupsEnabled {
            let controller = try AccountSessionController(service: service,
                storage: KeychainAccountSessionStorage(), binding: binding,
                groupVerifier: AccountGroupHistoryVerifier(storage: KeychainAccountGroupCheckpointStorage()),
                peerAuthorization: AccountPeerAuthorization(owner: context.authorizationOwner,
                    identity: context.identity, binding: binding, freshness: 300),
                firstDeviceEnrollment: AccountFirstDeviceEnrollment(identity: context.identity),
                deviceApproval: AccountDeviceApproval(identity: context.identity))
            // Both objects are cached before this actor reaches any suspension.
            cachedAccountController = controller
            cachedAccountLifecycle = AccountForegroundLifecycle(controller: controller)
            return controller
        }
        let controller = AccountSessionController(service: service,
            storage: KeychainAccountSessionStorage(), binding: binding,
            groupVerifier: configuration.groupsEnabled
                ? AccountGroupHistoryVerifier(storage: KeychainAccountGroupCheckpointStorage()) : nil,
            firstDeviceEnrollment: configuration.groupsEnabled
                ? AccountFirstDeviceEnrollment(identity: context.identity) : nil)
        cachedAccountController = controller
        return controller
    }
    func accountLifecycle() async throws -> AccountForegroundLifecycle? {
        _ = try await accountController()
        return cachedAccountLifecycle
    }
    func revoke(_ id: DeviceID) async throws { try await context.repository.revoke(id) }
    func persistTrust() async throws { try await context.persistTrust() }
    func rememberConfirmedPeer(_ peer: DeviceSummary) async {
        let trusted = await context.repository.currentTrustStore().trustedDeviceIDs
        names.remember(peer, trustedIDs: trusted)
    }
    func makePairingAttempt() async throws -> any PairingAttempt {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        let transport = try RendezvousPairingTransport(identity: context.identity,
            origin: URL(string: "https://channel.zensys-tech.com")!, session: URLSession(configuration: configuration))
        let name = await MainActor.run { UIDevice.current.name }
        do {
            let session = try context.makePairingSession(displayName: name, transport: transport)
            return ProductionPairingAttempt(session: session, transport: transport)
        } catch {
            await transport.stop()
            throw error
        }
    }
}

private actor ProductionPairingAttempt: PairingAttempt {
    private let session: MobilePairingSession
    private let transport: RendezvousPairingTransport
    init(session: MobilePairingSession, transport: RendezvousPairingTransport) {
        self.session = session; self.transport = transport
    }
    func join(code: String) async throws -> PairingJoinResult { try await session.join(code: code) }
    func awaitApproval() async throws -> DeviceSummary { try await session.awaitApproval() }
    func currentState() async -> MobilePairingState { await session.currentState() }
    func retrySaving() async throws -> DeviceSummary { try await session.retrySaving() }
    func cancel() async throws { try await session.cancel() }
    func stop() async { await transport.stop() }
}
