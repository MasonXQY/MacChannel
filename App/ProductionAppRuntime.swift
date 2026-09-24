import AppKit
import Darwin
import Foundation
import MacChannelCore

struct ProductionRuntimeConfiguration {
    let namespace: RuntimeNamespace
    let dataDirectory: URL
    let rendezvousWebSocketURL: URL?
    let rendezvousHTTPOrigin: URL?
    let environmentRendezvousURL: String?
    let packagedRendezvousURL: String
    let ice: ICEConfiguration
    let bonjourPort: UInt16
    let identityPolicy: KeychainPolicy
    let account: MacAccountRuntimeConfiguration?
    let isIsolatedLaunchTest: Bool

    var outgoingDirectory: URL {
        dataDirectory.appendingPathComponent("Outgoing", isDirectory: true)
    }

    var incomingDirectory: URL {
        dataDirectory.appendingPathComponent("Incoming", isDirectory: true)
    }

    static func current(
        namespace: RuntimeNamespace,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) throws -> ProductionRuntimeConfiguration {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let launchTestMarker: String? = arguments.firstIndex(of: "--production-launch-test")
            .flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        let directory =
            launchTestMarker.map {
                URL(fileURLWithPath: $0).appendingPathExtension("runtime")
            } ?? applicationSupport.appendingPathComponent(namespace.applicationSupportComponent, isDirectory: true)
        let identityPolicy =
            launchTestMarker.map { marker in
                let suffix = URL(fileURLWithPath: marker).lastPathComponent
                    .filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
                return KeychainPolicy(
                    service: "\(namespace.identityPolicy.service).launch-test.\(suffix)",
                    accessGroup: namespace.identityPolicy.accessGroup,
                    accessibility: .afterFirstUnlockThisDeviceOnly,
                    synchronizable: false
                )
            } ?? namespace.identityPolicy
        let resource =
            Bundle.module.url(
                forResource: "RuntimeConfig",
                withExtension: "json",
                subdirectory: "Resources"
            ) ?? Bundle.module.url(forResource: "RuntimeConfig", withExtension: "json")
        guard let resource else { throw ProductionRuntimeError.missingRuntimeConfiguration }
        struct RuntimeConfigWire: Decodable {
            let rendezvousURL: String
            let accountServiceOrigin: String?
            let accountAudience: String?
        }
        let wire = try JSONDecoder().decode(
            RuntimeConfigWire.self,
            from: Data(contentsOf: resource)
        )
        let packaged = wire.rendezvousURL
        let environmentURL = launchTestMarker == nil
            ? nil
            : environment["MACCHANNEL_RENDEZVOUS_URL"]
        let endpoints = try RendezvousEndpointConfiguration.parse(environmentURL ?? packaged)
        let stunURLs =
            (launchTestMarker == nil ? nil : environment["MACCHANNEL_STUN_URLS"])?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        let port = environment["MACCHANNEL_BONJOUR_PORT"].flatMap(UInt16.init) ?? 45_873
        let account: MacAccountRuntimeConfiguration?
        if let rawOrigin = wire.accountServiceOrigin, let audience = wire.accountAudience,
            !isLaunchTest(arguments)
        {
            guard let origin = URL(string: rawOrigin) else {
                throw ProductionRuntimeError.missingRuntimeConfiguration
            }
            account = try MacAccountRuntimeConfiguration(
                origin: origin, audience: audience)
        } else {
            account = nil
        }
        return ProductionRuntimeConfiguration(
            namespace: namespace,
            dataDirectory: directory,
            rendezvousWebSocketURL: endpoints.webSocketURL,
            rendezvousHTTPOrigin: endpoints.httpOrigin,
            environmentRendezvousURL: environmentURL,
            packagedRendezvousURL: packaged,
            ice: ICEConfiguration(stunURLs: stunURLs, turnServers: []),
            bonjourPort: port,
            identityPolicy: identityPolicy,
            account: account,
            isIsolatedLaunchTest: launchTestMarker != nil
        )
    }

    private static func isLaunchTest(_ arguments: [String]) -> Bool {
        arguments.contains("--production-launch-test")
    }

    func endpoints() throws -> RendezvousEndpointConfiguration {
        try RendezvousEndpointConfiguration.parse(
            environmentRendezvousURL ?? packagedRendezvousURL
        )
    }
}

enum ProductionRuntimeError: Error {
    case insecureRendezvousURL
    case missingRuntimeConfiguration
    case invalidTrustGeneration
}

struct RendezvousEndpointConfiguration: Equatable {
    static let packagedDefault = "wss://channel.zensys-tech.com/v1/ws"

    let webSocketURL: URL
    let httpOrigin: URL

    static func isValid(_ value: String) -> Bool {
        (try? parse(value)) != nil
    }

    static func parse(_ value: String) throws -> RendezvousEndpointConfiguration {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(),
            scheme == "https" || scheme == "wss",
            let host = components.host,
            !host.isEmpty,
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            components.path.isEmpty || components.path == "/" || components.path == "/v1/ws"
        else { throw ProductionRuntimeError.insecureRendezvousURL }
        components.scheme = "wss"
        components.path = "/v1/ws"
        guard let webSocketURL = components.url else {
            throw ProductionRuntimeError.insecureRendezvousURL
        }
        components.scheme = "https"
        components.path = ""
        guard let httpOrigin = components.url else {
            throw ProductionRuntimeError.insecureRendezvousURL
        }
        return RendezvousEndpointConfiguration(
            webSocketURL: webSocketURL,
            httpOrigin: httpOrigin
        )
    }
}

@MainActor
final class ProductionAppRuntimeBuilder: AppRuntimeBuilding {
    private let configuration: ProductionRuntimeConfiguration

    init(configuration: ProductionRuntimeConfiguration) {
        self.configuration = configuration
    }

    convenience init(namespace: RuntimeNamespace) throws {
        try self.init(configuration: .current(namespace: namespace))
    }

    func build() async throws -> AppRuntimeLaunch {
        let runtime = try await ProductionAppRuntime.bootstrap(configuration: configuration)
        return AppRuntimeLaunch(runtime: runtime, status: runtime.initialStatus)
    }
}

@MainActor
final class ProductionAppRuntime: AppRuntimeLifecycle {
    let container: AppContainer
    let initialStatus: AppRuntimeStatus

