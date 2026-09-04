import CryptoKit
import Darwin
import Foundation
import Network
import Security

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

struct HarnessTimeoutProfile: Equatable, Sendable {
    let connection: Duration
    let inactivity: Duration
    let interruption: Duration
    let largeTransferCompletion: Duration

    static let local = HarnessTimeoutProfile(
        connection: .seconds(15),
        inactivity: .seconds(30),
        interruption: .seconds(120),
        largeTransferCompletion: .seconds(900)
    )
    static let stack = HarnessTimeoutProfile(
        connection: .seconds(30),
        inactivity: .seconds(60),
        interruption: .seconds(600),
        largeTransferCompletion: .seconds(1_800)
    )

    static func profile(for policy: IntegrationRoutePolicy) -> HarnessTimeoutProfile {
        policy == .lanOnly ? .local : .stack
    }
}

enum TwoClientHarnessError: Error, Equatable {
    case stackConfigurationRequired
    case transferFailed(TransferID)
    case connectionFailed([String])
    case timedOut(TransferID)
    case missingTransfer
    case fileGenerationFailed
    case interruptionDidNotOccur
    case restartUnsupported
    case runtimeRetired
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

struct ResumeTransmissionEvidence: Equatable, Sendable {
    let acceptedBytes: Int64
    let acceptedMapChunkCount: Int
    let newConnectionWireBytes: Int64
    let maximumPermittedWireBytes: Int64
    let newConnectionCount: Int

    var provesNoConfirmedPayloadWasRetransmitted: Bool {
        acceptedBytes > 0
            && acceptedMapChunkCount > 0
            && newConnectionCount > 0
            && newConnectionWireBytes <= maximumPermittedWireBytes
    }
}

struct RuntimeRestartEvidence: Equatable, Sendable {
    let transferID: TransferID
    let identityBefore: DeviceID
    let identityAfter: DeviceID
    let runtimeGenerationBefore: UUID
    let runtimeGenerationAfter: UUID
    let identityKeyFingerprintBefore: String
    let identityKeyFingerprintAfter: String
    let secretStoreObjectChanged: Bool
    let trustRepositoryObjectChanged: Bool
    let deviceDirectoryObjectChanged: Bool
    let iceProviderObjectChanged: Bool
    let trustLoadedFromDisk: Bool
    let directoryRebuiltFromDurableTrust: Bool
    let oldRuntimeRejectedUse: Bool
    let databaseWasClosedAndReopened: Bool
}

struct PersonalMeshRestartEvidence: Equatable, Sendable {
    let identityBefore: DeviceID
    let identityAfter: DeviceID
    let identityKeyFingerprintBefore: String
    let identityKeyFingerprintAfter: String
    let secretStoreObjectChanged: Bool
    let trustRepositoryObjectChanged: Bool
    let candidateDirectoryObjectChanged: Bool
    let connectorObjectChanged: Bool
    let databaseWasClosedAndReopened: Bool
    let trustLoadedFromDisk: Bool
    let oldRuntimeRejectedUse: Bool
}

struct PersonalMeshResumeEvidence: Equatable, Sendable {
    let acceptedBytes: Int64
    let acceptedMapChunkCount: Int
    let newConnectionWireBytes: Int64
    let maximumPermittedWireBytes: Int64
    let newConnectionCount: Int

    var provesNoConfirmedPayloadWasRetransmitted: Bool {
        acceptedBytes > 0
            && acceptedMapChunkCount > 0
            && newConnectionCount > 0
            && newConnectionWireBytes <= maximumPermittedWireBytes
    }
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
    private let resumeRecorder: HarnessResumeNegotiationRecorder
    private let channelFaults: HarnessChannelFaults
    private let routePolicy: IntegrationRoutePolicy
    private let timeoutProfile: HarnessTimeoutProfile
    private var senderICEProvider: any ICEConfigurationProviding
    private var senderSecretStore: FileSecretStore
    private var senderTrustStore: AuthenticatedTrustSnapshotStore<FileSecretStore>
    private var senderRuntimeLease: HarnessRuntimeLease
    private var senderDatabase: TransferDatabase
    private var senderIdentity: DeviceIdentity
    private var senderRuntimeGeneration = UUID()
    private var senderRuntime: HarnessClientRuntime
    private let results: HarnessReceiveResults
    private var incomingListener: IncomingTransferListener
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
        let timeoutProfile = HarnessTimeoutProfile.profile(for: routePolicy)
        self.timeoutProfile = timeoutProfile

        let root =
            try root
            ?? FileManager.default.url(
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
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }

        let senderSecrets = try FileSecretStore(
            root: senderRoot.appendingPathComponent("secrets")
        )
        let receiverSecrets = try FileSecretStore(
            root: receiverRoot.appendingPathComponent("secrets")
        )
        let senderIdentity = try DeviceIdentity.loadOrCreate(keychain: senderSecrets)
        let receiverIdentity = try DeviceIdentity.loadOrCreate(keychain: receiverSecrets)
        self.senderIdentity = senderIdentity
        senderSecretStore = senderSecrets
        senderID = senderIdentity.id
        receiverID = receiverIdentity.id

        let senderTrustStore = AuthenticatedTrustSnapshotStore(
            url: senderRoot.appendingPathComponent("trust.json"),
            secrets: senderSecrets
        )
        let receiverTrustStore = AuthenticatedTrustSnapshotStore(
            url: receiverRoot.appendingPathComponent("trust.json"),
            secrets: receiverSecrets
        )
        self.senderTrustStore = senderTrustStore
        senderTrust = try await senderTrustStore.load(identity: senderIdentity)
        receiverTrust = try await receiverTrustStore.load(identity: receiverIdentity)
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
        try await senderTrustStore.persistLatest(from: senderTrust)
        try await receiverTrustStore.persistLatest(from: receiverTrust)

