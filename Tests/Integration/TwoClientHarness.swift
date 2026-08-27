import CryptoKit
import Darwin
import Foundation
@testable import MacChannelCore

enum IntegrationRoutePolicy: Sendable {
    case lanOnly
    case internetDirect
    case relayOnly

    var route: ConnectionRoute {
        switch self {
        case .lanOnly: .lan
        case .internetDirect: .directInternet
        case .relayOnly: .relay
        }
    }
}

enum TwoClientHarnessError: Error, Equatable {
    case stackConfigurationRequired
    case transferFailed(TransferID)
    case timedOut(TransferID)
    case missingTransfer
    case fileGenerationFailed
    case interruptionDidNotOccur
    case restartUnsupported
}

struct RelayRouteEvidence: Equatable, Sendable {
    let expiresAt: Date
    let usedAuthenticatedCredentials: Bool
    let usernameIsOpaque: Bool
}

struct NetworkInterruptionEvidence: Equatable, Sendable {
    let transferID: TransferID
    let senderDurableOffset: Int64
    let receiverDurableOffset: Int64
    let closedChannelCount: Int
    let connectionCount: Int
    let connectionInstanceID: UUID
}

struct NetworkResumeEvidence: Equatable, Sendable {
    let connectionCount: Int
    let connectionInstanceID: UUID
    let resumeOffset: Int64
    let bytesSentOnNewConnection: Int64
}

struct RuntimeRestartEvidence: Equatable, Sendable {
    let transferID: TransferID
    let identityBefore: DeviceID
    let identityAfter: DeviceID
    let runtimeGenerationBefore: UUID
    let runtimeGenerationAfter: UUID
    let databaseWasClosedAndReopened: Bool
}

struct TransferFailureEvidence: Equatable, Sendable {
    let senderPhase: TransferPhase
    let receiveFailure: IncomingTransferFailure?
    let receiveError: ReceiveStoreError?
    let stagingEntries: [String]
}

final class TwoClientHarness: @unchecked Sendable {
    let sender: HarnessSender
    let receiverID: DeviceID
    let senderID: DeviceID
    let root: URL
    let receiverDatabase: TransferDatabase
    let senderDownloadRoot: URL
    let receiverDownloadRoot: URL
    let thirdDownloadRoot: URL?

    private var senderTrust: TrustRepository
    private let receiverTrust: TrustRepository
    private var senderDirectory: DeviceDirectory
    private let connectionControl: HarnessConnectionControl
    private let channelFaults: HarnessChannelFaults
    private let routePolicy: IntegrationRoutePolicy
    private let senderICEProvider: any ICEConfigurationProviding
    private var senderDatabase: TransferDatabase
    private var senderIdentity: DeviceIdentity
    private var senderRuntimeGeneration = UUID()
    private let results: HarnessReceiveResults
    private let incomingListener: IncomingTransferListener
    private let connectionListener: WebRTCConnectionListener
    private let signalHub: LocalRendezvousHub?
    private let stackPresence: StackPresenceLifecycle?
    private let relayCredentialRecorder: RecordingTURNCredentialFetcher?
    private let senderOutgoing: URL
    private let thirdIncomingListener: IncomingTransferListener?
    private let thirdConnectionListener: WebRTCConnectionListener?
    private let thirdDatabase: TransferDatabase?
    private let cleanupState = HarnessCleanupState()

    init(
        routePolicy: IntegrationRoutePolicy,
        root: URL? = nil,
        capacity: any ReceiveCapacityProviding = VolumeReceiveCapacityProvider(),
        additionalOnlineClient: Bool = false,
        maximumConnectionAttempts: Int = 8,
        constructionCleanup: HarnessConstructionCleanup? = nil,
        failAfterStartingResourcesForTesting: Bool = false
    ) async throws {
        guard routePolicy == .lanOnly || !additionalOnlineClient else {
            throw TwoClientHarnessError.stackConfigurationRequired
        }

        let root = try root ?? FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: FileManager.default.temporaryDirectory,
            create: true
        )
        self.root = root.standardizedFileURL
        let senderRoot = self.root.appendingPathComponent("sender", isDirectory: true)
        let receiverRoot = self.root.appendingPathComponent("receiver", isDirectory: true)
        senderDownloadRoot = senderRoot.appendingPathComponent("downloads", isDirectory: true)
        receiverDownloadRoot = receiverRoot.appendingPathComponent("downloads", isDirectory: true)
        senderOutgoing = senderRoot.appendingPathComponent("outgoing", isDirectory: true)
        let receiverIncoming = receiverRoot.appendingPathComponent("incoming", isDirectory: true)
        // Production storage creates its private staging roots with mode 0700;
        // pre-creating them through FileManager would violate that contract.
        for directory in [senderDownloadRoot, receiverDownloadRoot] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let senderIdentity = try DeviceIdentity.loadOrCreate(
            keychain: try FileSecretStore(root: senderRoot.appendingPathComponent("secrets"))
        )
        let receiverIdentity = try DeviceIdentity.loadOrCreate(
            keychain: try FileSecretStore(root: receiverRoot.appendingPathComponent("secrets"))
        )
        self.senderIdentity = senderIdentity
        senderID = senderIdentity.id
        receiverID = receiverIdentity.id