    private let browser: BonjourPeerBrowser?
    private let advertiser: BonjourPeerAdvertiser?
    private let trustPersistenceTask: Task<Void, Never>
    private let historySource: RuntimeHistorySource
    private let receiveEvents: RuntimeReceiveEventSource
    private let statusSource: RuntimeStatusSource
    private let publicServiceLifecycle: AuthenticatedPresenceSupervisor?
    private let accountServiceLifecycle: AuthenticatedPresenceSupervisor?
    private let accountLifecycle: AccountForegroundLifecycle?
    private let dualPlaneProjection: MacDualPlaneProjection?
    private let dualPlaneConnector: MacDualPlaneConnector?
    private let publicServiceStatusTask: Task<Void, Never>?
    private let publicServiceTrustTask: Task<Void, Never>?
    private let signalSession: PresenceSignalBridge?
    private let pairingTransport: RendezvousPairingTransport?
    private let connectionListener: WebRTCConnectionListener?
    private let accountConnectionListener: WebRTCConnectionListener?
    private let incomingController: IncomingRuntimeController?
    private let transferCoordinator: TransferCoordinator?
    private let trustRepository: TrustRepository
    private let trustStore: any TrustSnapshotPersisting
    private let launchTestKeychain: KeychainStore?
    private let launchTestDataDirectory: URL?
    private var stopped = false
    private let trustSaveRetry = RuntimeTrustSaveRetry()
    private var localNetworkStarted = false

    init(
        container: AppContainer,
        initialStatus: AppRuntimeStatus,
        browser: BonjourPeerBrowser?,
        advertiser: BonjourPeerAdvertiser?,
        trustPersistenceTask: Task<Void, Never>,
        historySource: RuntimeHistorySource,
        receiveEvents: RuntimeReceiveEventSource,
        statusSource: RuntimeStatusSource,
        publicServiceLifecycle: AuthenticatedPresenceSupervisor?,
        accountServiceLifecycle: AuthenticatedPresenceSupervisor? = nil,
        accountLifecycle: AccountForegroundLifecycle? = nil,
        dualPlaneProjection: MacDualPlaneProjection? = nil,
        dualPlaneConnector: MacDualPlaneConnector? = nil,
        publicServiceStatusTask: Task<Void, Never>?,
        publicServiceTrustTask: Task<Void, Never>?,
        signalSession: PresenceSignalBridge?,
        pairingTransport: RendezvousPairingTransport?,
        connectionListener: WebRTCConnectionListener?,
        accountConnectionListener: WebRTCConnectionListener? = nil,
        incomingController: IncomingRuntimeController?,
        transferCoordinator: TransferCoordinator?,
        trustRepository: TrustRepository,
        trustStore: any TrustSnapshotPersisting,
        launchTestKeychain: KeychainStore?,
        launchTestDataDirectory: URL?
    ) {
        self.container = container
        self.initialStatus = initialStatus
        self.browser = browser
        self.advertiser = advertiser
        self.trustPersistenceTask = trustPersistenceTask
        self.historySource = historySource
        self.receiveEvents = receiveEvents
        self.statusSource = statusSource
        self.publicServiceLifecycle = publicServiceLifecycle
        self.accountServiceLifecycle = accountServiceLifecycle
        self.accountLifecycle = accountLifecycle
        self.dualPlaneProjection = dualPlaneProjection
        self.dualPlaneConnector = dualPlaneConnector
        self.publicServiceStatusTask = publicServiceStatusTask
        self.publicServiceTrustTask = publicServiceTrustTask
        self.signalSession = signalSession
        self.pairingTransport = pairingTransport
        self.connectionListener = connectionListener
        self.accountConnectionListener = accountConnectionListener
        self.incomingController = incomingController
        self.transferCoordinator = transferCoordinator
        self.trustRepository = trustRepository
        self.trustStore = trustStore
        self.launchTestKeychain = launchTestKeychain
        self.launchTestDataDirectory = launchTestDataDirectory
    }

    static func bootstrap(
        configuration: ProductionRuntimeConfiguration
    ) async throws -> ProductionAppRuntime {
        let cleanup = RuntimeBootstrapCleanup()
        do {
            let runtime = try await build(configuration: configuration, cleanup: cleanup)
            cleanup.disarm()
            return runtime
        } catch {
            await cleanup.run()
            throw error
        }
    }

