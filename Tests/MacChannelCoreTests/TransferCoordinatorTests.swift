import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import MacChannelCore

private actor IncomingResultRecorder {
    private var results: [TransferReceiveResult?] = []

    func record(_ result: TransferReceiveResult?) {
        results.append(result)
    }

    func successfulResult() -> TransferReceiveResult? {
        results.compactMap { $0 }.last
    }
}

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
        defer { removeCoordinatorTemporaryDirectory(root) }
        let peer = DeviceID(rawValue: UUID())
        let connector = CountingBlockingConnector()
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        let coordinator = TransferCoordinator(
            connector: connector,
            database: database,
            outgoingDirectory: root.appendingPathComponent("outgoing")
        )
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
        defer { removeCoordinatorTemporaryDirectory(root) }
        let peer = DeviceID(rawValue: UUID())
        let connector = CountingBlockingConnector()
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        let coordinator = TransferCoordinator(
            connector: connector,
            database: database,
            outgoingDirectory: root.appendingPathComponent("outgoing"),
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
        defer { removeCoordinatorTemporaryDirectory(root) }
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
        let coordinator = TransferCoordinator(
            connector: connector,
            database: database,
            outgoingDirectory: root.appendingPathComponent("outgoing")
        )

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

    func testDataPlaneFailureEscalatesPastTheRouteThatAlreadyConnected() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let source = root.appendingPathComponent("route-escalation.bin")
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
        let connector = RouteEscalatingMemoryConnector(destination: destination)
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        let coordinator = TransferCoordinator(
            connector: connector,
            database: database,
            outgoingDirectory: root.appendingPathComponent("outgoing")
        )

        let id = try await coordinator.send(items: [source], to: peer)
        try await waitForPhase(.completed, id: id, on: coordinator)

        let failedRouteHints = await connector.failedRouteHints()
        XCTAssertEqual(failedRouteHints, [nil, nil, .directInternet])
        let records = try await database.history()
        XCTAssertEqual(records.first { $0.id == id }?.route, .relay)
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent(source.lastPathComponent)),
            sourceData
        )
    }

    func testIncomingListenerAutoReceivesTrustedTransferThroughReceiveStore() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let sourceURL = root.appendingPathComponent("trusted.txt")
        let sourceData = Data("trusted automatic receive".utf8)
        try sourceData.write(to: sourceURL)
        let destination = root.appendingPathComponent("downloads", isDirectory: true)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        let occupiedDestination = destination.appendingPathComponent(sourceURL.lastPathComponent)
        let existingData = Data("existing destination".utf8)
        try existingData.write(to: occupiedDestination)
        let sourceDevice = DeviceID(rawValue: UUID())
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        let source = MemoryIncomingTransferSource()
        let receivedResults = IncomingResultRecorder()
        let listener = IncomingTransferListener(
            source: source,
            policy: ReceivePolicy(trustedSources: [sourceDevice]),
            directories: DownloadDirectory(globalDirectory: destination),
            database: database,
            incomingDirectory: incoming,
            onReceiveFinished: { result in
                await receivedResults.record(result)
            }
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
        try await waitForClose(on: pair.receiver)

        XCTAssertEqual(try Data(contentsOf: occupiedDestination), existingData)
        let recorded = await receivedResults.successfulResult()
        let result = try XCTUnwrap(recorded)
        XCTAssertEqual(result.transferID, manifest.id)
        let actualOutput = try XCTUnwrap(result.receivedURLs.first)
        XCTAssertNotEqual(actualOutput, occupiedDestination)
        XCTAssertEqual(try Data(contentsOf: actualOutput), sourceData)
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
        defer { removeCoordinatorTemporaryDirectory(root) }
        let source = root.appendingPathComponent("pause.txt")
        try Data("pause then resume".utf8).write(to: source)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        let connector = PausingMemoryConnector(destination: destination)
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        let coordinator = TransferCoordinator(
            connector: connector,
            database: database,
            outgoingDirectory: root.appendingPathComponent("outgoing")
        )
        let id = try await coordinator.send(
            items: [source],
            to: DeviceID(rawValue: UUID())
        )
        try await connector.waitUntilConnecting()

        try await coordinator.pause(id)
        await connector.releaseConnection()
        try await Task.sleep(for: .milliseconds(100))

        let pausedPhase = await currentPhase(id, on: coordinator)
        XCTAssertEqual(pausedPhase, .paused)

        try await coordinator.resume(id)
        try await waitForPhase(.completed, id: id, on: coordinator)
    }

    func testResumeOfKnownNonpausedTransferThrowsInvalidState() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let source = root.appendingPathComponent("stale-resume.txt")
        try Data("resume exactly once".utf8).write(to: source)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let connector = PausingMemoryConnector(destination: destination)
        let coordinator = TransferCoordinator(
            connector: connector,
            database: try TransferDatabase(url: root.appendingPathComponent("history.sqlite")),
            outgoingDirectory: root.appendingPathComponent("outgoing")
        )
        let id = try await coordinator.send(items: [source], to: DeviceID(rawValue: UUID()))
        try await connector.waitUntilConnecting()

        do {
            try await coordinator.resume(id)
            XCTFail("A nonpaused transfer must reject stale resume controls")
        } catch {
            XCTAssertEqual(error as? MacChannelError, .transferInvalidState)
        }
        await coordinator.cancel(id)
        await connector.releaseConnection()
    }

    func testIncomingListenerRejectsUntrustedSourceBeforeStaging() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
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
        defer { removeCoordinatorTemporaryDirectory(root) }
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
        defer { removeCoordinatorTemporaryDirectory(root) }
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
        let coordinator = TransferCoordinator(
            connector: connector,
            database: sendDatabase,
            outgoingDirectory: root.appendingPathComponent("outgoing")
        )

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
        defer { removeCoordinatorTemporaryDirectory(root) }
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
        try await database.record(
            preparing,
            displayFilename: "restart.bin",
            direction: .outbound
        )
        try await database.record(
            TransferSnapshot(
                id: id,
                peer: peer,
                phase: .transferring,
                completedBytes: 40,
                totalBytes: 100,
                route: .directInternet
            ),
            displayFilename: "restart.bin",
            direction: .outbound
        )

        let coordinator = try await TransferCoordinator.restoring(
            connector: CountingBlockingConnector(),
            database: database,
            outgoingDirectory: root.appendingPathComponent("outgoing")
        )

        let phase = await currentPhase(id, on: coordinator)
        XCTAssertEqual(phase, .failed)
        let history = try await database.history()
        XCTAssertEqual(history.first?.phase, .failed)
    }

    func testSharedDatabaseRestoreLeavesInboundCancellingOwnedByReceiveStore() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        let peer = DeviceID(rawValue: UUID())
        let inboundID = TransferID(rawValue: UUID())
        try await database.record(
            TransferSnapshot(
                id: inboundID,
                peer: peer,
                phase: .cancelling,
                completedBytes: 2,
                totalBytes: 10,
                route: .lan
            ),
            displayFilename: "incoming.bin"
        )

        let payload = root.appendingPathComponent("outbound.bin")
        try Data("resume me".utf8).write(to: payload)
        let outgoing = root.appendingPathComponent("outgoing")
        let package = try OutgoingTransferPackage.create(items: [payload], peer: peer, in: outgoing)
        try await database.record(
            TransferSnapshot(
                id: package.id,
                peer: peer,
                phase: .transferring,
                completedBytes: 0,
                totalBytes: package.totalBytes,
                route: .relay
            ),
            displayFilename: package.displayFilename,
            direction: .outbound
        )
        let connector = CountingBlockingConnector()
        let coordinator = try await TransferCoordinator.restoring(
            connector: connector,
            database: database,
            outgoingDirectory: outgoing,
            cancellationWatchdogDelay: .milliseconds(20)
        )
        try await connector.waitUntilStarted(1)

        let inbound = try await database.persistedTransfer(id: inboundID)
        XCTAssertEqual(inbound?.phase, .cancelling)
        XCTAssertEqual(inbound?.direction, .inbound)
        let outbound = try await database.persistedTransfer(id: package.id)
        XCTAssertEqual(outbound?.direction, .outbound)

        await coordinator.cancel(package.id)
        await connector.releaseAll()
    }

    func testSnapshotsPublishDurableByteProgressBeforeCompletion() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
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
        let coordinator = TransferCoordinator(
            connector: connector,
            database: sendDatabase,
            outgoingDirectory: root.appendingPathComponent("outgoing")
        )
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
        defer { removeCoordinatorTemporaryDirectory(root) }
        let source = root.appendingPathComponent("auth.txt")
        try Data("authentication must fail closed".utf8).write(to: source)
        let connector = AuthenticationFailureConnector()
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        let coordinator = TransferCoordinator(
            connector: connector,
            database: database,
            outgoingDirectory: root.appendingPathComponent("outgoing")
        )

        let id = try await coordinator.send(
            items: [source],
            to: DeviceID(rawValue: UUID())
        )
        try await waitForPhase(.failed, id: id, on: coordinator)

        let attempts = await connector.attemptCount()
        XCTAssertEqual(attempts, 1)
        let packageDirectory = root.appendingPathComponent("outgoing/")
            .appendingPathComponent(id.rawValue.uuidString.lowercased())
        XCTAssertFalse(FileManager.default.fileExists(atPath: packageDirectory.path))
    }

    func testTerminalSnapshotWaitsForRetriedPackageCleanup() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let source = root.appendingPathComponent("cleanup-retry.txt")
        try Data("cleanup must precede publication".utf8).write(to: source)
        let connector = CountingBlockingConnector()
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        let outgoing = root.appendingPathComponent("outgoing")
        let coordinator = TransferCoordinator(
            connector: connector,
            database: database,
            outgoingDirectory: outgoing,
            maximumConnectionAttempts: 1,
            persistenceRetryDelay: .milliseconds(10)
        )
        let id = try await coordinator.send(
            items: [source],
            to: DeviceID(rawValue: UUID())
        )
        try await connector.waitUntilStarted(1)
        XCTAssertEqual(chmod(outgoing.path, S_IRUSR | S_IXUSR), 0)
        await connector.releaseAll()
        try await waitForDatabasePhase(.failed, id: id, database: database)
        try await Task.sleep(for: .milliseconds(50))

        let packageDirectory = outgoing.appendingPathComponent(
            id.rawValue.uuidString.lowercased()
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageDirectory.path))
        let phaseBeforeCleanup = await currentPhase(id, on: coordinator)
        XCTAssertNotEqual(phaseBeforeCleanup, .failed)

        XCTAssertEqual(chmod(outgoing.path, S_IRWXU), 0)
        try await waitForPhase(.failed, id: id, on: coordinator)
        XCTAssertFalse(FileManager.default.fileExists(atPath: packageDirectory.path))
    }

    func testCoordinatorPublishesMixedSelectedItemsAsOneContainerToOnePeer() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destinationA = root.appendingPathComponent("peer-a", isDirectory: true)
        let destinationB = root.appendingPathComponent("peer-b", isDirectory: true)
        let outgoing = root.appendingPathComponent("outgoing", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationB, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("note.txt")
        let folder = source.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("note".utf8).write(to: file)
        try Data("image".utf8).write(to: folder.appendingPathComponent("one.jpg"))
        let peerA = DeviceID(rawValue: UUID())
        let peerB = DeviceID(rawValue: UUID())
        let connector = CoordinatorMemoryConnector(
            destinations: [peerA: destinationA, peerB: destinationB]
        )
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        let coordinator = TransferCoordinator(
            connector: connector,
            database: database,
            outgoingDirectory: outgoing
        )

        let id = try await coordinator.send(items: [folder, file], to: peerA)
        try await waitForPhase(.completed, id: id, on: coordinator)

        let container = destinationA.appendingPathComponent("MacChannel Transfer")
        XCTAssertEqual(
            try Data(contentsOf: container.appendingPathComponent("note.txt")),
            Data("note".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: container.appendingPathComponent("photos/one.jpg")),
            Data("image".utf8)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destinationB.appendingPathComponent("MacChannel Transfer").path
            )
        )
        let connectedIDs = await connector.connectedTransferIDs()
        XCTAssertEqual(connectedIDs, [id])
    }

    func testCoordinatorRejectsFilesystemEquivalentSelectedNames() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let composed = first.appendingPathComponent("caf\u{00e9}.txt")
        let decomposed = second.appendingPathComponent("cafe\u{0301}.txt")
        try Data("one".utf8).write(to: composed)
        try Data("two".utf8).write(to: decomposed)
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        let coordinator = TransferCoordinator(
            connector: CountingBlockingConnector(),
            database: database,
            outgoingDirectory: root.appendingPathComponent("outgoing")
        )

        do {
            _ = try await coordinator.send(
                items: [composed, decomposed],
                to: DeviceID(rawValue: UUID())
            )
            XCTFail("Expected equivalent selected names to be rejected")
        } catch {
            XCTAssertEqual(error as? TransferProtocolError, .destinationPathCollision)
        }
        let history = try await database.history()
        XCTAssertTrue(history.isEmpty)
    }

    func testIncomingSilentPeersTimeOutCloseAndAdvanceQueue() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let sourceDevice = DeviceID(rawValue: UUID())
        let destination = root.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let source = MemoryIncomingTransferSource()
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        let listener = IncomingTransferListener(
            source: source,
            policy: ReceivePolicy(trustedSources: [sourceDevice]),
            directories: DownloadDirectory(globalDirectory: destination),
            database: database,
            incomingDirectory: root.appendingPathComponent("incoming"),
            inactivityTimeout: .milliseconds(50)
        )
        let firstSilent = CloseTrackingSilentChannel()
        let secondSilent = CloseTrackingSilentChannel()
        await listener.start()
        await source.offer(
            IncomingTransferConnection(
                source: sourceDevice,
                transferID: TransferID(rawValue: UUID()),
                channel: firstSilent
            )
        )
        await source.offer(
            IncomingTransferConnection(
                source: sourceDevice,
                transferID: TransferID(rawValue: UUID()),
                channel: secondSilent
            )
        )

        let payload = root.appendingPathComponent("queued.txt")
        try Data("queue advanced".utf8).write(to: payload)
        let manifest = try TransferManifest.build(from: payload)
        let pair = CoordinatorMemoryChannelPair.make()
        let sender = Task { try await SendSession(manifest).run(on: pair.sender) }
        await source.offer(
            IncomingTransferConnection(
                source: sourceDevice,
                transferID: manifest.id,
                channel: pair.receiver
            )
        )

        try await waitForDatabasePhase(.completed, id: manifest.id, database: database)
        _ = try await sender.value
        let firstCloseCount = await firstSilent.closeCount()
        let secondCloseCount = await secondSilent.closeCount()
        XCTAssertGreaterThanOrEqual(firstCloseCount, 1)
        XCTAssertGreaterThanOrEqual(secondCloseCount, 1)
        await listener.stop()
    }

    func testIncomingCancellationInsensitiveCloseCapStopsAdmissionAndRemainsBounded()
        async throws
    {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let sourceDevice = DeviceID(rawValue: UUID())
        let destination = root.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let source = MemoryIncomingTransferSource()
        let listener = IncomingTransferListener(
            source: source,
            policy: ReceivePolicy(trustedSources: [sourceDevice]),
            directories: DownloadDirectory(globalDirectory: destination),
            database: try TransferDatabase(url: root.appendingPathComponent("history.sqlite")),
            incomingDirectory: root.appendingPathComponent("incoming"),
            inactivityTimeout: .milliseconds(20)
        )
        let gate = BlockingCloseGate()
        await listener.start()
        for _ in 0..<6 {
            await source.offer(
                IncomingTransferConnection(
                    source: sourceDevice,
                    transferID: TransferID(rawValue: UUID()),
                    channel: BlockingCloseChannel(base: CloseTrackingSilentChannel(), gate: gate)
                )
            )
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while await listener.retainedResourceCount()
            < BoundedChannelResourceRegistry.maximumPerDirection
        {
            guard ContinuousClock.now < deadline else {
                let resources = await listener.retainedResourceCount()
                XCTFail("retained=\(resources)")
                await gate.release()
                await listener.stop()
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(100))
        let retained = await listener.retainedResourceCount()
        XCTAssertEqual(retained, BoundedChannelResourceRegistry.maximumPerDirection)

        let stopping = Task { await listener.stop() }
        await gate.release()
        await stopping.value
        let releaseDeadline = ContinuousClock.now + .seconds(5)
        while await listener.retainedResourceCount() != 0 {
            guard ContinuousClock.now < releaseDeadline else {
                throw CoordinatorTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testIncomingBurstRetainsTwoActiveAndThirtyTwoQueuedBeforeNextSourcePull()
        async throws
    {
        XCTAssertEqual(IncomingTransferCapacity.maximumActiveTransfers, 2)
        XCTAssertEqual(IncomingTransferCapacity.maximumQueuedConnections, 32)
        XCTAssertEqual(IncomingTransferCapacity.maximumEstablishedConnections, 34)

        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let sourceDevice = DeviceID(rawValue: UUID())
        let destination = root.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let gate = CancellationInsensitiveFrameGate()
        let source = PullCountingIncomingSource(total: 100) { _ in
            IncomingTransferConnection(
                source: sourceDevice,
                transferID: TransferID(rawValue: UUID()),
                channel: CancellationInsensitiveFramesChannel(gate: gate)
            )
        }
        let listener = IncomingTransferListener(
            source: source,
            policy: ReceivePolicy(trustedSources: [sourceDevice]),
            directories: DownloadDirectory(globalDirectory: destination),
            database: try TransferDatabase(url: root.appendingPathComponent("history.sqlite")),
            incomingDirectory: root.appendingPathComponent("incoming"),
            inactivityTimeout: .seconds(30)
        )

        await listener.start()
        let deadline = ContinuousClock.now + .seconds(5)
        while await source.pullCount() < IncomingTransferCapacity.maximumAdmittedChannels {
            guard ContinuousClock.now < deadline else {
                let pulls = await source.pullCount()
                XCTFail("pulled=\(pulls)")
                await gate.release()
                await listener.stop()
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        try await gate.waitUntilStarted(2)
        try await Task.sleep(for: .milliseconds(100))
        let pullsAtCapacity = await source.pullCount()
        let activeReaders = await gate.startedCount()
        let activeTransfers = await listener.activeReceiveCount()
        let queuedConnections = await listener.queuedConnectionCount()
        XCTAssertEqual(pullsAtCapacity, IncomingTransferCapacity.maximumAdmittedChannels)
        XCTAssertEqual(activeReaders, 2)
        XCTAssertEqual(activeTransfers, IncomingTransferCapacity.maximumActiveTransfers)
        XCTAssertEqual(queuedConnections, IncomingTransferCapacity.maximumQueuedConnections)

        await listener.stop()
        await gate.release()
        let cleanupDeadline = ContinuousClock.now + .seconds(5)
        while await IncomingChannelCloseRegistry.shared.admittedChannelCount() != 0 {
            guard ContinuousClock.now < cleanupDeadline else {
                throw CoordinatorTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testIncomingCloseExecutorDrainsAdmittedChannelsFIFOAtFourWide() async throws {
        let registry = IncomingChannelCloseRegistry.shared
        let gate = OrderedCloseGate()
        var permits: [IncomingChannelCloseRegistry.Permit] = []
        for index in 0..<IncomingTransferCapacity.maximumAdmittedChannels {
            guard let permit = await registry.acquire() else {
                return XCTFail("Missing admission permit \(index)")
            }
            permits.append(permit)
            await registry.close(
                OrderedNoncooperativeCloseChannel(index: index, gate: gate),
                permit: permit,
                timeout: .milliseconds(10)
            )
        }

        let closeWidth = IncomingTransferCapacity.maximumConcurrentCloseOperations
        let queuedCount = IncomingTransferCapacity.maximumAdmittedChannels - closeWidth
        try await gate.waitUntilStarted(closeWidth)
        let initial = await gate.startedIndices()
        XCTAssertEqual(Set(initial), Set(0..<closeWidth))
        let activeAtCap = await registry.activeCloseCount()
        let queuedAtCap = await registry.queuedCloseCount()
        let admittedAtCap = await registry.admittedChannelCount()
        XCTAssertEqual(activeAtCap, IncomingTransferCapacity.maximumConcurrentCloseOperations)
        XCTAssertEqual(queuedAtCap, queuedCount)
        XCTAssertEqual(admittedAtCap, IncomingTransferCapacity.maximumAdmittedChannels)

        for index in 0..<queuedCount {
            await gate.release(index)
            try await gate.waitUntilStarted(index + closeWidth + 1)
            let started = await gate.startedIndices()
            XCTAssertEqual(started.last, index + closeWidth)
        }
        for index in queuedCount..<IncomingTransferCapacity.maximumAdmittedChannels {
            await gate.release(index)
        }

        let deadline = ContinuousClock.now + .seconds(5)
        while await registry.admittedChannelCount() != 0 {
            guard ContinuousClock.now < deadline else { throw CoordinatorTestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
        let finalStarted = await gate.startedIndices()
        XCTAssertEqual(finalStarted.count, IncomingTransferCapacity.maximumAdmittedChannels)
    }

    func testIncomingCloseAdmissionIsSharedAcrossCancelledListenerLifecycles() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let gate = NoncooperativeCloseGate()
        var lifecycles: [(IncomingTransferListener, SuspendedYieldIncomingSource)] = []

        for index in 0..<100 {
            let sourceID = DeviceID(rawValue: UUID())
            let transferID = TransferID(rawValue: UUID())
            let source = SuspendedYieldIncomingSource {
                IncomingTransferConnection(
                    source: sourceID,
                    transferID: transferID,
                    channel: NoncooperativeCloseChannel(gate: gate)
                )
            }
            let listener = IncomingTransferListener(
                source: source,
                policy: ReceivePolicy(trustedSources: []),
                database: try TransferDatabase(
                    url: root.appendingPathComponent("lifecycle-\(index).sqlite")
                ),
                incomingDirectory: root.appendingPathComponent("incoming-\(index)"),
                inactivityTimeout: .milliseconds(10)
            )
            await listener.start()
            lifecycles.append((listener, source))
        }

        let requestDeadline = ContinuousClock.now + .seconds(5)
        while await requestedSourceCount(lifecycles)
            < IncomingTransferCapacity.maximumAdmittedChannels
        {
            guard ContinuousClock.now < requestDeadline else {
                throw CoordinatorTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(50))
        let waitersAtCap = await IncomingChannelCloseRegistry.shared.waitingReaderCount()
        XCTAssertEqual(waitersAtCap, IncomingChannelCloseRegistry.maximumWaitingReaders)
        XCTAssertEqual(
            IncomingTransferCapacity.maximumEstablishedConnections,
            IncomingTransferCapacity.maximumAdmittedChannels
        )
        for (listener, _) in lifecycles { await listener.stop() }
        for (_, source) in lifecycles { await source.releaseYield() }

        try await gate.waitUntilStarted(BoundedChannelResourceRegistry.maximumPerDirection)
        try await Task.sleep(for: .milliseconds(50))
        let requestedAtCap = await requestedSourceCount(lifecycles)
        let createdAtCap = await createdSourceChannelCount(lifecycles)
        let startedAtCap = await gate.startedCount()
        let retainedAtCap = await BoundedChannelResourceRegistry.shared.counts()
        let admittedAtCap = await IncomingChannelCloseRegistry.shared.admittedChannelCount()
        let activeClosesAtCap = await IncomingChannelCloseRegistry.shared.activeCloseCount()
        let queuedClosesAtCap = await IncomingChannelCloseRegistry.shared.queuedCloseCount()
        XCTAssertEqual(requestedAtCap, IncomingTransferCapacity.maximumAdmittedChannels)
        XCTAssertEqual(createdAtCap, IncomingTransferCapacity.maximumAdmittedChannels)
        XCTAssertEqual(startedAtCap, BoundedChannelResourceRegistry.maximumPerDirection)
        XCTAssertEqual(retainedAtCap.inbound, BoundedChannelResourceRegistry.maximumPerDirection)
        XCTAssertEqual(admittedAtCap, IncomingTransferCapacity.maximumAdmittedChannels)
        XCTAssertEqual(
            activeClosesAtCap,
            IncomingTransferCapacity.maximumConcurrentCloseOperations
        )
        XCTAssertEqual(
            queuedClosesAtCap,
            IncomingTransferCapacity.maximumAdmittedChannels
                - IncomingTransferCapacity.maximumConcurrentCloseOperations
        )

        await gate.release()
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
            let retained = await BoundedChannelResourceRegistry.shared.counts()
            let admitted = await IncomingChannelCloseRegistry.shared.admittedChannelCount()
            if retained.inbound == 0, admitted == 0 { break }
            guard ContinuousClock.now < deadline else { throw CoordinatorTestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
        let allClosed = await gate.startedCount()
        XCTAssertEqual(allClosed, IncomingTransferCapacity.maximumAdmittedChannels)
    }

    private func requestedSourceCount(
        _ lifecycles: [(IncomingTransferListener, SuspendedYieldIncomingSource)]
    ) async -> Int {
        var count = 0
        for (_, source) in lifecycles where await source.wasRequested() { count += 1 }
        return count
    }

    private func createdSourceChannelCount(
        _ lifecycles: [(IncomingTransferListener, SuspendedYieldIncomingSource)]
    ) async -> Int {
        var count = 0
        for (_, source) in lifecycles where await source.didCreateChannel() { count += 1 }
        return count
    }

    func testIncomingCancellationInsensitiveFrameReadersStayHardBounded() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let sourceDevice = DeviceID(rawValue: UUID())
        let destination = root.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let source = MemoryIncomingTransferSource()
        let listener = IncomingTransferListener(
            source: source,
            policy: ReceivePolicy(trustedSources: [sourceDevice]),
            directories: DownloadDirectory(globalDirectory: destination),
            database: try TransferDatabase(url: root.appendingPathComponent("history.sqlite")),
            incomingDirectory: root.appendingPathComponent("incoming"),
            inactivityTimeout: .milliseconds(20)
        )
        let gate = CancellationInsensitiveFrameGate()
        await listener.start()
        for _ in 0..<6 {
            await source.offer(
                IncomingTransferConnection(
                    source: sourceDevice,
                    transferID: TransferID(rawValue: UUID()),
                    channel: CancellationInsensitiveFramesChannel(gate: gate)
                )
            )
        }

        try await gate.waitUntilStarted(
            BoundedChannelResourceRegistry.maximumPerDirection
        )
        try await Task.sleep(for: .milliseconds(100))
        let retained = await listener.retainedResourceCount()
        let readers = await gate.startedCount()
        XCTAssertEqual(retained, BoundedChannelResourceRegistry.maximumPerDirection)
        XCTAssertEqual(readers, BoundedChannelResourceRegistry.maximumPerDirection)

        let stopping = Task { await listener.stop() }
        await gate.release()
        await stopping.value
        let deadline = ContinuousClock.now + .seconds(5)
        while await listener.retainedResourceCount() != 0 {
            guard ContinuousClock.now < deadline else { throw CoordinatorTestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testIncomingPreOfferWatchdogBoundsStuckChallengeAndKeyExport() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let sourceDevice = DeviceID(rawValue: UUID())
        let destination = root.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let source = MemoryIncomingTransferSource()
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        let listener = IncomingTransferListener(
            source: source,
            policy: ReceivePolicy(trustedSources: [sourceDevice]),
            directories: DownloadDirectory(globalDirectory: destination),
            database: database,
            incomingDirectory: root.appendingPathComponent("incoming"),
            inactivityTimeout: .milliseconds(50)
        )
        let stuckSend = StuckHandshakeChannel(stuckOperation: .send)
        let stuckExport = StuckHandshakeChannel(stuckOperation: .exportKey)
        await listener.start()
        await source.offer(
            IncomingTransferConnection(
                source: sourceDevice,
                transferID: TransferID(rawValue: UUID()),
                channel: stuckSend
            )
        )
        await source.offer(
            IncomingTransferConnection(
                source: sourceDevice,
                transferID: TransferID(rawValue: UUID()),
                channel: stuckExport
            )
        )

        let payload = root.appendingPathComponent("after-handshake-timeout.txt")
        try Data("bounded initial handshake".utf8).write(to: payload)
        let manifest = try TransferManifest.build(from: payload)
        let pair = CoordinatorMemoryChannelPair.make()
        let sender = Task { try await SendSession(manifest).run(on: pair.sender) }
        await source.offer(
            IncomingTransferConnection(
                source: sourceDevice,
                transferID: manifest.id,
                channel: pair.receiver
            )
        )

        try await waitForDatabasePhase(.completed, id: manifest.id, database: database)
        _ = try await sender.value
        let stuckSendCloseCount = await stuckSend.closeCount()
        let stuckExportCloseCount = await stuckExport.closeCount()
        XCTAssertGreaterThanOrEqual(stuckSendCloseCount, 1)
        XCTAssertGreaterThanOrEqual(stuckExportCloseCount, 1)
        await listener.stop()
        await stuckSend.releaseOperation()
        await stuckExport.releaseOperation()
        let releaseDeadline = ContinuousClock.now + .seconds(5)
        while await listener.retainedResourceCount() != 0 {
            guard ContinuousClock.now < releaseDeadline else {
                throw CoordinatorTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testReceiverHandshakeRegistryBoundsCancellationInsensitiveOperations() async {
        let registry = ReceiverHandshakeOperationRegistry()
        let gate = NeverCompletingOperation()
        var accepted: [UUID] = []
        for _ in 0..<(IncomingTransferCapacity.maximumDetachedHandshakeOperations + 4) {
            if let token = await registry.start({ await gate.wait() }) {
                accepted.append(token)
            }
        }

        let retained = await registry.activeCount()
        XCTAssertEqual(
            accepted.count,
            IncomingTransferCapacity.maximumDetachedHandshakeOperations
        )
        XCTAssertEqual(
            retained,
            IncomingTransferCapacity.maximumDetachedHandshakeOperations
        )
        for token in accepted { await registry.cancel(token) }
        await gate.release()
    }

    func testSnapshotPublicationBoundsTerminalHistoryButDatabaseRetainsAll() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        let peer = DeviceID(rawValue: UUID())
        for index in 0..<205 {
            let snapshot = TransferSnapshot(
                id: TransferID(rawValue: UUID()),
                peer: peer,
                phase: .completed,
                completedBytes: Int64(index),
                totalBytes: Int64(index),
                route: .lan
            )
            try await database.record(
                snapshot,
                displayFilename: "item-\(index)",
                direction: .outbound
            )
        }

        let coordinator = try await TransferCoordinator.restoring(
            connector: CountingBlockingConnector(),
            database: database,
            outgoingDirectory: root.appendingPathComponent("outgoing")
        )
        let stream = await coordinator.snapshots()
        var iterator = stream.makeAsyncIterator()
        let published = await iterator.next()

        XCTAssertEqual(published?.count, 200)
        let history = try await database.history(limit: 1_000)
        XCTAssertEqual(history.count, 205)
    }

    func testPauseClaimWinsWhileConnectingPersistenceIsBlocked() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let payload = root.appendingPathComponent("pause-race.txt")
        try Data("pause wins".utf8).write(to: payload)
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        let persistence = BlockingTransferPersistence(
            database: database,
            blockedPhases: [.connecting]
        )
        let connector = CountingBlockingConnector()
        let coordinator = TransferCoordinator(
            connector: connector,
            database: persistence,
            outgoingDirectory: root.appendingPathComponent("outgoing"),
            persistenceRetryDelay: .milliseconds(1)
        )
        let id = try await coordinator.send(
            items: [payload],
            to: DeviceID(rawValue: UUID())
        )
        try await persistence.waitForBlockedWrites(1)

        let pause = Task { try await coordinator.pause(id) }
        try await waitForClaimedPhase(.paused, id: id, on: coordinator)
        await persistence.releaseBlockedWrites()
        try await pause.value
        try await waitForPhase(.paused, id: id, on: coordinator)

        let started = await connector.startedIDs()
        XCTAssertTrue(started.isEmpty)
        await coordinator.cancel(id)
        try await waitForPhase(.cancelled, id: id, on: coordinator)
    }

    func testCancellationWatchdogReleasesSlotWhileConnectingPersistenceIsBlocked() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        let persistence = BlockingTransferPersistence(
            database: database,
            blockedPhases: [.connecting]
        )
        let connector = CountingBlockingConnector()
        let coordinator = TransferCoordinator(
            connector: connector,
            database: persistence,
            outgoingDirectory: root.appendingPathComponent("outgoing"),
            persistenceRetryDelay: .milliseconds(1),
            cancellationWatchdogDelay: .milliseconds(30)
        )
        let peer = DeviceID(rawValue: UUID())
        let files = try (0..<3).map { index in
            let file = root.appendingPathComponent("blocked-\(index).txt")
            try Data("\(index)".utf8).write(to: file)
            return file
        }
        let ids = try await files.asyncMap {
            try await coordinator.send(items: [$0], to: peer)
        }
        try await persistence.waitForBlockedWrites(2)

        await coordinator.cancel(ids[0])
        try await waitForClaimedPhase(.cancelled, id: ids[0], on: coordinator)
        try await persistence.waitForBlockedWrites(3)
        let activeCount = await coordinator.activeTransferCount()
        XCTAssertEqual(activeCount, 2)

        await persistence.releaseBlockedWrites()
        try await waitForPhase(.cancelled, id: ids[0], on: coordinator)
        for id in ids.dropFirst() { await coordinator.cancel(id) }
        await connector.releaseAll()
    }

    func testReceiverPublicationWinsWhileVerificationPersistenceIsBlocked() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let payload = root.appendingPathComponent("verification-pause.txt")
        try Data("pause after session completion".utf8).write(to: payload)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let peer = DeviceID(rawValue: UUID())
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        let persistence = BlockingTransferPersistence(
            database: database,
            blockedPhases: [.verifying]
        )
        let coordinator = TransferCoordinator(
            connector: CoordinatorMemoryConnector(destinations: [peer: destination]),
            database: persistence,
            outgoingDirectory: root.appendingPathComponent("outgoing"),
            persistenceRetryDelay: .milliseconds(1)
        )
        let id = try await coordinator.send(items: [payload], to: peer)
        try await persistence.waitForBlockedWrites(1)

        do {
            try await coordinator.pause(id)
            XCTFail("Published completion must reject a stale pause control")
        } catch {
            XCTAssertEqual(error as? MacChannelError, .transferInvalidState)
        }
        let claimed = await coordinator.claimedPhase(for: id)
        XCTAssertEqual(claimed, .completed)
        await persistence.releaseBlockedWrites()
        try await waitForPhase(.completed, id: id, on: coordinator)
    }

    func testCancelDuringBlockedPostPublicationCloseIsTooLate() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let payload = root.appendingPathComponent("close-pause.txt")
        try Data("pause while close is suspended".utf8).write(to: payload)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let connector = BlockingCloseConnector(destination: destination)
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        let coordinator = TransferCoordinator(
            connector: connector,
            database: database,
            outgoingDirectory: root.appendingPathComponent("outgoing")
        )
        let id = try await coordinator.send(
            items: [payload],
            to: DeviceID(rawValue: UUID())
        )
        try await connector.waitUntilCloseStarted()

        let cancellation = await coordinator.cancel(id)
        XCTAssertEqual(cancellation, .tooLate)
        let claimed = await coordinator.claimedPhase(for: id)
        XCTAssertTrue(claimed == nil || claimed == .completed)
        try await waitForPhase(.completed, id: id, on: coordinator)
        let active = await coordinator.activeTransferCount()
        XCTAssertEqual(active, 0)
        let retained = await coordinator.retainedResourceCount()
        XCTAssertEqual(retained, 1)
        await connector.releaseClose()
        try await waitForActiveCount(0, on: coordinator)
    }

    func testCancellationInsensitiveClosesHaveHardOutboundCapAndStopAdmission() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let connector = BlockingCloseConnector(destination: destination)
        let coordinator = TransferCoordinator(
            connector: connector,
            database: try TransferDatabase(url: root.appendingPathComponent("history.sqlite")),
            outgoingDirectory: root.appendingPathComponent("outgoing"),
            cancellationWatchdogDelay: .milliseconds(10)
        )
        let peer = DeviceID(rawValue: UUID())
        var ids: [TransferID] = []
        for index in 0..<6 {
            let file = root.appendingPathComponent("close-cap-\(index).txt")
            try Data("\(index)".utf8).write(to: file)
            ids.append(try await coordinator.send(items: [file], to: peer))
        }
        try await connector.waitUntilConnections(4)
        try await Task.sleep(for: .milliseconds(100))

        let connectionCount = await connector.connectionCount()
        let retained = await coordinator.retainedResourceCount()
        XCTAssertEqual(connectionCount, BoundedChannelResourceRegistry.maximumPerDirection)
        XCTAssertEqual(retained, BoundedChannelResourceRegistry.maximumPerDirection)

        for id in ids.dropFirst(4) { await coordinator.cancel(id) }
        await connector.releaseClose()
        let deadline = ContinuousClock.now + .seconds(5)
        while await coordinator.retainedResourceCount() != 0 {
            guard ContinuousClock.now < deadline else { throw CoordinatorTestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testCancellationInsensitiveSendRunnersAndPinnedDescriptorsStayHardBounded()
        async throws
    {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let connector = StuckSendConnector(destination: destination)
        let coordinator = TransferCoordinator(
            connector: connector,
            database: try TransferDatabase(url: root.appendingPathComponent("history.sqlite")),
            outgoingDirectory: root.appendingPathComponent("outgoing"),
            cancellationWatchdogDelay: .milliseconds(20)
        )
        let baseline = try openDescriptorCount()
        let peer = DeviceID(rawValue: UUID())
        var ids: [TransferID] = []
        for index in 0..<6 {
            let file = root.appendingPathComponent("stuck-send-\(index).txt")
            try Data("\(index)".utf8).write(to: file)
            ids.append(try await coordinator.send(items: [file], to: peer))
        }
        try await connector.waitUntilSends(2)
        for id in ids.prefix(2) { await coordinator.cancel(id) }
        try await connector.waitUntilSends(4)
        for id in ids.dropFirst(2).prefix(2) { await coordinator.cancel(id) }
        try await Task.sleep(for: .milliseconds(100))

        let connections = await connector.connectionCount()
        let retained = await coordinator.retainedResourceCount()
        let detached = await coordinator.detachedRunnerCount()
        XCTAssertEqual(connections, 4)
        XCTAssertEqual(retained, 4)
        XCTAssertLessThanOrEqual(
            detached,
            BoundedChannelResourceRegistry.maximumPerDirection
        )
        XCTAssertLessThanOrEqual(try openDescriptorCount() - baseline, 12)

        for id in ids.dropFirst(4) { await coordinator.cancel(id) }
        await connector.releaseSends()
        let deadline = ContinuousClock.now + .seconds(5)
        while await coordinator.retainedResourceCount() != 0 {
            guard ContinuousClock.now < deadline else { throw CoordinatorTestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testPreConnectionRetriesReleaseResourceReservations() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let payload = root.appendingPathComponent("pre-connect-retry.txt")
        try Data("retry without a channel".utf8).write(to: payload)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let connector = FailingThenMemoryConnector(destination: destination, failures: 5)
        let coordinator = TransferCoordinator(
            connector: connector,
            database: try TransferDatabase(url: root.appendingPathComponent("history.sqlite")),
            outgoingDirectory: root.appendingPathComponent("outgoing"),
            maximumConnectionAttempts: 6,
            persistenceRetryDelay: .milliseconds(1)
        )

        let id = try await coordinator.send(
            items: [payload],
            to: DeviceID(rawValue: UUID())
        )
        try await waitForPhase(.completed, id: id, on: coordinator)

        let attemptCount = await connector.attemptCount()
        XCTAssertEqual(attemptCount, 6)
        let deadline = ContinuousClock.now + .seconds(5)
        while await coordinator.retainedResourceCount() != 0 {
            guard ContinuousClock.now < deadline else { throw CoordinatorTestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testTimedOutTerminalSendRetainsCapacityUntilOperationReturns() async throws {
        let registry = BoundedChannelResourceRegistry()
        guard let token = await registry.reserve(.outbound, onReleased: {}) else {
            return XCTFail("Expected an outbound resource reservation")
        }
        let channel = TerminalBlockingChannel()
        let ownership = TransferIOResourceOwnership(registry: registry, token: token)
        let cipher = try ChunkCipher(key: Data(repeating: 7, count: 32))
        let outcome = await TransferIOResourceContext.$ownership.withValue(ownership) {
            await sendTerminalFrameBestEffort(
                .cancel,
                transferID: TransferID(rawValue: UUID()),
                direction: .senderToReceiver,
                on: channel,
                cipher: cipher,
                sequence: 0
            )
        }
        guard case .timedOut = outcome else {
            return XCTFail("Expected the bounded terminal send to time out")
        }

        await registry.beginClose(channel, token: token, timeout: .milliseconds(10))
        await registry.runnerReturned(token)
        try await Task.sleep(for: .milliseconds(20))
        let retained = await registry.counts()
        XCTAssertEqual(retained.total, 1)

        await channel.releaseSend()
        let deadline = ContinuousClock.now + .seconds(5)
        while await registry.counts().total != 0 {
            guard ContinuousClock.now < deadline else { throw CoordinatorTestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testLateChannelHandoffCannotBeReleasedAsNoChannel() async throws {
        let registry = BoundedChannelResourceRegistry()
        guard let token = await registry.reserve(.outbound, onReleased: {}) else {
            return XCTFail("Expected an outbound resource reservation")
        }
        let gate = BlockingCloseGate()
        let pair = CoordinatorMemoryChannelPair.make()
        let channel = BlockingCloseChannel(base: pair.sender, gate: gate)

        await registry.beginClose(channel, token: token, timeout: .milliseconds(10))
        await registry.finishWithoutClose(token)
        try await Task.sleep(for: .milliseconds(25))

        let retained = await registry.counts()
        XCTAssertEqual(retained.total, 1)

        await gate.release()
        let deadline = ContinuousClock.now + .seconds(5)
        while await registry.counts().total != 0 {
            guard ContinuousClock.now < deadline else { throw CoordinatorTestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testCancelDuringBlockedVerificationAfterPublicationIsTooLate()
        async throws
    {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let payload = root.appendingPathComponent("verification-cancel.txt")
        try Data("cancel after session completion".utf8).write(to: payload)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let peer = DeviceID(rawValue: UUID())
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        let persistence = BlockingTransferPersistence(
            database: database,
            blockedPhases: [.verifying]
        )
        let coordinator = TransferCoordinator(
            connector: CoordinatorMemoryConnector(destinations: [peer: destination]),
            database: persistence,
            outgoingDirectory: root.appendingPathComponent("outgoing"),
            persistenceRetryDelay: .milliseconds(1),
            cancellationWatchdogDelay: .milliseconds(30)
        )
        let id = try await coordinator.send(items: [payload], to: peer)
        try await persistence.waitForBlockedWrites(1)

        let cancellation = await coordinator.cancel(id)
        XCTAssertEqual(cancellation, .tooLate)
        let claimed = await coordinator.claimedPhase(for: id)
        XCTAssertEqual(claimed, .completed)
        await persistence.releaseBlockedWrites()
        try await waitForPhase(.completed, id: id, on: coordinator)
        let record = try await database.history().first { $0.id == id }
        XCTAssertEqual(record?.phase, .completed)
    }

    func testOutboundRestartResumesSameTransferIDAndReceiveJournal() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let payload = root.appendingPathComponent("restart-outbound.bin")
        let bytes = Data(
            (0..<(TransferProtocolLimits.maximumChunkBytes * 8)).map { UInt8($0 % 199) }
        )
        try bytes.write(to: payload)
        let destination = root.appendingPathComponent("downloads", isDirectory: true)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let senderDevice = DeviceID(rawValue: UUID())
        let receiverDevice = DeviceID(rawValue: UUID())
        let receiveDatabase = try TransferDatabase(
            url: root.appendingPathComponent("receive.sqlite")
        )
        let sendDatabase = try TransferDatabase(url: root.appendingPathComponent("send.sqlite"))
        let outgoing = root.appendingPathComponent("outgoing")
        let firstConnector = CancellationMemoryConnector(
            source: senderDevice,
            policy: ReceivePolicy(trustedSources: [senderDevice]),
            directories: DownloadDirectory(globalDirectory: destination),
            database: receiveDatabase,
            incomingDirectory: incoming
        )
        let first = TransferCoordinator(
            connector: firstConnector,
            database: sendDatabase,
            outgoingDirectory: outgoing
        )
        let id = try await first.send(items: [payload], to: receiverDevice)
        try await firstConnector.waitUntilSenderHasSent(4)
        await first.shutdownForRestart()
        try await waitForDatabasePhase(.failed, id: id, database: receiveDatabase)

        let secondConnector = CancellationMemoryConnector(
            source: senderDevice,
            policy: ReceivePolicy(trustedSources: [senderDevice]),
            directories: DownloadDirectory(globalDirectory: destination),
            database: receiveDatabase,
            incomingDirectory: incoming
        )
        let restored = try await TransferCoordinator.restoring(
            connector: secondConnector,
            database: sendDatabase,
            outgoingDirectory: outgoing
        )
        try await waitForPhase(.completed, id: id, on: restored)

        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent(payload.lastPathComponent)),
            bytes
        )
        let reconnectedIDs = await secondConnector.connectedTransferIDs()
        XCTAssertEqual(reconnectedIDs, [id])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outgoing.appendingPathComponent(id.rawValue.uuidString.lowercased()).path
            )
        )
    }

    func testPausedOutboundRestartStaysPausedUntilResume() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let payload = root.appendingPathComponent("paused.txt")
        try Data("paused restart".utf8).write(to: payload)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let peer = DeviceID(rawValue: UUID())
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        let outgoing = root.appendingPathComponent("outgoing")
        let firstConnector = CountingBlockingConnector()
        let first = TransferCoordinator(
            connector: firstConnector,
            database: database,
            outgoingDirectory: outgoing
        )
        let id = try await first.send(items: [payload], to: peer)
        try await firstConnector.waitUntilStarted(1)
        try await first.pause(id)
        try await waitForPhase(.paused, id: id, on: first)
        await first.shutdownForRestart()
        await firstConnector.releaseAll()

        let secondConnector = CoordinatorMemoryConnector(destinations: [peer: destination])
        let restored = try await TransferCoordinator.restoring(
            connector: secondConnector,
            database: database,
            outgoingDirectory: outgoing
        )
        try await Task.sleep(for: .milliseconds(100))
        let restoredPhase = await currentPhase(id, on: restored)
        let connectionsBeforeResume = await secondConnector.connectedTransferIDs()
        XCTAssertEqual(restoredPhase, .paused)
        XCTAssertTrue(connectionsBeforeResume.isEmpty)

        try await restored.resume(id)
        try await waitForPhase(.completed, id: id, on: restored)
        let connectionsAfterResume = await secondConnector.connectedTransferIDs()
        XCTAssertEqual(connectionsAfterResume, [id])
    }

    func testRestoreResolvesPackageByExactIDOutsideRecentHistoryWindow() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let payload = root.appendingPathComponent("old-paused.txt")
        try Data("older than the recent history window".utf8).write(to: payload)
        let outgoing = root.appendingPathComponent("outgoing")
        let peer = DeviceID(rawValue: UUID())
        let id = TransferID(rawValue: UUID())
        let package = try OutgoingTransferPackage.create(
            items: [payload],
            peer: peer,
            in: outgoing,
            id: id
        )
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        try await database.record(
            TransferSnapshot(
                id: id,
                peer: peer,
                phase: .paused,
                completedBytes: 0,
                totalBytes: package.totalBytes,
                route: .relay
            ),
            displayFilename: package.displayFilename,
            direction: .outbound
        )
        let persistence = WindowedTransferPersistence(database: database)

        let restored = try await TransferCoordinator.restoring(
            connector: CountingBlockingConnector(),
            database: persistence,
            outgoingDirectory: outgoing
        )

        let restoredPhase = await currentPhase(id, on: restored)
        XCTAssertEqual(restoredPhase, .paused)
        await restored.cancel(id)
        try await waitForPhase(.cancelled, id: id, on: restored)
    }

    func testStuckConnectorsDoNotRetainPinnedSourcesOrFileDescriptors() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        let connector = CountingBlockingConnector()
        let coordinator = TransferCoordinator(
            connector: connector,
            database: database,
            outgoingDirectory: root.appendingPathComponent("outgoing"),
            cancellationWatchdogDelay: .milliseconds(20)
        )
        let baseline = try openDescriptorCount()
        let peer = DeviceID(rawValue: UUID())
        var ids: [TransferID] = []
        for index in 0..<24 {
            let file = root.appendingPathComponent("resource-\(index).txt")
            try Data(repeating: UInt8(index), count: 1_024).write(to: file)
            ids.append(try await coordinator.send(items: [file], to: peer))
        }
        try await connector.waitUntilStarted(2)
        let afterQueued = try openDescriptorCount()

        XCTAssertLessThanOrEqual(afterQueued - baseline, 6)
        let firstPackageURL = root.appendingPathComponent("outgoing")
            .appendingPathComponent(ids[0].rawValue.uuidString.lowercased())
        let firstPackage = try OutgoingTransferPackage.load(firstPackageURL)
        XCTAssertEqual(firstPackage.id, ids[0])
        XCTAssertEqual(firstPackage.peer, peer)
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: firstPackageURL.path))[
                .posixPermissions
            ] as? NSNumber,
            NSNumber(value: 0o700)
        )
        let packagedFile = firstPackageURL.appendingPathComponent("payload/resource-0.txt")
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: packagedFile.path))[
                .posixPermissions
            ] as? NSNumber,
            NSNumber(value: 0o400)
        )
        for id in ids { await coordinator.cancel(id) }
        await connector.releaseAll()
        for id in ids { try await waitForPhase(.cancelled, id: id, on: coordinator) }
    }

    func testPersistenceFailuresRetryAllCoordinatorPhasesWithoutStrandingRunner() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let payload = root.appendingPathComponent("retry.txt")
        try Data("retry every phase".utf8).write(to: payload)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let peer = DeviceID(rawValue: UUID())
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        let persistence = FailingTransferPersistence(
            database: database,
            failures: [
                .preparing: 1, .connecting: 1, .transferring: 1,
                .verifying: 1, .completed: 1,
            ]
        )
        let coordinator = TransferCoordinator(
            connector: CoordinatorMemoryConnector(destinations: [peer: destination]),
            database: persistence,
            outgoingDirectory: root.appendingPathComponent("outgoing"),
            persistenceRetryDelay: .milliseconds(1)
        )

        let id = try await coordinator.send(items: [payload], to: peer)
        try await waitForPhase(.completed, id: id, on: coordinator)

        for phase in [
            TransferPhase.preparing, .connecting, .transferring, .verifying, .completed,
        ] {
            let attempts = await persistence.attempts(for: phase)
            XCTAssertGreaterThanOrEqual(attempts, 2)
        }
    }

    func testConditionalConflictAfterCommitIsAdoptedForEveryOutboundPhase() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let payload = root.appendingPathComponent("conditional-conflict.txt")
        try Data("commit then report conflict".utf8).write(to: payload)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let peer = DeviceID(rawValue: UUID())
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        let persistence = CommitThenConflictPersistence(database: database)
        let coordinator = TransferCoordinator(
            connector: CoordinatorMemoryConnector(destinations: [peer: destination]),
            database: persistence,
            outgoingDirectory: root.appendingPathComponent("outgoing"),
            persistenceRetryDelay: .milliseconds(1)
        )

        let id = try await coordinator.send(items: [payload], to: peer)
        try await waitForPhase(.completed, id: id, on: coordinator)
        let phases = await persistence.conflictedPhases()
        XCTAssertTrue(phases.isSuperset(of: [.preparing, .connecting, .transferring]))
        XCTAssertTrue(phases.contains(.verifying))
        XCTAssertTrue(phases.contains(.completed))
        let record = try await database.persistedTransfer(id: id)
        XCTAssertEqual(record?.phase, .completed)
    }

    func testConditionalConflictAdoptsCompatibleNewerDurablePhase() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let payload = root.appendingPathComponent("newer-conflict.txt")
        try Data("durable writer advanced".utf8).write(to: payload)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let peer = DeviceID(rawValue: UUID())
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        let persistence = AdvanceThenConflictPersistence(database: database)
        let coordinator = TransferCoordinator(
            connector: CoordinatorMemoryConnector(destinations: [peer: destination]),
            database: persistence,
            outgoingDirectory: root.appendingPathComponent("outgoing")
        )

        let id = try await coordinator.send(items: [payload], to: peer)
        try await waitForPhase(.completed, id: id, on: coordinator)

        let didAdvance = await persistence.didAdvance()
        XCTAssertTrue(didAdvance)
        let record = try await database.persistedTransfer(id: id)
        XCTAssertEqual(record?.phase, .completed)
    }

    func testOutboundRestartCompletesDurableVerificationWithoutReconnect() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let payload = root.appendingPathComponent("published-before-crash.txt")
        try Data("receiver already published".utf8).write(to: payload)
        let peer = DeviceID(rawValue: UUID())
        let outgoing = root.appendingPathComponent("outgoing")
        let package = try OutgoingTransferPackage.create(items: [payload], peer: peer, in: outgoing)
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        try await persistOutboundLifecycleThroughVerification(package, database: database)
        let connector = CountingBlockingConnector()
        let coordinator = try await TransferCoordinator.restoring(
            connector: connector,
            database: database,
            outgoingDirectory: outgoing
        )

        try await waitForPhase(.completed, id: package.id, on: coordinator)

        let started = await connector.startedIDs()
        XCTAssertEqual(started, [])
        let record = try await database.persistedTransfer(id: package.id)
        XCTAssertEqual(record?.phase, .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.directory.path))
    }

    func testOutboundRestartCompletesVerificationAfterPackageCleanupAlreadyFinished() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let payload = root.appendingPathComponent("already-cleaned.txt")
        try Data("published package cleanup was durable".utf8).write(to: payload)
        let peer = DeviceID(rawValue: UUID())
        let outgoing = root.appendingPathComponent("outgoing")
        let package = try OutgoingTransferPackage.create(items: [payload], peer: peer, in: outgoing)
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        try await persistOutboundLifecycleThroughVerification(package, database: database)
        try package.remove()
        let connector = CountingBlockingConnector()

        let coordinator = try await TransferCoordinator.restoring(
            connector: connector,
            database: database,
            outgoingDirectory: outgoing
        )

        try await waitForPhase(.completed, id: package.id, on: coordinator)
        let started = await connector.startedIDs()
        XCTAssertEqual(started, [])
        let record = try await database.persistedTransfer(id: package.id)
        XCTAssertEqual(record?.phase, .completed)
    }

    func testConcretePersistenceIdentityConflictFailsSendOnceAndPreservesExistingRow()
        async throws
    {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let payload = root.appendingPathComponent("identity-conflict.txt")
        try Data("new private package".utf8).write(to: payload)
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        let persistence = ConcreteIdentityConflictPersistence(database: database)
        let coordinator = TransferCoordinator(
            connector: CountingBlockingConnector(),
            database: persistence,
            outgoingDirectory: root.appendingPathComponent("outgoing"),
            persistenceRetryDelay: .milliseconds(1)
        )

        do {
            _ = try await coordinator.send(
                items: [payload],
                to: DeviceID(rawValue: UUID())
            )
            XCTFail("Expected the concrete identity conflict to fail permanently")
        } catch {
            XCTAssertEqual(error as? TransferPersistenceError, .identityConflict)
        }

        let attemptCount = await persistence.attemptCount()
        XCTAssertEqual(attemptCount, 1)
        guard let conflictID = await persistence.conflictID() else {
            return XCTFail("Expected the persistence seam to capture the package identity")
        }
        let existing = try await database.persistedTransfer(id: conflictID)
        let conflictingPeer = await persistence.conflictingPeer()
        XCTAssertEqual(existing?.peer, conflictingPeer)
        XCTAssertEqual(existing?.phase, .preparing)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath:
                    root.appendingPathComponent("outgoing")
                    .appendingPathComponent(conflictID.rawValue.uuidString.lowercased()).path
            )
        )
        let active = await coordinator.activeTransferCount()
        let retained = await coordinator.retainedResourceCount()
        XCTAssertEqual(active, 0)
        XCTAssertEqual(retained, 0)
    }

    func testPermanentConflictPackageCleanupRetriesAfterRemovalFailure() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let outgoing = root.appendingPathComponent("outgoing")
        defer { _ = chmod(outgoing.path, S_IRWXU) }
        let payload = root.appendingPathComponent("cleanup-conflict.txt")
        try Data("cleanup must retry".utf8).write(to: payload)
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        let persistence = RemovalBlockedIdentityConflictPersistence(
            database: database,
            outgoingDirectory: outgoing
        )
        let coordinator = TransferCoordinator(
            connector: CountingBlockingConnector(),
            database: persistence,
            outgoingDirectory: outgoing,
            persistenceRetryDelay: .milliseconds(10)
        )

        do {
            _ = try await coordinator.send(
                items: [payload],
                to: DeviceID(rawValue: UUID())
            )
            XCTFail("Expected the permanent identity conflict")
        } catch {
            XCTAssertEqual(error as? TransferPersistenceError, .identityConflict)
        }
        guard let id = await persistence.conflictID() else {
            return XCTFail("Expected a captured conflict identity")
        }
        let packageDirectory = outgoing.appendingPathComponent(
            id.rawValue.uuidString.lowercased()
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageDirectory.path))
        let active = await coordinator.activeTransferCount()
        let retained = await coordinator.retainedResourceCount()
        XCTAssertEqual(active, 0)
        XCTAssertEqual(retained, 0)

        XCTAssertEqual(chmod(outgoing.path, S_IRWXU), 0)
        let cleanupDeadline = ContinuousClock.now + .seconds(5)
        while FileManager.default.fileExists(atPath: packageDirectory.path) {
            guard ContinuousClock.now < cleanupDeadline else {
                throw CoordinatorTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let preserved = try await database.persistedTransfer(id: id)
        let conflictingPeer = await persistence.conflictingPeer()
        XCTAssertEqual(preserved?.peer, conflictingPeer)
        XCTAssertEqual(preserved?.phase, .preparing)
    }

    func testRestartCleansConflictingPackageAndPreservesAuthoritativeOutboundRow()
        async throws
    {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let outgoing = root.appendingPathComponent("outgoing")
        let payload = root.appendingPathComponent("restart-conflict.txt")
        try Data("authoritative row wins".utf8).write(to: payload)
        let packagePeer = DeviceID(rawValue: UUID())
        let authoritativePeer = DeviceID(rawValue: UUID())
        let package = try OutgoingTransferPackage.create(
            items: [payload],
            peer: packagePeer,
            in: outgoing
        )
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        try await database.persist(
            TransferSnapshot(
                id: package.id,
                peer: authoritativePeer,
                phase: .preparing,
                completedBytes: 0,
                totalBytes: package.totalBytes,
                route: .lan
            ),
            displayFilename: package.displayFilename,
            expectedPhase: nil
        )
        let connector = CountingBlockingConnector()

        _ = try await TransferCoordinator.restoring(
            connector: connector,
            database: database,
            outgoingDirectory: outgoing,
            persistenceRetryDelay: .milliseconds(10)
        )
        _ = try await TransferCoordinator.restoring(
            connector: connector,
            database: database,
            outgoingDirectory: outgoing,
            persistenceRetryDelay: .milliseconds(10)
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: package.directory.path))
        let preserved = try await database.persistedTransfer(id: package.id)
        XCTAssertEqual(preserved?.peer, authoritativePeer)
        XCTAssertEqual(preserved?.phase, .preparing)
        let started = await connector.startedIDs()
        XCTAssertEqual(started, [])
    }

    func testRestartFinishesDurableConflictCleanupQuarantine() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let outgoing = root.appendingPathComponent("outgoing")
        let payload = root.appendingPathComponent("quarantined-conflict.txt")
        try Data("durable cleanup intent".utf8).write(to: payload)
        let package = try OutgoingTransferPackage.create(
            items: [payload],
            peer: DeviceID(rawValue: UUID()),
            in: outgoing
        )
        let authoritativePeer = DeviceID(rawValue: UUID())
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        try await database.persist(
            TransferSnapshot(
                id: package.id,
                peer: authoritativePeer,
                phase: .preparing,
                completedBytes: 0,
                totalBytes: package.totalBytes,
                route: .lan
            ),
            displayFilename: package.displayFilename,
            expectedPhase: nil
        )

        XCTAssertThrowsError(
            try package.removeAfterPersistenceConflict(afterQuarantine: {
                throw CoordinatorTestError.injectedFailure
            })
        ) { error in
            XCTAssertTrue(error is CoordinatorTestError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.directory.path))
        let interruptedCleanup = try FileManager.default.contentsOfDirectory(
            atPath: outgoing.path
        ).filter { $0.contains(".cleanup.") }
        XCTAssertEqual(interruptedCleanup.count, 1)

        _ = try await TransferCoordinator.restoring(
            connector: CountingBlockingConnector(),
            database: database,
            outgoingDirectory: outgoing
        )

        let remainingCleanup = try FileManager.default.contentsOfDirectory(
            atPath: outgoing.path
        ).filter { $0.contains(".cleanup.") }
        XCTAssertEqual(remainingCleanup, [])
        let preserved = try await database.persistedTransfer(id: package.id)
        XCTAssertEqual(preserved?.peer, authoritativePeer)
        XCTAssertEqual(preserved?.phase, .preparing)
    }

    func testConditionalConflictReconciliationRetriesTransientReadFailure() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let payload = root.appendingPathComponent("conflict-read-retry.txt")
        try Data("retry conflict reread".utf8).write(to: payload)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let peer = DeviceID(rawValue: UUID())
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        let persistence = ConflictThenReadFailurePersistence(database: database)
        let coordinator = TransferCoordinator(
            connector: CoordinatorMemoryConnector(destinations: [peer: destination]),
            database: persistence,
            outgoingDirectory: root.appendingPathComponent("outgoing"),
            persistenceRetryDelay: .milliseconds(1)
        )

        let id = try await coordinator.send(items: [payload], to: peer)
        try await waitForPhase(.completed, id: id, on: coordinator)

        let readFailures = await persistence.readFailureCount()
        XCTAssertEqual(readFailures, 1)
        let record = try await database.persistedTransfer(id: id)
        XCTAssertEqual(record?.phase, .completed)
    }

    func testConditionalConflictWithoutRowIsDurablyQuarantinedAndDoesNotStrandRunner()
        async throws
    {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let payload = root.appendingPathComponent("initial-conflict.txt")
        try Data("quarantine".utf8).write(to: payload)
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        let persistence = InitialConditionalConflictPersistence(database: database)
        let coordinator = TransferCoordinator(
            connector: CountingBlockingConnector(),
            database: persistence,
            outgoingDirectory: root.appendingPathComponent("outgoing"),
            cancellationWatchdogDelay: .milliseconds(10)
        )

        do {
            _ = try await coordinator.send(
                items: [payload],
                to: DeviceID(rawValue: UUID())
            )
            XCTFail("Expected the quarantined initial send to fail")
        } catch {}
        let history = try await database.history()
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.phase, .failed)
        XCTAssertEqual(history.first?.direction, .outbound)
        let active = await coordinator.activeTransferCount()
        let detached = await coordinator.detachedRunnerCount()
        XCTAssertEqual(active, 0)
        XCTAssertEqual(detached, 0)
    }

    func testPersistenceFailuresRetryPauseCancellationAndFailurePhases() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let payload = root.appendingPathComponent("control-retry.txt")
        try Data("control retry".utf8).write(to: payload)
        let database = try TransferDatabase(url: root.appendingPathComponent("control.sqlite"))
        let persistence = FailingTransferPersistence(
            database: database,
            failures: [.paused: 1, .cancelling: 1, .cancelled: 1]
        )
        let connector = CountingBlockingConnector()
        let coordinator = TransferCoordinator(
            connector: connector,
            database: persistence,
            outgoingDirectory: root.appendingPathComponent("control-outgoing"),
            persistenceRetryDelay: .milliseconds(1),
            cancellationWatchdogDelay: .milliseconds(20)
        )
        let id = try await coordinator.send(
            items: [payload],
            to: DeviceID(rawValue: UUID())
        )
        try await connector.waitUntilStarted(1)
        try await coordinator.pause(id)
        try await waitForPhase(.paused, id: id, on: coordinator)
        await coordinator.cancel(id)
        try await waitForPhase(.cancelled, id: id, on: coordinator)
        await connector.releaseAll()
        for phase in [TransferPhase.paused, .cancelling, .cancelled] {
            let attempts = await persistence.attempts(for: phase)
            XCTAssertGreaterThanOrEqual(attempts, 2)
        }

        let failedDatabase = try TransferDatabase(
            url: root.appendingPathComponent("failed.sqlite")
        )
        let failedPersistence = FailingTransferPersistence(
            database: failedDatabase,
            failures: [.failed: 1]
        )
        let failedCoordinator = TransferCoordinator(
            connector: AuthenticationFailureConnector(),
            database: failedPersistence,
            outgoingDirectory: root.appendingPathComponent("failed-outgoing"),
            persistenceRetryDelay: .milliseconds(1)
        )
        let failedID = try await failedCoordinator.send(
            items: [payload],
            to: DeviceID(rawValue: UUID())
        )
        try await waitForPhase(.failed, id: failedID, on: failedCoordinator)
        let failedAttempts = await failedPersistence.attempts(for: .failed)
        XCTAssertGreaterThanOrEqual(failedAttempts, 2)
    }

    func testConditionalPersistenceRejectsStalePhaseAndKeepsProgressMonotonic() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        let id = TransferID(rawValue: UUID())
        let peer = DeviceID(rawValue: UUID())
        func snapshot(_ phase: TransferPhase, _ completed: Int64) -> TransferSnapshot {
            TransferSnapshot(
                id: id,
                peer: peer,
                phase: phase,
                completedBytes: completed,
                totalBytes: 100,
                route: .lan
            )
        }
        try await database.persist(
            snapshot(.preparing, 0),
            displayFilename: "conditional.bin",
            expectedPhase: nil
        )
        try await database.persist(
            snapshot(.connecting, 50),
            displayFilename: "conditional.bin",
            expectedPhase: .preparing
        )
        try await database.persist(
            snapshot(.connecting, 25),
            displayFilename: "conditional.bin",
            expectedPhase: .connecting
        )
        do {
            try await database.persist(
                snapshot(.paused, 50),
                displayFilename: "conditional.bin",
                expectedPhase: .preparing
            )
            XCTFail("Expected a stale conditional transition to fail")
        } catch {
            XCTAssertEqual(error as? TransferPersistenceError, .conditionalConflict)
        }
        let record = try await database.history().first
        XCTAssertEqual(record?.phase, .connecting)
        XCTAssertEqual(record?.completedBytes, 50)

        try await database.persist(
            snapshot(.transferring, 50),
            displayFilename: "conditional.bin",
            expectedPhase: .connecting
        )
        try await database.persist(
            snapshot(.verifying, 100),
            displayFilename: "conditional.bin",
            expectedPhase: .transferring
        )
        do {
            try await database.persist(
                snapshot(.transferring, 100),
                displayFilename: "conditional.bin",
                expectedPhase: .verifying
            )
            XCTFail("Expected verification to reject a transfer regression")
        } catch {
            XCTAssertEqual(error as? TransferPersistenceError, .conditionalConflict)
        }
        let verifying = try await database.history().first
        XCTAssertEqual(verifying?.phase, .verifying)
    }

    func testConcreteDatabaseClassifiesIdentityAndDirectionConflictsPermanently() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        let id = TransferID(rawValue: UUID())
        let peer = DeviceID(rawValue: UUID())
        let snapshot = TransferSnapshot(
            id: id,
            peer: peer,
            phase: .preparing,
            completedBytes: 0,
            totalBytes: 10,
            route: .lan
        )
        try await database.persist(snapshot, displayFilename: "identity.bin", expectedPhase: nil)

        for mismatch in [
            TransferSnapshot(
                id: id,
                peer: DeviceID(rawValue: UUID()),
                phase: .connecting,
                completedBytes: 0,
                totalBytes: 10,
                route: .lan
            ),
            TransferSnapshot(
                id: id,
                peer: peer,
                phase: .connecting,
                completedBytes: 0,
                totalBytes: 11,
                route: .lan
            ),
        ] {
            do {
                try await database.persist(
                    mismatch,
                    displayFilename: "identity.bin",
                    expectedPhase: .preparing
                )
                XCTFail("Expected an identity conflict")
            } catch {
                XCTAssertEqual(error as? TransferPersistenceError, .identityConflict)
            }
        }
        do {
            try await database.persist(
                snapshot,
                displayFilename: "other-name.bin",
                expectedPhase: .preparing
            )
            XCTFail("Expected a filename identity conflict")
        } catch {
            XCTAssertEqual(error as? TransferPersistenceError, .identityConflict)
        }

        let inboundID = TransferID(rawValue: UUID())
        let inbound = TransferSnapshot(
            id: inboundID,
            peer: peer,
            phase: .preparing,
            completedBytes: 0,
            totalBytes: 10,
            route: .lan
        )
        try await database.record(inbound, displayFilename: "incoming.bin")
        do {
            try await database.persist(
                inbound,
                displayFilename: "incoming.bin",
                expectedPhase: .preparing
            )
            XCTFail("Expected a direction conflict")
        } catch {
            XCTAssertEqual(error as? TransferPersistenceError, .directionConflict)
        }

        let preserved = try await database.persistedTransfer(id: id)
        XCTAssertEqual(preserved?.phase, .preparing)
        XCTAssertEqual(preserved?.peer, peer)
        XCTAssertEqual(preserved?.displayFilename, "identity.bin")
    }

    func testQuarantineNeverRewritesPublishedVerificationAsFailure() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let payload = root.appendingPathComponent("published.txt")
        try Data("published".utf8).write(to: payload)
        let peer = DeviceID(rawValue: UUID())
        let package = try OutgoingTransferPackage.create(
            items: [payload],
            peer: peer,
            in: root.appendingPathComponent("outgoing")
        )
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))
        try await persistOutboundLifecycleThroughVerification(package, database: database)

        do {
            _ = try await database.quarantineOutboundTransfer(
                TransferSnapshot(
                    id: package.id,
                    peer: peer,
                    phase: .connecting,
                    completedBytes: 0,
                    totalBytes: package.totalBytes,
                    route: .lan
                ),
                displayFilename: package.displayFilename
            )
            XCTFail("Expected published verification to reject quarantine")
        } catch {
            XCTAssertEqual(error as? TransferPersistenceError, .conditionalConflict)
        }
        let preserved = try await database.persistedTransfer(id: package.id)
        XCTAssertEqual(preserved?.phase, .verifying)

        for forbiddenPhase in [TransferPhase.failed, .cancelled] {
            do {
                try await database.record(
                    TransferSnapshot(
                        id: package.id,
                        peer: peer,
                        phase: forbiddenPhase,
                        completedBytes: package.totalBytes,
                        totalBytes: package.totalBytes,
                        route: .lan
                    ),
                    displayFilename: package.displayFilename,
                    direction: .outbound
                )
                XCTFail("Expected outbound verification to reject \(forbiddenPhase)")
            } catch {}
            let stillPublished = try await database.persistedTransfer(id: package.id)
            XCTAssertEqual(stillPublished?.phase, .verifying)
        }
    }

    func testOutgoingPackageRejectsMetadataTampering() throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let payload = root.appendingPathComponent("authenticated.txt")
        try Data("authenticated".utf8).write(to: payload)
        let outgoing = root.appendingPathComponent("outgoing")
        let package = try OutgoingTransferPackage.create(
            items: [payload],
            peer: DeviceID(rawValue: UUID()),
            in: outgoing
        )
        let metadataURL = package.directory.appendingPathComponent("metadata.json")
        var metadata = try Data(contentsOf: metadataURL)
        metadata.append(0x20)
        XCTAssertEqual(chmod(metadataURL.path, S_IRUSR | S_IWUSR), 0)
        try metadata.write(to: metadataURL, options: .atomic)
        XCTAssertEqual(chmod(metadataURL.path, S_IRUSR), 0)

        XCTAssertThrowsError(try OutgoingTransferPackage.load(package.directory)) { error in
            XCTAssertEqual(error as? TransferProtocolError, .sourceChanged)
        }
    }

    func testOutgoingPackageRestoreReclaimsInterruptedCreatingTree() throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let payload = root.appendingPathComponent("durable.txt")
        try Data("durable package".utf8).write(to: payload)
        let outgoing = root.appendingPathComponent("outgoing")
        let package = try OutgoingTransferPackage.create(
            items: [payload],
            peer: DeviceID(rawValue: UUID()),
            in: outgoing
        )
        let interrupted = outgoing.appendingPathComponent(
            ".\(UUID().uuidString.lowercased()).creating.\(UUID().uuidString.lowercased())"
        )
        try FileManager.default.createDirectory(at: interrupted, withIntermediateDirectories: false)
        let abandonedClone = interrupted.appendingPathComponent("clone.bin")
        try Data(repeating: 9, count: 1024).write(to: abandonedClone)
        XCTAssertEqual(chmod(abandonedClone.path, S_IRUSR), 0)
        XCTAssertEqual(chmod(interrupted.path, S_IRUSR | S_IXUSR), 0)

        let loaded = try OutgoingTransferPackage.loadAll(from: outgoing)

        XCTAssertEqual(loaded.map(\.id), [package.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: interrupted.path))
    }

    func testRestartQuarantinesLegacyVersionOnePackageWithoutBlockingStartup() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let outgoing = root.appendingPathComponent("outgoing", isDirectory: true)
        let fixture = try makeLegacyOutgoingPackage(in: outgoing)

        _ = try await TransferCoordinator.restoring(
            connector: CountingBlockingConnector(),
            database: TransferDatabase(url: root.appendingPathComponent("history.sqlite")),
            outgoingDirectory: outgoing
        )

        let quarantine = outgoing.appendingPathComponent(
            ".legacy-v1.\(fixture.identifier)",
            isDirectory: true
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.package.path))
        XCTAssertEqual(
            try Data(contentsOf: quarantine.appendingPathComponent("payload/legacy.txt")),
            Data("legacy package remains recoverable".utf8)
        )

        XCTAssertNoThrow(try OutgoingTransferPackage.loadAll(from: outgoing))
    }

    func testLegacyPackageRecoveryRejectsCorruptChecksum() throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let outgoing = root.appendingPathComponent("outgoing", isDirectory: true)
        let fixture = try makeLegacyOutgoingPackage(in: outgoing)
        try replaceReadOnlyFile(fixture.checksum, with: Data(repeating: 0, count: 32))

        XCTAssertThrowsError(try OutgoingTransferPackage.loadAll(from: outgoing)) { error in
            XCTAssertEqual(error as? TransferProtocolError, .sourceChanged)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.package.path))
    }

    func testLegacyPackageRecoveryRejectsMalformedMetadataEvenWithMatchingChecksum() throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let outgoing = root.appendingPathComponent("outgoing", isDirectory: true)
        let fixture = try makeLegacyOutgoingPackage(in: outgoing)
        let malformed = Data("{not-json".utf8)
        try replaceReadOnlyFile(fixture.metadata, with: malformed)
        try replaceReadOnlyFile(fixture.checksum, with: Data(SHA256.hash(data: malformed)))

        XCTAssertThrowsError(try OutgoingTransferPackage.loadAll(from: outgoing))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.package.path))
    }

    func testLegacyPackageRecoveryDoesNotQuarantineVersionTwoWithoutAuthentication() throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let outgoing = root.appendingPathComponent("outgoing", isDirectory: true)
        let fixture = try makeLegacyOutgoingPackage(in: outgoing, version: 2)

        XCTAssertThrowsError(try OutgoingTransferPackage.loadAll(from: outgoing))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.package.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outgoing.appendingPathComponent(".legacy-v1.\(fixture.identifier)").path
            )
        )
    }

    func testLegacyPackageRecoveryRejectsNoncanonicalTransferIdentity() throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let outgoing = root.appendingPathComponent("outgoing", isDirectory: true)
        let fixture = try makeLegacyOutgoingPackage(in: outgoing)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.metadata))
                as? [String: Any]
        )
        object["transferID"] = UUID().uuidString.lowercased()
        let encoded = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try replaceReadOnlyFile(fixture.metadata, with: encoded)
        try replaceReadOnlyFile(fixture.checksum, with: Data(SHA256.hash(data: encoded)))

        XCTAssertThrowsError(try OutgoingTransferPackage.loadAll(from: outgoing)) { error in
            XCTAssertEqual(error as? TransferProtocolError, .sourceChanged)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.package.path))
    }

    func testLegacyPackageRecoveryRejectsPayloadTampering() throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let outgoing = root.appendingPathComponent("outgoing", isDirectory: true)
        let fixture = try makeLegacyOutgoingPackage(in: outgoing)
        try replaceReadOnlyFile(fixture.payloadFile, with: Data("changed payload".utf8))

        XCTAssertThrowsError(try OutgoingTransferPackage.loadAll(from: outgoing)) { error in
            XCTAssertEqual(error as? TransferProtocolError, .sourceChanged)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.package.path))
    }

    func testAuthenticatedVersionTwoPackageWithLegacyChecksumIsNotQuarantined() throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let payload = root.appendingPathComponent("authenticated.txt")
        try Data("authenticated v2".utf8).write(to: payload)
        let outgoing = root.appendingPathComponent("outgoing", isDirectory: true)
        let package = try OutgoingTransferPackage.create(
            items: [payload],
            peer: DeviceID(rawValue: UUID()),
            in: outgoing
        )
        let encoded = try Data(contentsOf: package.directory.appendingPathComponent("metadata.json"))
        let legacyChecksum = package.directory.appendingPathComponent("metadata.sha256")
        try Data(SHA256.hash(data: encoded)).write(to: legacyChecksum)
        XCTAssertEqual(chmod(legacyChecksum.path, S_IRUSR), 0)

        XCTAssertEqual(try OutgoingTransferPackage.loadAll(from: outgoing).map(\.id), [package.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.directory.path))
    }

    func testLegacyPackageRecoveryRejectsDirectoryReplacementBeforeQuarantineRename() throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let outgoing = root.appendingPathComponent("outgoing", isDirectory: true)
        let fixture = try makeLegacyOutgoingPackage(in: outgoing)
        let displaced = outgoing.appendingPathComponent("displaced", isDirectory: true)

        XCTAssertThrowsError(
            try OutgoingTransferPackage.recoverAll(
                from: outgoing,
                beforeLegacyQuarantineRename: { candidate in
                    XCTAssertEqual(
                        candidate.resolvingSymlinksInPath(),
                        fixture.package.resolvingSymlinksInPath()
                    )
                    try FileManager.default.moveItem(at: fixture.package, to: displaced)
                    try FileManager.default.createDirectory(
                        at: fixture.package,
                        withIntermediateDirectories: false
                    )
                    XCTAssertEqual(chmod(fixture.package.path, S_IRWXU), 0)
                }
            )
        ) { error in
            XCTAssertEqual(error as? TransferProtocolError, .sourceChanged)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: displaced.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.package.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outgoing.appendingPathComponent(".legacy-v1.\(fixture.identifier)").path
            )
        )
    }

    func testLegacyPackageRecoveryRejectsPackageObjectChangesAfterQuarantineRename() throws {
        enum Mutation: CaseIterable {
            case metadata
            case checksumHardLink
            case authentication
            case payload
            case directory
        }

        for mutation in Mutation.allCases {
            let root = try makeCoordinatorTemporaryDirectory()
            defer { removeCoordinatorTemporaryDirectory(root) }
            let outgoing = root.appendingPathComponent("outgoing", isDirectory: true)
            let fixture = try makeLegacyOutgoingPackage(in: outgoing)
            let externalLink = root.appendingPathComponent("linked-checksum")

            XCTAssertThrowsError(
                try OutgoingTransferPackage.recoverAll(
                    from: outgoing,
                    afterLegacyQuarantineRename: { quarantined in
                        switch mutation {
                        case .metadata:
                            let url = quarantined.appendingPathComponent("metadata.json")
                            var bytes = try Data(contentsOf: url)
                            bytes.append(0x20)
                            try replaceReadOnlyFile(url, with: bytes)
                        case .checksumHardLink:
                            XCTAssertEqual(
                                Darwin.link(
                                    quarantined.appendingPathComponent("metadata.sha256").path,
                                    externalLink.path
                                ),
                                0
                            )
                        case .authentication:
                            let url = quarantined.appendingPathComponent("metadata.hmac")
                            try Data(repeating: 3, count: 32).write(to: url)
                            XCTAssertEqual(chmod(url.path, S_IRUSR), 0)
                        case .payload:
                            try replaceReadOnlyFile(
                                quarantined.appendingPathComponent("payload/legacy.txt"),
                                with: Data("changed after quarantine".utf8)
                            )
                        case .directory:
                            let displaced = root.appendingPathComponent(
                                "displaced-quarantine",
                                isDirectory: true
                            )
                            try FileManager.default.moveItem(at: quarantined, to: displaced)
                            try FileManager.default.copyItem(at: displaced, to: quarantined)
                        }
                    }
                )
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.package.path))
            let quarantined = outgoing.appendingPathComponent(
                ".legacy-v1.\(fixture.identifier)",
                isDirectory: true
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: quarantined.path))
            if mutation != .directory {
                XCTAssertThrowsError(try OutgoingTransferPackage.loadAll(from: outgoing))
            }
        }
    }

    func testOutgoingPackageCreationModesAndAuthenticationKeyCrashRecovery() throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let payload = root.appendingPathComponent("mode.txt")
        try Data("private".utf8).write(to: payload)
        let outgoing = root.appendingPathComponent("outgoing")
        let package = try OutgoingTransferPackage.create(
            items: [payload],
            peer: DeviceID(rawValue: UUID()),
            in: outgoing
        )
        let key = outgoing.appendingPathComponent(".package-authentication-key")
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: outgoing.path))[.posixPermissions]
                as? NSNumber,
            NSNumber(value: 0o700)
        )
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: key.path))[.posixPermissions]
                as? NSNumber,
            NSNumber(value: 0o600)
        )

        try package.remove()
        try FileManager.default.removeItem(at: key)
        let recoverable = outgoing.appendingPathComponent(
            ".package-authentication-key.creating.\(UUID().uuidString.lowercased())"
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: recoverable.path, contents: Data(count: 7)))
        XCTAssertEqual(chmod(recoverable.path, S_IRUSR), 0)
        XCTAssertTrue(try OutgoingTransferPackage.loadAll(from: outgoing).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoverable.path))

        let broad = root.appendingPathComponent("broad-outgoing")
        try FileManager.default.createDirectory(at: broad, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(broad.path, 0o755), 0)
        XCTAssertThrowsError(
            try OutgoingTransferPackage.create(
                items: [payload],
                peer: DeviceID(rawValue: UUID()),
                in: broad
            )
        )

        let broadCreating = outgoing.appendingPathComponent(
            ".\(UUID().uuidString.lowercased()).creating.\(UUID().uuidString.lowercased())"
        )
        try FileManager.default.createDirectory(
            at: broadCreating,
            withIntermediateDirectories: false
        )
        XCTAssertEqual(chmod(broadCreating.path, 0o755), 0)
        XCTAssertThrowsError(try OutgoingTransferPackage.loadAll(from: outgoing))
    }

    func testRecoveryNeverReclaimsMissingAuthenticationKeyForEligiblePackage() throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let payload = root.appendingPathComponent("eligible.txt")
        try Data("eligible".utf8).write(to: payload)
        let outgoing = root.appendingPathComponent("outgoing")
        _ = try OutgoingTransferPackage.create(
            items: [payload],
            peer: DeviceID(rawValue: UUID()),
            in: outgoing
        )
        let key = outgoing.appendingPathComponent(".package-authentication-key")
        let interrupted = outgoing.appendingPathComponent(
            ".package-authentication-key.creating.\(UUID().uuidString.lowercased())"
        )
        try FileManager.default.moveItem(at: key, to: interrupted)

        XCTAssertThrowsError(try OutgoingTransferPackage.loadAll(from: outgoing)) { error in
            XCTAssertEqual(error as? TransferProtocolError, .sourceChanged)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: interrupted.path))
    }

    func testRecoveryReclaimsExactLegacyAuthenticationKeyHardLinkWindow() throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let payload = root.appendingPathComponent("legacy-key-window.txt")
        try Data("legacy link publication".utf8).write(to: payload)
        let outgoing = root.appendingPathComponent("outgoing")
        let package = try OutgoingTransferPackage.create(
            items: [payload],
            peer: DeviceID(rawValue: UUID()),
            in: outgoing
        )
        let key = outgoing.appendingPathComponent(".package-authentication-key")
        let interrupted = outgoing.appendingPathComponent(
            ".package-authentication-key.creating.\(UUID().uuidString.lowercased())"
        )
        XCTAssertEqual(Darwin.link(key.path, interrupted.path), 0)

        let loaded = try OutgoingTransferPackage.loadAll(from: outgoing)

        XCTAssertEqual(loaded.map(\.id), [package.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: interrupted.path))
        var status = stat()
        XCTAssertEqual(lstat(key.path, &status), 0)
        XCTAssertEqual(status.st_nlink, 1)
    }

    func testOutgoingPackageFailureAfterRenameCannotRestoreAsOrphan() throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let payload = root.appendingPathComponent("rename-failure.txt")
        try Data("do not send after API failure".utf8).write(to: payload)
        let outgoing = root.appendingPathComponent("outgoing")
        let id = TransferID(rawValue: UUID())

        XCTAssertThrowsError(
            try OutgoingTransferPackage.create(
                items: [payload],
                peer: DeviceID(rawValue: UUID()),
                in: outgoing,
                id: id,
                afterRename: { throw CoordinatorTestError.injectedFailure }
            )
        )

        let finalDirectory = outgoing.appendingPathComponent(
            id.rawValue.uuidString.lowercased()
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalDirectory.path))
        XCTAssertTrue(try OutgoingTransferPackage.loadAll(from: outgoing).isEmpty)
    }

    func testRestartDiscardsPackageWithoutDurableDatabaseEligibility() async throws {
        let root = try makeCoordinatorTemporaryDirectory()
        defer { removeCoordinatorTemporaryDirectory(root) }
        let payload = root.appendingPathComponent("ineligible.txt")
        try Data("never automatically send an uncommitted package".utf8).write(to: payload)
        let outgoing = root.appendingPathComponent("outgoing")
        let package = try OutgoingTransferPackage.create(
            items: [payload],
            peer: DeviceID(rawValue: UUID()),
            in: outgoing
        )
        let connector = CountingBlockingConnector()
        let database = try TransferDatabase(url: root.appendingPathComponent("history.sqlite"))

        let restored = try await TransferCoordinator.restoring(
            connector: connector,
            database: database,
            outgoingDirectory: outgoing
        )
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertFalse(FileManager.default.fileExists(atPath: package.directory.path))
        let startedIDs = await connector.startedIDs()
        let restoredPhase = await currentPhase(package.id, on: restored)
        XCTAssertTrue(startedIDs.isEmpty)
        XCTAssertNil(restoredPhase)
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

private func persistOutboundLifecycleThroughVerification(
    _ package: OutgoingTransferPackage,
    database: TransferDatabase
) async throws {
    func snapshot(_ phase: TransferPhase) -> TransferSnapshot {
        TransferSnapshot(
            id: package.id,
            peer: package.peer,
            phase: phase,
            completedBytes: phase == .verifying ? package.totalBytes : 0,
            totalBytes: package.totalBytes,
            route: .lan
        )
    }
    try await database.persist(
        snapshot(.preparing),
        displayFilename: package.displayFilename,
        expectedPhase: nil
    )
    try await database.persist(
        snapshot(.connecting),
        displayFilename: package.displayFilename,
        expectedPhase: .preparing
    )
    try await database.persist(
        snapshot(.transferring),
        displayFilename: package.displayFilename,
        expectedPhase: .connecting
    )
    try await database.persist(
        snapshot(.verifying),
        displayFilename: package.displayFilename,
        expectedPhase: .transferring
    )
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

private func waitForClaimedPhase(
    _ phase: TransferPhase,
    id: TransferID,
    on coordinator: TransferCoordinator
) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if await coordinator.claimedPhase(for: id) == phase { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw CoordinatorTestError.timedOut
}

private func waitForActiveCount(
    _ count: Int,
    on coordinator: TransferCoordinator
) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if await coordinator.activeTransferCount() == count { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw CoordinatorTestError.timedOut
}

private func openDescriptorCount() throws -> Int {
    try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
}

private func waitForClose(on channel: CoordinatorMemoryChannel) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if await channel.closeCount() > 0 { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw CoordinatorTestError.timedOut
}

private func makeCoordinatorTemporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private struct LegacyOutgoingPackageFixture {
    let identifier: String
    let package: URL
    let payloadFile: URL
    let metadata: URL
    let checksum: URL
}

private func makeLegacyOutgoingPackage(
    in outgoing: URL,
    version: Int = 1
) throws -> LegacyOutgoingPackageFixture {
    if !FileManager.default.fileExists(atPath: outgoing.path) {
        try FileManager.default.createDirectory(at: outgoing, withIntermediateDirectories: false)
    }
    guard chmod(outgoing.path, S_IRWXU) == 0 else {
        throw TransferProtocolError.unsupportedSource
    }
    let transferID = TransferID(rawValue: UUID())
    let identifier = transferID.rawValue.uuidString.lowercased()
    let package = outgoing.appendingPathComponent(identifier, isDirectory: true)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
    guard chmod(package.path, S_IRWXU) == 0 else {
        throw TransferProtocolError.unsupportedSource
    }
    let payload = package.appendingPathComponent("payload", isDirectory: true)
    try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false)
    let payloadFile = payload.appendingPathComponent("legacy.txt")
    let payloadBytes = Data("legacy package remains recoverable".utf8)
    try payloadBytes.write(to: payloadFile)
    guard chmod(payloadFile.path, S_IRUSR) == 0,
        chmod(payload.path, S_IRUSR | S_IXUSR) == 0
    else { throw TransferProtocolError.unsupportedSource }
    let manifest = try TransferManifest.build(
        from: payloadFile,
        transferID: transferID,
        immutablePackageSource: true
    )
    let metadata = OutgoingTransferPackage.Metadata(
        version: version,
        transferID: identifier,
        peerID: UUID().uuidString.lowercased(),
        displayFilename: "legacy.txt",
        rootRelativePath: "payload/legacy.txt",
        totalBytes: Int64(payloadBytes.count),
        manifestFingerprint: try manifestFingerprint(manifest).base64EncodedString(),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    let encoded = try encoder.encode(metadata)
    let metadataURL = package.appendingPathComponent("metadata.json")
    let checksumURL = package.appendingPathComponent("metadata.sha256")
    try encoded.write(to: metadataURL)
    try Data(SHA256.hash(data: encoded)).write(to: checksumURL)
    guard chmod(metadataURL.path, S_IRUSR) == 0,
        chmod(checksumURL.path, S_IRUSR) == 0
    else { throw TransferProtocolError.unsupportedSource }
    return LegacyOutgoingPackageFixture(
        identifier: identifier,
        package: package,
        payloadFile: payloadFile,
        metadata: metadataURL,
        checksum: checksumURL
    )
}

private func replaceReadOnlyFile(_ url: URL, with data: Data) throws {
    guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else {
        throw TransferProtocolError.unsupportedSource
    }
    try data.write(to: url)
    guard chmod(url.path, S_IRUSR) == 0 else {
        throw TransferProtocolError.unsupportedSource
    }
}

private func removeCoordinatorTemporaryDirectory(_ root: URL) {
    func makeRemovable(_ url: URL) {
        var status = stat()
        guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else {
            return
        }
        _ = chmod(url.path, S_IRWXU)
        let children = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        )) ?? []
        for child in children { makeRemovable(child) }
    }
    makeRemovable(root)
    try? FileManager.default.removeItem(at: root)
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

private actor FailingThenMemoryConnector: TransferAwarePeerConnector {
    private let destination: URL
    private let failures: Int
    private var attempts = 0

    init(destination: URL, failures: Int) {
        self.destination = destination
        self.failures = failures
    }

    func connect(to device: DeviceID) async throws -> any SecureChannel {
        throw MacChannelError.connectionFailed
    }

    func connect(to device: DeviceID, transferID: TransferID) async throws -> any SecureChannel {
        attempts += 1
        guard attempts > failures else { throw MacChannelError.connectionFailed }
        let pair = CoordinatorMemoryChannelPair.make()
        Task {
            _ = try? await ReceiveSession(
                transferID: transferID,
                destinationDirectory: destination
            ).run(on: pair.receiver)
        }
        return pair.sender
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

private actor RouteEscalatingMemoryConnector: RouteEscalatingPeerConnector {
    private let destination: URL
    private var hints: [ConnectionRoute?] = []
    private var previousReceive: Task<TransferReceiveResult?, Never>?

    init(destination: URL) {
        self.destination = destination
    }

    func connect(to device: DeviceID) async throws -> any SecureChannel {
        throw MacChannelError.connectionFailed
    }

    func connect(to device: DeviceID, transferID: TransferID) async throws -> any SecureChannel {
        try await connect(to: device, transferID: transferID, after: nil)
    }

    func connect(
        to device: DeviceID,
        transferID: TransferID,
        after failedRoute: ConnectionRoute?
    ) async throws -> any SecureChannel {
        if let previousReceive { _ = await previousReceive.value }
        hints.append(failedRoute)
        let shouldRelay = failedRoute == .directInternet
        let pair = CoordinatorMemoryChannelPair.make(
            route: shouldRelay ? .relay : .directInternet,
            failSenderAfter: shouldRelay ? nil : 3
        )
        previousReceive = Task {
            try? await ReceiveSession(
                transferID: transferID,
                destinationDirectory: destination
            ).run(on: pair.receiver)
        }
        return pair.sender
    }

    func failedRouteHints() -> [ConnectionRoute?] {
        hints
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

private actor SuspendedYieldIncomingSource: IncomingTransferConnectionSource {
    private let makeConnection: @Sendable () -> IncomingTransferConnection
    private var requested = false
    private var released = false
    private var createdChannel = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(makeConnection: @escaping @Sendable () -> IncomingTransferConnection) {
        self.makeConnection = makeConnection
    }

    func connections() async -> AsyncThrowingStream<IncomingTransferConnection, Error> {
        requested = true
        if !released {
            await withCheckedContinuation { continuation in
                releaseWaiter = continuation
            }
        }
        let connection = makeConnection()
        createdChannel = true
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(1)) { continuation in
            continuation.yield(connection)
            continuation.finish()
        }
    }

    func waitUntilRequested() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !requested {
            guard ContinuousClock.now < deadline else { throw CoordinatorTestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func wasRequested() -> Bool { requested }
    func didCreateChannel() -> Bool { createdChannel }

    func releaseYield() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor PullCountingIncomingSource: IncomingTransferConnectionSource {
    private let total: Int
    private let makeConnection: @Sendable (Int) -> IncomingTransferConnection
    private var pulls = 0

    init(
        total: Int,
        makeConnection: @escaping @Sendable (Int) -> IncomingTransferConnection
    ) {
        self.total = total
        self.makeConnection = makeConnection
    }

    func connections() -> AsyncThrowingStream<IncomingTransferConnection, Error> {
        AsyncThrowingStream(unfolding: { await self.nextConnection() })
    }

    private func nextConnection() -> IncomingTransferConnection? {
        guard pulls < total else { return nil }
        defer { pulls += 1 }
        return makeConnection(pulls)
    }

    func pullCount() -> Int { pulls }
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

private actor BlockingCloseConnector: TransferAwarePeerConnector {
    private let destination: URL
    private let closeGate = BlockingCloseGate()
    private var connections = 0

    init(destination: URL) {
        self.destination = destination
    }

    func connect(to device: DeviceID) async throws -> any SecureChannel {
        throw MacChannelError.connectionFailed
    }

    func connect(to device: DeviceID, transferID: TransferID) async throws -> any SecureChannel {
        connections += 1
        let pair = CoordinatorMemoryChannelPair.make()
        Task {
            _ = try? await ReceiveSession(
                transferID: transferID,
                destinationDirectory: destination
            ).run(on: pair.receiver)
        }
        return BlockingCloseChannel(base: pair.sender, gate: closeGate)
    }

    func waitUntilCloseStarted() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await closeGate.hasStarted()) {
            guard ContinuousClock.now < deadline else { throw CoordinatorTestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func releaseClose() async {
        await closeGate.release()
    }

    func connectionCount() -> Int { connections }

    func waitUntilConnections(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while connections < count {
            guard ContinuousClock.now < deadline else { throw CoordinatorTestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor StuckSendConnector: TransferAwarePeerConnector {
    private let gate = StuckSendGate()
    private let destination: URL
    private var connections = 0

    init(destination: URL) {
        self.destination = destination
    }

    func connect(to device: DeviceID) async throws -> any SecureChannel {
        throw MacChannelError.connectionFailed
    }

    func connect(to device: DeviceID, transferID: TransferID) async throws -> any SecureChannel {
        connections += 1
        let pair = CoordinatorMemoryChannelPair.make()
        Task {
            _ = try? await ReceiveSession(
                transferID: transferID,
                destinationDirectory: destination
            ).run(on: pair.receiver)
        }
        return StuckSendChannel(base: pair.sender, gate: gate)
    }

    func connectionCount() -> Int { connections }

    func waitUntilConnections(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while connections < count {
            guard ContinuousClock.now < deadline else { throw CoordinatorTestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func waitUntilSends(_ count: Int) async throws {
        try await gate.waitUntilStarted(count)
    }

    func releaseSends() async { await gate.release() }
}

private final class StuckSendChannel: SecureChannel, @unchecked Sendable {
    let route: ConnectionRoute
    private let base: any SecureChannel
    private let gate: StuckSendGate

    init(base: any SecureChannel, gate: StuckSendGate) {
        self.base = base
        self.gate = gate
        route = base.route
    }

    func send(_ frame: Data) async throws {
        await gate.startAndWait()
        try await base.send(frame)
    }
    func frames() -> AsyncThrowingStream<Data, Error> { base.frames() }

    func exportKey(label: String, context: Data, length: Int) async throws -> Data {
        try await base.exportKey(label: label, context: context, length: length)
    }

    func close() async { await base.close() }
}

private final class TerminalBlockingChannel: SecureChannel, @unchecked Sendable {
    let route: ConnectionRoute = .lan
    private let gate = StuckSendGate()

    func send(_ frame: Data) async throws { await gate.startAndWait() }

    func frames() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }

    func exportKey(label: String, context: Data, length: Int) async throws -> Data {
        Data(repeating: 1, count: length)
    }

    func close() async {}

    func releaseSend() async { await gate.release() }
}

private actor StuckSendGate {
    private var started = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func startAndWait() async {
        started += 1
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilStarted(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while started < count {
            guard ContinuousClock.now < deadline else { throw CoordinatorTestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func release() {
        released = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}

private final class BlockingCloseChannel: SecureChannel, @unchecked Sendable {
    let route: ConnectionRoute
    private let base: any SecureChannel
    private let gate: BlockingCloseGate

    init(base: any SecureChannel, gate: BlockingCloseGate) {
        self.base = base
        self.gate = gate
        route = base.route
    }

    func send(_ frame: Data) async throws { try await base.send(frame) }

    func frames() -> AsyncThrowingStream<Data, Error> { base.frames() }

    func exportKey(label: String, context: Data, length: Int) async throws -> Data {
        try await base.exportKey(label: label, context: context, length: length)
    }

    func close() async {
        await gate.waitForRelease()
        await base.close()
    }
}

private actor BlockingCloseGate {
    private var started = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func hasStarted() -> Bool { started }

    func waitForRelease() async {
        started = true
        guard !released else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        released = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}

private actor CancellationMemoryConnector: TransferAwarePeerConnector {
    private let source: DeviceID
    private let policy: ReceivePolicy
    private let directories: DownloadDirectory
    private let database: TransferDatabase
    private let incomingDirectory: URL
    private var senderChannel: CoordinatorMemoryChannel?
    private var connectedIDs: [TransferID] = []

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
        connectedIDs.append(transferID)
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

    func connectedTransferIDs() -> [TransferID] { connectedIDs }
}

private actor BlockingTransferPersistence: TransferSnapshotPersistence {
    private let database: TransferDatabase
    private let blockedPhases: Set<TransferPhase>
    private var isBlocking = true
    private var blockedWriteCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(database: TransferDatabase, blockedPhases: Set<TransferPhase>) {
        self.database = database
        self.blockedPhases = blockedPhases
    }

    func persist(
        _ snapshot: TransferSnapshot,
        displayFilename: String,
        expectedPhase: TransferPhase?
    ) async throws {
        if isBlocking, blockedPhases.contains(snapshot.phase) {
            blockedWriteCount += 1
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        try await database.persist(
            snapshot,
            displayFilename: displayFilename,
            expectedPhase: expectedPhase
        )
    }

    func persistedHistory(limit: Int) async throws -> [TransferHistoryRecord] {
        try await database.history(limit: limit)
    }

    func waitForBlockedWrites(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while blockedWriteCount < count {
            guard ContinuousClock.now < deadline else { throw CoordinatorTestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func releaseBlockedWrites() {
        isBlocking = false
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}

/// Simulates a valid package row that has fallen outside the bounded recent
/// history window while exact identity lookup remains authoritative.
private actor WindowedTransferPersistence: TransferSnapshotPersistence {
    private let database: TransferDatabase

    init(database: TransferDatabase) {
        self.database = database
    }

    func persist(
        _ snapshot: TransferSnapshot,
        displayFilename: String,
        expectedPhase: TransferPhase?
    ) async throws {
        try await database.persist(
            snapshot,
            displayFilename: displayFilename,
            expectedPhase: expectedPhase
        )
    }

    func persistedHistory(limit: Int) async throws -> [TransferHistoryRecord] { [] }

    func persistedTransfer(id: TransferID) async throws -> TransferHistoryRecord? {
        try await database.persistedTransfer(id: id)
    }
}

private actor FailingTransferPersistence: TransferSnapshotPersistence {
    private let database: TransferDatabase
    private var remainingFailures: [TransferPhase: Int]
    private var attemptCounts: [TransferPhase: Int] = [:]

    init(database: TransferDatabase, failures: [TransferPhase: Int]) {
        self.database = database
        remainingFailures = failures
    }

    func persist(
        _ snapshot: TransferSnapshot,
        displayFilename: String,
        expectedPhase: TransferPhase?
    ) async throws {
        attemptCounts[snapshot.phase, default: 0] += 1
        if remainingFailures[snapshot.phase, default: 0] > 0 {
            remainingFailures[snapshot.phase, default: 0] -= 1
            throw ReceiveStoreError.databaseFailure
        }
        try await database.persist(
            snapshot,
            displayFilename: displayFilename,
            expectedPhase: expectedPhase
        )
    }

    func persistedHistory(limit: Int) async throws -> [TransferHistoryRecord] {
        try await database.history(limit: limit)
    }

    func attempts(for phase: TransferPhase) -> Int {
        attemptCounts[phase, default: 0]
    }
}

private actor CommitThenConflictPersistence: TransferSnapshotPersistence {
    private let database: TransferDatabase
    private var phases: Set<TransferPhase> = []

    init(database: TransferDatabase) {
        self.database = database
    }

    func persist(
        _ snapshot: TransferSnapshot,
        displayFilename: String,
        expectedPhase: TransferPhase?
    ) async throws {
        try await database.persist(
            snapshot,
            displayFilename: displayFilename,
            expectedPhase: expectedPhase
        )
        phases.insert(snapshot.phase)
        throw TransferPersistenceError.conditionalConflict
    }

    func persistedHistory(limit: Int) async throws -> [TransferHistoryRecord] {
        try await database.history(limit: limit)
    }

    func persistedTransfer(id: TransferID) async throws -> TransferHistoryRecord? {
        try await database.persistedTransfer(id: id)
    }

    func conflictedPhases() -> Set<TransferPhase> { phases }
}

private actor InitialConditionalConflictPersistence: TransferSnapshotPersistence {
    private let database: TransferDatabase

    init(database: TransferDatabase) {
        self.database = database
    }

    func persist(
        _ snapshot: TransferSnapshot,
        displayFilename: String,
        expectedPhase: TransferPhase?
    ) async throws {
        if snapshot.phase == .preparing {
            throw TransferPersistenceError.conditionalConflict
        }
        try await database.persist(
            snapshot,
            displayFilename: displayFilename,
            expectedPhase: expectedPhase
        )
    }

    func persistedHistory(limit: Int) async throws -> [TransferHistoryRecord] {
        try await database.history(limit: limit)
    }

    func persistedTransfer(id: TransferID) async throws -> TransferHistoryRecord? {
        try await database.persistedTransfer(id: id)
    }
}

private actor AdvanceThenConflictPersistence: TransferSnapshotPersistence {
    private let database: TransferDatabase
    private var advanced = false

    init(database: TransferDatabase) {
        self.database = database
    }

    func persist(
        _ snapshot: TransferSnapshot,
        displayFilename: String,
        expectedPhase: TransferPhase?
    ) async throws {
        if snapshot.phase == .connecting, !advanced {
            advanced = true
            try await database.persist(
                TransferSnapshot(
                    id: snapshot.id,
                    peer: snapshot.peer,
                    phase: .transferring,
                    completedBytes: snapshot.completedBytes,
                    totalBytes: snapshot.totalBytes,
                    route: .relay
                ),
                displayFilename: displayFilename,
                expectedPhase: expectedPhase
            )
            throw TransferPersistenceError.conditionalConflict
        }
        try await database.persist(
            snapshot,
            displayFilename: displayFilename,
            expectedPhase: expectedPhase
        )
    }

    func persistedHistory(limit: Int) async throws -> [TransferHistoryRecord] {
        try await database.history(limit: limit)
    }

    func persistedTransfer(id: TransferID) async throws -> TransferHistoryRecord? {
        try await database.persistedTransfer(id: id)
    }

    func didAdvance() -> Bool { advanced }
}

private actor ConcreteIdentityConflictPersistence: TransferSnapshotPersistence {
    private let database: TransferDatabase
    private let conflictPeer = DeviceID(
        rawValue: UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!
    )
    private var attempts = 0
    private var capturedID: TransferID?

    init(database: TransferDatabase) {
        self.database = database
    }

    func persist(
        _ snapshot: TransferSnapshot,
        displayFilename: String,
        expectedPhase: TransferPhase?
    ) async throws {
        attempts += 1
        guard attempts == 1 else { throw TransferPersistenceError.conditionalConflict }
        capturedID = snapshot.id
        try await database.persist(
            TransferSnapshot(
                id: snapshot.id,
                peer: conflictPeer,
                phase: .preparing,
                completedBytes: 0,
                totalBytes: snapshot.totalBytes,
                route: snapshot.route
            ),
            displayFilename: displayFilename,
            expectedPhase: nil
        )
        try await database.persist(
            snapshot,
            displayFilename: displayFilename,
            expectedPhase: expectedPhase
        )
    }

    func persistedHistory(limit: Int) async throws -> [TransferHistoryRecord] {
        try await database.history(limit: limit)
    }

    func persistedTransfer(id: TransferID) async throws -> TransferHistoryRecord? {
        try await database.persistedTransfer(id: id)
    }

    func attemptCount() -> Int { attempts }
    func conflictID() -> TransferID? { capturedID }
    func conflictingPeer() -> DeviceID { conflictPeer }
}

private actor RemovalBlockedIdentityConflictPersistence: TransferSnapshotPersistence {
    private let database: TransferDatabase
    private let outgoingDirectory: URL
    private let conflictPeer = DeviceID(
        rawValue: UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!
    )
    private var capturedID: TransferID?

    init(database: TransferDatabase, outgoingDirectory: URL) {
        self.database = database
        self.outgoingDirectory = outgoingDirectory
    }

    func persist(
        _ snapshot: TransferSnapshot,
        displayFilename: String,
        expectedPhase: TransferPhase?
    ) async throws {
        guard capturedID == nil else { throw TransferPersistenceError.conditionalConflict }
        capturedID = snapshot.id
        try await database.persist(
            TransferSnapshot(
                id: snapshot.id,
                peer: conflictPeer,
                phase: .preparing,
                completedBytes: 0,
                totalBytes: snapshot.totalBytes,
                route: snapshot.route
            ),
            displayFilename: displayFilename,
            expectedPhase: nil
        )
        guard chmod(outgoingDirectory.path, S_IRUSR | S_IXUSR) == 0 else {
            throw CoordinatorTestError.injectedFailure
        }
        try await database.persist(
            snapshot,
            displayFilename: displayFilename,
            expectedPhase: expectedPhase
        )
    }

    func persistedTransfer(id: TransferID) async throws -> TransferHistoryRecord? {
        try await database.persistedTransfer(id: id)
    }

    func persistedHistory(limit: Int) async throws -> [TransferHistoryRecord] {
        try await database.persistedHistory(limit: limit)
    }

    func conflictID() -> TransferID? { capturedID }
    func conflictingPeer() -> DeviceID { conflictPeer }
}

private actor ConflictThenReadFailurePersistence: TransferSnapshotPersistence {
    private let database: TransferDatabase
    private var injectedConflict = false
    private var readFailures = 0

    init(database: TransferDatabase) {
        self.database = database
    }

    func persist(
        _ snapshot: TransferSnapshot,
        displayFilename: String,
        expectedPhase: TransferPhase?
    ) async throws {
        try await database.persist(
            snapshot,
            displayFilename: displayFilename,
            expectedPhase: expectedPhase
        )
        if snapshot.phase == .connecting, !injectedConflict {
            injectedConflict = true
            throw TransferPersistenceError.conditionalConflict
        }
    }

    func persistedHistory(limit: Int) async throws -> [TransferHistoryRecord] {
        try await database.history(limit: limit)
    }

    func persistedTransfer(id: TransferID) async throws -> TransferHistoryRecord? {
        if injectedConflict, readFailures == 0 {
            readFailures += 1
            throw ReceiveStoreError.databaseFailure
        }
        return try await database.persistedTransfer(id: id)
    }

    func readFailureCount() -> Int { readFailures }
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
        sender = TransferCoordinator(
            connector: connector,
            database: database,
            outgoingDirectory: root.appendingPathComponent("outgoing")
        )
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
        removeCoordinatorTemporaryDirectory(root)
    }
}

private enum CoordinatorTestError: Error {
    case injectedFailure
    case streamEnded
    case timedOut
}

private actor CoordinatorMemoryConnector: TransferAwarePeerConnector {
    private let destinations: [DeviceID: URL]
    private var receiveTasks: [TransferID: Task<Void, Never>] = [:]
    private var connectedIDs: [TransferID] = []

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
        connectedIDs.append(transferID)
        let pair = CoordinatorMemoryChannelPair.make()
        receiveTasks[transferID] = Task {
            _ = try? await ReceiveSession(
                transferID: transferID,
                destinationDirectory: destination
            ).run(on: pair.receiver)
        }
        return pair.sender
    }

    func connectedTransferIDs() -> [TransferID] {
        connectedIDs
    }
}

private actor CloseTrackingSilentChannel: SecureChannel {
    nonisolated let route: ConnectionRoute = .lan
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var closes = 0

    init() {
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        stream = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(1)) {
            continuation = $0
        }
        self.continuation = continuation
    }

    func send(_ frame: Data) async throws {}

    nonisolated func frames() -> AsyncThrowingStream<Data, Error> {
        stream
    }

    func exportKey(label: String, context: Data, length: Int) async throws -> Data {
        Data(repeating: 7, count: length)
    }

    func close() async {
        closes += 1
        continuation.finish()
    }

    func closeCount() -> Int { closes }
}

private actor NoncooperativeCloseGate {
    private var started = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func startAndWait() async {
        started += 1
        guard !released else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func waitUntilStarted(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while started < count {
            guard ContinuousClock.now < deadline else { throw CoordinatorTestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func startedCount() -> Int { started }

    func release() {
        released = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}

private actor NoncooperativeCloseChannel: SecureChannel {
    nonisolated let route: ConnectionRoute = .lan
    private let gate: NoncooperativeCloseGate

    init(gate: NoncooperativeCloseGate) {
        self.gate = gate
    }

    func send(_ frame: Data) async throws {}

    nonisolated func frames() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }

    func exportKey(label: String, context: Data, length: Int) async throws -> Data {
        Data(repeating: 9, count: length)
    }

    func close() async { await gate.startAndWait() }
}

private actor OrderedCloseGate {
    private var started: [Int] = []
    private var released: Set<Int> = []
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]

    func startAndWait(_ index: Int) async {
        started.append(index)
        guard !released.contains(index) else { return }
        await withCheckedContinuation { continuation in
            waiters[index] = continuation
        }
    }

    func waitUntilStarted(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while started.count < count {
            guard ContinuousClock.now < deadline else { throw CoordinatorTestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func startedIndices() -> [Int] { started }

    func release(_ index: Int) {
        released.insert(index)
        waiters.removeValue(forKey: index)?.resume()
    }
}

private actor OrderedNoncooperativeCloseChannel: SecureChannel {
    nonisolated let route: ConnectionRoute = .lan
    private let index: Int
    private let gate: OrderedCloseGate

    init(index: Int, gate: OrderedCloseGate) {
        self.index = index
        self.gate = gate
    }

    func send(_ frame: Data) async throws {}

    nonisolated func frames() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }

    func exportKey(label: String, context: Data, length: Int) async throws -> Data {
        Data(repeating: 9, count: length)
    }

    func close() async { await gate.startAndWait(index) }
}

private actor CancellationInsensitiveFramesChannel: SecureChannel {
    nonisolated let route: ConnectionRoute = .lan
    nonisolated let gate: CancellationInsensitiveFrameGate

    init(gate: CancellationInsensitiveFrameGate) {
        self.gate = gate
    }

    func send(_ frame: Data) async throws {}

    nonisolated func frames() -> AsyncThrowingStream<Data, Error> {
        let gate = gate
        return AsyncThrowingStream(unfolding: {
            await gate.startAndWait()
            return nil
        })
    }

    func exportKey(label: String, context: Data, length: Int) async throws -> Data {
        Data(repeating: 7, count: length)
    }

    func close() async {}
}

private actor CancellationInsensitiveFrameGate {
    private var started = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func startAndWait() async {
        started += 1
        guard !released else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func waitUntilStarted(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while started < count {
            guard ContinuousClock.now < deadline else { throw CoordinatorTestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func startedCount() -> Int { started }

    func release() {
        released = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}

private actor StuckHandshakeChannel: SecureChannel {
    enum Operation: Equatable {
        case send
        case exportKey
    }

    nonisolated let route: ConnectionRoute = .lan
    private let stuckOperation: Operation
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let gate = NeverCompletingOperation()
    private var closes = 0

    init(stuckOperation: Operation) {
        self.stuckOperation = stuckOperation
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        stream = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(1)) {
            continuation = $0
        }
        self.continuation = continuation
    }

    func send(_ frame: Data) async throws {
        if stuckOperation == .send { await gate.wait() }
    }

    nonisolated func frames() -> AsyncThrowingStream<Data, Error> { stream }

    func exportKey(label: String, context: Data, length: Int) async throws -> Data {
        if stuckOperation == .exportKey { await gate.wait() }
        return Data(repeating: 7, count: length)
    }

    func close() async {
        closes += 1
        continuation.finish()
    }

    func closeCount() -> Int { closes }

    func releaseOperation() async { await gate.release() }
}

private actor NeverCompletingOperation {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        released = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations { continuation.resume() }
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
        await sendGate.recordClose()
        continuation.finish()
        peer?.continuation.finish()
    }

    func sentCount() async -> Int {
        await sendGate.sentCount()
    }

    func closeCount() async -> Int {
        await sendGate.closeCount()
    }
}

private actor CoordinatorMemorySendGate {
    private let failAfter: Int?
    private let delay: Duration?
    private var count = 0
    private var closes = 0

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

    func recordClose() { closes += 1 }

    func closeCount() -> Int { closes }
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
