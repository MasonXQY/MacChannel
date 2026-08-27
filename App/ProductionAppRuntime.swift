import AppKit
import Darwin
import Foundation
import MacChannelCore
import Network

struct ProductionRuntimeConfiguration {
    let dataDirectory: URL
    let rendezvousWebSocketURL: URL?
    let rendezvousHTTPOrigin: URL?
    let environmentRendezvousURL: String?
    let packagedRendezvousURL: String
    let ice: ICEConfiguration
    let bonjourPort: UInt16
    let identityPolicy: KeychainPolicy
    let isIsolatedLaunchTest: Bool

    static func current(
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
        let directory = launchTestMarker.map {
            URL(fileURLWithPath: $0).appendingPathExtension("runtime")
        } ?? applicationSupport.appendingPathComponent("MacChannel", isDirectory: true)
        let identityPolicy = launchTestMarker.map { marker in
            let suffix = URL(fileURLWithPath: marker).lastPathComponent
                .filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
            return KeychainPolicy(
                service: "com.mason.macchannel.identity.launch-test.\(suffix)",
                accessibility: .afterFirstUnlockThisDeviceOnly,
                synchronizable: false
            )
        } ?? KeychainStore.identityPolicy
        let resource = Bundle.module.url(
            forResource: "RuntimeConfig",
            withExtension: "json",
            subdirectory: "Resources"
        ) ?? Bundle.module.url(forResource: "RuntimeConfig", withExtension: "json")
        guard let resource else { throw ProductionRuntimeError.missingRuntimeConfiguration }
        struct RuntimeConfigWire: Decodable { let rendezvousURL: String }
        let packaged = try JSONDecoder().decode(
            RuntimeConfigWire.self,
            from: Data(contentsOf: resource)
        ).rendezvousURL
        let environmentURL = environment["MACCHANNEL_RENDEZVOUS_URL"]
        let endpoints = try RendezvousEndpointConfiguration.parse(environmentURL ?? packaged)
        let stunURLs = environment["MACCHANNEL_STUN_URLS"]?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        let port = environment["MACCHANNEL_BONJOUR_PORT"].flatMap(UInt16.init) ?? 45_873
        return ProductionRuntimeConfiguration(
            dataDirectory: directory,
            rendezvousWebSocketURL: endpoints.webSocketURL,
            rendezvousHTTPOrigin: endpoints.httpOrigin,
            environmentRendezvousURL: environmentURL,
            packagedRendezvousURL: packaged,
            ice: ICEConfiguration(stunURLs: stunURLs, turnServers: []),
            bonjourPort: port,
            identityPolicy: identityPolicy,
            isIsolatedLaunchTest: launchTestMarker != nil
        )
    }

    func endpoints(persistedURL: String) throws -> RendezvousEndpointConfiguration {
        try RendezvousEndpointConfiguration.parse(
            environmentRendezvousURL ?? (persistedURL.isEmpty ? packagedRendezvousURL : persistedURL)
        )
    }
}

enum ProductionRuntimeError: Error {
    case insecureRendezvousURL
    case missingRuntimeConfiguration
    case invalidTrustGeneration
}

struct RendezvousEndpointConfiguration: Equatable {
    static let packagedDefault = "wss://localhost:8443/v1/ws"

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