    private static func build(
        configuration: ProductionRuntimeConfiguration,
        cleanup: RuntimeBootstrapCleanup
    ) async throws -> ProductionAppRuntime {
        try FileManager.default.createDirectory(
            at: configuration.dataDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let keychain = KeychainStore(policy: configuration.identityPolicy)
        if configuration.isIsolatedLaunchTest {
            cleanup.push {
                try? keychain.removeAll()
                try? FileManager.default.removeItem(at: configuration.dataDirectory)
            }
        }
        let identity = try DeviceIdentity.loadOrCreate(
            keychain: keychain,
            policy: configuration.identityPolicy
        )
        let authorizationOwner = PeerAuthorizationOwner.live(identity: identity)
        let trustStore = AuthenticatedTrustSnapshotStore(
            url: configuration.dataDirectory.appendingPathComponent("trust.json"),
            secrets: keychain,
            policy: configuration.identityPolicy
        )
        let trustRepository = try await trustStore.load(
            identity: identity, authorizationOwner: authorizationOwner)
        let currentTrust = await trustRepository.currentTrustStore()
        let directory = DeviceDirectory(trust: currentTrust)
        await directory.observeAuthorization(authorizationOwner)
        let manualDirectory = DeviceDirectory(trust: currentTrust)
        await manualDirectory.observeTrust(trustRepository)

        let settingsStore = try RuntimeSettingsStore(
            url: configuration.dataDirectory.appendingPathComponent("settings.json"),
            trustedDevices: currentTrust.trustedDeviceIDs.subtracting([identity.id]),
            authorization: SecurityScopedDirectoryStore(mode: configuration.namespace.directoryAuthorizationMode, namespace: configuration.namespace.applicationSupportComponent),
            defaultReceiveFolderName: configuration.namespace.defaultReceiveFolderName
        )
        let settingsSnapshot = await settingsStore.current()
        let database = try TransferDatabase(
            url: configuration.dataDirectory.appendingPathComponent("transfers.sqlite3")
        )
        let outputLocator = try RuntimeOutputLocator(
            url: configuration.dataDirectory.appendingPathComponent("received-outputs.json")
        )
        let history = RuntimeHistorySource(
            database: database,
            settings: settingsStore,
            outputLocator: outputLocator
        )
        let receiveEvents = RuntimeReceiveEventSource()
        cleanup.push { await receiveEvents.finish() }
        let settingsService = ProductionDeviceSettingsService(
            store: settingsStore,
            trustRepository: trustRepository,
            trustStore: trustStore
        )
        let statusSource = RuntimeStatusSource()

        let browser = BonjourPeerBrowser(
            directory: directory,
            trust: DeviceTrust(trustedIDs: currentTrust.trustedDeviceIDs)
        )
        browser.observeAuthorization(authorizationOwner)
        cleanup.push { await browser.stop() }
        let advertiser = try BonjourPeerAdvertiser(
            device: identity.id,
            port: configuration.bonjourPort
        ) { connection in
            // The authenticated WebRTC listener owns transfer channels. This
            // advertised TCP endpoint is discovery evidence only.
            connection.cancel()
        }
        cleanup.push { await advertiser.stopAndWait() }

        let trustPersistenceTask = Task {
            let updates = await trustRepository.updates()
            for await _ in updates {
                guard !Task.isCancelled else { return }
                do {
                    try await trustStore.persistLatest(from: trustRepository)
                    statusSource.clearTrustSaveFailure()
                } catch {
                    statusSource.yield(.serviceError(.statusTrustSaveFailed))
                }
            }
        }
        cleanup.push {
            trustPersistenceTask.cancel()
            await trustPersistenceTask.value
        }

        let configuredEndpoints = try configuration.endpoints()

        let webSocketURL = configuredEndpoints.webSocketURL
        let httpOrigin = configuredEndpoints.httpOrigin

        let httpSession = URLSession(configuration: .ephemeral)
        let pairingTransport = try RendezvousPairingTransport(
            identity: identity,
            origin: httpOrigin,
            session: httpSession
        )
        cleanup.push { await pairingTransport.stop() }
        let pairingCoordinator = try PairingCoordinator(
            identity: identity,
            displayName: settingsSnapshot.localDisplayName,
            trustRepository: trustRepository,
            transport: pairingTransport
        )
        let pairingService = PersistingPairingSurfaceService(
            coordinator: pairingCoordinator,
            settings: settingsStore,
            trustStore: trustStore,
            trustRepository: trustRepository
        )

        let accountRuntime = try configuration.account.map {
            try MacAccountRuntime.make(
                configuration: $0, identity: identity, authorizationOwner: authorizationOwner)
        }
        let accountDirectory = accountRuntime.map { _ in
            DeviceDirectory(trust: DeviceTrust(trustedIDs: []))
        }
        if let accountDirectory { await accountDirectory.observeAuthorization(authorizationOwner) }
        let dualPlaneProjection = accountDirectory.map {
            MacDualPlaneProjection(manual: manualDirectory, account: $0, destination: directory)
        }
        await dualPlaneProjection?.start()
        cleanup.push { await dualPlaneProjection?.stop() }

        let publicServiceLifecycle = AuthenticatedPresenceSupervisor(
            identity: identity, repository: trustRepository, directory: manualDirectory,
            origin: webSocketURL,
            makeSocket: { try URLSessionPresenceWebSocket(origin: webSocketURL) },
            sleep: { try await Task.sleep(for: $0) },
            onState: { state in
                await MainActor.run { statusSource.updatePresence(state, account: false) }
            },
            onTrustSyncState: { state in
                await MainActor.run { statusSource.updateTrustSync(state) }
            },
            publication: { await trustRepository.publicationSnapshot(persisted: trustStore.persistedState()) },
            persistedUpdates: { await trustStore.persistedUpdates() }
        )
        let signalSession = publicServiceLifecycle.bridge
        cleanup.push { await publicServiceLifecycle.stop() }

        let accountServiceLifecycle: AuthenticatedPresenceSupervisor?
        if let accountConfiguration = configuration.account,
            let accountRuntime, let accountDirectory
        {
            let accountOrigin = accountConfiguration.webSocketOrigin
            accountServiceLifecycle = AuthenticatedPresenceSupervisor(
                identity: identity, repository: trustRepository, directory: accountDirectory,
                origin: accountOrigin,
                makeSocket: { try URLSessionPresenceWebSocket(origin: accountOrigin) },
                sleep: { try await Task.sleep(for: $0) },
                onState: { state in
                    await MainActor.run { statusSource.updatePresence(state, account: true) }
                },
                publication: { TrustPublicationSnapshot(records: []) },
                accountController: accountRuntime.controller)
            cleanup.push { await accountServiceLifecycle?.stop() }
        } else {
            accountServiceLifecycle = nil
        }

        let signaling = RendezvousWebRTCSignaling(session: signalSession)
        let turnClient = try RendezvousTURNCredentialClient(
            identity: identity,
            origin: httpOrigin,
            session: httpSession
        )
        let iceProvider = RefreshingICEConfigurationProvider(
            base: configuration.ice,
            fetcher: turnClient
        )
        let manualConnector = ConnectionCoordinator(attempts: WebRTCConnectionAttempts(
            directory: directory, identity: identity,
            authorizationProvider: authorizationOwner,
            signaling: signaling, iceProvider: iceProvider))
        let accountConnectionListener: WebRTCConnectionListener?
        let dualPlaneConnector: MacDualPlaneConnector?
        let selectedConnector: any RouteEscalatingPeerConnector
        if let accountRuntime, let accountServiceLifecycle {
            let accountSignaling = RendezvousWebRTCSignaling(session: accountServiceLifecycle.bridge)
            let accountICE = MacAccountICEProvider(
                fetcher: AccountTURNCredentialFetcher(controller: accountRuntime.controller))
            let accountConnector = ConnectionCoordinator(attempts: WebRTCConnectionAttempts(
                directory: directory, identity: identity,
                authorizationProvider: authorizationOwner,
                signaling: accountSignaling, iceProvider: accountICE))
            let selector = MacDualPlaneConnector(
                repository: trustRepository, authorization: authorizationOwner,
                manual: manualConnector, account: accountConnector)
            dualPlaneConnector = selector
            selectedConnector = selector
            let listener = WebRTCConnectionListener(
                directory: directory, identity: identity,
                authorizationProvider: authorizationOwner,
                signaling: accountSignaling, iceProvider: accountICE)
            accountConnectionListener = listener
            cleanup.push { await listener.stop() }
        } else {
            dualPlaneConnector = nil
            selectedConnector = manualConnector
            accountConnectionListener = nil
        }
        let transferCoordinator = try await TransferCoordinator.restoring(
            connector: selectedConnector,
            database: database,
            outgoingDirectory: configuration.outgoingDirectory
        )
        cleanup.push { await transferCoordinator.shutdownForRestart() }
        let connectionListener = WebRTCConnectionListener(
            directory: directory,
            identity: identity,
            authorizationProvider: authorizationOwner,
            signaling: signaling,
            iceProvider: iceProvider
        )
        cleanup.push { await connectionListener.stop() }
        let incomingSources: [any IncomingTransferConnectionSource] = accountConnectionListener.map {
            [connectionListener, $0]
        } ?? [connectionListener]
        let incoming = IncomingRuntimeController(
            sources: incomingSources,
            trustRepository: trustRepository,
            authorizationProvider: authorizationOwner,
            settings: settingsStore,
            database: database,
            incomingDirectory: configuration.incomingDirectory,
            ownerID: identity.id,
            onReceiveFinished: makeReceiveFinishedHandler(
                recordInboundResult: { result in await history.recordInboundResult(result) },
                publishReceiveEvent: { result in await receiveEvents.publish(result) }
            )
        )
        await incoming.start()
        cleanup.push { await incoming.stop() }
        settingsService.onReceiveConfigurationChanged = { await incoming.restart() }
        pairingService.onReceiveConfigurationChanged = { await incoming.restart() }
        await accountRuntime?.lifecycle.start()
        await publicServiceLifecycle.start()
        await accountServiceLifecycle?.start()
        await history.start(snapshots: { await transferCoordinator.snapshots() })
        cleanup.push { await history.stop() }
        let container = AppContainer(
            deviceDirectory: directory,
            transferCoordinator: transferCoordinator,
            pairingSurfaceService: pairingService,
            settingsSurfaceService: settingsService,
            transferSnapshots: { await transferCoordinator.snapshots() },
            durablePairingStates: pairingService.durableStates,
            initialSettingsSnapshot: settingsSnapshot,
            settingsSnapshots: { await settingsStore.snapshots() },
            transferHistory: { await history.stream() },
            receiveEvents: { await receiveEvents.stream() },
            receiveCompletionState: receiveEvents.completionState,
            runtimeIdentityID: identity.id,
            accountController: accountRuntime?.controller,
            localNetworkState: { (browser.state(), advertiser.state()) },
            localNetworkStates: { (browser.states(), advertiser.states()) },
            sourceAccess: configuration.namespace.directoryAuthorizationMode == .securityScopedBookmarks ? UserSelectedSourceAccess() : nil
        )
        return ProductionAppRuntime(
            container: container,
            initialStatus: .serviceOffline(.statusServiceConnecting),
            browser: browser,
            advertiser: advertiser,
            trustPersistenceTask: trustPersistenceTask,
            historySource: history,
            receiveEvents: receiveEvents,
            statusSource: statusSource,
            publicServiceLifecycle: publicServiceLifecycle,
            accountServiceLifecycle: accountServiceLifecycle,
            accountLifecycle: accountRuntime?.lifecycle,
            dualPlaneProjection: dualPlaneProjection,
            dualPlaneConnector: dualPlaneConnector,
            publicServiceStatusTask: nil,
            publicServiceTrustTask: nil,
            signalSession: signalSession,
            pairingTransport: pairingTransport,
            connectionListener: connectionListener,
            accountConnectionListener: accountConnectionListener,
            incomingController: incoming,
            transferCoordinator: transferCoordinator,
            trustRepository: trustRepository,
            trustStore: trustStore,
            launchTestKeychain: configuration.isIsolatedLaunchTest ? keychain : nil,
            launchTestDataDirectory: configuration.isIsolatedLaunchTest
                ? configuration.dataDirectory
                : nil
        )
    }

    func shutdown() async {
        guard !stopped else { return }
        stopped = true
        await trustSaveRetry.stop()
        await container.pairingSurfaceService.stopObservation()
        await receiveEvents.finish()
        await historySource.stop()
        publicServiceTrustTask?.cancel()
        await dualPlaneConnector?.stop()
        await publicServiceLifecycle?.stop()
        await accountServiceLifecycle?.stop()
        await accountLifecycle?.stop()
        await dualPlaneProjection?.stop()
        await publicServiceTrustTask?.value
        publicServiceStatusTask?.cancel()
        await publicServiceStatusTask?.value
        if let incomingController { await incomingController.stop() }
        if let connectionListener { await connectionListener.stop() }
        if let accountConnectionListener { await accountConnectionListener.stop() }
        if let transferCoordinator { await transferCoordinator.shutdownForRestart() }
        await signalSession?.finish()
        if let pairingTransport { await pairingTransport.stop() }
        do {
            try await trustStore.persistLatest(from: trustRepository)
        } catch {
            statusSource.yield(.serviceError(.statusTrustSaveFailed))
        }
        trustPersistenceTask.cancel()
        await trustPersistenceTask.value
        if let browser { await browser.stop() }
        if let advertiser { await advertiser.stopAndWait() }
        try? launchTestKeychain?.removeAll()
        if let launchTestDataDirectory {
            try? FileManager.default.removeItem(at: launchTestDataDirectory)
        }
        statusSource.finish()
    }

    func statusUpdates() -> AsyncStream<AppRuntimeStatus>? { statusSource.stream }
    func presenceUpdates() -> AsyncStream<RuntimePresenceSnapshot>? { statusSource.presenceStream }

    func reconnectPublicService() async {
        await publicServiceLifecycle?.retryConnection()
        await accountServiceLifecycle?.retryConnection()
        if localNetworkStarted {
            browser?.start()
            advertiser?.start()
        }
    }

    func retryTrustPersistence() async {
        guard !stopped else { return }
        await trustSaveRetry.run(save: { [trustStore, trustRepository] in
            try await trustStore.persistLatest(from: trustRepository)
        }, completed: { [weak self] saved in
            guard let self, !self.stopped else { return }
            if saved {
                self.statusSource.clearTrustSaveFailure()
                await self.publicServiceLifecycle?.refreshTrust()
            } else { self.statusSource.yield(.serviceError(.statusTrustSaveFailed)) }
        })
    }

    func startLocalNetwork() async {
        guard !stopped else { return }
        localNetworkStarted = true
        browser?.start()
        advertiser?.start()
    }
}

final class RuntimeStatusSource: @unchecked Sendable {
    let presenceStream: AsyncStream<RuntimePresenceSnapshot>
    private let presenceContinuation: AsyncStream<RuntimePresenceSnapshot>.Continuation
    @MainActor private var presence = RuntimePresenceSnapshot()
    @MainActor private var manualPresence: PresenceSessionState = .inactive
    @MainActor private var accountPresence: PresenceSessionState = .inactive
    let stream: AsyncStream<AppRuntimeStatus>
    private let continuation: AsyncStream<AppRuntimeStatus>.Continuation

