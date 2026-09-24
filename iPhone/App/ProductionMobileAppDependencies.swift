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
    private let sentSources: MobileSentSourceStore
    private let photoHistory = MobilePhotoHistorySource()
    private var cachedAccountController: AccountSessionController?
    private var cachedAccountLifecycle: AccountForegroundLifecycle?
    private var cachedForegroundOwnership: MobileForegroundOwnership?
    private var accountConfigurationUnavailable = false

    static func load() async throws -> ProductionMobileAppDependencies {
        let (support, documents) = try storageRoots()
        // Actor-independent async assembly keeps synchronous filesystem setup off MainActor.
        let context = try await MobileIdentityContext.load(
            layout: MobileStorageLayout(applicationSupport: support, documents: documents),
            secrets: KeychainStore(policy: MobileIdentityPolicy.policy))
        try await MobileImportStager(directory: context.layout.stagingDirectory).recoverAbandonedImports()
        let dependencies = try ProductionMobileAppDependencies(context: context)
        await dependencies.recoverHistoryActions()
        await dependencies.applyInitialDiscoveryPreference()
        #if DEBUG
        print("DropMesh production bootstrap succeeded")
        #endif
        return dependencies
    }

    static func recoverOrphanedIdentity() throws {
        let (support, documents) = try storageRoots()
        let layout = MobileStorageLayout(applicationSupport: support, documents: documents)
        try layout.prepare()
        let keychain = KeychainStore(policy: MobileIdentityPolicy.policy)
        try MobileIdentityRecovery.recreateOrphanedIdentity(
            layout: layout, secrets: keychain, erase: { try keychain.removeAll() }
        )
    }

    private static func storageRoots() throws -> (URL, URL) {
        let manager = FileManager.default
        guard let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let documents = manager.urls(for: .documentDirectory, in: .userDomainMask).first
        else { throw CocoaError(.fileNoSuchFile) }
        return (support, documents)
    }
    private func recoverHistoryActions() async { await sentSources.recoverAbandonedActions() }
    private init(context: MobileIdentityContext<KeychainStore>) throws {
        self.context = context
        durableTrust = MobileDurableTrust(repository: context.repository,
            persistedState: { await context.persistedTrustState() })
        runtime = try MobileForegroundRuntime(context: context)
        discoveryPreference = MobileDiscoveryPreference(
            url: context.layout.stateDirectory.appendingPathComponent("local-discovery.json"))
        discoveryEnabled = try discoveryPreference.load()
        names = MobilePeerNames(url: context.layout.stateDirectory.appendingPathComponent("peer-display-names.json"))
        let photoSource = photoHistory
        sentSources = MobileSentSourceStore(
            url: context.layout.stateDirectory.appendingPathComponent("sent-source-references-v1.json"),
            actions: context.layout.stateDirectory.appendingPathComponent("history-actions", isDirectory: true),
            resolvePhoto: { try await photoSource.resolve(assetIdentifier: $0, destination: $1) })
    }
    func snapshot() async -> MobileAppSnapshot {
        let current = await runtime.currentSnapshot()
        let trustedIDs = await durableTrust.trustedIDs()
        return MobileAppSnapshot(state: current.state, trustSyncState: current.trustSyncState, localID: context.identity.id,
            trustedIDs: trustedIDs, effectivePeerIDs: Set(context.authorizationOwner.snapshot().peers.keys),
            accountConfigurationUnavailable: accountConfigurationUnavailable, reachable: current.devices,
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
                for await _ in context.authorizationOwner.updates() {
                    guard !Task.isCancelled else { break }
                    await changed()
                }
            }
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
    func startForeground() async throws { try await foregroundOwnership().start() }
    func stopForeground() async { await foregroundOwnership().stop() }

    private func foregroundOwnership() -> MobileForegroundOwnership {
        if let cachedForegroundOwnership { return cachedForegroundOwnership }
        let owner = MobileForegroundOwnership(
            startRuntime: { [weak self] in try await self?.prepareAndStartRuntime() },
            stopRuntime: { [runtime] in await runtime.stopForeground() },
            startAccount: { [weak self] in await self?.startAccountForeground() },
            stopAccount: { [weak self] in await self?.stopAccountForeground() })
        cachedForegroundOwnership = owner
        return owner
    }

    private func prepareAndStartRuntime() async throws {
        try Task.checkCancellation()
        if await runtime.currentSnapshot().foregroundRequested {
            try Task.checkCancellation()
            try await runtime.startForeground()
            return
        }
        var plane: MobileAccountPlaneConfiguration?
        accountConfigurationUnavailable = false
        do {
            if let configuration = try MobileAccountConfiguration.load(),
               let origin = configuration.transportOrigin,
               let controller = try await accountController() {
                var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
                components.scheme = "wss"; components.path = "/v1/ws"
                plane = try MobileAccountPlaneConfiguration(webSocketOrigin: components.url!, controller: controller,
                    turnFetcher: AccountTURNCredentialFetcher(controller: controller))
            }
        } catch { accountConfigurationUnavailable = true }
        try Task.checkCancellation()
        try await runtime.configureAccountPlane(plane)
        try Task.checkCancellation()
        try await runtime.startForeground()
    }

    private func startAccountForeground() async {
        // Account configuration failure must not disable the manual plane.
        if let lifecycle = try? await accountLifecycle() { await lifecycle.start() }
    }
    private func stopAccountForeground() async { await cachedAccountLifecycle?.stop() }
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
        var entries = try await runtime.history(limit: limit).map(MobileHistoryEntry.init)
        for index in entries.indices where entries[index].direction == .outbound {
            var files = entries[index].files
            for fileIndex in files.indices {
                guard await sentSources.contains(files[fileIndex].id) else { continue }
                let file = files[fileIndex]
                files[fileIndex] = MobileTransferHistoryFile(id: file.id, name: file.name, size: file.size,
                    isDirectory: file.isDirectory, isAvailable: true, availableURL: nil)
            }
            entries[index].files = files
        }
        return entries
    }
    func deleteHistory(ids: Set<TransferID>?) async throws {
        try await runtime.deleteHistory(ids: ids)
        let candidates: Set<TransferID>
        if let ids { candidates = ids }
        else { candidates = await sentSources.transferIDs() }
        var deleted: Set<TransferID> = []
        for id in candidates where await runtime.isHistoryDeleted(id) { deleted.insert(id) }
        try await sentSources.remove(transfers: deleted)
    }
    func availableReceivedURL(for id: TransferID) async -> URL? {
        await runtime.availableReceivedURL(for: id)
    }
    func receivedFolderURL() async -> URL? {
        let folder = context.layout.receiveDirectory
        guard let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else { return nil }
        return folder
    }
    func availableHistoryFileURL(for id: TransferID, itemID: MobileHistoryFileID) async -> URL? {
        guard !(await runtime.isHistoryDeleted(id)) else { return nil }
        if let sent = await sentSources.resolve(transfer: id, item: itemID) { return sent }
        return await runtime.availableReceivedURL(for: id, itemID: itemID)
    }
    func historyThumbnail(for id: TransferID, itemID: MobileHistoryFileID) async -> MobileHistoryThumbnail? {
        guard !(await runtime.isHistoryDeleted(id)) else { return nil }
        if let sent = await sentSources.thumbnail(transfer: id, item: itemID, photo: photoHistory) { return sent }
        guard let received = await runtime.availableReceivedURL(for: id, itemID: itemID) else { return nil }
        return await MobileHistoryThumbnailLoader.load(received)
    }
    func recordSentHistorySources(_ files: [MobileSentHistorySource], for id: TransferID) async {
        guard !(await runtime.isHistoryDeleted(id)) else { return }
        await sentSources.record(files, transfer: id)
    }
    func releaseHistoryActionURL(_ url: URL) async { await sentSources.release(url) }
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
        let checkpoints = KeychainAccountGroupCheckpointStorage()
        let bootstrapIntents = KeychainAccountGroupBootstrapIntentStorage()
        let approvalIntents = KeychainAccountGroupApprovalIntentStorage()
        let invitationLinks = KeychainAccountInvitationLinkStorage()
        let invitations = KeychainAccountInvitationStorage()
        let invitationConfiguration = AccountInvitationConfiguration(identity: context.identity,
            links: invitationLinks, invitations: invitations)
        let deletion: AccountDeletionConfiguration? = configuration.deletionEnabled
            ? AccountDeletionConfiguration(storage: KeychainAccountDeletionStorage(binding: binding),
                clearAccountCheckpoints: { binding, accountID in
                    let account = accountID.uuidString.lowercased()
                    try await checkpoints.removeForAccount(binding: binding, accountID: account)
                    try await bootstrapIntents.removeForAccount(binding: binding, accountID: account)
                    try await approvalIntents.removeForAccount(binding: binding, accountID: account)
                    try await invitationLinks.removeForAccount(binding: binding, accountID: account)
                    try await invitations.removeForAccount(binding: binding, accountID: account)
                }) : nil
        if let authorization = try configuration.makePeerAuthorization(owner: context.authorizationOwner, identity: context.identity) {
            let controller = try AccountSessionController(service: service,
                storage: KeychainAccountSessionStorage(binding: binding), binding: binding,
                groupVerifier: AccountGroupHistoryVerifier(storage: checkpoints),
                peerAuthorization: authorization,
                firstDeviceEnrollment: AccountFirstDeviceEnrollment(identity: context.identity, intentStorage: bootstrapIntents),
                deviceApproval: AccountDeviceApproval(identity: context.identity, intentStorage: approvalIntents),
                deletion: deletion, invitations: invitationConfiguration)
            // Both objects are cached before this actor reaches any suspension.
            cachedAccountController = controller
            cachedAccountLifecycle = AccountForegroundLifecycle(controller: controller,
                automaticEnrollment: AccountAutomaticEnrollment(controller: controller))
            return controller
        }
        let controller = AccountSessionController(service: service,
            storage: KeychainAccountSessionStorage(), binding: binding,
            groupVerifier: configuration.groupsEnabled
                ? AccountGroupHistoryVerifier(storage: checkpoints) : nil,
            firstDeviceEnrollment: configuration.groupsEnabled
                ? AccountFirstDeviceEnrollment(identity: context.identity, intentStorage: bootstrapIntents) : nil,
            deviceApproval: configuration.groupsEnabled
                ? AccountDeviceApproval(identity: context.identity, intentStorage: approvalIntents) : nil,
            deletion: deletion, invitations: invitationConfiguration)
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
    func renamePeer(id: DeviceID, name: String) async throws {
        let trusted = await context.repository.currentTrustStore().trustedDeviceIDs
        let eligible = trusted.union(context.authorizationOwner.snapshot().peers.keys)
        try names.rename(id, to: name, trustedIDs: eligible)
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
