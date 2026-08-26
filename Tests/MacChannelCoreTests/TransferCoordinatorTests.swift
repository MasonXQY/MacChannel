import Foundation
import XCTest

@testable import MacChannelCore

final class TransferCoordinatorTests: XCTestCase {
    func testCoordinatorSendsOneItemToExactlyOnePeer() async throws {
        let fixture = try CoordinatorFixture(twoPeers: true)
        defer { fixture.removeTemporaryFiles() }

        let id = try await fixture.sender.send(items: [fixture.file], to: fixture.peerA)
        try await fixture.waitUntilCompleted(id)

        XCTAssertEqual(try fixture.receivedData(on: fixture.peerA), fixture.sourceData)
        XCTAssertNil(try fixture.receivedData(on: fixture.peerB))
    }

    func testCoordinatorStartsAtMostTwoTransfersAndQueuesTheThird() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let peer = DeviceID(rawValue: UUID())
        let connector = CountingBlockingConnector()
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        let coordinator = TransferCoordinator(connector: connector, database: database)
        let files = try (0..<3).map { index in
            let file = root.appendingPathComponent("payload-\(index).txt")
            try Data("payload \(index)".utf8).write(to: file)
            return file
        }

        let ids = try await files.asyncMap { file in
            try await coordinator.send(items: [file], to: peer)
        }
        try await connector.waitUntilStarted(2)
        try await Task.sleep(for: .milliseconds(100))

        let started = await connector.startedIDs()
        XCTAssertEqual(started, Array(ids.prefix(2)))