    convenience init() throws {
        try self.init(configuration: .current())
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

    private let browser: BonjourPeerBrowser
    private let advertiser: BonjourPeerAdvertiser
    private let trustPersistenceTask: Task<Void, Never>
    private let historySource: RuntimeHistorySource
    private let statusSource: RuntimeStatusSource
    private let presenceSession: AuthenticatedPresenceSession?
    private let presenceTask: Task<Void, Never>?
    private let pairingTransport: RendezvousPairingTransport?
    private let connectionListener: WebRTCConnectionListener?
    private let incomingController: IncomingRuntimeController?
    private let transferCoordinator: TransferCoordinator?
    private let trustRepository: TrustRepository
    private let trustStore: any TrustSnapshotPersisting
    private let launchTestKeychain: KeychainStore?
    private let launchTestDataDirectory: URL?
    private var stopped = false

    private init(
        container: AppContainer,
        initialStatus: AppRuntimeStatus,
        browser: BonjourPeerBrowser,
        advertiser: BonjourPeerAdvertiser,
        trustPersistenceTask: Task<Void, Never>,
        historySource: RuntimeHistorySource,
        statusSource: RuntimeStatusSource,
        presenceSession: AuthenticatedPresenceSession?,
        presenceTask: Task<Void, Never>?,
        pairingTransport: RendezvousPairingTransport?,
        connectionListener: WebRTCConnectionListener?,
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
        self.statusSource = statusSource
        self.presenceSession = presenceSession
        self.presenceTask = presenceTask
        self.pairingTransport = pairingTransport
        self.connectionListener = connectionListener
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
        let trustStore = LocalTrustSnapshotStore(
            url: configuration.dataDirectory.appendingPathComponent("trust.json"),
            keychain: keychain,
            keychainPolicy: configuration.identityPolicy
        )
        let trustRepository = try await trustStore.load(identity: identity)
        let currentTrust = await trustRepository.currentTrustStore()
        let directory = DeviceDirectory(trust: currentTrust)
        await directory.observeTrust(trustRepository)

        let settingsStore = try RuntimeSettingsStore(
            url: configuration.dataDirectory.appendingPathComponent("settings.json"),
            trustedDevices: currentTrust.trustedDeviceIDs.subtracting([identity.id]),
            defaultRendezvousURL: configuration.packagedRendezvousURL
        )
        let configuredEndpoints = try configuration.endpoints(
            persistedURL: await settingsStore.current().rendezvousURL
        )
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
        browser.observeTrust(trustRepository)
        browser.start()
        cleanup.push { await browser.stop() }
        let advertiser = try BonjourPeerAdvertiser(
            device: identity.id,
            port: configuration.bonjourPort
        ) { connection in
            // The authenticated WebRTC listener owns transfer channels. This
            // advertised TCP endpoint is discovery evidence only.
            connection.cancel()
        }
        advertiser.start()
        cleanup.push { await advertiser.stopAndWait() }

        let trustPersistenceTask = Task {
            let updates = await trustRepository.updates()
            for await _ in updates {
                guard !Task.isCancelled else { return }
                do {
                    try await trustStore.persistLatest(from: trustRepository)
                } catch {
                    statusSource.yield(.error("无法保存设备信任状态；请检查本地存储权限。"))
                }
            }
        }
        cleanup.push {
            trustPersistenceTask.cancel()
            await trustPersistenceTask.value
        }

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
            displayName: Host.current().localizedName ?? "Mac",
            trustRepository: trustRepository,
            transport: pairingTransport
        )
        let pairingService = PersistingPairingSurfaceService(
            coordinator: pairingCoordinator,
            settings: settingsStore,
            trustStore: trustStore,
            trustRepository: trustRepository
        )

        let socket = try URLSessionPresenceWebSocket(origin: webSocketURL)
        let presenceClient = PresenceClient(directory: directory)
        let presence = try AuthenticatedPresenceSession(
            identity: identity,
            origin: webSocketURL,
            socket: socket,
            client: presenceClient,
            trustRepository: trustRepository
        )

        do {
            try await RuntimePresenceConnect.withTimeout(.seconds(5), session: presence)
        } catch {
            await presence.stop()
            let container = AppContainer(
                deviceDirectory: directory,
                transferCoordinator: UnavailableTransferCoordinator(),
                pairingSurfaceService: pairingService,
                settingsSurfaceService: settingsService,
                pairingStates: pairingCoordinator.states,
                settingsSnapshots: { await settingsStore.snapshots() },
                transferHistory: { await history.stream() },
                runtimeIdentityID: identity.id
            )
            return ProductionAppRuntime(
                container: container,
                initialStatus: .offline("安全中继暂时不可用；局域网发现和本地设置仍可使用。"),
                browser: browser,
                advertiser: advertiser,
                trustPersistenceTask: trustPersistenceTask,
                historySource: history,
                statusSource: statusSource,
                presenceSession: presence,
                presenceTask: nil,
                pairingTransport: pairingTransport,
                connectionListener: nil,
                incomingController: nil,
                transferCoordinator: nil,
                trustRepository: trustRepository,
                trustStore: trustStore,
                launchTestKeychain: configuration.isIsolatedLaunchTest ? keychain : nil,
                launchTestDataDirectory: configuration.isIsolatedLaunchTest
                    ? configuration.dataDirectory
                    : nil
            )
        }
        cleanup.push { await presence.stop() }

        let signaling = RendezvousWebRTCSignaling(session: presence)
        let connector = ConnectionCoordinator(
            directory: directory,
            identity: identity,
            trustRepository: trustRepository,
            signaling: signaling,
            ice: configuration.ice
        )
        let transferCoordinator = try await TransferCoordinator.restoring(
            connector: connector,
            database: database
        )
        cleanup.push { await transferCoordinator.shutdownForRestart() }
        let connectionListener = WebRTCConnectionListener(
            directory: directory,
            identity: identity,
            trustRepository: trustRepository,
            signaling: signaling,
            ice: configuration.ice
        )
        cleanup.push { await connectionListener.stop() }
        let incoming = IncomingRuntimeController(
            source: connectionListener,
            trustRepository: trustRepository,
            settings: settingsStore,
            database: database,
            ownerID: identity.id,
            onReceiveFinished: { result in
                await history.recordInboundResult(result)
            }
        )
        await incoming.start()
        cleanup.push { await incoming.stop() }
        settingsService.onReceiveConfigurationChanged = { await incoming.restart() }
        pairingService.onReceiveConfigurationChanged = { await incoming.restart() }
        let presenceTask = Task {
            do {
                try await presence.run()
            } catch {
                statusSource.yield(
                    .offline("安全中继连接已中断；局域网发现和本地设置仍可使用。")
                )
            }
        }
        cleanup.push {
            await RuntimePresenceShutdown.cancelCloseAndWait(presenceTask) {
                await presence.stop()
            }
        }
        await history.start(snapshots: { await transferCoordinator.snapshots() })
        cleanup.push { await history.stop() }
        let container = AppContainer(
            deviceDirectory: directory,
            transferCoordinator: transferCoordinator,
            pairingSurfaceService: pairingService,
            settingsSurfaceService: settingsService,
            transferSnapshots: { await transferCoordinator.snapshots() },
            pairingStates: pairingCoordinator.states,
            settingsSnapshots: { await settingsStore.snapshots() },
            transferHistory: { await history.stream() },
            runtimeIdentityID: identity.id
        )
        return ProductionAppRuntime(
            container: container,
            initialStatus: .ready,
            browser: browser,
            advertiser: advertiser,
            trustPersistenceTask: trustPersistenceTask,
            historySource: history,
            statusSource: statusSource,
            presenceSession: presence,
            presenceTask: presenceTask,
            pairingTransport: pairingTransport,
            connectionListener: connectionListener,
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
        await historySource.stop()
        await RuntimePresenceShutdown.cancelCloseAndWait(presenceTask) {
            if let presenceSession { await presenceSession.stop() }
        }
        if let incomingController { await incomingController.stop() }
        if let connectionListener { await connectionListener.stop() }
        if let transferCoordinator { await transferCoordinator.shutdownForRestart() }
        if let pairingTransport { await pairingTransport.stop() }
        do {
            try await trustStore.persistLatest(from: trustRepository)
        } catch {
            statusSource.yield(.error("无法保存设备信任状态；请检查本地存储权限。"))
        }
        trustPersistenceTask.cancel()
        await trustPersistenceTask.value
        await browser.stop()
        await advertiser.stopAndWait()
        try? launchTestKeychain?.removeAll()
        if let launchTestDataDirectory {
            try? FileManager.default.removeItem(at: launchTestDataDirectory)
        }
        statusSource.finish()
    }

    func statusUpdates() -> AsyncStream<AppRuntimeStatus>? { statusSource.stream }
}

enum RuntimePresenceConnect {
    static func withTimeout(
        _ timeout: Duration,
        session: AuthenticatedPresenceSession
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await session.connect() }
            group.addTask {
                try await Task.sleep(for: timeout)
                await session.stop()
                throw AuthenticatedPresenceError.transport("connection_timeout")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw AuthenticatedPresenceError.transport("connection_cancelled")
            }
            return first
        }
    }
}

