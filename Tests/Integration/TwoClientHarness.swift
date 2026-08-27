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
}

struct RelayRouteEvidence: Equatable, Sendable {
    let expiresAt: Date
    let usedAuthenticatedCredentials: Bool
    let usernameIsOpaque: Bool
}

final class TwoClientHarness: @unchecked Sendable {
    let sender: HarnessSender
    let receiverID: DeviceID
    let senderID: DeviceID
    let root: URL
    let senderDatabase: TransferDatabase
    let receiverDatabase: TransferDatabase
    let senderDownloadRoot: URL
    let receiverDownloadRoot: URL
    let thirdDownloadRoot: URL?

    private let senderTrust: TrustRepository
    private let receiverTrust: TrustRepository
    private let senderDirectory: DeviceDirectory
    private let connector: HarnessRouteConnector
    private let results: HarnessReceiveResults
    private let incomingListener: IncomingTransferListener
    private let connectionListener: WebRTCConnectionListener
    private let signalHub: LocalRendezvousHub?
    private let stackPresence: StackPresenceLifecycle?
    private let relayCredentials: RendezvousTURNCredentials?
    private let senderOutgoing: URL
    private let thirdIncomingListener: IncomingTransferListener?
    private let thirdConnectionListener: WebRTCConnectionListener?

    init(
        routePolicy: IntegrationRoutePolicy,
        root: URL? = nil,
        capacity: any ReceiveCapacityProviding = VolumeReceiveCapacityProvider(),
        additionalOnlineClient: Bool = false,
        maximumConnectionAttempts: Int = 8
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

        let senderIdentity = try DeviceIdentity.loadOrCreate(keychain: MemorySecretStore())
        let receiverIdentity = try DeviceIdentity.loadOrCreate(keychain: MemorySecretStore())
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
        let senderICE: ICEConfiguration
        let receiverICE: ICEConfiguration
        if let stackOrigin {
            let senderCredential = try await RendezvousTURNCredentialClient(
                identity: senderIdentity,
                origin: stackOrigin,
                session: URLSession(configuration: .ephemeral)
            ).fetch()
            let receiverCredential = try await RendezvousTURNCredentialClient(
                identity: receiverIdentity,
                origin: stackOrigin,
                session: URLSession(configuration: .ephemeral)
            ).fetch()
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
            stackPresence = StackPresenceLifecycle(
                sender: senderPresence,
                receiver: receiverPresence,
                senderTask: senderPresenceTask,
                receiverTask: receiverPresenceTask
            )
            relayCredentials = routePolicy == .relayOnly ? senderCredential : nil
            senderSignalSession = senderPresence
            receiverSignalSession = receiverPresence
            senderICE = senderCredential.iceConfiguration
            receiverICE = receiverCredential.iceConfiguration
        } else {
            let hub = LocalRendezvousHub()
            signalHub = hub
            stackPresence = nil
            relayCredentials = nil
            senderSignalSession = LocalRendezvousSignalSession(
                localDevice: senderIdentity.id,
                hub: hub
            )
            receiverSignalSession = LocalRendezvousSignalSession(
                localDevice: receiverIdentity.id,
                hub: hub
            )
            senderICE = ICEConfiguration(stunURLs: [], turnServers: [])
            receiverICE = senderICE
        }
        let senderSignaling = RendezvousWebRTCSignaling(
            session: senderSignalSession
        )
        let receiverSignaling = RendezvousWebRTCSignaling(
            session: receiverSignalSession
        )
        let attempts = WebRTCConnectionAttempts(
            directory: senderDirectory,
            identity: senderIdentity,
            trustRepository: senderTrust,
            signaling: senderSignaling,
            ice: senderICE,
            factory: WebRTCFactory(connectionTimeout: .seconds(15))
        )
        connector = HarnessRouteConnector(attempts: attempts, route: routePolicy.route)

        senderDatabase = try TransferDatabase(
            url: senderRoot.appendingPathComponent("history.sqlite")
        )
        receiverDatabase = try TransferDatabase(
            url: receiverRoot.appendingPathComponent("history.sqlite")
        )
        let coordinator = try await TransferCoordinator.restoring(
            connector: connector,
            database: senderDatabase,
            outgoingDirectory: senderOutgoing,
            maximumConnectionAttempts: maximumConnectionAttempts,
            persistenceRetryDelay: .milliseconds(20),
            cancellationWatchdogDelay: .seconds(1)
        )
        sender = HarnessSender(coordinator: coordinator)

        connectionListener = WebRTCConnectionListener(
            directory: receiverDirectory,
            identity: receiverIdentity,
            trustRepository: receiverTrust,
            signaling: receiverSignaling,
            ice: receiverICE,
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
            }
        )
        await incomingListener.start()