        await connector.releaseAll()
        for id in ids { await coordinator.cancel(id) }
    }

    func testCancellationWatchdogReleasesSlotFromStuckConnector() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let peer = DeviceID(rawValue: UUID())
        let connector = CountingBlockingConnector()
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        let coordinator = TransferCoordinator(
            connector: connector,
            database: database,
            maximumConnectionAttempts: 1
        )
        let files = try (0..<3).map { index in
            let file = root.appendingPathComponent("stuck-\(index).txt")
            try Data("payload \(index)".utf8).write(to: file)
            return file
        }
        let ids = try await files.asyncMap { file in
            try await coordinator.send(items: [file], to: peer)
        }
        try await connector.waitUntilStarted(2)

        await coordinator.cancel(ids[0])
        try await waitForPhase(.cancelled, id: ids[0], on: coordinator)
        try await connector.waitUntilStarted(3)

        let started = await connector.startedIDs()
        XCTAssertEqual(started, ids)
        await connector.releaseAll()
        await coordinator.cancel(ids[1])
        await coordinator.cancel(ids[2])
    }

    func testReconnectUsesSameTransferIDAndPublishesNewRoute() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("large.bin")
        let sourceData = Data(
            (0..<(TransferProtocolLimits.maximumChunkBytes * 4)).map { UInt8($0 % 251) }
        )
        try sourceData.write(to: source)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        let peer = DeviceID(rawValue: UUID())
        let connector = ReconnectingMemoryConnector(destination: destination)
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        let coordinator = TransferCoordinator(connector: connector, database: database)

        let id = try await coordinator.send(items: [source], to: peer)
        try await waitForPhase(.completed, id: id, on: coordinator)

        let connectedIDs = await connector.connectedTransferIDs()
        XCTAssertEqual(connectedIDs, [id, id])
        let records = try await database.history()
        XCTAssertEqual(records.filter { $0.id == id }.count, 1)
        XCTAssertEqual(records.first { $0.id == id }?.route, .relay)
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent(source.lastPathComponent)),
            sourceData
        )
    }

    func testIncomingListenerAutoReceivesTrustedTransferThroughReceiveStore() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("trusted.txt")
        let sourceData = Data("trusted automatic receive".utf8)
        try sourceData.write(to: sourceURL)
        let destination = root.appendingPathComponent("downloads", isDirectory: true)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        let sourceDevice = DeviceID(rawValue: UUID())
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        let source = MemoryIncomingTransferSource()
        let listener = IncomingTransferListener(
            source: source,
            policy: ReceivePolicy(trustedSources: [sourceDevice]),
            directories: DownloadDirectory(globalDirectory: destination),
            database: database,
            incomingDirectory: incoming
        )
        await listener.start()
        defer { Task { await listener.stop() } }
        let manifest = try TransferManifest.build(from: sourceURL)
        let pair = CoordinatorMemoryChannelPair.make()

        await source.offer(
            IncomingTransferConnection(
                source: sourceDevice,
                transferID: manifest.id,
                channel: pair.receiver
            )
        )
        _ = try await SendSession(manifest).run(on: pair.sender)
        try await waitForDatabasePhase(.completed, id: manifest.id, database: database)

        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent(sourceURL.lastPathComponent)),
            sourceData
        )
    }

    func testProductionConnectionCoordinatorBindsConnectionToTransferID() async throws {
        let attempts = TransferIdentityRecordingAttempts()
        let connector = ConnectionCoordinator(attempts: attempts)
        let peer = DeviceID(rawValue: UUID())
        let transferID = TransferID(rawValue: UUID())

        _ = try await connector.connect(to: peer, transferID: transferID)

        let identities = await attempts.identities()
        XCTAssertEqual(identities, [transferID])
    }

    func testPauseDuringConnectStaysPausedUntilExplicitResume() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("pause.txt")
        try Data("pause then resume".utf8).write(to: source)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        let connector = PausingMemoryConnector(destination: destination)
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        let coordinator = TransferCoordinator(connector: connector, database: database)
        let id = try await coordinator.send(
            items: [source],
            to: DeviceID(rawValue: UUID())
        )
        try await connector.waitUntilConnecting()

        await coordinator.pause(id)
        await connector.releaseConnection()
        try await Task.sleep(for: .milliseconds(100))

        let pausedPhase = await currentPhase(id, on: coordinator)
        XCTAssertEqual(pausedPhase, .paused)

        try await coordinator.resume(id)
        try await waitForPhase(.completed, id: id, on: coordinator)
    }

    func testIncomingListenerRejectsUntrustedSourceBeforeStaging() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("untrusted.txt")
        try Data("must not arrive".utf8).write(to: sourceURL)
        let destination = root.appendingPathComponent("downloads", isDirectory: true)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        let sourceDevice = DeviceID(rawValue: UUID())
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        let source = MemoryIncomingTransferSource()
        let listener = IncomingTransferListener(
            source: source,
            policy: ReceivePolicy(trustedSources: []),
            directories: DownloadDirectory(globalDirectory: destination),
            database: database,
            incomingDirectory: incoming
        )
        await listener.start()
        defer { Task { await listener.stop() } }
        let manifest = try TransferManifest.build(from: sourceURL)
        let pair = CoordinatorMemoryChannelPair.make()
        await source.offer(
            IncomingTransferConnection(
                source: sourceDevice,
                transferID: manifest.id,
                channel: pair.receiver
            )
        )

        do {
            _ = try await SendSession(manifest).run(on: pair.sender)
            XCTFail("Expected the untrusted source to be rejected")
        } catch {}

        let history = try await database.history()
        XCTAssertTrue(history.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent(sourceURL.lastPathComponent).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath:
                    incoming
                    .appendingPathComponent(manifest.id.rawValue.uuidString.lowercased())
                    .path
            )
        )
    }

    func testIncomingListenerRecoversPartialTransferAfterRestart() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("restart.bin")
        let sourceData = Data(
            (0..<(TransferProtocolLimits.maximumChunkBytes * 4)).map { UInt8($0 % 239) }
        )
        try sourceData.write(to: sourceURL)
        let destination = root.appendingPathComponent("downloads", isDirectory: true)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        let sourceDevice = DeviceID(rawValue: UUID())
        let policy = ReceivePolicy(trustedSources: [sourceDevice])
        let directories = DownloadDirectory(globalDirectory: destination)
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        let manifest = try TransferManifest.build(from: sourceURL)

        let firstSource = MemoryIncomingTransferSource()
        let firstListener = IncomingTransferListener(
            source: firstSource,
            policy: policy,
            directories: directories,
            database: database,
            incomingDirectory: incoming
        )
        await firstListener.start()
        let interrupted = CoordinatorMemoryChannelPair.make(failSenderAfter: 3)
        await firstSource.offer(
            IncomingTransferConnection(
                source: sourceDevice,
                transferID: manifest.id,
                channel: interrupted.receiver
            )
        )
        do {
            _ = try await SendSession(manifest).run(on: interrupted.sender)
            XCTFail("Expected an interrupted first attempt")
        } catch {}
        try await waitForDatabasePhase(.failed, id: manifest.id, database: database)
        await firstListener.stop()

        let restartedSource = MemoryIncomingTransferSource()
        let restartedListener = IncomingTransferListener(
            source: restartedSource,
            policy: policy,
            directories: directories,
            database: database,
            incomingDirectory: incoming
        )
        await restartedListener.start()
        defer { Task { await restartedListener.stop() } }
        let resumed = CoordinatorMemoryChannelPair.make()
        await restartedSource.offer(
            IncomingTransferConnection(
                source: sourceDevice,
                transferID: manifest.id,
                channel: resumed.receiver
            )
        )

        _ = try await SendSession(manifest).run(on: resumed.sender)
        try await waitForDatabasePhase(.completed, id: manifest.id, database: database)

        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent(sourceURL.lastPathComponent)),
            sourceData
        )
    }

    func testCancellationClosesChannelAndDurablyCancelsReceiveStaging() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("cancel.bin")
        try Data(
            (0..<(TransferProtocolLimits.maximumChunkBytes * 8)).map { UInt8($0 % 227) }
        ).write(to: sourceURL)
        let destination = root.appendingPathComponent("downloads", isDirectory: true)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        let senderDevice = DeviceID(rawValue: UUID())
        let receiverDevice = DeviceID(rawValue: UUID())
        let receiveDatabase = try TransferDatabase(
            url: root.appendingPathComponent("receive-history.sqlite")
        )
        let connector = CancellationMemoryConnector(
            source: senderDevice,
            policy: ReceivePolicy(trustedSources: [senderDevice]),
            directories: DownloadDirectory(globalDirectory: destination),
            database: receiveDatabase,
            incomingDirectory: incoming
        )
        let sendDatabase = try TransferDatabase(
            url: root.appendingPathComponent("send-history.sqlite")
        )
        let coordinator = TransferCoordinator(connector: connector, database: sendDatabase)

        let id = try await coordinator.send(items: [sourceURL], to: receiverDevice)
        try await connector.waitUntilSenderHasSent(3)
        await coordinator.cancel(id)
        try await waitForPhase(.cancelled, id: id, on: coordinator)
        try await waitForDatabasePhase(.cancelled, id: id, database: receiveDatabase)

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent(sourceURL.lastPathComponent).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath:
                    incoming
                    .appendingPathComponent(id.rawValue.uuidString.lowercased())
                    .path
            )
        )
    }

    func testCoordinatorRestartRecoversInterruptedHistoryAsFailedSnapshot() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        let id = TransferID(rawValue: UUID())
        let peer = DeviceID(rawValue: UUID())
        let preparing = TransferSnapshot(
            id: id,
            peer: peer,
            phase: .preparing,
            completedBytes: 0,
            totalBytes: 100,
            route: .lan
        )
        try await database.record(preparing, displayFilename: "restart.bin")
        try await database.record(
            TransferSnapshot(
                id: id,
                peer: peer,
                phase: .transferring,
                completedBytes: 40,
                totalBytes: 100,
                route: .directInternet
            ),
            displayFilename: "restart.bin"
        )

        let coordinator = try await TransferCoordinator.restoring(
            connector: CountingBlockingConnector(),
            database: database
        )

        let phase = await currentPhase(id, on: coordinator)
        XCTAssertEqual(phase, .failed)
        let history = try await database.history()
        XCTAssertEqual(history.first?.phase, .failed)
    }

    func testSnapshotsPublishDurableByteProgressBeforeCompletion() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("progress.bin")
        try Data(
            (0..<(TransferProtocolLimits.maximumChunkBytes * 8)).map { UInt8($0 % 211) }
        ).write(to: sourceURL)
        let destination = root.appendingPathComponent("downloads", isDirectory: true)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        let senderDevice = DeviceID(rawValue: UUID())
        let receiverDevice = DeviceID(rawValue: UUID())
        let receiveDatabase = try TransferDatabase(
            url: root.appendingPathComponent("receive-history.sqlite")
        )
        let connector = CancellationMemoryConnector(
            source: senderDevice,
            policy: ReceivePolicy(trustedSources: [senderDevice]),
            directories: DownloadDirectory(globalDirectory: destination),
            database: receiveDatabase,
            incomingDirectory: incoming
        )
        let sendDatabase = try TransferDatabase(
            url: root.appendingPathComponent("send-history.sqlite")
        )
        let coordinator = TransferCoordinator(connector: connector, database: sendDatabase)
        let stream = await coordinator.snapshots()

        let id = try await coordinator.send(items: [sourceURL], to: receiverDevice)
        let progress = try await firstProgressSnapshot(id: id, from: stream)

        XCTAssertGreaterThan(progress.completedBytes, 0)
        XCTAssertLessThan(progress.completedBytes, progress.totalBytes)
        let record = try await sendDatabase.history().first { $0.id == id }
        XCTAssertEqual(record?.completedBytes, UInt64(progress.completedBytes))
        try await waitForPhase(.completed, id: id, on: coordinator)
    }

    func testAuthenticationFailureFailsClosedWithoutReconnect() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("auth.txt")
        try Data("authentication must fail closed".utf8).write(to: source)
        let connector = AuthenticationFailureConnector()
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        let coordinator = TransferCoordinator(connector: connector, database: database)

        let id = try await coordinator.send(
            items: [source],
            to: DeviceID(rawValue: UUID())
        )
        try await waitForPhase(.failed, id: id, on: coordinator)

        let attempts = await connector.attemptCount()
        XCTAssertEqual(attempts, 1)
    }
}