        senderTrust = try TrustRepository(
            ownerIdentity: senderIdentity,
            trustStore: TrustStore(owner: senderIdentity.id),
            persistedGeneration: 0
        )
        receiverTrust = try TrustRepository(
            ownerIdentity: receiverIdentity,
            trustStore: TrustStore(owner: receiverIdentity.id),
            persistedGeneration: 0
        )
        let stackOrigin: URL?
        if routePolicy == .lanOnly {
            stackOrigin = nil
            _ = try await senderTrust.issueAuthorization(
                subject: receiverIdentity.id,
                subjectPublicKey: receiverIdentity.publicKey.rawRepresentation,
                timestamp: Date()
            )
            _ = try await receiverTrust.issueAuthorization(
                subject: senderIdentity.id,
                subjectPublicKey: senderIdentity.publicKey.rawRepresentation,
                timestamp: Date()
            )
        } else {
            guard ProcessInfo.processInfo.environment["MACCHANNEL_E2E_STACK"] == "1",
                  let origin = URL(
                    string: ProcessInfo.processInfo.environment["MACCHANNEL_E2E_STACK_ORIGIN"]
                        ?? "https://localhost:8443"
                  )
            else { throw TwoClientHarnessError.stackConfigurationRequired }
            try await Self.pairThroughStack(
                senderIdentity: senderIdentity,
                senderTrust: senderTrust,
                receiverIdentity: receiverIdentity,
                receiverTrust: receiverTrust,
                origin: origin
            )
            stackOrigin = origin
        }

        senderDirectory = DeviceDirectory(trust: await senderTrust.currentTrustStore())
        let receiverDirectory = DeviceDirectory(trust: await receiverTrust.currentTrustStore())
        await senderDirectory.observeTrust(senderTrust)
        await receiverDirectory.observeTrust(receiverTrust)
        if routePolicy == .lanOnly {
            await senderDirectory.apply(
                .lan(receiverIdentity.id, host: "127.0.0.1", port: 9_001)
            )
            await receiverDirectory.apply(
                .lan(senderIdentity.id, host: "127.0.0.1", port: 9_002)
            )
        } else {
            await senderDirectory.apply(.internet(receiverIdentity.id, online: true))
            await receiverDirectory.apply(.internet(senderIdentity.id, online: true))
        }

        let senderSignalSession: any RendezvousSignalSession
        let receiverSignalSession: any RendezvousSignalSession
        let senderProvider: any ICEConfigurationProviding
        let receiverProvider: any ICEConfigurationProviding
        if let stackOrigin {
            let senderFetcher = RecordingTURNCredentialFetcher(base: try RendezvousTURNCredentialClient(
                identity: senderIdentity,
                origin: stackOrigin,
                session: URLSession(configuration: .ephemeral)
            ))
            let receiverFetcher = RecordingTURNCredentialFetcher(base: try RendezvousTURNCredentialClient(
                identity: receiverIdentity,
                origin: stackOrigin,
                session: URLSession(configuration: .ephemeral)
            ))
            guard let webSocketURL = Self.webSocketURL(from: stackOrigin) else {
                throw TwoClientHarnessError.stackConfigurationRequired
            }
            let senderPresence = try AuthenticatedPresenceSession(
                identity: senderIdentity,
                origin: webSocketURL,
                socket: try URLSessionPresenceWebSocket(origin: webSocketURL),
                client: PresenceClient(directory: senderDirectory),
                trustRepository: senderTrust
            )
            let receiverPresence = try AuthenticatedPresenceSession(
                identity: receiverIdentity,
                origin: webSocketURL,
                socket: try URLSessionPresenceWebSocket(origin: webSocketURL),
                client: PresenceClient(directory: receiverDirectory),
                trustRepository: receiverTrust
            )
            try await senderPresence.connect()
            let senderPresenceTask = Task<Void, Never> {
                do { try await senderPresence.run() } catch {}
            }
            do {
                try await receiverPresence.connect()
            } catch {
                await senderPresence.stop()
                senderPresenceTask.cancel()
                await senderPresenceTask.value
                throw error
            }
            let receiverPresenceTask = Task<Void, Never> {
                do { try await receiverPresence.run() } catch {}
            }
            signalHub = nil
            let lifecycle = StackPresenceLifecycle(
                sender: senderPresence,
                receiver: receiverPresence,
                senderTask: senderPresenceTask,
                receiverTask: receiverPresenceTask
            )
            stackPresence = lifecycle
            constructionCleanup?.push { await lifecycle.shutdown() }
            relayCredentialRecorder = routePolicy == .relayOnly ? senderFetcher : nil
            senderSignalSession = senderPresence
            receiverSignalSession = receiverPresence
            senderProvider = RefreshingICEConfigurationProvider(
                base: ICEConfiguration(stunURLs: [], turnServers: []),
                fetcher: senderFetcher
            )
            receiverProvider = RefreshingICEConfigurationProvider(
                base: ICEConfiguration(stunURLs: [], turnServers: []),
                fetcher: receiverFetcher
            )
        } else {
            let hub = LocalRendezvousHub()
            signalHub = hub
            constructionCleanup?.push { await hub.finish() }
            stackPresence = nil
            relayCredentialRecorder = nil
            senderSignalSession = LocalRendezvousSignalSession(
                localDevice: senderIdentity.id,
                hub: hub
            )
            receiverSignalSession = LocalRendezvousSignalSession(
                localDevice: receiverIdentity.id,
                hub: hub
            )
            let localProvider = StaticICEConfigurationProvider(
                ICEConfiguration(stunURLs: [], turnServers: [])
            )
            senderProvider = localProvider
            receiverProvider = localProvider
        }
        let senderSignaling = RendezvousWebRTCSignaling(
            session: senderSignalSession
        )
        let receiverSignaling = RendezvousWebRTCSignaling(
            session: receiverSignalSession
        )
        senderICEProvider = senderProvider
        self.routePolicy = routePolicy
        let control = HarnessConnectionControl()
        connectionControl = control
        let faults = HarnessChannelFaults()
        channelFaults = faults
        let attempts = WebRTCConnectionAttempts(
            directory: senderDirectory,
            identity: senderIdentity,
            trustRepository: senderTrust,
            signaling: senderSignaling,
            iceProvider: senderProvider,
            factory: WebRTCFactory(connectionTimeout: .seconds(15))
        )
        let routeAttempts = HarnessRouteAttempts(
            attempts: attempts,
            policy: routePolicy,
            control: control,
            faults: faults
        )
        let connector = ConnectionCoordinator(attempts: routeAttempts)