        senderDirectory = DeviceDirectory(trust: await senderTrust.currentTrustStore())
        let receiverDirectory = DeviceDirectory(trust: await receiverTrust.currentTrustStore())
        await senderDirectory.observeTrust(senderTrust)
        await receiverDirectory.observeTrust(receiverTrust)
        if routePolicy == .lanOnly {
            await senderDirectory.apply(.internet(receiverIdentity.id, online: true))
            await receiverDirectory.apply(.internet(senderIdentity.id, online: true))
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
            let senderFetcher = RecordingTURNCredentialFetcher(
                base: try RendezvousTURNCredentialClient(
                    identity: senderIdentity,
                    origin: stackOrigin,
                    session: try Self.stackSession()
                ))
            let receiverFetcher = RecordingTURNCredentialFetcher(
                base: try RendezvousTURNCredentialClient(
                    identity: receiverIdentity,
                    origin: stackOrigin,
                    session: try Self.stackSession()
                ))
            guard let webSocketURL = Self.webSocketURL(from: stackOrigin) else {
                throw TwoClientHarnessError.stackConfigurationRequired
            }
            let senderPresence = try AuthenticatedPresenceSession(
                identity: senderIdentity,
                origin: webSocketURL,
                socket: try URLSessionPresenceWebSocket(
                    origin: webSocketURL,
                    session: try Self.stackSession()
                ),
                client: PresenceClient(directory: senderDirectory),
                trustRepository: senderTrust
            )
            let receiverPresence = try AuthenticatedPresenceSession(
                identity: receiverIdentity,
                origin: webSocketURL,
                socket: try URLSessionPresenceWebSocket(
                    origin: webSocketURL,
                    session: try Self.stackSession()
                ),
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
            senderProvider = RefreshingICEConfigurationProvider(
                base: ICEConfiguration(stunURLs: [], turnServers: []),
                fetcher: HarnessUnavailableTURNCredentialFetcher()
            )
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
        let resumeRecorder = HarnessResumeNegotiationRecorder(control: control)
        self.resumeRecorder = resumeRecorder
        let runtimeLease = HarnessRuntimeLease()
        senderRuntimeLease = runtimeLease
        let faults = HarnessChannelFaults()
        channelFaults = faults
        let attempts = WebRTCConnectionAttempts(
            directory: senderDirectory,
            identity: senderIdentity,
            trustRepository: senderTrust,
            signaling: senderSignaling,
            iceProvider: senderProvider,
            factory: WebRTCFactory(connectionTimeout: timeoutProfile.connection)
        )
        let routeAttempts = HarnessRouteAttempts(
            attempts: attempts,
            policy: routePolicy,
            control: control,
            faults: faults,
            runtimeLease: runtimeLease
        )
        let connector = ConnectionCoordinator(attempts: routeAttempts)

        senderDatabase = try TransferDatabase(
            url: senderRoot.appendingPathComponent("history.sqlite")
        )
        constructionCleanup?.push { [senderDatabase] in try await senderDatabase.close() }
        receiverDatabase = try TransferDatabase(
            url: receiverRoot.appendingPathComponent("history.sqlite")
        )
        constructionCleanup?.push { [receiverDatabase] in try await receiverDatabase.close() }
        let coordinator = try await TransferCoordinator.restoring(
            connector: connector,
            database: senderDatabase,
            outgoingDirectory: senderOutgoing,
            maximumConnectionAttempts: maximumConnectionAttempts,
            persistenceRetryDelay: .milliseconds(20),
            cancellationWatchdogDelay: .seconds(1),
            resumeObserver: resumeRecorder
        )
        constructionCleanup?.push { await coordinator.shutdownForRestart() }
        senderRuntime = HarnessClientRuntime(
            generation: senderRuntimeGeneration,
            secretStore: senderSecrets,
            identity: senderIdentity,
            trustRepository: senderTrust,
            directory: senderDirectory,
            iceProvider: senderProvider,
            signaling: senderSignaling,
            database: senderDatabase,
            coordinator: coordinator,
            lease: runtimeLease
        )
        sender = HarnessSender(coordinator: coordinator)

        connectionListener = WebRTCConnectionListener(
            directory: receiverDirectory,
            identity: receiverIdentity,
            trustRepository: receiverTrust,
            signaling: receiverSignaling,
            iceProvider: receiverProvider,
            factory: WebRTCFactory(connectionTimeout: timeoutProfile.connection)
        )
        results = HarnessReceiveResults()
        incomingListener = IncomingTransferListener(
            source: connectionListener,
            policy: ReceivePolicy(trustedSources: [senderIdentity.id]),
            directories: DownloadDirectory(globalDirectory: receiverDownloadRoot),
            database: receiverDatabase,
            incomingDirectory: receiverIncoming,
            capacity: capacity,
            inactivityTimeout: timeoutProfile.inactivity,
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
            let thirdSecrets = try FileSecretStore(
                root: thirdRoot.appendingPathComponent("secrets")
            )
            let thirdIdentity = try DeviceIdentity.loadOrCreate(keychain: thirdSecrets)
            let thirdTrustStore = AuthenticatedTrustSnapshotStore(
                url: thirdRoot.appendingPathComponent("trust.json"),
                secrets: thirdSecrets
            )
            let thirdTrust = try await thirdTrustStore.load(identity: thirdIdentity)
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
            try await senderTrustStore.persistLatest(from: senderTrust)
            try await thirdTrustStore.persistLatest(from: thirdTrust)
            await senderDirectory.waitForTrustUpdates()
            await senderDirectory.apply(.internet(thirdIdentity.id, online: true))
            await senderDirectory.apply(
                .lan(thirdIdentity.id, host: "127.0.0.1", port: 9_003)
            )
            let thirdDirectory = DeviceDirectory(trust: await thirdTrust.currentTrustStore())
            await thirdDirectory.observeTrust(thirdTrust)
            await thirdDirectory.apply(.internet(senderIdentity.id, online: true))
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
                factory: WebRTCFactory(connectionTimeout: timeoutProfile.connection)
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
                inactivityTimeout: timeoutProfile.inactivity
            )
            thirdDownloadRoot = thirdDownloads
            thirdConnectionListener = thirdConnection
            thirdIncomingListener = thirdIncoming
            self.thirdDatabase = thirdDatabase
            await thirdIncoming.start()
            constructionCleanup?.push { [thirdIncoming, thirdConnection, thirdDatabase] in
                await thirdIncoming.stop()
                await thirdConnection.stop()
                try await thirdDatabase.close()
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
        let sourceDirectory = senderDownloadRoot.appendingPathComponent(
            "sources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory, withIntermediateDirectories: true)
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

    func restartReceiverListener() async {
        await incomingListener.stop()
        let restarted = IncomingTransferListener(
            source: connectionListener,
            policy: ReceivePolicy(trustedSources: [senderID]),
            directories: DownloadDirectory(globalDirectory: receiverDownloadRoot),
            database: receiverDatabase,
            incomingDirectory: root.appendingPathComponent("receiver/incoming", isDirectory: true),
            inactivityTimeout: timeoutProfile.inactivity,
            onReceiveFinished: { [results] result in
                await results.record(result)
            },
            onReceiveFailed: { [results] transferID, failure in
                await results.recordFailure(failure, for: transferID)
            }
        )
        incomingListener = restarted
        await restarted.start()
    }

    func iceConfiguration(for route: ConnectionRoute) async throws -> ICEConfiguration {
        try await senderICEProvider.configuration(for: route)
    }

    func makeDeterministicDirectory(named name: String = "folder") throws -> URL {
        let directory =
            senderDownloadRoot
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
                    let failures = await connectionControl.attemptFailures
                    if !failures.isEmpty { throw TwoClientHarnessError.connectionFailed(failures) }
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
        let deadline = ContinuousClock.now.advanced(by: timeoutProfile.interruption)
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
                let failures = await connectionControl.attemptFailures
                if !failures.isEmpty { throw TwoClientHarnessError.connectionFailed(failures) }
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
            if count > interruption.connectionCount,
                let connectionID,
                connectionID != interruption.connectionInstanceID,
                let negotiation = await resumeRecorder.value(
                    transferID: interruption.transferID,
                    connectionID: connectionID
                ),
                negotiation.acceptedBytes <= UInt64(Int64.max),
                Int64(negotiation.acceptedBytes) >= interruption.receiverDurableOffset,
                bytes > 0
            {
                return NetworkResumeEvidence(
                    connectionCount: count,
                    connectionInstanceID: connectionID,
                    resumeOffset: Int64(negotiation.acceptedBytes),
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

    func resumeTransmissionEvidence(
        after interruption: NetworkInterruptionEvidence,
        totalPayloadBytes: Int64
    ) async throws -> ResumeTransmissionEvidence {
        let transport = await connectionControl.transportEvidence(
            afterConnectionCount: interruption.connectionCount
        )
        guard !transport.isEmpty else { throw TwoClientHarnessError.interruptionDidNotOccur }
        let negotiations = await resumeRecorder.values(
            transferID: interruption.transferID,
            connectionIDs: Set(transport.map(\.id))
        )
        guard !negotiations.isEmpty else {
            throw TwoClientHarnessError.interruptionDidNotOccur
        }
        let maximumChunkBytes = Int64(TransferProtocolLimits.maximumChunkBytes)
        let maximumFrameBytes = Int64(TransferProtocolLimits.maximumWireFrameBytes)
        var maximumPermittedWireBytes: Int64 = 0
        for item in transport {
            guard let negotiation = negotiations.first(where: { $0.connectionID == item.id }) else {
                // A connection that dies before authenticated `.accept` cannot
                // carry chunks; permit only offer/error control frames.
                maximumPermittedWireBytes += maximumFrameBytes * 2
                continue
            }
            guard negotiation.value.acceptedBytes <= UInt64(Int64.max) else {
                throw TwoClientHarnessError.interruptionDidNotOccur
            }
            let accepted = Int64(negotiation.value.acceptedBytes)
            let remaining = max(0, totalPayloadBytes - accepted)
            let remainingChunks = (remaining + maximumChunkBytes - 1) / maximumChunkBytes
            let chunkEnvelopeBytes = remainingChunks * 84
            let controlFrameAllowance = maximumFrameBytes * 4
            maximumPermittedWireBytes += remaining + chunkEnvelopeBytes + controlFrameAllowance
        }
        return ResumeTransmissionEvidence(
            acceptedBytes: Int64(negotiations.map(\.value.acceptedBytes).min() ?? 0),
            acceptedMapChunkCount: negotiations.map(\.value.resumeMap.chunkCount).min() ?? 0,
            newConnectionWireBytes: transport.reduce(0) { $0 + $1.wireBytes },
            maximumPermittedWireBytes: maximumPermittedWireBytes,
            newConnectionCount: transport.count
        )
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
        try await senderTrustStore.persistLatest(from: senderTrust)
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
        let identityKeyFingerprintBefore = Self.keyFingerprint(senderIdentity)
        let generationBefore = senderRuntimeGeneration
        let oldSecretStoreID = ObjectIdentifier(senderSecretStore)
        let oldTrustRepositoryID = ObjectIdentifier(senderTrust)
        let oldDirectoryID = ObjectIdentifier(senderDirectory)
        let oldICEProviderID = ObjectIdentifier(senderICEProvider as AnyObject)
        let oldRuntime = senderRuntime
        await oldRuntime.retire()
        guard await connectionControl.interruptNetwork() > 0 else {
            throw TwoClientHarnessError.interruptionDidNotOccur
        }
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
        let reopenedSecrets = try FileSecretStore(
            root: senderRoot.appendingPathComponent("secrets")
        )
        let reopenedIdentity = try DeviceIdentity.loadOrCreate(keychain: reopenedSecrets)
        let reopenedTrustStore = AuthenticatedTrustSnapshotStore(
            url: senderRoot.appendingPathComponent("trust.json"),
            secrets: reopenedSecrets
        )
        let reopenedTrust = try await reopenedTrustStore.load(identity: reopenedIdentity)
        guard reopenedIdentity.id == identityBefore else {
            throw TwoClientHarnessError.restartUnsupported
        }
        let trustLoadedFromDisk = await reopenedTrust.publicKey(for: receiverID) != nil
        guard trustLoadedFromDisk else { throw TwoClientHarnessError.restartUnsupported }
        let reopenedDirectory = DeviceDirectory(
            trust: await reopenedTrust.currentTrustStore()
        )
        await reopenedDirectory.observeTrust(reopenedTrust)
        await reopenedDirectory.apply(.internet(receiverID, online: true))
        await reopenedDirectory.apply(.lan(receiverID, host: "127.0.0.1", port: 9_001))
        let directoryRebuiltFromDurableTrust =
            await reopenedDirectory.endpoint(for: receiverID) != nil
        guard directoryRebuiltFromDurableTrust else {
            throw TwoClientHarnessError.restartUnsupported
        }
        let reopenedICEProvider = RefreshingICEConfigurationProvider(
            base: ICEConfiguration(stunURLs: [], turnServers: []),
            fetcher: HarnessUnavailableTURNCredentialFetcher()
        )
        let reopenedRuntimeLease = HarnessRuntimeLease()
        let reopenedDatabase = try TransferDatabase(
            url: senderRoot.appendingPathComponent("history.sqlite")
        )
        let signaling = RendezvousWebRTCSignaling(
            session: LocalRendezvousSignalSession(localDevice: reopenedIdentity.id, hub: hub)
        )
        let attempts = WebRTCConnectionAttempts(
            directory: reopenedDirectory,
            identity: reopenedIdentity,
            trustRepository: reopenedTrust,
            signaling: signaling,
            iceProvider: reopenedICEProvider,
            factory: WebRTCFactory(connectionTimeout: timeoutProfile.connection)
        )
        let routeAttempts = HarnessRouteAttempts(
            attempts: attempts,
            policy: routePolicy,
            control: connectionControl,
            faults: channelFaults,
            runtimeLease: reopenedRuntimeLease
        )
        let connector = ConnectionCoordinator(attempts: routeAttempts)
        await connectionControl.restoreNetwork()
        let restored = try await TransferCoordinator.restoring(
            connector: connector,
            database: reopenedDatabase,
            outgoingDirectory: senderOutgoing,
            maximumConnectionAttempts: 8,
            persistenceRetryDelay: .milliseconds(20),
            cancellationWatchdogDelay: .seconds(1),
            resumeObserver: resumeRecorder
        )
        senderIdentity = reopenedIdentity
        senderSecretStore = reopenedSecrets
        senderTrustStore = reopenedTrustStore
        senderTrust = reopenedTrust
        senderDirectory = reopenedDirectory
        senderICEProvider = reopenedICEProvider
        senderRuntimeLease = reopenedRuntimeLease
        senderDatabase = reopenedDatabase
        senderRuntimeGeneration = UUID()
        senderRuntime = HarnessClientRuntime(
            generation: senderRuntimeGeneration,
            secretStore: reopenedSecrets,
            identity: reopenedIdentity,
            trustRepository: reopenedTrust,
            directory: reopenedDirectory,
            iceProvider: reopenedICEProvider,
            signaling: signaling,
            database: reopenedDatabase,
            coordinator: restored,
            lease: reopenedRuntimeLease
        )
        await sender.install(restored)
        let oldRuntimeRejectedUse: Bool
        do {
            try await oldRuntime.requireActive()
            oldRuntimeRejectedUse = false
        } catch TwoClientHarnessError.runtimeRetired {
            oldRuntimeRejectedUse = true
        }
        return RuntimeRestartEvidence(
            transferID: transfer,
            identityBefore: identityBefore,
            identityAfter: reopenedIdentity.id,
            runtimeGenerationBefore: generationBefore,
            runtimeGenerationAfter: senderRuntimeGeneration,
            identityKeyFingerprintBefore: identityKeyFingerprintBefore,
            identityKeyFingerprintAfter: Self.keyFingerprint(reopenedIdentity),
            secretStoreObjectChanged: oldSecretStoreID != ObjectIdentifier(reopenedSecrets),
            trustRepositoryObjectChanged: oldTrustRepositoryID != ObjectIdentifier(reopenedTrust),
            deviceDirectoryObjectChanged: oldDirectoryID != ObjectIdentifier(reopenedDirectory),
            iceProviderObjectChanged: oldICEProviderID
                != ObjectIdentifier(reopenedICEProvider as AnyObject),
            trustLoadedFromDisk: trustLoadedFromDisk,
            directoryRebuiltFromDurableTrust: directoryRebuiltFromDurableTrust,
            oldRuntimeRejectedUse: oldRuntimeRejectedUse,
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
        if case .receiveStore(let error) = failure {
            receiveError = error
        } else {
            receiveError = nil
        }
        let incoming = root.appendingPathComponent("receiver/incoming", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: incoming.path)) ?? []
        return TransferFailureEvidence(
            senderPhase: senderPhase,
            receiveFailure: failure,
            receiveError: receiveError,
            stagingEntries: entries.sorted()
        )
    }

    func shutdown() async throws {
        guard await cleanupState.beginShutdown() else { return }
        await senderRuntime.retire()
        _ = await connectionControl.interruptNetwork()
        await incomingListener.stop()
        await connectionListener.stop()
        await thirdIncomingListener?.stop()
        await thirdConnectionListener?.stop()
        await signalHub?.finish()
        await stackPresence?.shutdown()
        var firstError: (any Error)?
        do { try await senderDatabase.close() } catch { firstError = error }
        do { try await receiverDatabase.close() } catch {
            if firstError == nil { firstError = error }
        }
        do { try await thirdDatabase?.close() } catch {
            if firstError == nil { firstError = error }
        }
        if let firstError { throw firstError }
    }

    func shutdownAndRemoveRoot() async throws {
        var firstError: (any Error)?
        do { try await shutdown() } catch { firstError = error }
        if await cleanupState.beginRemoval() {
            do { try restoreReceiverDirectoryPermissions() } catch {
                if firstError == nil { firstError = error }
            }
            do {
                if FileManager.default.fileExists(atPath: root.path) {
                    try makeTreeRemovable()
                    try FileManager.default.removeItem(at: root)
                }
            } catch {
                if firstError == nil { firstError = error }
            }
            if FileManager.default.fileExists(atPath: root.path), firstError == nil {
                firstError = TwoClientHarnessError.fileGenerationFailed
            }
        }
        if let firstError { throw firstError }
    }

    private func makeTreeRemovable() throws {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsPackageDescendants]
            )
        else { throw TwoClientHarnessError.fileGenerationFailed }
        for case let url as URL in enumerator {
            var information = stat()
            guard lstat(url.path, &information) == 0 else {
                throw TwoClientHarnessError.fileGenerationFailed
            }
            switch information.st_mode & S_IFMT {
            case S_IFDIR:
                guard chmod(url.path, S_IRWXU) == 0 else {
                    throw TwoClientHarnessError.fileGenerationFailed
                }
            case S_IFREG:
                guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else {
                    throw TwoClientHarnessError.fileGenerationFailed
                }
            default:
                break
            }
        }
        guard chmod(root.path, S_IRWXU) == 0 else {
            throw TwoClientHarnessError.fileGenerationFailed
        }
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
            session: try stackSession()
        )
        let receiverTransport = try RendezvousPairingTransport(
            identity: receiverIdentity,
            origin: origin,
            session: try stackSession()
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

    private static func stackSession() throws -> URLSession {
        try StackSessionFactory.make(
            certificatePath: ProcessInfo.processInfo.environment["MACCHANNEL_E2E_CA_FILE"]
        )
    }

    private static func keyFingerprint(_ identity: DeviceIdentity) -> String {
        SHA256.hash(data: identity.publicKey.rawRepresentation)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum StackSessionFactory {
    static func make(certificatePath: String?) throws -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        guard let certificatePath, !certificatePath.isEmpty else {
            return URLSession(configuration: configuration)
        }
        let delegate = try PinnedLocalCASessionDelegate(
            certificateURL: URL(fileURLWithPath: certificatePath)
        )
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }
}

final class PinnedLocalCASessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked
    Sendable
{
    private let certificate: SecCertificate

    init(certificateURL: URL) throws {
        let pem = try String(contentsOf: certificateURL, encoding: .utf8)
        let beginMarker = "-----BEGIN CERTIFICATE-----"
        let endMarker = "-----END CERTIFICATE-----"
        guard let begin = pem.range(of: beginMarker),
            let end = pem.range(of: endMarker, range: begin.upperBound..<pem.endIndex),
            pem[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw TwoClientHarnessError.stackConfigurationRequired }
        let encoded = pem[begin.upperBound..<end.lowerBound].filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: String(encoded)),
            let certificate = SecCertificateCreateWithData(nil, data as CFData)
        else {
            throw TwoClientHarnessError.stackConfigurationRequired
        }
        self.certificate = certificate
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        respond(to: challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        respond(to: challenge, completionHandler: completionHandler)
    }

    private func respond(
        to challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust,
            SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
            SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
            SecTrustEvaluateWithError(trust, nil)
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

private actor HarnessClientRuntime {
    let generation: UUID
    private let secretStore: FileSecretStore
    private let identity: DeviceIdentity
    private let trustRepository: TrustRepository
    private let directory: DeviceDirectory
    private let iceProvider: any ICEConfigurationProviding
    private let signaling: RendezvousWebRTCSignaling
    private let database: TransferDatabase
    private let coordinator: TransferCoordinator
    private let lease: HarnessRuntimeLease
    private var active = true

    init(
        generation: UUID,
        secretStore: FileSecretStore,
        identity: DeviceIdentity,
        trustRepository: TrustRepository,
        directory: DeviceDirectory,
        iceProvider: any ICEConfigurationProviding,
        signaling: RendezvousWebRTCSignaling,
        database: TransferDatabase,
        coordinator: TransferCoordinator,
        lease: HarnessRuntimeLease
    ) {
        self.generation = generation
        self.secretStore = secretStore
        self.identity = identity
        self.trustRepository = trustRepository
        self.directory = directory
        self.iceProvider = iceProvider
        self.signaling = signaling
        self.database = database
        self.coordinator = coordinator
        self.lease = lease
    }

    func requireActive() throws {
        guard active else { throw TwoClientHarnessError.runtimeRetired }
    }

    func retire() async {
        guard active else { return }
        active = false
        await lease.retire()
        await coordinator.shutdownForRestart()
    }
}

actor HarnessSender: TransferCoordinating {
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

    func pause(_ id: TransferID) async throws {
        try await coordinator.pause(id)
    }

    func resume(_ id: TransferID) async throws {
        try await coordinator.resume(id)
    }

    func cancel(_ id: TransferID) async -> TransferCancellationResult {
        await coordinator.cancel(id)
    }

    func snapshots() async -> AsyncStream<[TransferSnapshot]> {
        await coordinator.snapshots()
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
    private let runtimeLease: HarnessRuntimeLease

    init(
        attempts: WebRTCConnectionAttempts,
        policy: IntegrationRoutePolicy,
        control: HarnessConnectionControl,
        faults: HarnessChannelFaults,
        runtimeLease: HarnessRuntimeLease
    ) {
        self.attempts = attempts
        self.policy = policy
        self.control = control
        self.faults = faults
        self.runtimeLease = runtimeLease
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
        try await runtimeLease.requireActive()
        try await control.waitUntilOnline()
        await control.recordAttempt(route)
        guard route == policy.route else { throw ConnectionAttemptError.routeUnavailable }
        let channel: any SecureChannel
        do {
            channel = try await attempts.connect(
                to: device,
                route: route,
                transferID: transferID
            )
        } catch {
            await control.recordFailure(route: route, error: error)
            throw error
        }
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
    struct TransportEvidence: Sendable {
        let id: UUID
        let wireBytes: Int64
    }
    private var online = true
    private var channels: [UUID: HarnessSecureChannel] = [:]
    private var connectionOrder: [UUID] = []
    private var bytesByConnection: [UUID: Int64] = [:]
    private(set) var attemptedRoutes: [ConnectionRoute] = []
    private(set) var actualRoutes: [ConnectionRoute] = []
    private(set) var attemptFailures: [String] = []

    func waitUntilOnline() async throws {
        while !online {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func recordAttempt(_ route: ConnectionRoute) {
        attemptedRoutes.append(route)
    }

    func recordFailure(route: ConnectionRoute, error: any Error) {
        attemptFailures.append("\(route): \(String(describing: error))")
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

    func transportEvidence(afterConnectionCount count: Int) -> [TransportEvidence] {
        guard count >= 0, count <= connectionOrder.count else { return [] }
        return connectionOrder.dropFirst(count).map { identifier in
            TransportEvidence(id: identifier, wireBytes: bytesByConnection[identifier] ?? 0)
        }
    }
}

private actor HarnessResumeNegotiationRecorder: TransferResumeNegotiationObserving {
    struct Value: Sendable {
        let connectionID: UUID
        let value: TransferResumeNegotiation
    }

    private let control: HarnessConnectionControl
    private var recorded: [Value] = []

    init(control: HarnessConnectionControl) { self.control = control }

    func recordResumeNegotiation(_ value: TransferResumeNegotiation) async {
        guard let connectionID = await control.latestConnectionID() else { return }
        recorded.append(Value(connectionID: connectionID, value: value))
    }

    func values(transferID: TransferID, connectionIDs: Set<UUID>) -> [Value] {
        recorded.filter {
            $0.value.transferID == transferID && connectionIDs.contains($0.connectionID)
        }
    }

    func value(transferID: TransferID, connectionID: UUID) -> TransferResumeNegotiation? {
        recorded.last {
            $0.value.transferID == transferID && $0.connectionID == connectionID
        }?.value
    }
}

private actor HarnessRuntimeLease {
    private var active = true

    func requireActive() throws {
        guard active else { throw TwoClientHarnessError.runtimeRetired }
    }

    func retire() { active = false }
}

private actor HarnessUnavailableTURNCredentialFetcher: RendezvousTURNCredentialFetching {
    func fetch() async throws -> RendezvousTURNCredentials {
        throw RendezvousTURNClientError.unavailable
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

    func protocolErrors() async -> AsyncStream<RendezvousProtocolError> {
        AsyncStream { $0.finish() }
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

extension Optional {
    fileprivate func unwrap() throws -> Wrapped {
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
    private var actions: [@Sendable () async throws -> Void] = []
    private var active = true

    func push(_ action: @escaping @Sendable () async throws -> Void) {
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

    func run() async throws {
        let pending: [@Sendable () async throws -> Void] = lock.withLock {
            guard active else { return [] }
            active = false
            defer { actions.removeAll() }
            return Array(actions.reversed())
        }
        var firstError: (any Error)?
        for action in pending {
            do { try await action() } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
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
            var reachedEnd = false
            try autoreleasepool {
                let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
                if data.isEmpty {
                    reachedEnd = true
                } else {
                    hasher.update(data: data)
                }
            }
            if reachedEnd { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

final class PersonalMeshHarness: @unchecked Sendable {
    let sender: HarnessSender
    let receiverID: DeviceID
    let senderID: DeviceID
    let root: URL
    let senderRoot: URL
    let receiverRoot: URL
    private(set) var senderDatabase: TransferDatabase
    let receiverDatabase: TransferDatabase
    let senderDownloadRoot: URL
    let receiverDownloadRoot: URL
    let thirdID: DeviceID?
    let thirdDownloadRoot: URL?
    let hasIndependentClientRootsAndDatabases: Bool

    private var connector: PersonalMeshRecordingConnector
    private let network: PersonalMeshLoopbackNetwork
    private var senderTrust: TrustRepository
    private var senderTrustStore: AuthenticatedTrustSnapshotStore<FileSecretStore>
    private var senderSecretStore: FileSecretStore
    private var senderIdentity: DeviceIdentity
    private var coordinator: TransferCoordinator
    private let incoming: IncomingTransferListener
    private let source: MeshTransferConnectionSource
    private var senderRegistry: MeshConnectionRegistry
    private let receiverRegistry: MeshConnectionRegistry
    private let results: PersonalMeshReceiveResults
    private let cleanupState = PersonalMeshCleanupState()
    private let thirdIncoming: IncomingTransferListener?
    private let thirdSource: MeshTransferConnectionSource?
    private let thirdRegistry: MeshConnectionRegistry?
    private let thirdDatabase: TransferDatabase?
    private let candidateValues: [DeviceID: MeshPeerCandidate]
    private let routeValues: [String: TailscaleConnectionKind]
    private var candidateDirectory: PersonalMeshCandidates
    private var runtimeLease: PersonalMeshRuntimeLease
    private let resumeRecorder: PersonalMeshResumeRecorder

    init(
        capacity: any ReceiveCapacityProviding = VolumeReceiveCapacityProvider(),
        maximumConnectionAttempts: Int = 3,
        additionalOnlineClient: Bool = false
    ) async throws {
        root = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: FileManager.default.temporaryDirectory,
            create: true
        ).standardizedFileURL
        senderRoot = root.appendingPathComponent("sender", isDirectory: true)
        receiverRoot = root.appendingPathComponent("receiver", isDirectory: true)
        senderDownloadRoot = senderRoot.appendingPathComponent("downloads", isDirectory: true)
        receiverDownloadRoot = receiverRoot.appendingPathComponent("downloads", isDirectory: true)
        for directory in [senderDownloadRoot, receiverDownloadRoot] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        let senderSecrets = try FileSecretStore(
            root: senderRoot.appendingPathComponent("secrets", isDirectory: true)
        )
        let receiverSecrets = try FileSecretStore(
            root: receiverRoot.appendingPathComponent("secrets", isDirectory: true)
        )
        let senderIdentity = try DeviceIdentity.loadOrCreate(keychain: senderSecrets)
        let receiverIdentity = try DeviceIdentity.loadOrCreate(keychain: receiverSecrets)
        self.senderIdentity = senderIdentity
        senderSecretStore = senderSecrets
        senderID = senderIdentity.id
        receiverID = receiverIdentity.id

        let senderTrustStore = AuthenticatedTrustSnapshotStore(
            url: senderRoot.appendingPathComponent("trust.json"),
            secrets: senderSecrets
        )
        let receiverTrustStore = AuthenticatedTrustSnapshotStore(
            url: receiverRoot.appendingPathComponent("trust.json"),
            secrets: receiverSecrets
        )
        let senderTrust = try await senderTrustStore.load(identity: senderIdentity)
        let receiverTrust = try await receiverTrustStore.load(identity: receiverIdentity)
        self.senderTrustStore = senderTrustStore
        self.senderTrust = senderTrust
        let senderAuthorization = try SignedTrustRecord.authorizing(
            receiverIdentity,
            signedBy: senderIdentity,
            timestamp: Date(timeIntervalSince1970: 10_000)
        )
        let receiverAuthorization = try SignedTrustRecord.authorizing(
            senderIdentity,
            signedBy: receiverIdentity,
            timestamp: Date(timeIntervalSince1970: 10_000)
        )
        try await senderTrust.commitBilateralPairing(
            localAuthorization: senderAuthorization,
            peerAuthorization: receiverAuthorization
        )
        try await receiverTrust.commitBilateralPairing(
            localAuthorization: receiverAuthorization,
            peerAuthorization: senderAuthorization
        )

        let thirdIdentity: DeviceIdentity?
        let thirdTrust: TrustRepository?
        let thirdRoot: URL?
        if additionalOnlineClient {
            let thirdClientRoot = root.appendingPathComponent("third", isDirectory: true)
            let downloads = thirdClientRoot.appendingPathComponent("downloads", isDirectory: true)
            try FileManager.default.createDirectory(
                at: downloads,
                withIntermediateDirectories: true
            )
            let secrets = try FileSecretStore(
                root: thirdClientRoot.appendingPathComponent("secrets", isDirectory: true)
            )
            let identity = try DeviceIdentity.loadOrCreate(keychain: secrets)
            let trust = try TrustRepository(
                ownerIdentity: identity,
                trustStore: TrustStore(owner: identity.id),
                persistedGeneration: 0
            )
            let senderToThird = try await senderTrust.prepareAuthorization(
                subject: identity.id,
                subjectPublicKey: identity.publicKey.rawRepresentation,
                timestamp: Date(timeIntervalSince1970: 10_001)
            )
            let thirdToSender = try await trust.prepareAuthorization(
                subject: senderIdentity.id,
                subjectPublicKey: senderIdentity.publicKey.rawRepresentation,
                timestamp: Date(timeIntervalSince1970: 10_001)
            )
            try await senderTrust.commitBilateralPairing(
                localAuthorization: senderToThird,
                peerAuthorization: thirdToSender
            )
            try await trust.commitBilateralPairing(
                localAuthorization: thirdToSender,
                peerAuthorization: senderToThird
            )
            thirdIdentity = identity
            thirdTrust = trust
            thirdRoot = thirdClientRoot
            thirdID = identity.id
            thirdDownloadRoot = downloads
        } else {
            thirdIdentity = nil
            thirdTrust = nil
            thirdRoot = nil
            thirdID = nil
            thirdDownloadRoot = nil
        }
        try await senderTrustStore.persistLatest(from: senderTrust)
        try await receiverTrustStore.persistLatest(from: receiverTrust)

        let senderEndpoint = NWEndpoint.hostPort(host: "100.64.0.1", port: 51_338)
        let receiverEndpoint = NWEndpoint.hostPort(host: "100.64.0.2", port: 51_338)
        var candidateValues: [DeviceID: MeshPeerCandidate] = [
            senderIdentity.id: MeshPeerCandidate(
                nodeID: "sender-node",
                endpoint: senderEndpoint,
                probeNonce: Data(repeating: 1, count: 32),
                deviceIDHash: MeshPeerDirectory.deviceIDHash(for: senderIdentity.id),
                displayName: "Sender"
            ),
            receiverIdentity.id: MeshPeerCandidate(
                nodeID: "receiver-node",
                endpoint: receiverEndpoint,
                probeNonce: Data(repeating: 2, count: 32),
                deviceIDHash: MeshPeerDirectory.deviceIDHash(for: receiverIdentity.id),
                displayName: "Receiver"
            ),
        ]
        var routeValues: [String: TailscaleConnectionKind] = [
            "sender-node": .direct,
            "receiver-node": .direct,
        ]
        let thirdEndpoint = NWEndpoint.hostPort(host: "100.64.0.3", port: 51_338)
        if let thirdIdentity {
            candidateValues[thirdIdentity.id] = MeshPeerCandidate(
                nodeID: "third-node",
                endpoint: thirdEndpoint,
                probeNonce: Data(repeating: 3, count: 32),
                deviceIDHash: MeshPeerDirectory.deviceIDHash(for: thirdIdentity.id),
                displayName: "Third"
            )
            routeValues["third-node"] = .direct
        }
        let candidates = PersonalMeshCandidates(candidateValues)
        let routes = PersonalMeshRoutes(routeValues)
        self.candidateValues = candidateValues
        self.routeValues = routeValues
        candidateDirectory = candidates
        let listenerTransport = PersonalMeshListenerTransport()
        let listener = MeshConnectionListener(transport: listenerTransport)
        try await listener.start()
        let thirdListenerTransport = additionalOnlineClient ? PersonalMeshListenerTransport() : nil
        let thirdListener = thirdListenerTransport.map { MeshConnectionListener(transport: $0) }
        if let thirdListener { try await thirdListener.start() }
        var destinations = [
            PersonalMeshLoopbackNetwork.key(receiverEndpoint): listenerTransport
        ]
        if let thirdListenerTransport {
            destinations[PersonalMeshLoopbackNetwork.key(thirdEndpoint)] = thirdListenerTransport
        }
        let network = PersonalMeshLoopbackNetwork(
            destinations: destinations
        )
        self.network = network
        let runtimeLease = PersonalMeshRuntimeLease()
        self.runtimeLease = runtimeLease
        resumeRecorder = PersonalMeshResumeRecorder(network: network)
        senderRegistry = MeshConnectionRegistry(trustRepository: senderTrust)
        receiverRegistry = MeshConnectionRegistry(trustRepository: receiverTrust)
        let productionConnector = MeshTransferConnector(
            identity: senderIdentity,
            trustRepository: senderTrust,
            directory: candidates,
            routes: routes,
            opener: network,
            registry: senderRegistry
        )
        connector = PersonalMeshRecordingConnector(
            base: productionConnector,
            network: network,
            lease: runtimeLease
        )
        source = MeshTransferConnectionSource(
            listener: listener,
            identity: receiverIdentity,
            trustRepository: receiverTrust,
            directory: candidates,
            routes: routes,
            registry: receiverRegistry
        )

        senderDatabase = try TransferDatabase(
            url: senderRoot.appendingPathComponent("history.sqlite")
        )
        receiverDatabase = try TransferDatabase(
            url: receiverRoot.appendingPathComponent("history.sqlite")
        )
        coordinator = try await TransferCoordinator.restoring(
            connector: connector,
            database: senderDatabase,
            outgoingDirectory: senderRoot.appendingPathComponent("outgoing", isDirectory: true),
            maximumConnectionAttempts: maximumConnectionAttempts,
            persistenceRetryDelay: .milliseconds(20),
            resumeObserver: resumeRecorder
        )
        sender = HarnessSender(coordinator: coordinator)
        results = PersonalMeshReceiveResults()
        incoming = IncomingTransferListener(
            source: source,
            policy: ReceivePolicy(trustedSources: [senderIdentity.id]),
            directories: DownloadDirectory(globalDirectory: receiverDownloadRoot),
            database: receiverDatabase,
            incomingDirectory: receiverRoot.appendingPathComponent("incoming", isDirectory: true),
            capacity: capacity,
            inactivityTimeout: .seconds(30),
            onReceiveFinished: { [results] result in await results.record(result) },
            onReceiveFailed: { [results] transferID, failure in
                await results.record(failure, transferID: transferID)
            }
        )
        await incoming.start()

        if let thirdIdentity, let thirdTrust, let thirdRoot, let thirdListener {
            let registry = MeshConnectionRegistry(trustRepository: thirdTrust)
            let source = MeshTransferConnectionSource(
                listener: thirdListener,
                identity: thirdIdentity,
                trustRepository: thirdTrust,
                directory: candidates,
                routes: routes,
                registry: registry
            )
            let database = try TransferDatabase(
                url: thirdRoot.appendingPathComponent("history.sqlite")
            )
            let incoming = IncomingTransferListener(
                source: source,
                policy: ReceivePolicy(trustedSources: [senderIdentity.id]),
                directories: DownloadDirectory(
                    globalDirectory: thirdRoot.appendingPathComponent(
                        "downloads",
                        isDirectory: true
                    )
                ),
                database: database,
                incomingDirectory: thirdRoot.appendingPathComponent("incoming", isDirectory: true),
                inactivityTimeout: .seconds(30)
            )
            thirdRegistry = registry
            thirdSource = source
            thirdDatabase = database
            thirdIncoming = incoming
            await incoming.start()
        } else {
            thirdRegistry = nil
            thirdSource = nil
            thirdDatabase = nil
            thirdIncoming = nil
        }
        hasIndependentClientRootsAndDatabases =
            senderRoot != receiverRoot
            && senderDatabase !== receiverDatabase
            && senderIdentity.id != receiverIdentity.id
        await Task.yield()
    }

    func makeDeterministicFile(
        size: Int,
        named name: String = "personal-mesh.bin"
    ) throws -> URL {
        guard size >= 0 else { throw TwoClientHarnessError.fileGenerationFailed }
        let directory = senderDownloadRoot.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var blockBytes: [UInt8] = []
        blockBytes.reserveCapacity(64 * 1_024)
        for index in 0..<(64 * 1_024) {
            blockBytes.append(UInt8((index &* 31 &+ 17) % 251))
        }
        let block = Data(blockBytes)
        var remaining = size
        while remaining > 0 {
            let count = min(remaining, block.count)
            try handle.write(contentsOf: count == block.count ? block : Data(block.prefix(count)))
            remaining -= count
        }
        try handle.synchronize()
        return url
    }

    func receivedFile(named name: String) -> URL {
        receiverDownloadRoot.appendingPathComponent(name)
    }

    func makeDeterministicDirectory(named name: String = "personal-folder") throws -> URL {
        let directory =
            senderDownloadRoot
            .appendingPathComponent("sources", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        let nested = directory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try makeDeterministicFile(size: 512 * 1_024, named: "temporary-payload.bin")
        let temporary =
            senderDownloadRoot
            .appendingPathComponent("sources", isDirectory: true)
            .appendingPathComponent("temporary-payload.bin")
        try FileManager.default.moveItem(
            at: temporary,
            to: nested.appendingPathComponent("payload.bin")
        )
        try Data("个人网络".utf8).write(to: directory.appendingPathComponent("说明.txt"))
        return directory
    }

    func waitForCompletion(
        _ transfer: TransferID,
        timeout: Duration = .seconds(30)
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let snapshot = await sender.snapshot(for: transfer) {
                switch snapshot.phase {
                case .completed:
                    if await results.result(for: transfer) != nil { return }
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

    func actualRoutes() async -> [ConnectionRoute] { await connector.routes() }

    func waitForFailure(
        _ transfer: TransferID,
        timeout: Duration = .seconds(30)
    ) async throws {
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

    func receiveFailure(for transfer: TransferID) async -> IncomingTransferFailure? {
        await results.failure(for: transfer)
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

    func revokeReceiverFromSender() async throws {
        _ = try await senderTrust.revoke(receiverID)
    }

    func tamperNextCiphertext() async { await network.tamperNextCiphertext() }
    func tamperedCiphertextCount() async -> Int { await network.tamperedCiphertextCount() }

    func thirdReceivedEntries() throws -> [String] {
        guard let thirdDownloadRoot else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: thirdDownloadRoot.path)
            .filter { !$0.hasPrefix(".") }
    }

    func cutNetwork(afterBytes: Int64) async throws -> NetworkInterruptionEvidence {
        guard let transfer = await sender.latestTransferID else {
            throw TwoClientHarnessError.missingTransfer
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        var senderOffset: UInt64 = 0
        var receiverOffset: UInt64 = 0
        while ContinuousClock.now < deadline {
            senderOffset =
                try await senderDatabase
                .history(limit: 200)
                .first(where: { $0.id == transfer })?.completedBytes ?? 0
            receiverOffset =
                try await receiverDatabase
                .history(limit: 200)
                .first(where: { $0.id == transfer })?.completedBytes ?? 0
            if senderOffset >= UInt64(afterBytes), receiverOffset >= UInt64(afterBytes) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard senderOffset >= UInt64(afterBytes), receiverOffset >= UInt64(afterBytes),
            let connectionID = await network.latestConnectionID()
        else { throw TwoClientHarnessError.interruptionDidNotOccur }
        let connectionCount = await network.connectionCount()
        let closed = await network.interrupt()
        guard closed > 0 else { throw TwoClientHarnessError.interruptionDidNotOccur }
        return NetworkInterruptionEvidence(
            transferID: transfer,
            senderDurableOffset: Int64(senderOffset),
            receiverDurableOffset: Int64(receiverOffset),
            closedChannelCount: closed,
            connectionCount: connectionCount,
            connectionInstanceID: connectionID
        )
    }

    func restartSender() async throws -> PersonalMeshRestartEvidence {
        let identityBefore = senderIdentity.id
        let fingerprintBefore = Self.keyFingerprint(senderIdentity)
        let oldSecretID = ObjectIdentifier(senderSecretStore)
        let oldTrustID = ObjectIdentifier(senderTrust)
        let oldDirectoryID = ObjectIdentifier(candidateDirectory)
        let oldConnectorID = ObjectIdentifier(connector)
        let oldConnector = connector

        await runtimeLease.retire()
        await coordinator.shutdownForRestart()
        await senderRegistry.stop()
        try await senderDatabase.close()

        let reopenedSecrets = try FileSecretStore(
            root: senderRoot.appendingPathComponent("secrets", isDirectory: true)
        )
        let reopenedIdentity = try DeviceIdentity.loadOrCreate(keychain: reopenedSecrets)
        let reopenedTrustStore = AuthenticatedTrustSnapshotStore(
            url: senderRoot.appendingPathComponent("trust.json"),
            secrets: reopenedSecrets
        )
        let reopenedTrust = try await reopenedTrustStore.load(identity: reopenedIdentity)
        let trustLoaded = await reopenedTrust.publicKey(for: receiverID) != nil
        guard reopenedIdentity.id == identityBefore, trustLoaded else {
            throw TwoClientHarnessError.restartUnsupported
        }
        let reopenedDirectory = PersonalMeshCandidates(candidateValues)
        let reopenedRoutes = PersonalMeshRoutes(routeValues)
        let reopenedRegistry = MeshConnectionRegistry(trustRepository: reopenedTrust)
        let productionConnector = MeshTransferConnector(
            identity: reopenedIdentity,
            trustRepository: reopenedTrust,
            directory: reopenedDirectory,
            routes: reopenedRoutes,
            opener: network,
            registry: reopenedRegistry
        )
        let reopenedLease = PersonalMeshRuntimeLease()
        let reopenedConnector = PersonalMeshRecordingConnector(
            base: productionConnector,
            network: network,
            lease: reopenedLease
        )
        let reopenedDatabase = try TransferDatabase(
            url: senderRoot.appendingPathComponent("history.sqlite")
        )
        await network.restore()
        let restored = try await TransferCoordinator.restoring(
            connector: reopenedConnector,
            database: reopenedDatabase,
            outgoingDirectory: senderRoot.appendingPathComponent("outgoing", isDirectory: true),
            maximumConnectionAttempts: 8,
            persistenceRetryDelay: .milliseconds(20),
            resumeObserver: resumeRecorder
        )

        senderSecretStore = reopenedSecrets
        senderIdentity = reopenedIdentity
        senderTrustStore = reopenedTrustStore
        senderTrust = reopenedTrust
        candidateDirectory = reopenedDirectory
        senderRegistry = reopenedRegistry
        runtimeLease = reopenedLease
        connector = reopenedConnector
        senderDatabase = reopenedDatabase
        coordinator = restored
        await sender.install(restored)

        let oldRuntimeRejectedUse: Bool
        do {
            try await oldConnector.requireActive()
            oldRuntimeRejectedUse = false
        } catch TwoClientHarnessError.runtimeRetired {
            oldRuntimeRejectedUse = true
        }
        return PersonalMeshRestartEvidence(
            identityBefore: identityBefore,
            identityAfter: reopenedIdentity.id,
            identityKeyFingerprintBefore: fingerprintBefore,
            identityKeyFingerprintAfter: Self.keyFingerprint(reopenedIdentity),
            secretStoreObjectChanged: oldSecretID != ObjectIdentifier(reopenedSecrets),
            trustRepositoryObjectChanged: oldTrustID != ObjectIdentifier(reopenedTrust),
            candidateDirectoryObjectChanged: oldDirectoryID != ObjectIdentifier(reopenedDirectory),
            connectorObjectChanged: oldConnectorID != ObjectIdentifier(reopenedConnector),
            databaseWasClosedAndReopened: true,
            trustLoadedFromDisk: trustLoaded,
            oldRuntimeRejectedUse: oldRuntimeRejectedUse
        )
    }

    func resumeEvidence(
        after interruption: NetworkInterruptionEvidence,
        totalPayloadBytes: Int64
    ) async throws -> PersonalMeshResumeEvidence {
        let wire = await network.wireEvidence(afterConnectionCount: interruption.connectionCount)
        let negotiations = await resumeRecorder.values(
            transferID: interruption.transferID,
            connectionIDs: Set(wire.map(\.id))
        )
        guard !wire.isEmpty, !negotiations.isEmpty else {
            throw TwoClientHarnessError.interruptionDidNotOccur
        }
        let maximumChunk = Int64(TransferProtocolLimits.maximumChunkBytes)
        let maximumFrame = Int64(TransferProtocolLimits.maximumWireFrameBytes)
        var maximumWire: Int64 = 0
        for item in wire {
            guard let negotiation = negotiations.first(where: { $0.connectionID == item.id }) else {
                maximumWire += maximumFrame * 2
                continue
            }
            let accepted = Int64(negotiation.negotiation.acceptedBytes)
            let remaining = max(0, totalPayloadBytes - accepted)
            let chunks = (remaining + maximumChunk - 1) / maximumChunk
            maximumWire += remaining + chunks * (84 + 33) + maximumFrame * 6
        }
        return PersonalMeshResumeEvidence(
            acceptedBytes: Int64(negotiations.map(\.negotiation.acceptedBytes).min() ?? 0),
            acceptedMapChunkCount: negotiations.map(\.negotiation.resumeMap.chunkCount).min() ?? 0,
            newConnectionWireBytes: wire.reduce(0) { $0 + $1.bytes },
            maximumPermittedWireBytes: maximumWire,
            newConnectionCount: wire.count
        )
    }

    private static func keyFingerprint(_ identity: DeviceIdentity) -> String {
        SHA256.hash(data: identity.publicKey.rawRepresentation)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func shutdownAndRemoveRoot() async throws {
        guard await cleanupState.begin() else { return }
        await incoming.stop()
        await source.stop()
        await thirdIncoming?.stop()
        await thirdSource?.stop()
        await coordinator.shutdownForRestart()
        await senderRegistry.stop()
        await receiverRegistry.stop()
        await thirdRegistry?.stop()
        try await senderDatabase.close()
        try await receiverDatabase.close()
        try await thirdDatabase?.close()
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        guard !FileManager.default.fileExists(atPath: root.path) else {
            throw TwoClientHarnessError.fileGenerationFailed
        }
    }
}

private actor PersonalMeshReceiveResults {
    private var values: [TransferID: TransferReceiveResult] = [:]
    private var failures: [TransferID: IncomingTransferFailure] = [:]

    func record(_ result: TransferReceiveResult?) {
        guard let result else { return }
        values[result.transferID] = result
    }

    func record(_ failure: IncomingTransferFailure, transferID: TransferID) {
        failures[transferID] = failure
    }

    func result(for transferID: TransferID) -> TransferReceiveResult? { values[transferID] }
    func failure(for transferID: TransferID) -> IncomingTransferFailure? { failures[transferID] }
}

private actor PersonalMeshCleanupState {
    private var started = false
    func begin() -> Bool {
        guard !started else { return false }
        started = true
        return true
    }
}

private actor PersonalMeshRecordingConnector: TransferAwarePeerConnector {
    private let base: MeshTransferConnector
    private let network: PersonalMeshLoopbackNetwork
    private let lease: PersonalMeshRuntimeLease
    private var establishedRoutes: [ConnectionRoute] = []

    init(
        base: MeshTransferConnector,
        network: PersonalMeshLoopbackNetwork,
        lease: PersonalMeshRuntimeLease
    ) {
        self.base = base
        self.network = network
        self.lease = lease
    }

    func connect(to device: DeviceID) async throws -> any SecureChannel {
        try await lease.requireActive()
        let channel = try await base.connect(to: device)
        await network.markLatestSecure()
        establishedRoutes.append(channel.route)
        return channel
    }

    func connect(to device: DeviceID, transferID: TransferID) async throws -> any SecureChannel {
        try await lease.requireActive()
        let channel = try await base.connect(to: device, transferID: transferID)
        await network.markLatestSecure()
        establishedRoutes.append(channel.route)
        return channel
    }

    func routes() -> [ConnectionRoute] { establishedRoutes }
    func requireActive() async throws { try await lease.requireActive() }
}

private actor PersonalMeshRuntimeLease {
    private var active = true
    func requireActive() throws {
        guard active else { throw TwoClientHarnessError.runtimeRetired }
    }
    func retire() { active = false }
}

private actor PersonalMeshResumeRecorder: TransferResumeNegotiationObserving {
    struct Entry: Sendable {
        let connectionID: UUID
        let negotiation: TransferResumeNegotiation
    }

    private let network: PersonalMeshLoopbackNetwork
    private var entries: [Entry] = []

    init(network: PersonalMeshLoopbackNetwork) { self.network = network }

    func recordResumeNegotiation(_ value: TransferResumeNegotiation) async {
        guard let connectionID = await network.latestConnectionID() else { return }
        entries.append(Entry(connectionID: connectionID, negotiation: value))
    }

    func values(transferID: TransferID, connectionIDs: Set<UUID>) -> [Entry] {
        entries.filter {
            $0.negotiation.transferID == transferID && connectionIDs.contains($0.connectionID)
        }
    }
}

private actor PersonalMeshCandidates: MeshPeerCandidateProviding {
    private let values: [DeviceID: MeshPeerCandidate]
    init(_ values: [DeviceID: MeshPeerCandidate]) { self.values = values }
    func candidate(for device: DeviceID) -> MeshPeerCandidate? { values[device] }
}

private actor PersonalMeshRoutes: MeshRouteEvidenceProviding {
    private let values: [String: TailscaleConnectionKind]
    init(_ values: [String: TailscaleConnectionKind]) { self.values = values }
    func connectionKind(to nodeID: String) -> TailscaleConnectionKind { values[nodeID] ?? .unknown }
}

private actor PersonalMeshListenerTransport: MeshListenerTransport {
    private var callback: (@Sendable (any MeshByteConnection) -> Void)?

    func start(
        binding: MeshListenerBinding,
        onConnection: @escaping @Sendable (any MeshByteConnection) -> Void
    ) {
        callback = onConnection
    }

    func stop() { callback = nil }
    func inject(_ connection: any MeshByteConnection) { callback?(connection) }
}

private actor PersonalMeshLoopbackNetwork: MeshTransferConnectionOpening {
    struct WireEvidence: Sendable {
        let id: UUID
        let bytes: Int64
    }

    private let destinations: [String: PersonalMeshListenerTransport]
    private var links: [UUID: PersonalMeshMemoryLink] = [:]
    private var connectionOrder: [UUID] = []
    private var secureConnections: Set<UUID> = []
    private var shouldTamperNextCiphertext = false
    private var ciphertextMutations = 0
    private var bytesByConnection: [UUID: Int64] = [:]
    private var online = true

    init(destinations: [String: PersonalMeshListenerTransport]) {
        self.destinations = destinations
    }

    static func key(_ endpoint: NWEndpoint) -> String { String(describing: endpoint) }

    func open(endpoint: NWEndpoint) async throws -> any MeshByteConnection {
        guard online else { throw MeshTransferConnectionError.unavailablePeer }
        guard let destination = destinations[Self.key(endpoint)] else {
            throw MeshTransferConnectionError.unavailablePeer
        }
        let identifier = UUID()
        let link = PersonalMeshMemoryLink(identifier: identifier, network: self)
        links[identifier] = link
        connectionOrder.append(identifier)
        bytesByConnection[identifier] = 0
        let endpoints = await link.endpoints()
        await destination.inject(endpoints.receiver)
        return endpoints.sender
    }

    func markLatestSecure() {
        guard let latest = connectionOrder.last else { return }
        secureConnections.insert(latest)
    }

    func tamperNextCiphertext() { shouldTamperNextCiphertext = true }

    func transform(_ data: Data, connection: UUID, senderSide: Bool) -> Data {
        if senderSide { bytesByConnection[connection, default: 0] += Int64(data.count) }
        guard senderSide,
            secureConnections.contains(connection),
            shouldTamperNextCiphertext,
            !data.isEmpty
        else { return data }
        shouldTamperNextCiphertext = false
        ciphertextMutations += 1
        var mutated = data
        mutated[mutated.index(before: mutated.endIndex)] ^= 0x01
        return mutated
    }

    func tamperedCiphertextCount() -> Int { ciphertextMutations }

    func latestConnectionID() -> UUID? { connectionOrder.last }
    func connectionCount() -> Int { connectionOrder.count }

    func interrupt() async -> Int {
        online = false
        let current = Array(links.values)
        for link in current { await link.closeBoth() }
        return current.count
    }

    func restore() { online = true }

    func wireEvidence(afterConnectionCount count: Int) -> [WireEvidence] {
        guard count >= 0, count <= connectionOrder.count else { return [] }
        return connectionOrder.dropFirst(count).map {
            WireEvidence(id: $0, bytes: bytesByConnection[$0] ?? 0)
        }
    }
}

private actor PersonalMeshMemoryLink {
    private let identifier: UUID
    private let network: PersonalMeshLoopbackNetwork
    private var buffers: [Bool: Data] = [false: Data(), true: Data()]
    private var waiters: [Bool: [PersonalMeshMemoryWaiter]] = [false: [], true: []]
    private var closed: Set<Bool> = []

    init(identifier: UUID, network: PersonalMeshLoopbackNetwork) {
        self.identifier = identifier
        self.network = network
    }

    func endpoints() -> (
        sender: PersonalMeshMemoryConnection,
        receiver: PersonalMeshMemoryConnection
    ) {
        (
            PersonalMeshMemoryConnection(side: false, link: self),
            PersonalMeshMemoryConnection(side: true, link: self)
        )
    }

    func send(_ data: Data, side: Bool) async throws {
        guard !closed.contains(side), !closed.contains(!side) else {
            throw MeshWireError.connectionClosed
        }
        try await Task.sleep(for: .microseconds(250))
        let data = await network.transform(data, connection: identifier, senderSide: !side)
        let target = !side
        buffers[target, default: Data()].append(data)
        if let waiter = waiters[target]?.first {
            waiters[target]?.removeFirst()
            waiter.continuation.resume(returning: take(side: target, maximum: waiter.maximum)!)
        }
    }

    func receive(side: Bool, maximum: Int) async throws -> Data {
        if let bytes = take(side: side, maximum: maximum) { return bytes }
        return try await withCheckedThrowingContinuation { continuation in
            waiters[side, default: []].append(
                PersonalMeshMemoryWaiter(maximum: maximum, continuation: continuation)
            )
        }
    }

    func close(side: Bool) {
        guard closed.insert(side).inserted else { return }
        for target in [false, true] {
            let current = waiters[target, default: []]
            waiters[target] = []
            for waiter in current {
                waiter.continuation.resume(throwing: MeshWireError.connectionClosed)
            }
        }
    }

    func closeBoth() {
        close(side: false)
        close(side: true)
    }

    private func take(side: Bool, maximum: Int) -> Data? {
        guard !buffers[side, default: Data()].isEmpty else {
            return closed.contains(side) || closed.contains(!side) ? Data() : nil
        }
        let count = min(maximum, buffers[side, default: Data()].count)
        let bytes = Data(buffers[side, default: Data()].prefix(count))
        buffers[side]?.removeFirst(count)
        return bytes
    }
}

private struct PersonalMeshMemoryWaiter {
    let maximum: Int
    let continuation: CheckedContinuation<Data, Error>
}

private final class PersonalMeshMemoryConnection: MeshByteConnection, @unchecked Sendable {
    private let side: Bool
    private let link: PersonalMeshMemoryLink

    init(side: Bool, link: PersonalMeshMemoryLink) {
        self.side = side
        self.link = link
    }

    func send(_ bytes: Data) async throws { try await link.send(bytes, side: side) }
    func receive(minimum: Int, maximum: Int) async throws -> Data {
        try await link.receive(side: side, maximum: maximum)
    }
    func close() async { await link.close(side: side) }
}