private final class RuntimeStatusSource: @unchecked Sendable {
    let stream: AsyncStream<AppRuntimeStatus>
    private let continuation: AsyncStream<AppRuntimeStatus>.Continuation

    init() {
        let pair = AsyncStream<AppRuntimeStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream = pair.stream
        continuation = pair.continuation
    }

    func yield(_ status: AppRuntimeStatus) { continuation.yield(status) }
    func finish() { continuation.finish() }
}

protocol TrustSnapshotPersisting: Sendable {
    func persistLatest(from repository: TrustRepository) async throws
}

private actor LocalTrustSnapshotStore: TrustSnapshotPersisting {
    private static let generationAccount = "trust-snapshot-generation"
    private let url: URL
    private let keychain: KeychainStore
    private let keychainPolicy: KeychainPolicy

    init(
        url: URL,
        keychain: KeychainStore,
        keychainPolicy: KeychainPolicy = KeychainStore.identityPolicy
    ) {
        self.url = url
        self.keychain = keychain
        self.keychainPolicy = keychainPolicy
    }

    func load(identity: DeviceIdentity) throws -> TrustRepository {
        let generation = try storedGeneration()
        if FileManager.default.fileExists(atPath: url.path) {
            let snapshot = try JSONDecoder().decode(
                TrustStoreSnapshot.self,
                from: Data(contentsOf: url)
            )
            let store = try TrustStore(
                snapshot: snapshot,
                expectedOwner: identity,
                minimumGeneration: generation
            )
            if snapshot.generation > generation {
                try storeGeneration(snapshot.generation)
            }
            return try TrustRepository(
                ownerIdentity: identity,
                trustStore: store,
                persistedGeneration: snapshot.generation
            )
        }
        guard generation == 0 else { throw ProductionRuntimeError.invalidTrustGeneration }
        return try TrustRepository(
            ownerIdentity: identity,
            trustStore: TrustStore(owner: identity.id),
            persistedGeneration: 0
        )
    }

    func persistLatest(from repository: TrustRepository) async throws {
        guard let snapshot = try? await repository.latestSignedSnapshot() else { return }
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
        guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else {
            throw ProductionRuntimeError.invalidTrustGeneration
        }
        try storeGeneration(snapshot.generation)
    }

    private func storedGeneration() throws -> UInt64 {
        guard let data = try keychain.data(
            for: Self.generationAccount,
            policy: keychainPolicy
        ) else { return 0 }
        guard data.count == MemoryLayout<UInt64>.size else {
            throw ProductionRuntimeError.invalidTrustGeneration
        }
        return data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private func storeGeneration(_ generation: UInt64) throws {
        let data = Data((0..<8).reversed().map { shift in
            UInt8(truncatingIfNeeded: generation >> UInt64(shift * 8))
        })
        try keychain.store(
            data,
            for: Self.generationAccount,
            policy: keychainPolicy
        )
    }
}

actor RuntimeSettingsStore {
    private struct DeviceWire: Codable {
        var displayName: String
        var autoAccept: Bool
        var maximumBytes: UInt64?
        var directoryPath: String?
    }
    private struct Wire: Codable {
        var defaultDirectoryPath: String?
        var rendezvousURL: String?
        var devices: [UUID: DeviceWire]
    }

    private let url: URL
    private let defaultRendezvousURL: String
    private var wire: Wire
    private var subscribers: [UUID: AsyncStream<SettingsSurfaceSnapshot>.Continuation] = [:]

    init(
        url: URL,
        trustedDevices: Set<DeviceID>,
        defaultRendezvousURL: String = RendezvousEndpointConfiguration.packagedDefault
    ) throws {
        self.url = url
        self.defaultRendezvousURL = defaultRendezvousURL
        if FileManager.default.fileExists(atPath: url.path) {
            wire = try JSONDecoder().decode(Wire.self, from: Data(contentsOf: url))
        } else {
            wire = Wire(defaultDirectoryPath: nil, rendezvousURL: nil, devices: [:])
        }
        for device in trustedDevices where wire.devices[device.rawValue] == nil {
            wire.devices[device.rawValue] = DeviceWire(
                displayName: "已配对 Mac",
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
            guard candidate.devices[id.rawValue] != nil else { throw SettingsStoreError.unknownDevice }
            candidate.devices[id.rawValue]?.displayName = name
        }
    }

    func remove(_ id: DeviceID) throws {
        try mutate { $0.devices.removeValue(forKey: id.rawValue) }
    }

    func updatePolicy(_ id: DeviceID, autoAccept: Bool, maximumBytes: UInt64?) throws {
        try mutate { candidate in
            guard candidate.devices[id.rawValue] != nil else { throw SettingsStoreError.unknownDevice }
            candidate.devices[id.rawValue]?.autoAccept = autoAccept
            candidate.devices[id.rawValue]?.maximumBytes = maximumBytes
        }
    }

    func updateDefaultDirectory(_ directory: URL) throws {
        try mutate { $0.defaultDirectoryPath = directory.standardizedFileURL.path }
    }

    func updateRendezvousURL(_ value: String) throws {
        let endpoints = try RendezvousEndpointConfiguration.parse(value)
        try mutate { $0.rendezvousURL = endpoints.webSocketURL.absoluteString }
    }

    func updateDirectory(_ directory: URL?, for id: DeviceID) throws {
        try mutate { candidate in
            guard candidate.devices[id.rawValue] != nil else { throw SettingsStoreError.unknownDevice }
            candidate.devices[id.rawValue]?.directoryPath = directory?.standardizedFileURL.path
        }
    }

    func recordPaired(_ device: DeviceSummary) throws {
        try mutate { candidate in
            let previous = candidate.devices[device.id.rawValue]
            candidate.devices[device.id.rawValue] = DeviceWire(
                displayName: device.displayName.isEmpty
                    ? (previous?.displayName ?? "已配对 Mac")
                    : device.displayName,
                autoAccept: previous?.autoAccept ?? true,
                maximumBytes: previous?.maximumBytes,
                directoryPath: previous?.directoryPath
            )
        }
    }

    func downloadDirectory() -> DownloadDirectory {
        DownloadDirectory(
            globalDirectory: wire.defaultDirectoryPath.map(URL.init(fileURLWithPath:)),
            perSource: Dictionary(uniqueKeysWithValues: wire.devices.compactMap { id, value in
                value.directoryPath.map { (DeviceID(rawValue: id), URL(fileURLWithPath: $0)) }
            })
        )
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
        try data.write(to: url, options: .atomic)
        guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else { throw SettingsStoreError.persistence }
    }

    private func snapshot(_ wire: Wire) -> SettingsSurfaceSnapshot {
        SettingsSurfaceSnapshot(
            defaultDirectory: wire.defaultDirectoryPath.map(URL.init(fileURLWithPath:)),
            rendezvousURL: wire.rendezvousURL ?? defaultRendezvousURL,
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
            }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        )
    }

    private func removeSubscriber(_ id: UUID) { subscribers.removeValue(forKey: id) }
}

private enum SettingsStoreError: Error { case unknownDevice, persistence }

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

    func rename(_ id: DeviceID, to displayName: String) async throws { try await store.rename(id, to: displayName) }
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
            return .committedWithWarning(
                "设备信任已撤销，但部分本地记录未保存；请检查存储权限后重启确认。"
            )
        }
        return .committed
    }
    func updateReceivePolicy(_ id: DeviceID, autoAccept: Bool, maximumBytes: UInt64?) async throws {
        try await store.updatePolicy(id, autoAccept: autoAccept, maximumBytes: maximumBytes)
        await onReceiveConfigurationChanged?()
    }
    func updateDefaultDirectory(_ directory: URL) async throws {
        try await store.updateDefaultDirectory(directory)
        await onReceiveConfigurationChanged?()
    }
    func updateRendezvousURL(_ value: String) async throws {
        try await store.updateRendezvousURL(value)
    }
    func updateDirectory(_ directory: URL?, for id: DeviceID) async throws {
        try await store.updateDirectory(directory, for: id)
        await onReceiveConfigurationChanged?()
    }
}