        senderDatabase = try TransferDatabase(
            url: senderRoot.appendingPathComponent("history.sqlite")
        )
        constructionCleanup?.push { [senderDatabase] in try? await senderDatabase.close() }
        receiverDatabase = try TransferDatabase(
            url: receiverRoot.appendingPathComponent("history.sqlite")
        )
        constructionCleanup?.push { [receiverDatabase] in try? await receiverDatabase.close() }
        let coordinator = try await TransferCoordinator.restoring(
            connector: connector,
            database: senderDatabase,
            outgoingDirectory: senderOutgoing,
            maximumConnectionAttempts: maximumConnectionAttempts,
            persistenceRetryDelay: .milliseconds(20),
            cancellationWatchdogDelay: .seconds(1)
        )
        constructionCleanup?.push { await coordinator.shutdownForRestart() }
        sender = HarnessSender(coordinator: coordinator)

        connectionListener = WebRTCConnectionListener(
            directory: receiverDirectory,
            identity: receiverIdentity,
            trustRepository: receiverTrust,
            signaling: receiverSignaling,
            iceProvider: receiverProvider,
            factory: WebRTCFactory(connectionTimeout: .seconds(15))
        )
        results = HarnessReceiveResults()
        incomingListener = IncomingTransferListener(
            source: connectionListener,
            policy: ReceivePolicy(trustedSources: [senderIdentity.id]),
            directories: DownloadDirectory(globalDirectory: receiverDownloadRoot),
            database: receiverDatabase,
            incomingDirectory: receiverIncoming,
            capacity: capacity,
            inactivityTimeout: .seconds(15),
            onReceiveFinished: { [results] result in
                await results.record(result)
            },
            onReceiveFailed: { [results] transferID, failure in
                await results.recordFailure(failure, for: transferID)
            }
        )
        await incomingListener.start()
        constructionCleanup?.push { [incomingListener, connectionListener] in
            await incomingListener.stop()
            await connectionListener.stop()
        }