        if additionalOnlineClient {
            let thirdRoot = self.root.appendingPathComponent("third", isDirectory: true)
            let thirdDownloads = thirdRoot.appendingPathComponent("downloads", isDirectory: true)
            try FileManager.default.createDirectory(
                at: thirdDownloads,
                withIntermediateDirectories: true
            )
            let thirdIdentity = try DeviceIdentity.loadOrCreate(keychain: MemorySecretStore())
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
                ice: senderICE,
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
            await thirdIncoming.start()
        } else {
            thirdDownloadRoot = nil
            thirdConnectionListener = nil
            thirdIncomingListener = nil
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

    func cutNetwork(afterBytes: Int64) async {
        guard let transfer = await sender.latestTransferID else { return }
        while let snapshot = await sender.snapshot(for: transfer),
              snapshot.completedBytes < afterBytes,
              snapshot.phase != .failed,
              snapshot.phase != .completed,
              snapshot.phase != .cancelled
        {
            try? await Task.sleep(for: .milliseconds(5))
        }
        await connector.interruptNetwork()
    }

    func restoreNetwork() async {
        await connector.restoreNetwork()
    }

    func actualRoutes() async -> [ConnectionRoute] {
        await connector.actualRoutes
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
        await connector.tamperNextChunk()
    }

    func receiveFailureCount() async -> Int {
        await results.failures
    }

    func revokeReceiverFromSender() async throws {
        _ = try await senderTrust.revoke(receiverID)
        await senderDirectory.waitForTrustUpdates()
    }

    func restartSender(afterBytes: Int64) async throws {
        guard let transfer = await sender.latestTransferID else {
            throw TwoClientHarnessError.missingTransfer
        }
        while let snapshot = await sender.snapshot(for: transfer),
              snapshot.completedBytes < afterBytes,
              snapshot.phase != .failed,
              snapshot.phase != .completed,
              snapshot.phase != .cancelled
        {
            try await Task.sleep(for: .milliseconds(5))
        }
        await connector.interruptNetwork()
        await sender.shutdownForRestart()
        let receiveDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < receiveDeadline {
            if try await receiverDatabase.history(limit: 100)
                .first(where: { $0.id == transfer })?.phase == .failed
            {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        await connector.restoreNetwork()
        let restored = try await TransferCoordinator.restoring(
            connector: connector,
            database: senderDatabase,
            outgoingDirectory: senderOutgoing,
            maximumConnectionAttempts: 8,
            persistenceRetryDelay: .milliseconds(20),
            cancellationWatchdogDelay: .seconds(1)
        )
        await sender.install(restored)
    }

    func onlinePeerCount() async -> Int {
        await senderDirectory.snapshot().count
    }

    func relayEvidence() async throws -> RelayRouteEvidence {
        guard let relayCredentials else {
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

    func shutdown() async {
        await sender.shutdownForRestart()
        await incomingListener.stop()
        await connectionListener.stop()
        await thirdIncomingListener?.stop()
        await thirdConnectionListener?.stop()
        await signalHub?.finish()
        await stackPresence?.shutdown()
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
}

private actor HarnessRouteConnector: TransferAwarePeerConnector {
    private let attempts: WebRTCConnectionAttempts
    private let route: ConnectionRoute
    private var online = true
    private var channels: [UUID: HarnessSecureChannel] = [:]
    private(set) var actualRoutes: [ConnectionRoute] = []
    private let faults = HarnessChannelFaults()

    init(attempts: WebRTCConnectionAttempts, route: ConnectionRoute) {
        self.attempts = attempts
        self.route = route
    }

    func connect(to device: DeviceID) async throws -> any SecureChannel {
        try await connect(to: device, transferID: TransferID(rawValue: UUID()))
    }

    func connect(to device: DeviceID, transferID: TransferID) async throws -> any SecureChannel {
        while !online {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
        let channel = try await attempts.connect(
            to: device,
            route: route,
            transferID: transferID
        )
        await faults.channelOpened()
        let wrapped = HarnessSecureChannel(base: channel, faults: faults)
        channels[UUID()] = wrapped
        actualRoutes.append(channel.route)
        return wrapped
    }

    func interruptNetwork() async {
        online = false
        let current = Array(channels.values)
        channels.removeAll()
        for channel in current { await channel.close() }
    }

    func restoreNetwork() {
        online = true
    }

    func tamperNextChunk() async {
        await faults.tamperNextChunk()
    }
}

private final class HarnessSecureChannel: SecureChannel, @unchecked Sendable {
    let route: ConnectionRoute
    private let base: any SecureChannel
    private let faults: HarnessChannelFaults

    init(base: any SecureChannel, faults: HarnessChannelFaults) {
        self.base = base
        self.faults = faults
        route = base.route
    }

    func send(_ frame: Data) async throws {
        try await base.send(await faults.transform(frame))
    }

    func frames() -> AsyncThrowingStream<Data, Error> {
        base.frames()
    }

    func exportKey(label: String, context: Data, length: Int) async throws -> Data {
        try await base.exportKey(label: label, context: context, length: length)
    }

    func close() async {
        await base.close()
    }
}

private actor HarnessChannelFaults {
    private var outboundOrdinal = 0
    private var tamperArmed = false

    func channelOpened() {
        outboundOrdinal = 0
    }

    func tamperNextChunk() {
        tamperArmed = true
    }

    func transform(_ frame: Data) -> Data {
        outboundOrdinal += 1
        guard tamperArmed, outboundOrdinal >= 2, !frame.isEmpty else { return frame }
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

private final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func data(for account: String, policy: KeychainPolicy) throws -> Data? {
        lock.withLock { values["\(policy.service):\(account)"] }
    }

    func store(_ data: Data, for account: String, policy: KeychainPolicy) throws {
        lock.withLock { values["\(policy.service):\(account)"] = data }
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
