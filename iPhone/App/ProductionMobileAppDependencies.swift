import DropMeshMobileRuntime
import Foundation
import MacChannelCore
import UIKit

/// Concrete production assembly is excluded from the inert test application.
actor ProductionMobileAppDependencies: MobileAppSession {
    private let context: MobileIdentityContext<KeychainStore>
    private let runtime: MobileForegroundRuntime
    private var names: MobilePeerNames

    static func load() async throws -> ProductionMobileAppDependencies {
        let manager = FileManager.default
        guard let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let documents = manager.urls(for: .documentDirectory, in: .userDomainMask).first
        else { throw CocoaError(.fileNoSuchFile) }
        // Actor-independent async assembly keeps synchronous filesystem setup off MainActor.
        let context = try await MobileIdentityContext.load(
            layout: MobileStorageLayout(applicationSupport: support, documents: documents),
            secrets: KeychainStore(policy: MobileIdentityPolicy.policy))
        return try ProductionMobileAppDependencies(context: context)
    }
    private init(context: MobileIdentityContext<KeychainStore>) throws {
        self.context = context
        runtime = try MobileForegroundRuntime(context: context)
        names = MobilePeerNames(url: context.layout.stateDirectory.appendingPathComponent("peer-display-names.json"))
    }
    func snapshot() async -> MobileAppSnapshot {
        let current = await runtime.currentSnapshot()
        let trust = await context.repository.currentTrustStore()
        return MobileAppSnapshot(state: current.state, localID: context.identity.id,
            trustedIDs: trust.trustedDeviceIDs, reachable: current.devices,
            names: names.values, failure: current.failure)
    }
    func observe(_ changed: @escaping @Sendable () async -> Void) async {
        let runtime = runtime
        let repository = context.repository
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
            await group.waitForAll()
        }
    }
    func startForeground() async throws { try await runtime.startForeground() }
    func stopForeground() async { await runtime.stopForeground() }
    func refreshTrust() async throws { try await runtime.refreshTrust() }
    func retryConnection() async { await runtime.retryConnection() }
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