protocol ProductionPairingCoordinating: Sendable {
    func createCode() async throws -> String
    func join(code: String) async throws -> PairingJoinResult
    func confirmForSurface(_ fingerprint: String) async throws
    func cancelPendingPairing() async throws
    func pendingPeerSummary() async -> DeviceSummary?
}

extension PairingCoordinator: ProductionPairingCoordinating {
    func confirmForSurface(_ fingerprint: String) async throws {
        _ = try await confirmFingerprint(fingerprint)
    }
}

@MainActor
final class PersistingPairingSurfaceService: PairingSurfaceServicing {
    let isAvailable = true
    var onReceiveConfigurationChanged: (() async -> Void)?
    private let coordinator: any ProductionPairingCoordinating
    private let settings: RuntimeSettingsStore
    private let trustStore: any TrustSnapshotPersisting
    private let trustRepository: TrustRepository

    init(
        coordinator: any ProductionPairingCoordinating,
        settings: RuntimeSettingsStore,
        trustStore: any TrustSnapshotPersisting,
        trustRepository: TrustRepository
    ) {
        self.coordinator = coordinator
        self.settings = settings
        self.trustStore = trustStore
        self.trustRepository = trustRepository
    }

    func createCode() async throws -> String { try await coordinator.createCode() }
    func join(code: String) async throws -> PairingJoinResult { try await coordinator.join(code: code) }
    func confirmFingerprint(_ fingerprint: String) async throws -> SurfaceActionResult {
        let pendingPeer = await coordinator.pendingPeerSummary()
        var warnings: [String] = []
        do {
            try await coordinator.confirmForSurface(fingerprint)
        } catch {
            guard let pendingPeer,
                  await trustRepository.isTrusted(pendingPeer.id)
            else { throw error }
            warnings.append("本机信任已建立，但对端授权确认未完成；请在设置中撤销后重新配对。")
        }
        do {
            try await trustStore.persistLatest(from: trustRepository)
        } catch {
            warnings.append("设备信任已建立，但本地信任记录未保存；请检查存储权限后重启确认。")
        }
        if let device = pendingPeer,
           await trustRepository.isTrusted(device.id)
        {
            do {
                try await settings.recordPaired(device)
            } catch {
                warnings.append("设备信任已建立，但设备设置未保存；请检查存储权限后重试。")
            }
        }
        await onReceiveConfigurationChanged?()
        guard !warnings.isEmpty else { return .committed }
        return .committedWithWarning(warnings.joined(separator: " "))
    }
    func cancel() async throws { try await coordinator.cancelPendingPairing() }
    func pendingPeer() async -> DeviceSummary? { await coordinator.pendingPeerSummary() }
}