private func firstProgressSnapshot(
    id: TransferID,
    from stream: AsyncStream<[TransferSnapshot]>
) async throws -> TransferSnapshot {
    try await withThrowingTaskGroup(of: TransferSnapshot.self) { group in
        group.addTask {
            for await snapshots in stream {
                if let snapshot = snapshots.first(where: {
                    $0.id == id && $0.completedBytes > 0 && $0.completedBytes < $0.totalBytes
                }) {
                    return snapshot
                }
            }
            throw CoordinatorTestError.streamEnded
        }
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            throw CoordinatorTestError.timedOut
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

private func currentPhase(
    _ id: TransferID,
    on coordinator: TransferCoordinator
) async -> TransferPhase? {
    let stream = await coordinator.snapshots()
    var iterator = stream.makeAsyncIterator()
    return await iterator.next()?.first(where: { $0.id == id })?.phase
}

private func waitForDatabasePhase(
    _ phase: TransferPhase,
    id: TransferID,
    database: TransferDatabase
) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if try await database.history().first(where: { $0.id == id })?.phase == phase { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw CoordinatorTestError.timedOut
}

private func waitForPhase(
    _ phase: TransferPhase,
    id: TransferID,
    on coordinator: TransferCoordinator
) async throws {
    let stream = await coordinator.snapshots()
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            for await snapshots in stream {
                if snapshots.first(where: { $0.id == id })?.phase == phase { return }
            }
            throw CoordinatorTestError.streamEnded
        }
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            throw CoordinatorTestError.timedOut
        }
        _ = try await group.next()
        group.cancelAll()
    }
}