    init() {
        let presencePair = AsyncStream<RuntimePresenceSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        presenceStream = presencePair.stream
        presenceContinuation = presencePair.continuation
        presenceContinuation.yield(RuntimePresenceSnapshot())
        let pair = AsyncStream<AppRuntimeStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream = pair.stream
        continuation = pair.continuation
    }

    @MainActor func yield(_ status: AppRuntimeStatus) {
        if status == .serviceError(.statusTrustSaveFailed) {
            presence.trustSaveFailed = true
            presenceContinuation.yield(presence)
        }
        continuation.yield(status)
    }
    @MainActor func clearTrustSaveFailure() {
        guard presence.trustSaveFailed else { return }
        presence.trustSaveFailed = false
        presenceContinuation.yield(presence)
        continuation.yield(presence.authenticated ? .ready : .serviceOffline(.statusServiceRecovering))
    }
    @MainActor func updatePresence(_ state: PresenceSessionState, account: Bool = false) {
        if account { accountPresence = state } else { manualPresence = state }
        presence.authenticated = manualPresence == .online || accountPresence == .online
        if !presence.authenticated { presence.trustSync = .idle }
        presenceContinuation.yield(presence)
        if presence.authenticated {
            continuation.yield(.ready)
        } else if manualPresence == .connecting || manualPresence == .reconnecting
                    || accountPresence == .connecting || accountPresence == .reconnecting {
            continuation.yield(.serviceOffline(.statusServiceRecovering))
        } else {
            continuation.yield(.serviceOffline(.statusServiceOffline))
        }
    }
    @MainActor func updateTrustSync(_ state: PresenceTrustSyncState) {
        presence.trustSync = state
        presenceContinuation.yield(presence)
    }
    func finish() { continuation.finish(); presenceContinuation.finish() }
}

protocol RuntimeReceiveSettingsProviding: Sendable {
    func current() async -> SettingsSurfaceSnapshot
    func downloadDirectory() async -> DownloadDirectory
    func authorizeReceiveDirectories() async throws -> AuthorizedReceiveDirectories
    func reportDirectoryAuthorizationError(_ message: String?) async
}

extension RuntimeReceiveSettingsProviding {
    func authorizeReceiveDirectories() async throws -> AuthorizedReceiveDirectories {
        AuthorizedReceiveDirectories(directories: await downloadDirectory(), leases: [])
    }
    func reportDirectoryAuthorizationError(_ message: String?) async {}
}

actor RuntimeSettingsStore: RuntimeReceiveSettingsProviding {
    private struct DeviceWire: Codable {
        var displayName: String
        var autoAccept: Bool
        var maximumBytes: UInt64?
        var directoryPath: String?
        var directoryReference: StoredDirectoryReference?
    }
    private struct Wire: Codable {
        var schemaVersion: Int?
        var localDisplayName: String?
        var defaultDirectoryPath: String?
        var defaultDirectoryReference: StoredDirectoryReference?
        var autoReceive: Bool?
        var launchAtLogin: Bool?
        var devices: [UUID: DeviceWire]
    }

    private let url: URL
    nonisolated let authorization: SecurityScopedDirectoryStore
    private let defaultReceiveFolderName: String
    private var wire: Wire
    private var directoryAuthorizationError: String?
    private var subscribers: [UUID: AsyncStream<SettingsSurfaceSnapshot>.Continuation] = [:]

    init(
        url: URL,
        trustedDevices: Set<DeviceID>,
        authorization: SecurityScopedDirectoryStore = SecurityScopedDirectoryStore(mode: .directPath, namespace: "MacChannel"),
        defaultReceiveFolderName: String = "Mac 通道"
    ) throws {
        self.url = url
        self.authorization = authorization
        self.defaultReceiveFolderName = defaultReceiveFolderName
        let existed = FileManager.default.fileExists(atPath: url.path)
        if existed {
            wire = try JSONDecoder().decode(Wire.self, from: Data(contentsOf: url))
        } else {
            wire = Wire(
                schemaVersion: 2,
                localDisplayName: Host.current().localizedName ?? "Mac",
                defaultDirectoryPath: nil,
                autoReceive: true,
                launchAtLogin: false,
                devices: [:]
            )
        }
        wire.schemaVersion = 3
        if wire.defaultDirectoryReference == nil, let path = wire.defaultDirectoryPath {
            wire.defaultDirectoryReference = StoredDirectoryReference(path: path, bookmark: nil)
        }
        for id in wire.devices.keys {
            if wire.devices[id]?.directoryReference == nil, let path = wire.devices[id]?.directoryPath {
                wire.devices[id]?.directoryReference = StoredDirectoryReference(path: path, bookmark: nil)
            }
        }
        if wire.localDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            != false
        {
            wire.localDisplayName = Host.current().localizedName ?? "Mac"
        }
        if wire.autoReceive == nil { wire.autoReceive = true }
        if wire.launchAtLogin == nil { wire.launchAtLogin = false }
        for device in trustedDevices where wire.devices[device.rawValue] == nil {
            wire.devices[device.rawValue] = DeviceWire(
                displayName: "",
                autoAccept: true,
                maximumBytes: nil,
                directoryPath: nil
            )
        }
        try Self.persist(wire, to: url)
    }

    func current() -> SettingsSurfaceSnapshot { snapshot(wire) }

    func snapshots() -> AsyncStream<SettingsSurfaceSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            subscribers[id] = continuation
            continuation.yield(snapshot(wire))
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
        }
    }

    func rename(_ id: DeviceID, to name: String) throws {
        try mutate { candidate in
            guard candidate.devices[id.rawValue] != nil else {
                throw SettingsStoreError.unknownDevice
            }
            candidate.devices[id.rawValue]?.displayName = name
        }
    }

    func remove(_ id: DeviceID) throws {
        try mutate { $0.devices.removeValue(forKey: id.rawValue) }
    }

    func updatePolicy(_ id: DeviceID, autoAccept: Bool, maximumBytes: UInt64?) throws {
        try mutate { candidate in
            guard candidate.devices[id.rawValue] != nil else {
                throw SettingsStoreError.unknownDevice
            }
            candidate.devices[id.rawValue]?.autoAccept = autoAccept
            candidate.devices[id.rawValue]?.maximumBytes = maximumBytes
        }
    }

    func updateDefaultDirectory(_ directory: URL) throws {
        try updateDefaultDirectoryReference(authorization.select(directory, settingKey: "default"))
    }

    func updateDefaultDirectoryReference(_ reference: StoredDirectoryReference) throws {
        let validated = try authorization.resolve(reference, settingKey: "default")
        defer { validated.lease.release() }
        try mutate {
            $0.defaultDirectoryPath = validated.reference.path
            $0.defaultDirectoryReference = validated.reference
        }
    }

    func updateLocalDisplayName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SettingsStoreError.invalidDisplayName }
        try mutate { $0.localDisplayName = trimmed }
    }

    func updateAutoReceive(_ enabled: Bool) throws {
        try mutate { $0.autoReceive = enabled }
    }

    func updateLaunchAtLogin(_ enabled: Bool) throws {
        try mutate { $0.launchAtLogin = enabled }
    }

    func updateDirectory(_ directory: URL?, for id: DeviceID) throws {
        try updateDirectoryReference(directory.map { try authorization.select($0, settingKey: id.rawValue.uuidString) }, for: id)
    }

    func updateDirectoryReference(_ reference: StoredDirectoryReference?, for id: DeviceID) throws {
        let validated = try reference.map { try authorization.resolve($0, settingKey: id.rawValue.uuidString) }
        defer { validated?.lease.release() }
        try mutate { candidate in
            guard candidate.devices[id.rawValue] != nil else {
                throw SettingsStoreError.unknownDevice
            }
            candidate.devices[id.rawValue]?.directoryPath = validated?.reference.path
            candidate.devices[id.rawValue]?.directoryReference = validated?.reference
        }
    }

    func recordPaired(_ device: DeviceSummary) throws {
        try mutate { candidate in
            let previous = candidate.devices[device.id.rawValue]
            candidate.devices[device.id.rawValue] = DeviceWire(
                displayName: device.displayName.isEmpty
                    ? (previous?.displayName ?? "")
                    : device.displayName,
                autoAccept: previous?.autoAccept ?? true,
                maximumBytes: previous?.maximumBytes,
                directoryPath: previous?.directoryPath,
                directoryReference: previous?.directoryReference
            )
        }
    }

    func downloadDirectory() -> DownloadDirectory {
        DownloadDirectory(
            globalDirectory: wire.defaultDirectoryPath.map(URL.init(fileURLWithPath:)),
            perSource: Dictionary(
                uniqueKeysWithValues: wire.devices.compactMap { id, value in
                    value.directoryPath.map { (DeviceID(rawValue: id), URL(fileURLWithPath: $0)) }
                }),
            defaultFolderName: defaultReceiveFolderName
        )
    }

    func authorizeReceiveDirectories() async throws -> AuthorizedReceiveDirectories {
        var candidate = wire
        var leases: [any UserSelectedSourceLease] = []
        do {
            if let reference = candidate.defaultDirectoryReference {
                let resolved = try authorization.resolve(reference, settingKey: "default")
                leases.append(resolved.lease)
                candidate.defaultDirectoryReference = resolved.reference
                candidate.defaultDirectoryPath = resolved.reference.path
            }
            for id in candidate.devices.keys {
                if let reference = candidate.devices[id]?.directoryReference {
                    let resolved = try authorization.resolve(reference, settingKey: id.uuidString)
                    leases.append(resolved.lease)
                    candidate.devices[id]?.directoryReference = resolved.reference
                    candidate.devices[id]?.directoryPath = resolved.reference.path
                }
            }
            // Commit all stale refreshes as a single durable settings transaction.
            try persist(candidate)
            wire = candidate
            return AuthorizedReceiveDirectories(directories: downloadDirectory(), leases: leases)
        } catch {
            leases.forEach { $0.release() }
            throw error
        }
    }

    func reportDirectoryAuthorizationError(_ message: String?) {
        guard directoryAuthorizationError != message else { return }
        directoryAuthorizationError = message
        let value = snapshot(wire)
        subscribers.values.forEach { $0.yield(value) }
    }

    private func mutate(_ body: (inout Wire) throws -> Void) throws {
        var candidate = wire
        try body(&candidate)
        try persist(candidate)
        wire = candidate
        let value = snapshot(candidate)
        subscribers.values.forEach { $0.yield(value) }
    }

    private func persist(_ candidate: Wire) throws {
        try Self.persist(candidate, to: url)
    }

    private static func persist(_ candidate: Wire, to url: URL) throws {
        let data = try JSONEncoder().encode(candidate)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporary = directory.appendingPathComponent(".settings-\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: .withoutOverwriting)
            guard chmod(temporary.path, S_IRUSR | S_IWUSR) == 0 else {
                throw SettingsStoreError.persistence
            }
            let descriptor = open(temporary.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { throw SettingsStoreError.persistence }
            defer { close(descriptor) }
            guard fsync(descriptor) == 0 else { throw SettingsStoreError.persistence }
            guard Darwin.rename(temporary.path, url.path) == 0 else {
                throw SettingsStoreError.persistence
            }
            let directoryDescriptor = open(directory.path, O_RDONLY | O_CLOEXEC)
            guard directoryDescriptor >= 0 else { throw SettingsStoreError.persistence }
            defer { close(directoryDescriptor) }
            guard fsync(directoryDescriptor) == 0 else { throw SettingsStoreError.persistence }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private func snapshot(_ wire: Wire) -> SettingsSurfaceSnapshot {
        SettingsSurfaceSnapshot(
            localDisplayName: wire.localDisplayName ?? "Mac",
            defaultDirectory: wire.defaultDirectoryPath.map(URL.init(fileURLWithPath:))
                ?? (authorization.mode == .securityScopedBookmarks ? DownloadDirectory(defaultFolderName: defaultReceiveFolderName).defaultDirectory : nil),
            autoReceive: wire.autoReceive ?? true,
            launchAtLogin: wire.launchAtLogin ?? false,
            devices: wire.devices.map { id, value in
                DeviceSetting(
                    device: DeviceSummary(
                        id: DeviceID(rawValue: id),
                        displayName: value.displayName,
                        availability: .offline
                    ),
                    autoAccept: value.autoAccept,
                    maximumBytes: value.maximumBytes,
                    directory: value.directoryPath.map(URL.init(fileURLWithPath:))
                )
            }.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            },
            directoryAuthorizationError: directoryAuthorizationError
        )
    }

    private func removeSubscriber(_ id: UUID) { subscribers.removeValue(forKey: id) }
}

private enum SettingsStoreError: Error { case unknownDevice, invalidDisplayName, persistence }

@MainActor
final class ProductionDeviceSettingsService: DeviceSettingsServicing {
    let isAvailable = true
    var onReceiveConfigurationChanged: (() async -> Void)?
    private let store: RuntimeSettingsStore
    private let trustRepository: TrustRepository
    private let trustStore: any TrustSnapshotPersisting

    init(
        store: RuntimeSettingsStore,
        trustRepository: TrustRepository,
        trustStore: any TrustSnapshotPersisting
    ) {
        self.store = store
        self.trustRepository = trustRepository
        self.trustStore = trustStore
    }

    func updateLocalDisplayName(_ name: String) async throws {
        try await store.updateLocalDisplayName(name)
    }
    func updateAutoReceive(_ enabled: Bool) async throws {
        try await store.updateAutoReceive(enabled)
        await onReceiveConfigurationChanged?()
    }
    func updateLaunchAtLogin(_ enabled: Bool) async throws {
        try await store.updateLaunchAtLogin(enabled)
    }
    func rename(_ id: DeviceID, to displayName: String) async throws {
        try await store.rename(id, to: displayName)
    }
    func revoke(_ id: DeviceID) async throws -> SurfaceActionResult {
        _ = try await trustRepository.revoke(id)
        var hadPersistenceFailure = false
        do {
            try await trustStore.persistLatest(from: trustRepository)
        } catch {
            hadPersistenceFailure = true
        }
        do {
            try await store.remove(id)
        } catch {
            hadPersistenceFailure = true
        }
        await onReceiveConfigurationChanged?()
        if hadPersistenceFailure {
            return SurfaceActionResult(warningKeys: [.trustRevokePartial])
        }
        return .committed
    }
    func updateReceivePolicy(_ id: DeviceID, autoAccept: Bool, maximumBytes: UInt64?) async throws {
        try await store.updatePolicy(id, autoAccept: autoAccept, maximumBytes: maximumBytes)
        await onReceiveConfigurationChanged?()
    }
    func updateDefaultDirectory(_ directory: URL) async throws {
        let reference = try store.authorization.selectedOnMainActor(directory, settingKey: "default")
        try await store.updateDefaultDirectoryReference(reference)
        await onReceiveConfigurationChanged?()
    }
    func updateDirectory(_ directory: URL?, for id: DeviceID) async throws {
        let reference = try directory.map { try store.authorization.selectedOnMainActor($0, settingKey: id.rawValue.uuidString) }
        try await store.updateDirectoryReference(reference, for: id)
        await onReceiveConfigurationChanged?()
    }
}

typealias ProductionPairingCoordinating = DurablePairingCoordinating

@MainActor
final class PersistingPairingSurfaceService: PairingSurfaceServicing {
    let isAvailable = true
    let codeLifetime: TimeInterval = 300
    var onReceiveConfigurationChanged: (() async -> Void)?
    private let session: DurablePairingSession
    private var retired = false
    var durableStates: AsyncStream<DurablePairingState> { session.states }
    var usesDurableStates: Bool { true }

    init(
        coordinator: any ProductionPairingCoordinating,
        settings: RuntimeSettingsStore,
        trustStore: any TrustSnapshotPersisting,
        trustRepository: TrustRepository
    ) {
        self.session = DurablePairingSession(coordinator: coordinator) { device in
            try await trustStore.persistLatest(from: trustRepository)
            guard await trustRepository.isTrusted(device.id) else { throw PairingError.staleOperation }
            try await settings.recordPaired(device)
        }
    }

    func createCode() async throws -> String { try await session.createCode() }
    func join(code: String) async throws -> PairingJoinResult {
        return try await session.join(code: code)
    }
    func approve() async throws -> SurfaceActionResult {
        _ = try await session.approve()
        if !retired { await onReceiveConfigurationChanged?() }
        return .committed
    }
    func reject() async throws { try await session.reject() }
    func awaitHostApproval() async throws -> SurfaceActionResult {
        _ = try await session.awaitApproval()
        if !retired { await onReceiveConfigurationChanged?() }
        return .committed
    }
    func cancel() async throws { try await session.cancel() }
    func pendingPeer() async -> DeviceSummary? { await session.pendingPeerSummary() }
    func currentDurableState() async -> DurablePairingState? { await session.currentState() }
    func startObservation() async { await session.startObservation() }
    func stopObservation() async {
        retired = true
        await session.stopObservation()
    }
    func retrySaving() async throws {
        _ = try await session.retrySaving()
        if !retired { await onReceiveConfigurationChanged?() }
    }
}

enum RuntimeReceivePolicy {
    static func make(
        snapshot: SettingsSurfaceSnapshot,
        trustedSources: Set<DeviceID>
    ) -> ReceivePolicy {
        ReceivePolicy(
            trustedSources: trustedSources,
            defaultAutoAccept: snapshot.autoReceive,
            perDevice: Dictionary(
                uniqueKeysWithValues: snapshot.devices.map {
                    (
                        $0.id,
                        DeviceReceivePolicy(
                            autoAccept: snapshot.autoReceive && $0.autoAccept,
                            maximumBytes: SettingsSizeLimit.bytes(
                                megabytes: $0.maximumMegabytes
                            )
                        )
                    )
                }
            )
        )
    }
}

func makeReceiveFinishedHandler(
    recordInboundResult: @escaping @Sendable (TransferReceiveResult?) async -> Void,
    publishReceiveEvent: @escaping @Sendable (TransferReceiveResult) async -> Void
) -> @Sendable (TransferReceiveResult?) async -> Void {
    { result in
        await recordInboundResult(result)
        if let result, !result.receivedURLs.isEmpty {
            await publishReceiveEvent(result)
        }
    }
}

actor IncomingRuntimeController {
    private let sources: [any IncomingTransferConnectionSource]
    private let trustRepository: TrustRepository
    private let authorizationProvider: (any PeerAuthorizationProviding)?
    private let settings: any RuntimeReceiveSettingsProviding
    private let database: TransferDatabase
    private let incomingDirectory: URL
    private let ownerID: DeviceID
    private let onReceiveFinished: @Sendable (TransferReceiveResult?) async -> Void
    private var listener: IncomingTransferListener?
    private var directoryAuthorization: AuthorizedReceiveDirectories?
    private(set) var directoryAuthorizationError: String?
    private var transitionTask: Task<Void, Never>?
    private var transitionGeneration = 0
    private var stopTask: Task<Void, Never>?
    private var stopped = false

    init(
        source: any IncomingTransferConnectionSource,
        trustRepository: TrustRepository,
        settings: any RuntimeReceiveSettingsProviding,
        database: TransferDatabase,
        incomingDirectory: URL,
        ownerID: DeviceID,
        onReceiveFinished: @escaping @Sendable (TransferReceiveResult?) async -> Void
    ) {
        self.init(sources: [source], trustRepository: trustRepository,
            settings: settings, database: database, incomingDirectory: incomingDirectory,
            ownerID: ownerID, onReceiveFinished: onReceiveFinished)
    }

    init(
        sources: [any IncomingTransferConnectionSource],
        trustRepository: TrustRepository,
        authorizationProvider: (any PeerAuthorizationProviding)? = nil,
        settings: any RuntimeReceiveSettingsProviding,
        database: TransferDatabase,
        incomingDirectory: URL,
        ownerID: DeviceID,
        onReceiveFinished: @escaping @Sendable (TransferReceiveResult?) async -> Void
    ) {
        precondition((1...2).contains(sources.count))
        self.sources = sources
        self.trustRepository = trustRepository
        self.authorizationProvider = authorizationProvider
        self.settings = settings
        self.database = database
        self.incomingDirectory = incomingDirectory
        self.ownerID = ownerID
        self.onReceiveFinished = onReceiveFinished
    }

    func start() async {
        await configureListener(restart: false)
    }

    func restart() async {
        await configureListener(restart: true)
    }

    private func configureListener(restart: Bool) async {
        guard !stopped else { return }
        transitionGeneration += 1
        let generation = transitionGeneration
        let previous = transitionTask
        let task = Task {
            await previous?.value
            guard !stopped else { return }
            if restart {
                let previousListener = listener
                listener = nil
                await previousListener?.stop()
                directoryAuthorization?.release()
                directoryAuthorization = nil
            }
            guard !stopped, listener == nil else { return }
            guard let (created, authorized) = await makeListener() else { return }
            guard !stopped else { authorized.release(); return }
            listener = created
            directoryAuthorization = authorized
            await created.start()
        }
        transitionTask = task
        await task.value
        if generation == transitionGeneration { transitionTask = nil }
    }

    func stop() async {
        if let stopTask { await stopTask.value; return }
        stopped = true
        let pending = transitionTask
        let task = Task {
            await pending?.value
            let previousListener = listener
            listener = nil
            await previousListener?.stop()
            directoryAuthorization?.release()
            directoryAuthorization = nil
        }
        stopTask = task
        await task.value
    }

    private func makeListener() async -> (IncomingTransferListener, AuthorizedReceiveDirectories)? {
        let trust = await trustRepository.currentTrustStore()
        let snapshot = await settings.current()
        let effective = authorizationProvider.map { Set($0.snapshot().peers.keys) }
            ?? trust.trustedDeviceIDs
        let policy = RuntimeReceivePolicy.make(
            snapshot: snapshot,
            trustedSources: effective.subtracting([ownerID])
        )
        let authorized: AuthorizedReceiveDirectories
        do {
            authorized = try await settings.authorizeReceiveDirectories()
            directoryAuthorizationError = nil
            await settings.reportDirectoryAuthorizationError(nil)
        } catch {
            directoryAuthorizationError = DirectoryAuthorizationError.reselect.localizedDescription
            await settings.reportDirectoryAuthorizationError(directoryAuthorizationError)
            return nil
        }
        return (IncomingTransferListener(
            sources: sources,
            policy: policy,
            directories: authorized.directories,
            database: database,
            incomingDirectory: incomingDirectory,
            onReceiveFinished: onReceiveFinished
        ), authorized)
    }
}

actor RuntimeHistorySource {
    private let database: TransferDatabase
    private let settings: RuntimeSettingsStore
    private let outputLocator: RuntimeOutputLocator
    private var subscribers: [UUID: AsyncStream<[TransferSurfaceItem]>.Continuation] = [:]
    private var observationTask: Task<Void, Never>?

    init(
        database: TransferDatabase,
        settings: RuntimeSettingsStore,
        outputLocator: RuntimeOutputLocator
    ) {
        self.database = database
        self.settings = settings
        self.outputLocator = outputLocator
    }

    func start(
        snapshots: @escaping @Sendable () async -> AsyncStream<[TransferSnapshot]>
    ) {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            let updates = await snapshots()
            for await _ in updates {
                guard !Task.isCancelled else { return }
                await self?.publish()
            }
        }
    }

    func stream() -> AsyncStream<[TransferSurfaceItem]> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            subscribers[id] = continuation
            Task { [weak self] in
                guard let self else { return }
                continuation.yield(await self.items())
            }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
        }
    }

    func recordInboundResult(_ result: TransferReceiveResult?) async {
        if let result {
            do {
                try await outputLocator.record(result)
            } catch {
                // The durable database still owns transfer state. A missing
                // output locator disables Finder rather than guessing a path.
            }
        }
        await publish()
    }

    func stop() async {
        let task = observationTask
        task?.cancel()
        observationTask = nil
        await task?.value
        subscribers.values.forEach { $0.finish() }
        subscribers.removeAll()
    }

    private func publish() async {
        let value = await items()
        subscribers.values.forEach { $0.yield(value) }
    }

    private func items() async -> [TransferSurfaceItem] {
        let outputRevision = await outputLocator.retentionRevision()
        guard
            let records = try? await database.persistedHistory(
                limit: AppSurfaceController.historyLimit)
        else {
            return []
        }
        let settingsSnapshot = await settings.current()
        let names = Dictionary(
            uniqueKeysWithValues: settingsSnapshot.devices.map { ($0.id, $0.displayName) })
        do {
            try await outputLocator.retain(
                Set(records.map(\.id)),
                ifUnchangedSince: outputRevision
            )
        } catch {
            // Retention failure does not hide otherwise valid history.
        }
        var items: [TransferSurfaceItem] = []
        items.reserveCapacity(records.count)
        for record in records {
            let outputURL: URL? =
                if record.direction == .inbound && record.phase == .completed {
                    await outputLocator.outputURL(for: record.id)
                } else {
                    nil
                }
            items.append(
                TransferSurfaceItem(
                    snapshot: TransferSnapshot(
                        id: record.id,
                        peer: record.peer,
                        phase: record.phase,
                        completedBytes: Int64(clamping: record.completedBytes),
                        totalBytes: Int64(clamping: record.aggregateSize),
                        route: record.route
                    ),
                    peerName: names[record.peer] ?? "",
                    displayName: record.displayFilename,
                    bytesPerSecond: nil,
                    estimatedTimeRemaining: nil,
                    outputURL: outputURL,
                    updatedAt: record.updatedAt
                ))
        }
        return items
    }

    private func removeSubscriber(_ id: UUID) { subscribers.removeValue(forKey: id) }
}