private actor IncomingRuntimeController {
    private let source: any IncomingTransferConnectionSource
    private let trustRepository: TrustRepository
    private let settings: RuntimeSettingsStore
    private let database: TransferDatabase
    private let ownerID: DeviceID
    private let onReceiveFinished: @Sendable (TransferReceiveResult?) async -> Void
    private var listener: IncomingTransferListener?
    private var stopped = false

    init(
        source: any IncomingTransferConnectionSource,
        trustRepository: TrustRepository,
        settings: RuntimeSettingsStore,
        database: TransferDatabase,
        ownerID: DeviceID,
        onReceiveFinished: @escaping @Sendable (TransferReceiveResult?) async -> Void
    ) {
        self.source = source
        self.trustRepository = trustRepository
        self.settings = settings
        self.database = database
        self.ownerID = ownerID
        self.onReceiveFinished = onReceiveFinished
    }

    func start() async {
        guard listener == nil, !stopped else { return }
        let created = await makeListener()
        listener = created
        await created.start()
    }

    func restart() async {
        guard !stopped else { return }
        if let listener { await listener.stop() }
        listener = nil
        await start()
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        if let listener { await listener.stop() }
        listener = nil
    }

    private func makeListener() async -> IncomingTransferListener {
        let trust = await trustRepository.currentTrustStore()
        let snapshot = await settings.current()
        let policy = ReceivePolicy(
            trustedSources: trust.trustedDeviceIDs.subtracting([ownerID]),
            perDevice: Dictionary(uniqueKeysWithValues: snapshot.devices.map {
                ($0.id, DeviceReceivePolicy(
                    autoAccept: $0.autoAccept,
                    maximumBytes: SettingsSizeLimit.bytes(megabytes: $0.maximumMegabytes)
                ))
            })
        )
        return IncomingTransferListener(
            source: source,
            policy: policy,
            directories: await settings.downloadDirectory(),
            database: database,
            onReceiveFinished: onReceiveFinished
        )
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
        guard let records = try? await database.persistedHistory(limit: AppSurfaceController.historyLimit) else {
            return []
        }
        let settingsSnapshot = await settings.current()
        let names = Dictionary(uniqueKeysWithValues: settingsSnapshot.devices.map { ($0.id, $0.displayName) })
        do {
            try await outputLocator.retain(Set(records.map(\.id)))
        } catch {
            // Retention failure does not hide otherwise valid history.
        }
        var items: [TransferSurfaceItem] = []
        items.reserveCapacity(records.count)
        for record in records {
            let outputURL: URL? = if record.direction == .inbound && record.phase == .completed {
                await outputLocator.outputURL(for: record.id)
            } else {
                nil
            }
            items.append(TransferSurfaceItem(
                snapshot: TransferSnapshot(
                    id: record.id,
                    peer: record.peer,
                    phase: record.phase,
                    completedBytes: Int64(clamping: record.completedBytes),
                    totalBytes: Int64(clamping: record.aggregateSize),
                    route: record.route
                ),
                peerName: names[record.peer] ?? "未知设备",
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