private func makeCoordinatorTemporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

extension Array {
    fileprivate func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        result.reserveCapacity(count)
        for element in self {
            result.append(try await transform(element))
        }
        return result
    }
}

private actor CountingBlockingConnector: TransferAwarePeerConnector {
    private var started: [TransferID] = []
    private var connectionWaiters: [CheckedContinuation<Void, Never>] = []

    func connect(to device: DeviceID) async throws -> any SecureChannel {
        throw MacChannelError.connectionFailed
    }

    func connect(to device: DeviceID, transferID: TransferID) async throws -> any SecureChannel {
        started.append(transferID)
        await withCheckedContinuation { continuation in
            connectionWaiters.append(continuation)
        }
        throw MacChannelError.connectionFailed
    }

    func startedIDs() -> [TransferID] {
        started
    }

    func waitUntilStarted(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while started.count < count {
            guard ContinuousClock.now < deadline else { throw CoordinatorTestError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func releaseAll() {
        let waiters = connectionWaiters
        connectionWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private actor AuthenticationFailureConnector: TransferAwarePeerConnector {
    private var attempts = 0

    func connect(to device: DeviceID) async throws -> any SecureChannel {
        throw ConnectionAttemptError.authenticationFailed
    }

    func connect(to device: DeviceID, transferID: TransferID) async throws -> any SecureChannel {
        attempts += 1
        throw ConnectionAttemptError.authenticationFailed
    }

    func attemptCount() -> Int { attempts }
}

private actor ReconnectingMemoryConnector: TransferAwarePeerConnector {
    private let destination: URL
    private var ids: [TransferID] = []
    private var previousReceive: Task<TransferReceiveResult?, Never>?

    init(destination: URL) {
        self.destination = destination
    }

    func connect(to device: DeviceID) async throws -> any SecureChannel {
        throw MacChannelError.connectionFailed
    }

    func connect(to device: DeviceID, transferID: TransferID) async throws -> any SecureChannel {
        if let previousReceive { _ = await previousReceive.value }
        ids.append(transferID)
        let first = ids.count == 1
        let pair = CoordinatorMemoryChannelPair.make(
            route: first ? .lan : .relay,
            failSenderAfter: first ? 3 : nil
        )
        previousReceive = Task {
            try? await ReceiveSession(
                transferID: transferID,
                destinationDirectory: destination
            ).run(on: pair.receiver)
        }
        return pair.sender
    }

    func connectedTransferIDs() -> [TransferID] {
        ids
    }
}

private actor MemoryIncomingTransferSource: IncomingTransferConnectionSource {
    private let stream: AsyncThrowingStream<IncomingTransferConnection, Error>
    private let continuation: AsyncThrowingStream<IncomingTransferConnection, Error>.Continuation

    init() {
        var continuation: AsyncThrowingStream<IncomingTransferConnection, Error>.Continuation!
        stream = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(16)) {
            continuation = $0
        }
        self.continuation = continuation
    }

    func connections() -> AsyncThrowingStream<IncomingTransferConnection, Error> {
        stream
    }

    func offer(_ connection: IncomingTransferConnection) {
        continuation.yield(connection)
    }
}

private actor TransferIdentityRecordingAttempts: TransferAwareConnectionAttempting {
    private var transferIDs: [TransferID] = []

    func connect(to device: DeviceID, route: ConnectionRoute) async throws -> any SecureChannel {
        throw MacChannelError.connectionFailed
    }

    func connect(
        to device: DeviceID,
        route: ConnectionRoute,
        transferID: TransferID
    ) async throws -> any SecureChannel {
        transferIDs.append(transferID)
        return CoordinatorMemoryChannelPair.make(route: route).sender
    }

    func identities() -> [TransferID] {
        transferIDs
    }
}

private actor PausingMemoryConnector: TransferAwarePeerConnector {
    private let destination: URL
    private var connecting = false
    private var released = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(destination: URL) {
        self.destination = destination
    }

    func connect(to device: DeviceID) async throws -> any SecureChannel {
        throw MacChannelError.connectionFailed
    }

    func connect(to device: DeviceID, transferID: TransferID) async throws -> any SecureChannel {
        connecting = true
        if !released {
            await withCheckedContinuation { continuation in
                releaseWaiter = continuation
            }
        }
        let pair = CoordinatorMemoryChannelPair.make()
        Task {
            _ = try? await ReceiveSession(
                transferID: transferID,
                destinationDirectory: destination
            ).run(on: pair.receiver)
        }
        return pair.sender
    }

    func waitUntilConnecting() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !connecting {
            guard ContinuousClock.now < deadline else { throw CoordinatorTestError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func releaseConnection() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor CancellationMemoryConnector: TransferAwarePeerConnector {
    private let source: DeviceID
    private let policy: ReceivePolicy
    private let directories: DownloadDirectory
    private let database: TransferDatabase
    private let incomingDirectory: URL
    private var senderChannel: CoordinatorMemoryChannel?

    init(
        source: DeviceID,
        policy: ReceivePolicy,
        directories: DownloadDirectory,
        database: TransferDatabase,
        incomingDirectory: URL
    ) {
        self.source = source
        self.policy = policy
        self.directories = directories
        self.database = database
        self.incomingDirectory = incomingDirectory
    }

    func connect(to device: DeviceID) async throws -> any SecureChannel {
        throw MacChannelError.connectionFailed
    }

    func connect(to device: DeviceID, transferID: TransferID) async throws -> any SecureChannel {
        let pair = CoordinatorMemoryChannelPair.make(senderDelay: .milliseconds(20))
        senderChannel = pair.sender
        Task {
            _ = try? await ReceiveSession(
                transferID: transferID,
                source: source,
                policy: policy,
                directories: directories,
                database: database,
                incomingDirectory: incomingDirectory
            ).run(on: pair.receiver)
        }
        return pair.sender
    }

    func waitUntilSenderHasSent(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
            if let senderChannel, await senderChannel.sentCount() >= count { return }
            guard ContinuousClock.now < deadline else { throw CoordinatorTestError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class CoordinatorFixture: @unchecked Sendable {
    let root: URL
    let file: URL
    let sourceData = Data("one intended peer".utf8)
    let peerA = DeviceID(rawValue: UUID())
    let peerB = DeviceID(rawValue: UUID())
    let sender: TransferCoordinator

    private let destinations: [DeviceID: URL]

    init(twoPeers: Bool) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destinationA = root.appendingPathComponent("peer-a", isDirectory: true)
        let destinationB = root.appendingPathComponent("peer-b", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationA, withIntermediateDirectories: true)
        if twoPeers {
            try FileManager.default.createDirectory(
                at: destinationB,
                withIntermediateDirectories: true
            )
        }
        file = source.appendingPathComponent("payload.txt")
        try sourceData.write(to: file)
        destinations = [peerA: destinationA, peerB: destinationB]
        let connector = CoordinatorMemoryConnector(destinations: destinations)
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        sender = TransferCoordinator(connector: connector, database: database)
    }

    func waitUntilCompleted(_ id: TransferID) async throws {
        let stream = await sender.snapshots()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await snapshots in stream {
                    if snapshots.first(where: { $0.id == id })?.phase == .completed {
                        return
                    }
                }
                throw CoordinatorTestError.streamEnded
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw CoordinatorTestError.timedOut
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    func receivedData(on peer: DeviceID) throws -> Data? {
        guard let destination = destinations[peer] else { return nil }
        let received = destination.appendingPathComponent(file.lastPathComponent)
        guard FileManager.default.fileExists(atPath: received.path) else { return nil }
        return try Data(contentsOf: received)
    }

    func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum CoordinatorTestError: Error {
    case streamEnded
    case timedOut
}

private actor CoordinatorMemoryConnector: TransferAwarePeerConnector {
    private let destinations: [DeviceID: URL]
    private var receiveTasks: [TransferID: Task<Void, Never>] = [:]

    init(destinations: [DeviceID: URL]) {
        self.destinations = destinations
    }

    func connect(to device: DeviceID) async throws -> any SecureChannel {
        throw MacChannelError.connectionFailed
    }

    func connect(to device: DeviceID, transferID: TransferID) async throws -> any SecureChannel {
        guard let destination = destinations[device] else {
            throw MacChannelError.connectionFailed
        }
        let pair = CoordinatorMemoryChannelPair.make()
        receiveTasks[transferID] = Task {
            _ = try? await ReceiveSession(
                transferID: transferID,
                destinationDirectory: destination
            ).run(on: pair.receiver)
        }
        return pair.sender
    }
}

private final class CoordinatorMemoryChannel: SecureChannel, @unchecked Sendable {
    let route: ConnectionRoute

    private let key: Data
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let sendGate: CoordinatorMemorySendGate
    private weak var peer: CoordinatorMemoryChannel?

    init(
        route: ConnectionRoute,
        key: Data,
        failAfter: Int? = nil,
        sendDelay: Duration? = nil
    ) {
        self.route = route
        self.key = key
        sendGate = CoordinatorMemorySendGate(failAfter: failAfter, delay: sendDelay)
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        stream = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(128)) {
            continuation = $0
        }
        self.continuation = continuation
    }

    func connect(to peer: CoordinatorMemoryChannel) {
        self.peer = peer
    }

    func send(_ frame: Data) async throws {
        guard let peer else { throw MacChannelError.connectionFailed }
        guard await sendGate.permit() else {
            continuation.finish(throwing: MacChannelError.connectionFailed)
            peer.continuation.finish(throwing: MacChannelError.connectionFailed)
            throw MacChannelError.connectionFailed
        }
        switch peer.continuation.yield(frame) {
        case .enqueued:
            return
        case .dropped, .terminated:
            throw MacChannelError.connectionFailed
        @unknown default:
            throw MacChannelError.connectionFailed
        }
    }

    func frames() -> AsyncThrowingStream<Data, Error> {
        stream
    }

    func exportKey(label: String, context: Data, length: Int) async throws -> Data {
        guard label == "macchannel-transfer-v1", context.count == 16, length == key.count else {
            throw MacChannelError.connectionFailed
        }
        return key
    }

    func close() async {
        continuation.finish()
        peer?.continuation.finish()
    }

    func sentCount() async -> Int {
        await sendGate.sentCount()
    }
}

private actor CoordinatorMemorySendGate {
    private let failAfter: Int?
    private let delay: Duration?
    private var count = 0

    init(failAfter: Int?, delay: Duration?) {
        self.failAfter = failAfter
        self.delay = delay
    }

    func permit() async -> Bool {
        if let delay { try? await Task.sleep(for: delay) }
        count += 1
        guard let failAfter else { return true }
        return count <= failAfter
    }

    func sentCount() -> Int { count }
}

private enum CoordinatorMemoryChannelPair {
    static func make(
        route: ConnectionRoute = .lan,
        failSenderAfter: Int? = nil,
        senderDelay: Duration? = nil
    ) -> (
        sender: CoordinatorMemoryChannel,
        receiver: CoordinatorMemoryChannel
    ) {
        let key = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        let sender = CoordinatorMemoryChannel(
            route: route,
            key: key,
            failAfter: failSenderAfter,
            sendDelay: senderDelay
        )
        let receiver = CoordinatorMemoryChannel(route: route, key: key)
        sender.connect(to: receiver)
        receiver.connect(to: sender)
        return (sender, receiver)
    }
}
