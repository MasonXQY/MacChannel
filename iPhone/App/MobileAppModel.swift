import DropMeshMobileRuntime
import Foundation
import MacChannelCore
import Observation
import SwiftUI
import UIKit

enum MobileBootstrapState: Equatable {
    case idle
    case loading
    case ready
    case failed
}

@MainActor
@Observable
final class MobileAppModel {
    private(set) var bootstrapState: MobileBootstrapState = .idle
    private(set) var bootstrapError: String?
    private(set) var pairedDevices: [DeviceSummary] = []
    var pairing: PairingModel?

    private var context: MobileIdentityContext<KeychainStore>?
    private var directory: DeviceDirectory?
    private var trustObservationTask: Task<Void, Never>?

    func bootstrap() async {
        guard bootstrapState == .idle || bootstrapState == .failed else { return }
        bootstrapState = .loading
        bootstrapError = nil
        do {
            let fileManager = FileManager.default
            guard let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first,
            let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            else { throw BootstrapError.missingSandboxRoot }
            let layout = MobileStorageLayout(applicationSupport: applicationSupport, documents: documents)
            let loaded = try await MobileIdentityContext.load(
                layout: layout,
                secrets: KeychainStore(policy: MobileIdentityPolicy.policy)
            )
            context = loaded
            let deviceDirectory = DeviceDirectory(trust: await loaded.repository.currentTrustStore())
            await deviceDirectory.observeTrust(loaded.repository)
            directory = deviceDirectory
            await refreshDevices()
            observeTrust(repository: loaded.repository)
            bootstrapState = .ready
        } catch {
            context = nil
            directory = nil
            pairedDevices = []
            bootstrapState = .failed
            bootstrapError = String(localized: "bootstrap.error")
        }
    }

    func retryBootstrap() async {
        await bootstrap()
    }

    func presentPairing() {
        guard pairing == nil, let context else { return }
        pairing = PairingModel(
            makeAttempt: { @MainActor in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 15
                let urlSession = URLSession(configuration: configuration)
                let origin = URL(string: "https://channel.zensys-tech.com")!
                let transport = try RendezvousPairingTransport(
                    identity: context.identity,
                    origin: origin,
                    session: urlSession
                )
                let session = try context.makePairingSession(
                    displayName: UIDevice.current.name,
                    transport: transport
                )
                return ProductionPairingAttempt(session: session, transport: transport)
            },
            refreshDevices: { [weak self] in await self?.refreshDevices() }
        )
    }

    func dismissPairingIfAllowed() {
        guard pairing?.mayDismiss == true else { return }
        pairing = nil
    }

    func handleScenePhase(_ phase: ScenePhase) async {
        switch phase {
        case .background:
            await pairing?.handleBackground()
        case .active:
            await refreshDevices()
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    func refreshDevices() async {
        guard let context else { return }
        let store = await context.repository.currentTrustStore()
        let directorySnapshot = await directory?.snapshot() ?? []
        let observed = Dictionary(uniqueKeysWithValues: directorySnapshot.map { ($0.id, $0) })
        pairedDevices = store.trustedDeviceIDs
            .filter { $0 != context.identity.id }
            .map { id in
                observed[id] ?? DeviceSummary(id: id, displayName: "", availability: .offline)
            }
            .sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
    }

    private func observeTrust(repository: TrustRepository) {
        trustObservationTask?.cancel()
        trustObservationTask = Task { [weak self] in
            let updates = await repository.updates()
            for await _ in updates {
                guard !Task.isCancelled else { return }
                await self?.refreshDevices()
            }
        }
    }
}

private enum BootstrapError: Error {
    case missingSandboxRoot
}