        if additionalOnlineClient {
            let thirdRoot = self.root.appendingPathComponent("third", isDirectory: true)
            let thirdDownloads = thirdRoot.appendingPathComponent("downloads", isDirectory: true)
            try FileManager.default.createDirectory(
                at: thirdDownloads,
                withIntermediateDirectories: true
            )
            let thirdIdentity = try DeviceIdentity.loadOrCreate(
                keychain: try FileSecretStore(root: thirdRoot.appendingPathComponent("secrets"))
            )
            let thirdTrust = try TrustRepository(
                ownerIdentity: thirdIdentity,
                trustStore: TrustStore(owner: thirdIdentity.id),
                persistedGeneration: 0
            )
            _ = try await senderTrust.issueAuthorization(
                subject: thirdIdentity.id,
                subjectPublicKey: thirdIdentity.publicKey.rawRepresentation,
                timestamp: Date()
            )
            _ = try await thirdTrust.issueAuthorization(
                subject: senderIdentity.id,
                subjectPublicKey: senderIdentity.publicKey.rawRepresentation,
                timestamp: Date()
            )
            await senderDirectory.waitForTrustUpdates()
            await senderDirectory.apply(
                .lan(thirdIdentity.id, host: "127.0.0.1", port: 9_003)
            )
            let thirdDirectory = DeviceDirectory(trust: await thirdTrust.currentTrustStore())
            await thirdDirectory.observeTrust(thirdTrust)
            await thirdDirectory.apply(
                .lan(senderIdentity.id, host: "127.0.0.1", port: 9_004)
            )
            let thirdSignaling = RendezvousWebRTCSignaling(
                session: LocalRendezvousSignalSession(
                    localDevice: thirdIdentity.id,
                    hub: try signalHub.unwrap()
                )
            )
            let thirdConnection = WebRTCConnectionListener(
                directory: thirdDirectory,
                identity: thirdIdentity,
                trustRepository: thirdTrust,
                signaling: thirdSignaling,
                iceProvider: senderProvider,
                factory: WebRTCFactory(connectionTimeout: .seconds(15))
            )
            let thirdDatabase = try TransferDatabase(
                url: thirdRoot.appendingPathComponent("history.sqlite")
            )
            let thirdIncoming = IncomingTransferListener(
                source: thirdConnection,
                policy: ReceivePolicy(trustedSources: [senderIdentity.id]),
                directories: DownloadDirectory(globalDirectory: thirdDownloads),
                database: thirdDatabase,
                incomingDirectory: thirdRoot.appendingPathComponent("incoming"),
                inactivityTimeout: .seconds(15)
            )
            thirdDownloadRoot = thirdDownloads
            thirdConnectionListener = thirdConnection
            thirdIncomingListener = thirdIncoming
            self.thirdDatabase = thirdDatabase
            await thirdIncoming.start()
            constructionCleanup?.push { [thirdIncoming, thirdConnection, thirdDatabase] in
                await thirdIncoming.stop()
                await thirdConnection.stop()
                try? await thirdDatabase.close()
            }
        } else {
            thirdDownloadRoot = nil
            thirdConnectionListener = nil
            thirdIncomingListener = nil
            thirdDatabase = nil
        }
        if failAfterStartingResourcesForTesting {
            throw TwoClientHarnessError.fileGenerationFailed
        }
        await Task.yield()
    }

    func makeDeterministicFile(
        size: Int,
        named name: String = "deterministic.bin"
    ) throws -> URL {
        guard size >= 0 else { throw TwoClientHarnessError.fileGenerationFailed }
        let sourceDirectory = senderDownloadRoot.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let url = sourceDirectory.appendingPathComponent(name)
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let blockSize = 1024 * 1024
        let block = Data((0..<blockSize).map { UInt8(($0 &* 31 &+ 17) % 251) })
        var remaining = size
        while remaining > 0 {
            let count = min(block.count, remaining)
            try handle.write(contentsOf: count == block.count ? block : block.prefix(count))
            remaining -= count
        }
        try handle.synchronize()
        return url
    }

    func receivedFile(named name: String) -> URL {
        receiverDownloadRoot.appendingPathComponent(name)
    }

    func makeDeterministicDirectory(named name: String = "folder") throws -> URL {
        let directory = senderDownloadRoot
            .appendingPathComponent("sources", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        let nested = directory.appendingPathComponent("nested", isDirectory: true)
        let empty = directory.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let payload = nested.appendingPathComponent("payload.bin")
        try writeDeterministicFile(at: payload, size: 1024 * 1024)
        try Data("说明".utf8).write(to: directory.appendingPathComponent("说明.txt"))
        return directory
    }

    func waitForCompletion(_ transfer: TransferID, timeout: Duration) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let snapshot = await sender.snapshot(for: transfer) {
                switch snapshot.phase {
                case .completed:
                    while ContinuousClock.now < deadline {
                        if await results.result(for: transfer) != nil { return }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                case .failed, .cancelled:
                    throw TwoClientHarnessError.transferFailed(transfer)
                default:
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TwoClientHarnessError.timedOut(transfer)
    }

    func waitForFailure(_ transfer: TransferID, timeout: Duration) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let snapshot = await sender.snapshot(for: transfer) {
                if snapshot.phase == .failed { return }
                if snapshot.phase == .completed || snapshot.phase == .cancelled {
                    throw TwoClientHarnessError.transferFailed(transfer)
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TwoClientHarnessError.timedOut(transfer)
    }

    func cutNetwork(afterBytes: Int64) async throws -> NetworkInterruptionEvidence {
        guard let transfer = await sender.latestTransferID else {
            throw TwoClientHarnessError.missingTransfer
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        var senderOffset: UInt64 = 0
        var receiverOffset: UInt64 = 0
        while ContinuousClock.now < deadline {
            let senderRecord = try await senderDatabase.history(limit: 200)
                .first(where: { $0.id == transfer })
            let receiverRecord = try await receiverDatabase.history(limit: 200)
                .first(where: { $0.id == transfer })
            senderOffset = senderRecord?.completedBytes ?? 0
            receiverOffset = receiverRecord?.completedBytes ?? 0
            if senderOffset >= UInt64(afterBytes), receiverOffset >= UInt64(afterBytes) { break }
            if let phase = senderRecord?.phase,
               phase == .failed || phase == .completed || phase == .cancelled
            {
                throw TwoClientHarnessError.interruptionDidNotOccur
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard senderOffset >= UInt64(afterBytes), receiverOffset >= UInt64(afterBytes) else {
            throw TwoClientHarnessError.interruptionDidNotOccur
        }
        let connectionCount = await connectionControl.connectionCount()
        guard let connectionInstanceID = await connectionControl.latestConnectionID() else {
            throw TwoClientHarnessError.interruptionDidNotOccur
        }
        let closed = await connectionControl.interruptNetwork()
        guard closed > 0 else { throw TwoClientHarnessError.interruptionDidNotOccur }
        return NetworkInterruptionEvidence(
            transferID: transfer,
            senderDurableOffset: Int64(senderOffset),
            receiverDurableOffset: Int64(receiverOffset),
            closedChannelCount: closed,
            connectionCount: connectionCount,
            connectionInstanceID: connectionInstanceID
        )
    }

    func restoreNetwork() async {
        await connectionControl.restoreNetwork()
    }

    func waitForResume(
        after interruption: NetworkInterruptionEvidence,
        timeout: Duration
    ) async throws -> NetworkResumeEvidence {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let count = await connectionControl.connectionCount()
            let connectionID = await connectionControl.latestConnectionID()
            let bytes = await connectionControl.latestConnectionBytes()
            let record = try await senderDatabase.history(limit: 200)
                .first(where: { $0.id == interruption.transferID })
            let offset = Int64(record?.completedBytes ?? 0)
            if count > interruption.connectionCount,
               let connectionID,
               connectionID != interruption.connectionInstanceID,
               offset >= interruption.receiverDurableOffset,
               bytes > 0
            {
                return NetworkResumeEvidence(
                    connectionCount: count,
                    connectionInstanceID: connectionID,
                    resumeOffset: offset,
                    bytesSentOnNewConnection: bytes
                )
            }
            if let phase = record?.phase, phase == .failed || phase == .cancelled {
                throw TwoClientHarnessError.transferFailed(interruption.transferID)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw TwoClientHarnessError.timedOut(interruption.transferID)
    }

    func actualRoutes() async -> [ConnectionRoute] {
        await connectionControl.actualRoutes
    }

    func attemptedRoutes() async -> [ConnectionRoute] {
        await connectionControl.attemptedRoutes
    }

    func makeReceiverDirectoryUnwritable() throws {
        guard chmod(receiverDownloadRoot.path, S_IRUSR | S_IXUSR) == 0 else {
            throw TwoClientHarnessError.fileGenerationFailed
        }
    }

    func restoreReceiverDirectoryPermissions() throws {
        guard chmod(receiverDownloadRoot.path, S_IRWXU) == 0 else {
            throw TwoClientHarnessError.fileGenerationFailed
        }
    }

    func tamperNextChunk() async {
        await channelFaults.tamperNextChunk()
    }

    func receiveFailureCount() async -> Int {
        await results.failures
    }

    func revokeReceiverFromSender() async throws {
        _ = try await senderTrust.revoke(receiverID)
        await senderDirectory.waitForTrustUpdates()
    }

    func restartSender(afterBytes: Int64) async throws -> RuntimeRestartEvidence {
        guard let transfer = await sender.latestTransferID else {
            throw TwoClientHarnessError.missingTransfer
        }
        guard let hub = signalHub, routePolicy == .lanOnly else {
            throw TwoClientHarnessError.restartUnsupported
        }
        while let record = try await senderDatabase.history(limit: 200)
            .first(where: { $0.id == transfer }),
            record.completedBytes < UInt64(afterBytes),
            record.phase != .failed,
            record.phase != .completed,
            record.phase != .cancelled
        {
            try await Task.sleep(for: .milliseconds(5))
        }
        let identityBefore = senderIdentity.id
        let generationBefore = senderRuntimeGeneration
        guard await connectionControl.interruptNetwork() > 0 else {
            throw TwoClientHarnessError.interruptionDidNotOccur
        }
        await sender.shutdownForRestart()
        try await senderDatabase.close()
        let receiveDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < receiveDeadline {
            if try await receiverDatabase.history(limit: 100)
                .first(where: { $0.id == transfer })?.phase == .failed
            {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let senderRoot = root.appendingPathComponent("sender", isDirectory: true)
        let reopenedIdentity = try DeviceIdentity.loadOrCreate(
            keychain: try FileSecretStore(root: senderRoot.appendingPathComponent("secrets"))
        )
        guard reopenedIdentity.id == identityBefore else {
            throw TwoClientHarnessError.restartUnsupported
        }
        let reopenedDatabase = try TransferDatabase(
            url: senderRoot.appendingPathComponent("history.sqlite")
        )
        let signaling = RendezvousWebRTCSignaling(
            session: LocalRendezvousSignalSession(localDevice: reopenedIdentity.id, hub: hub)
        )
        let attempts = WebRTCConnectionAttempts(
            directory: senderDirectory,
            identity: reopenedIdentity,
            trustRepository: senderTrust,
            signaling: signaling,
            iceProvider: senderICEProvider,
            factory: WebRTCFactory(connectionTimeout: .seconds(15))
        )
        let routeAttempts = HarnessRouteAttempts(
            attempts: attempts,
            policy: routePolicy,
            control: connectionControl,
            faults: channelFaults
        )
        let connector = ConnectionCoordinator(attempts: routeAttempts)
        await connectionControl.restoreNetwork()
        let restored = try await TransferCoordinator.restoring(
            connector: connector,
            database: reopenedDatabase,
            outgoingDirectory: senderOutgoing,
            maximumConnectionAttempts: 8,
            persistenceRetryDelay: .milliseconds(20),
            cancellationWatchdogDelay: .seconds(1)
        )
        senderIdentity = reopenedIdentity
        senderDatabase = reopenedDatabase
        senderRuntimeGeneration = UUID()
        await sender.install(restored)
        return RuntimeRestartEvidence(
            transferID: transfer,
            identityBefore: identityBefore,
            identityAfter: reopenedIdentity.id,
            runtimeGenerationBefore: generationBefore,
            runtimeGenerationAfter: senderRuntimeGeneration,
            databaseWasClosedAndReopened: true
        )
    }

    func onlinePeerCount() async -> Int {
        await senderDirectory.snapshot().count
    }

    func relayEvidence() async throws -> RelayRouteEvidence {
        guard let relayCredentials = await relayCredentialRecorder?.latest else {
            throw TwoClientHarnessError.stackConfigurationRequired
        }
        return RelayRouteEvidence(
            expiresAt: relayCredentials.expiresAt,
            usedAuthenticatedCredentials: !relayCredentials.username.isEmpty
                && !relayCredentials.credential.isEmpty,
            usernameIsOpaque: !relayCredentials.username.lowercased().contains(
                senderID.rawValue.uuidString.lowercased()
            )
        )
    }

    func failureEvidence(for transfer: TransferID) async throws -> TransferFailureEvidence {
        let senderPhase = try await senderDatabase.history(limit: 200)
            .first(where: { $0.id == transfer })?.phase
        guard let senderPhase else { throw TwoClientHarnessError.missingTransfer }
        let failure = await results.failure(for: transfer)
        let receiveError: ReceiveStoreError?
        if case let .receiveStore(error) = failure { receiveError = error } else { receiveError = nil }
        let incoming = root.appendingPathComponent("receiver/incoming", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: incoming.path)) ?? []
        return TransferFailureEvidence(
            senderPhase: senderPhase,
            receiveFailure: failure,
            receiveError: receiveError,
            stagingEntries: entries.sorted()
        )
    }

    func shutdown() async {
        guard await cleanupState.beginShutdown() else { return }
        await sender.shutdownForRestart()
        _ = await connectionControl.interruptNetwork()
        await incomingListener.stop()
        await connectionListener.stop()
        await thirdIncomingListener?.stop()
        await thirdConnectionListener?.stop()
        await signalHub?.finish()
        await stackPresence?.shutdown()
        try? await senderDatabase.close()
        try? await receiverDatabase.close()
        try? await thirdDatabase?.close()
    }

    func shutdownAndRemoveRoot() async {
        await shutdown()
        guard await cleanupState.beginRemoval() else { return }
        try? restoreReceiverDirectoryPermissions()
        try? FileManager.default.removeItem(at: root)
    }

    private func writeDeterministicFile(at url: URL, size: Int) throws {
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let blockSize = 1024 * 1024
        let block = Data((0..<blockSize).map { UInt8(($0 &* 31 &+ 17) % 251) })
        var remaining = size
        while remaining > 0 {
            let count = min(block.count, remaining)
            try handle.write(contentsOf: count == block.count ? block : block.prefix(count))
            remaining -= count
        }
        try handle.synchronize()
    }

    private static func pairThroughStack(
        senderIdentity: DeviceIdentity,
        senderTrust: TrustRepository,
        receiverIdentity: DeviceIdentity,
        receiverTrust: TrustRepository,
        origin: URL
    ) async throws {
        let senderTransport = try RendezvousPairingTransport(
            identity: senderIdentity,
            origin: origin,
            session: URLSession(configuration: .ephemeral)
        )
        let receiverTransport = try RendezvousPairingTransport(
            identity: receiverIdentity,
            origin: origin,
            session: URLSession(configuration: .ephemeral)
        )
        do {
            let host = try PairingCoordinator(
                identity: senderIdentity,
                displayName: "端到端发送端",
                trustRepository: senderTrust,
                transport: senderTransport
            )
            let joiner = try PairingCoordinator(
                identity: receiverIdentity,
                displayName: "端到端接收端",
                trustRepository: receiverTrust,
                transport: receiverTransport
            )
            let code = try await host.createCode()
            let result = try await joiner.join(code: code)
            _ = try await host.confirmFingerprint(result.fingerprint)
            _ = try await joiner.confirmFingerprint(result.fingerprint)
            await senderTransport.stop()
            await receiverTransport.stop()
        } catch {
            await senderTransport.stop()
            await receiverTransport.stop()
            throw error
        }
    }

    private static func webSocketURL(from origin: URL) -> URL? {
        guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)
        else { return nil }
        components.scheme = "wss"
        components.path = "/v1/ws"
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

actor HarnessSender {
    private var coordinator: TransferCoordinator
    private(set) var latestTransferID: TransferID?

    init(coordinator: TransferCoordinator) {
        self.coordinator = coordinator
    }

    func send(items: [URL], to device: DeviceID) async throws -> TransferID {
        let transfer = try await coordinator.send(items: items, to: device)
        latestTransferID = transfer
        return transfer
    }

    func snapshot(for transfer: TransferID) async -> TransferSnapshot? {
        var iterator = await coordinator.snapshots().makeAsyncIterator()
        return await iterator.next()?.first { $0.id == transfer }
    }

    func shutdownForRestart() async {
        await coordinator.shutdownForRestart()
    }

    func install(_ restored: TransferCoordinator) {
        coordinator = restored
    }
}

private actor HarnessReceiveResults {
    private var results: [TransferID: TransferReceiveResult] = [:]
    private var receiveFailures: [TransferID: IncomingTransferFailure] = [:]
    private(set) var failures = 0

    func record(_ result: TransferReceiveResult?) {
        guard let result else {
            failures += 1
            return
        }
        results[result.transferID] = result
    }

    func result(for transfer: TransferID) -> TransferReceiveResult? {
        results[transfer]
    }

    func recordFailure(_ failure: IncomingTransferFailure, for transfer: TransferID) {
        receiveFailures[transfer] = failure
    }

    func failure(for transfer: TransferID) -> IncomingTransferFailure? {
        receiveFailures[transfer]
    }
}

private actor HarnessRouteAttempts: TransferAwareConnectionAttempting {
    private let attempts: WebRTCConnectionAttempts
    private let policy: IntegrationRoutePolicy
    private let control: HarnessConnectionControl
    private let faults: HarnessChannelFaults

    init(
        attempts: WebRTCConnectionAttempts,
        policy: IntegrationRoutePolicy,
        control: HarnessConnectionControl,
        faults: HarnessChannelFaults
    ) {
        self.attempts = attempts
        self.policy = policy
        self.control = control
        self.faults = faults
    }

    func connect(to device: DeviceID, route: ConnectionRoute) async throws -> any SecureChannel {
        try await connect(
            to: device,
            route: route,
            transferID: TransferID(rawValue: UUID())
        )
    }

    func connect(
        to device: DeviceID,
        route: ConnectionRoute,
        transferID: TransferID
    ) async throws -> any SecureChannel {
        try await control.waitUntilOnline()
        await control.recordAttempt(route)
        guard route == policy.route else { throw ConnectionAttemptError.routeUnavailable }
        let channel = try await attempts.connect(
            to: device,
            route: route,
            transferID: transferID
        )
        let identifier = UUID()
        let wrapped = HarnessSecureChannel(
            identifier: identifier,
            base: channel,
            faults: faults,
            control: control
        )
        await control.register(identifier, channel: wrapped, route: channel.route)
        return wrapped
    }
}

private actor HarnessConnectionControl {
    private var online = true
    private var channels: [UUID: HarnessSecureChannel] = [:]
    private var connectionOrder: [UUID] = []
    private var bytesByConnection: [UUID: Int64] = [:]
    private(set) var attemptedRoutes: [ConnectionRoute] = []
    private(set) var actualRoutes: [ConnectionRoute] = []

    func waitUntilOnline() async throws {
        while !online {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func recordAttempt(_ route: ConnectionRoute) {
        attemptedRoutes.append(route)
    }

    func register(
        _ identifier: UUID,
        channel: HarnessSecureChannel,
        route: ConnectionRoute
    ) {
        channels[identifier] = channel
        connectionOrder.append(identifier)
        bytesByConnection[identifier] = 0
        actualRoutes.append(route)
    }

    func recordSentBytes(_ count: Int, on identifier: UUID) {
        bytesByConnection[identifier, default: 0] += Int64(count)
    }

    func channelClosed(_ identifier: UUID) {
        channels.removeValue(forKey: identifier)
    }

    func interruptNetwork() async -> Int {
        online = false
        let current = Array(channels.values)
        for channel in current { await channel.close() }
        return current.count
    }

    func restoreNetwork() {
        online = true
    }

    func connectionCount() -> Int { connectionOrder.count }

    func latestConnectionID() -> UUID? { connectionOrder.last }

    func latestConnectionBytes() -> Int64 {
        guard let identifier = connectionOrder.last else { return 0 }
        return bytesByConnection[identifier] ?? 0
    }
}

private final class HarnessSecureChannel: SecureChannel, @unchecked Sendable {
    let route: ConnectionRoute
    private let identifier: UUID
    private let base: any SecureChannel
    private let faults: HarnessChannelFaults
    private let control: HarnessConnectionControl
    private let lock = NSLock()
    private var didClose = false
    private var outboundOrdinal = 0

    init(
        identifier: UUID,
        base: any SecureChannel,
        faults: HarnessChannelFaults,
        control: HarnessConnectionControl
    ) {
        self.identifier = identifier
        self.base = base
        self.faults = faults
        self.control = control
        route = base.route
    }

    func send(_ frame: Data) async throws {
        outboundOrdinal += 1
        let transformed = await faults.transform(frame, ordinal: outboundOrdinal)
        try await base.send(transformed)
        await control.recordSentBytes(transformed.count, on: identifier)
    }

    func frames() -> AsyncThrowingStream<Data, Error> {
        base.frames()
    }

    func exportKey(label: String, context: Data, length: Int) async throws -> Data {
        try await base.exportKey(label: label, context: context, length: length)
    }

    func close() async {
        let shouldClose = lock.withLock {
            guard !didClose else { return false }
            didClose = true
            return true
        }
        guard shouldClose else { return }
        await base.close()
        await control.channelClosed(identifier)
    }
}

private actor HarnessChannelFaults {
    private var tamperArmed = false

    func tamperNextChunk() {
        tamperArmed = true
    }

    func transform(_ frame: Data, ordinal: Int) -> Data {
        guard tamperArmed, ordinal >= 2, !frame.isEmpty else { return frame }
        tamperArmed = false
        var mutated = frame
        mutated[mutated.index(before: mutated.endIndex)] ^= 0x01
        return mutated
    }
}

private actor LocalRendezvousHub {
    private var continuations: [DeviceID: AsyncStream<RendezvousSignalFrame>.Continuation] = [:]
    private var pending: [DeviceID: [RendezvousSignalFrame]] = [:]
    private var finished = false

    func stream(for device: DeviceID) -> AsyncStream<RendezvousSignalFrame> {
        AsyncStream(bufferingPolicy: .bufferingOldest(256)) { continuation in
            guard !finished else {
                continuation.finish()
                return
            }
            continuations.removeValue(forKey: device)?.finish()
            continuations[device] = continuation
            for frame in pending.removeValue(forKey: device) ?? [] {
                continuation.yield(frame)
            }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.remove(device, continuation: continuation) }
            }
        }
    }

    func send(_ payload: Data, from: DeviceID, to: DeviceID) throws {
        guard !finished else { throw WebRTCFactoryError.signalingEnded }
        let frame = RendezvousSignalFrame(from: from, payload: payload)
        if let continuation = continuations[to] {
            continuation.yield(frame)
        } else {
            pending[to, default: []].append(frame)
        }
    }

    func finish() {
        finished = true
        for continuation in continuations.values { continuation.finish() }
        continuations.removeAll()
        pending.removeAll()
    }

    private func remove(
        _ device: DeviceID,
        continuation: AsyncStream<RendezvousSignalFrame>.Continuation
    ) {
        _ = continuation
        continuations.removeValue(forKey: device)
    }
}

private struct LocalRendezvousSignalSession: RendezvousSignalSession {
    let localDevice: DeviceID
    let hub: LocalRendezvousHub

    func signalFrames() async -> AsyncStream<RendezvousSignalFrame> {
        await hub.stream(for: localDevice)
    }

    func sendSignal(_ payload: Data, to device: DeviceID) async throws {
        try await hub.send(payload, from: localDevice, to: device)
    }
}

private final class StackPresenceLifecycle: @unchecked Sendable {
    private let sender: AuthenticatedPresenceSession
    private let receiver: AuthenticatedPresenceSession
    private let senderTask: Task<Void, Never>
    private let receiverTask: Task<Void, Never>

    init(
        sender: AuthenticatedPresenceSession,
        receiver: AuthenticatedPresenceSession,
        senderTask: Task<Void, Never>,
        receiverTask: Task<Void, Never>
    ) {
        self.sender = sender
        self.receiver = receiver
        self.senderTask = senderTask
        self.receiverTask = receiverTask
    }

    func shutdown() async {
        await sender.stop()
        await receiver.stop()
        senderTask.cancel()
        receiverTask.cancel()
        await senderTask.value
        await receiverTask.value
    }
}

private extension Optional {
    func unwrap() throws -> Wrapped {
        guard let value = self else {
            throw TwoClientHarnessError.stackConfigurationRequired
        }
        return value
    }
}

private actor HarnessCleanupState {
    private var didShutdown = false
    private var didRemove = false

    func beginShutdown() -> Bool {
        guard !didShutdown else { return false }
        didShutdown = true
        return true
    }

    func beginRemoval() -> Bool {
        guard !didRemove else { return false }
        didRemove = true
        return true
    }
}

final class HarnessConstructionCleanup: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [@Sendable () async -> Void] = []
    private var active = true

    func push(_ action: @escaping @Sendable () async -> Void) {
        lock.withLock {
            guard active else { return }
            actions.append(action)
        }
    }

    func disarm() {
        lock.withLock {
            active = false
            actions.removeAll()
        }
    }

    func run() async {
        let pending: [@Sendable () async -> Void] = lock.withLock {
            guard active else { return [] }
            active = false
            defer { actions.removeAll() }
            return Array(actions.reversed())
        }
        for action in pending { await action() }
    }
}

private actor RecordingTURNCredentialFetcher: RendezvousTURNCredentialFetching {
    private let base: any RendezvousTURNCredentialFetching
    private(set) var latest: RendezvousTURNCredentials?

    init(base: any RendezvousTURNCredentialFetching) {
        self.base = base
    }

    func fetch() async throws -> RendezvousTURNCredentials {
        let credentials = try await base.fetch()
        latest = credentials
        return credentials
    }
}

private final class FileSecretStore: SecretStore, @unchecked Sendable {
    private let root: URL
    private let lock = NSLock()

    init(root: URL) throws {
        self.root = root.standardizedFileURL
        try FileManager.default.createDirectory(
            at: self.root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(self.root.path, S_IRWXU) == 0 else {
            throw TwoClientHarnessError.fileGenerationFailed
        }
    }

    func data(for account: String, policy: KeychainPolicy) throws -> Data? {
        try lock.withLock {
            let url = fileURL(account: account, policy: policy)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        }
    }

    func store(_ data: Data, for account: String, policy: KeychainPolicy) throws {
        try lock.withLock {
            let url = fileURL(account: account, policy: policy)
            try data.write(to: url, options: [.atomic])
            guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else {
                throw TwoClientHarnessError.fileGenerationFailed
            }
        }
    }

    private func fileURL(account: String, policy: KeychainPolicy) -> URL {
        let digest = SHA256.hash(data: Data("\(policy.service)\u{0}\(account)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return root.appendingPathComponent(digest)
    }
}

extension SHA256 {
    static func hash(file url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            guard !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
