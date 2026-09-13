import Foundation
import XCTest
@testable import MacChannelCore
@testable import DropMeshMobileRuntime

final class MobileForegroundRuntimeTests: XCTestCase {
    func testCompletedSendWinsLateRevocationAccountingWithoutRewritingHistory() async throws {
        let fixture = try await RuntimeFixture.make()
        await fixture.persistence.release.open()
        try await fixture.runtime.startForeground()
        let pair = RuntimeChannel.pair()
        await fixture.networks.lastConnector.install(pair.0)
        let send = Task { try await fixture.runtime.send(items: [fixture.file], to: fixture.peer) }
        await fixture.accounting.entered.wait()
        let coordinator = await fixture.probe.coordinator!
        var stream = await coordinator.snapshots().makeAsyncIterator()
        let snapshots = await stream.next() ?? []
        let id = try XCTUnwrap(snapshots.first?.id)
        _ = try await ReceiveSession(transferID: id, destinationDirectory: fixture.layout.receiveDirectory).run(on: pair.1)
        try await eventually { try await fixture.persistence.database.history().contains { $0.id == id && $0.phase == .completed } }
        _ = try await fixture.repository.revoke(fixture.peer)
        try await fixture.runtime.refreshTrust()
        await fixture.accounting.release.open()
        do { let result = try await send.value; XCTAssertEqual(result, id) }
        catch { XCTFail("Completion won cancellation and must remain truthful: \(error)") }
        let cancellation = await fixture.runtime.cancel(id)
        XCTAssertEqual(cancellation, .tooLate)
        let history = try await fixture.persistence.database.history()
        XCTAssertEqual(history.first { $0.id == id }?.phase, .completed)
        await fixture.runtime.stopForeground()
    }

    func testRevocationCancelsWorkOnAnEstablishedChannel() async throws {
        let fixture = try await RuntimeFixture.make()
        await fixture.persistence.release.open(); await fixture.accounting.release.open()
        try await fixture.runtime.startForeground()
        let channel = RuntimeHeldOutgoingChannel()
        await fixture.networks.lastConnector.install(channel)
        let id = try await fixture.runtime.send(items: [fixture.file], to: fixture.peer)
        await channel.challenge(id)
        do { try await eventually { await channel.entered.isOpen } }
        catch { await channel.close(); await fixture.runtime.stopForeground(); throw error }
        await fixture.persistence.blockTerminal()
        do {
            _ = try await fixture.repository.revoke(fixture.peer)
            try await fixture.runtime.refreshTrust()
            let coordinator = await fixture.probe.coordinator!
            try await eventually { await fixture.persistence.terminalEntered.isOpen }
            let claimed = await coordinator.claimedPhase(for: id)
            XCTAssertTrue(claimed == .cancelling || claimed == .cancelled)
            // cancel() claims intent; snapshots publish only after the FIFO writer
            // saves it. Waiting for the durable snapshot is a separate boundary.
            await fixture.persistence.terminalRelease.open()
            try await eventually {
                var stream = await coordinator.snapshots().makeAsyncIterator()
                return await stream.next()?.contains { $0.id == id && $0.phase == .cancelled } == true
            }
        } catch {
            await fixture.persistence.terminalRelease.open()
            await channel.close()
            await fixture.runtime.stopForeground()
            throw error
        }
        await channel.release.open()
        await fixture.runtime.stopForeground()
    }

    func testRevocationCancelsPausedAndActivePeerButPreservesOtherPeer() async throws {
        let fixture = try await RuntimeFixture.make()
        let peer = try DeviceIdentity.loadOrCreate(keychain: RuntimeSecrets(), policy: MobileIdentityPolicy.policy)
        let other = try DeviceIdentity.loadOrCreate(keychain: RuntimeSecrets(), policy: MobileIdentityPolicy.policy)
        for identity in [peer, other] {
            _ = try await fixture.repository.issueAuthorization(subject: identity.id,
                subjectPublicKey: identity.publicKey.rawRepresentation, timestamp: Date())
        }
        await fixture.persistence.release.open(); await fixture.accounting.release.open()
        try await fixture.runtime.startForeground()
        let active = try await fixture.runtime.send(items: [fixture.file], to: peer.id)
        let paused = try await fixture.runtime.send(items: [fixture.file], to: peer.id)
        try await fixture.runtime.pause(paused)
        let retained = try await fixture.runtime.send(items: [fixture.file], to: other.id)
        _ = try await fixture.repository.revoke(peer.id)
        try await fixture.runtime.refreshTrust()
        let owner = await fixture.probe.coordinator!
        var stream = await owner.snapshots().makeAsyncIterator()
        let values = await stream.next() ?? []
        for id in [active, paused] {
            XCTAssertTrue(values.contains { $0.id == id && [.cancelling, .cancelled].contains($0.phase) })
        }
        XCTAssertTrue(values.contains { $0.id == retained && ![.cancelling, .cancelled].contains($0.phase) })
        await fixture.runtime.stopForeground()
    }

    func testRevocationDuringHiddenAccountingRejectsLateAdmission() async throws {
        let fixture = try await RuntimeFixture.make()
        let peer = try DeviceIdentity.loadOrCreate(keychain: RuntimeSecrets(), policy: MobileIdentityPolicy.policy)
        _ = try await fixture.repository.issueAuthorization(subject: peer.id,
            subjectPublicKey: peer.publicKey.rawRepresentation, timestamp: Date())
        try await fixture.runtime.startForeground()
        let send = Task { try await fixture.runtime.send(items: [fixture.file], to: peer.id) }
        await fixture.persistence.entered.wait()
        _ = try await fixture.repository.revoke(peer.id)
        try await fixture.runtime.refreshTrust()
        await fixture.persistence.release.open()
        await fixture.accounting.entered.wait()
        await fixture.accounting.release.open()
        do { _ = try await send.value; XCTFail("Revoked late admission must not succeed") }
        catch { XCTAssertEqual(error as? MobileRuntimeError, .interrupted) }
        await fixture.runtime.stopForeground()
    }

    func testActionLookupPublishesNewIndexReplacementDiagnostic() async throws {
        let fixture = try await RuntimeFixture.make()
        let peer = try DeviceIdentity.loadOrCreate(keychain: RuntimeSecrets(), policy: MobileIdentityPolicy.policy)
        _ = try await fixture.repository.issueAuthorization(subject: peer.id,
            subjectPublicKey: peer.publicKey.rawRepresentation, timestamp: Date())
        try await fixture.runtime.startForeground()
        let source = await fixture.networks.lastSource
        let manifest = try TransferManifest.build(from: fixture.file)
        let pair = RuntimeChannel.pair()
        let sender = Task { try await SendSession(manifest).run(on: pair.0) }
        try await source.offer(IncomingTransferConnection(source: peer.id, transferID: manifest.id, channel: pair.1))
        _ = try await sender.value
        try await eventually { await fixture.runtime.currentSnapshot().received.count == 1 }

        let stream = await fixture.runtime.snapshots()
        let observation = Task<MobileRuntimeSnapshot?, Never> {
            for await snapshot in stream where snapshot.historyAvailabilityFailure != nil { return snapshot }
            return nil
        }
        let oldIndex = fixture.layout.stateDirectory.appendingPathComponent("old-index")
        try FileManager.default.moveItem(at: fixture.layout.receivedOutputIndexFile, to: oldIndex)
        try Data("replacement".utf8).write(to: fixture.layout.receivedOutputIndexFile,
            options: .atomic)
        let available = await fixture.runtime.availableReceivedURL(for: manifest.id)
        XCTAssertNil(available)
        let changed = try await observedSnapshot(from: observation)
        XCTAssertEqual(changed?.historyAvailabilityFailure, .receivedOutputIndexUnavailable)
        let current = await fixture.runtime.currentSnapshot()
        XCTAssertEqual(current.historyAvailabilityFailure, .receivedOutputIndexUnavailable)
        await fixture.runtime.stopForeground()
    }

    func testCorruptIndexAtConstructionReportsAvailabilityWithoutBlockingStartup() async throws {
        let fixture = try await RuntimeFixture.make(corruptIndex: true)
        let initial = await fixture.runtime.currentSnapshot()
        XCTAssertEqual(initial.historyAvailabilityFailure, .receivedOutputIndexUnavailable)
        try await fixture.runtime.startForeground()
        let online = await fixture.runtime.currentSnapshot()
        XCTAssertEqual(online.state, .online)
        XCTAssertNil(online.failure)
        let history = try await fixture.runtime.history()
        XCTAssertTrue(history.isEmpty)
        await fixture.runtime.stopForeground()
    }
    func testHiddenSendHoldsReentryThroughResultAccounting() async throws {
        let fixture = try await RuntimeFixture.make()
        let runtime = fixture.runtime
        try await runtime.startForeground()
        let send = Task { try await runtime.send(items: [fixture.file], to: fixture.peer) }
        await fixture.persistence.entered.wait()
        let coordinator = await fixture.probe.coordinator!
        var snapshots = await coordinator.snapshots().makeAsyncIterator()
        let hidden = await snapshots.next()
        XCTAssertEqual(hidden?.count, 0)
        let stop = Task { await runtime.stopForeground() }
        await fixture.networks.firstStopped.wait()
        let restart = Task { try await runtime.startForeground() }
        await fixture.persistence.release.open()
        await fixture.accounting.entered.wait()
        let countWhileBlocked = await fixture.networks.count
        XCTAssertEqual(countWhileBlocked, 1)
        let blockedState = await runtime.currentSnapshot()
        XCTAssertEqual(blockedState.state, .stopping)
        await fixture.accounting.release.open()
        await stop.value
        try await restart.value
        do { _ = try await send.value; XCTFail("Interrupted send must fail") } catch { }
        let restoreCount = await fixture.probe.restores
        XCTAssertEqual(restoreCount, 1)
        let calls = await fixture.networks.lastConnector.calls
        XCTAssertTrue(calls.isEmpty)
        await runtime.stopForeground()
    }

    func testCallerCancellationRetainsHiddenWorkerAndInputUntilAccounted() async throws {
        let fixture = try await RuntimeFixture.make()
        try await fixture.runtime.startForeground()
        let send = Task { try await fixture.runtime.send(items: [fixture.file], to: fixture.peer) }
        await fixture.persistence.entered.wait()
        send.cancel()
        let stop = Task { await fixture.runtime.stopForeground() }
        await fixture.networks.firstStopped.wait()
        let restart = Task { try await fixture.runtime.startForeground() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
        await fixture.persistence.release.open()
        await fixture.accounting.entered.wait()
        let count = await fixture.networks.count
        XCTAssertEqual(count, 1)
        await fixture.accounting.release.open()
        await stop.value
        try await restart.value
        do { _ = try await send.value; XCTFail("Caller cancellation must be reported") }
        catch is CancellationError { }
        catch { XCTFail("Expected cancellation, got \(error)") }
        await fixture.runtime.stopForeground()
    }

    func testInitialSnapshotAndInactiveAdmission() async throws {
        let fixture = try await RuntimeFixture.make()
        var stream = await fixture.runtime.snapshots().makeAsyncIterator()
        let initial = await stream.next()
        XCTAssertEqual(initial?.state, .inactive)
        XCTAssertEqual(initial?.received.count, 0)
        do { _ = try await fixture.runtime.send(items: [fixture.file], to: fixture.peer); XCTFail() }
        catch MobileRuntimeError.notForeground { }
        let restores = await fixture.probe.restores
        XCTAssertEqual(restores, 0)
    }

    func testTerminalPersistenceDoesNotBlockNewForegroundAndFreshSendUsesNewConnector() async throws {
        let fixture = try await RuntimeFixture.make()
        await fixture.persistence.release.open()
        await fixture.accounting.release.open()
        try await fixture.runtime.startForeground()
        let old = try await fixture.runtime.send(items: [fixture.file], to: fixture.peer)
        await fixture.persistence.blockTerminal()
        await fixture.runtime.stopForeground()
        await fixture.persistence.terminalEntered.wait()
        try await fixture.runtime.startForeground()
        let fresh = try await fixture.runtime.send(items: [fixture.file], to: fixture.peer)
        let connector = await fixture.networks.lastConnector
        try await eventually { await connector.calls.contains(fresh) }
        let calls = await connector.calls
        XCTAssertFalse(calls.contains(old))
        let restores = await fixture.probe.restores
        XCTAssertEqual(restores, 1)
        await fixture.persistence.terminalRelease.open()
        await fixture.runtime.stopForeground()
        try await eventually {
            try await fixture.persistence.database.history().contains { $0.id == old && $0.phase == .cancelled }
        }
    }

    func testStopStartStopDuringHiddenSendOnlyHonorsLatestDesiredState() async throws {
        let fixture = try await RuntimeFixture.make()
        try await fixture.runtime.startForeground()
        let send = Task { try await fixture.runtime.send(items: [fixture.file], to: fixture.peer) }
        await fixture.persistence.entered.wait()
        let stop = Task { await fixture.runtime.stopForeground() }
        await fixture.networks.firstStopped.wait()
        let restart = Task { try await fixture.runtime.startForeground() }
        try await eventually { await fixture.runtime.currentSnapshot().foregroundRequested }
        let finalStop = Task { await fixture.runtime.stopForeground() }
        try await eventually { await !fixture.runtime.currentSnapshot().foregroundRequested }
        await fixture.persistence.release.open()
        await fixture.accounting.entered.wait()
        await fixture.accounting.release.open()
        _ = try? await send.value
        await stop.value; _ = try? await restart.value; await finalStop.value
        let snapshot = await fixture.runtime.currentSnapshot()
        XCTAssertEqual(snapshot.state, .inactive)
        let count = await fixture.networks.count
        XCTAssertEqual(count, 1)
    }

    func testSendFailureAndPreAdmissionCancellationDoNotLeakBarrier() async throws {
        let fixture = try await RuntimeFixture.make()
        await fixture.accounting.release.open()
        await fixture.persistence.release.open()
        try await fixture.runtime.startForeground()
        do { _ = try await fixture.runtime.send(items: [fixture.file.appendingPathComponent("missing")], to: fixture.peer); XCTFail() }
        catch MobileRuntimeError.sendFailed { }
        let gate = RuntimeGate()
        let cancelled = Task {
            await gate.wait()
            return try await fixture.runtime.send(items: [fixture.file], to: fixture.peer)
        }
        cancelled.cancel(); await gate.open()
        do { _ = try await cancelled.value; XCTFail() } catch is CancellationError { }
        await fixture.runtime.stopForeground()
        try await fixture.runtime.startForeground()
        let restores = await fixture.probe.restores
        XCTAssertEqual(restores, 1)
        await fixture.runtime.stopForeground()
    }

    func testReceivePublishesOnlyActualCompletionIntoDocuments() async throws {
        let fixture = try await RuntimeFixture.make()
        let peer = try DeviceIdentity.loadOrCreate(keychain: RuntimeSecrets(), policy: MobileIdentityPolicy.policy)
        _ = try await fixture.repository.issueAuthorization(subject: peer.id, subjectPublicKey: peer.publicKey.rawRepresentation, timestamp: Date())
        try await fixture.runtime.startForeground()
        let source = await fixture.networks.lastSource
        let manifest = try TransferManifest.build(from: fixture.file)
        let pair = RuntimeChannel.pair()
        let stream = await fixture.runtime.snapshots()
        let firstCompletion = Task {
            for await snapshot in stream where !snapshot.received.isEmpty {
                // Synchronous filesystem observation at the first delivered completion.
                return FileManager.default.fileExists(atPath: fixture.layout.receivedOutputIndexFile.path)
            }
            return false
        }
        let sender = Task { try await SendSession(manifest).run(on: pair.0) }
        try await source.offer(IncomingTransferConnection(source: peer.id, transferID: manifest.id, channel: pair.1))
        _ = try await sender.value
        let alreadyRecorded = await firstCompletion.value
        XCTAssertTrue(alreadyRecorded)
        try await eventually { await fixture.runtime.currentSnapshot().received.count == 1 }
        let snapshot = await fixture.runtime.currentSnapshot()
        let result = try XCTUnwrap(snapshot.received.first)
        XCTAssertEqual(result.transferID, manifest.id)
        XCTAssertEqual(result.receivedURLs.first?.deletingLastPathComponent(), fixture.layout.receiveDirectory)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.receivedURLs.first)), Data("fixture".utf8))
        let history = try await fixture.runtime.history()
        XCTAssertEqual(history.first?.id, result.transferID)
        XCTAssertEqual(history.first?.availableURL, result.receivedURLs.first)
        let reopenedIndex = MobileReceivedOutputIndex(url: fixture.layout.receivedOutputIndexFile,
            receiveDirectory: fixture.layout.receiveDirectory, database: fixture.persistence.database)
        let durableURL = await reopenedIndex.availableURL(for: result.transferID)
        XCTAssertEqual(durableURL, result.receivedURLs.first)
        let badPair = RuntimeChannel.pair()
        try await source.offer(IncomingTransferConnection(source: peer.id, transferID: TransferID(rawValue: UUID()), channel: badPair.1))
        await badPair.0.close()
        try await eventually { await fixture.runtime.currentSnapshot().failure == .receive }
        let failed = await fixture.runtime.currentSnapshot()
        XCTAssertEqual(failed.received.count, 1)
        await fixture.runtime.stopForeground()
    }

    func testCorruptIndexDoesNotBlockNetworkOrSuccessfulReceiveSnapshot() async throws {
        let fixture = try await RuntimeFixture.make()
        // The owner already exists: force its first index publication to fail.
        try FileManager.default.createDirectory(at: fixture.layout.receivedOutputIndexFile, withIntermediateDirectories: false)
        let peer = try DeviceIdentity.loadOrCreate(keychain: RuntimeSecrets(), policy: MobileIdentityPolicy.policy)
        _ = try await fixture.repository.issueAuthorization(subject: peer.id, subjectPublicKey: peer.publicKey.rawRepresentation, timestamp: Date())
        try await fixture.runtime.startForeground()
        let source = await fixture.networks.lastSource
        let manifest = try TransferManifest.build(from: fixture.file)
        let pair = RuntimeChannel.pair()
        let sender = Task { try await SendSession(manifest).run(on: pair.0) }
        try await source.offer(IncomingTransferConnection(source: peer.id, transferID: manifest.id, channel: pair.1))
        _ = try await sender.value
        try await eventually { await fixture.runtime.currentSnapshot().received.count == 1 }
        let snapshot = await fixture.runtime.currentSnapshot()
        XCTAssertEqual(snapshot.state, .online)
        XCTAssertNil(snapshot.failure)
        XCTAssertEqual(snapshot.historyAvailabilityFailure, .receivedOutputIndexUnavailable)
        let history = try await fixture.runtime.history()
        XCTAssertEqual(history.first?.phase, .completed)
        XCTAssertNil(history.first?.availableURL)
        await fixture.runtime.stopForeground()
        try await fixture.runtime.startForeground()
        let restores = await fixture.probe.restores
        XCTAssertEqual(restores, 1)
        let persisted = try await fixture.runtime.history()
        XCTAssertEqual(persisted.first?.phase, .completed)
        await fixture.runtime.stopForeground()
    }

    func testTrustPolicyReplacementWaitsForReceiveDrainAndUsesLatestRevocation() async throws {
        let fixture = try await RuntimeFixture.make()
        let peer = try DeviceIdentity.loadOrCreate(keychain: RuntimeSecrets(), policy: MobileIdentityPolicy.policy)
        _ = try await fixture.repository.issueAuthorization(subject: peer.id, subjectPublicKey: peer.publicKey.rawRepresentation, timestamp: Date())
        try await fixture.runtime.startForeground()
        let source = await fixture.networks.lastSource
        let channel = RuntimeBlockedChannel()
        try await source.offer(IncomingTransferConnection(source: peer.id, transferID: TransferID(rawValue: UUID()), channel: channel))
        await channel.entered.wait()
        _ = try await fixture.repository.revoke(peer.id)
        let refresh = Task { try await fixture.runtime.refreshTrust() }
        await channel.closeEntered.wait()
        let before = await source.consumers
        XCTAssertEqual(before, 1)
        // A second update while drain is blocked must coalesce, never create a consumer.
        let another = try DeviceIdentity.loadOrCreate(keychain: RuntimeSecrets(), policy: MobileIdentityPolicy.policy)
        _ = try await fixture.repository.issueAuthorization(subject: another.id, subjectPublicKey: another.publicKey.rawRepresentation, timestamp: Date())
        await channel.release.open()
        try await refresh.value
        try await eventually { await source.consumers >= 2 }
        let manifest = try TransferManifest.build(from: fixture.file)
        let pair = RuntimeChannel.pair()
        let sender = Task { try await SendSession(manifest).run(on: pair.0) }
        try await source.offer(IncomingTransferConnection(source: peer.id, transferID: manifest.id, channel: pair.1))
        do { _ = try await sender.value; XCTFail("Revoked peer must be rejected") } catch { }
        let snapshot = await fixture.runtime.currentSnapshot()
        XCTAssertTrue(snapshot.received.isEmpty)
        await fixture.runtime.stopForeground()
    }

    func testStopInitiatesNetworkShutdownWhileTrustRefreshIsDraining() async throws {
        let fixture = try await RuntimeFixture.make()
        let peer = try DeviceIdentity.loadOrCreate(keychain: RuntimeSecrets(), policy: MobileIdentityPolicy.policy)
        _ = try await fixture.repository.issueAuthorization(subject: peer.id, subjectPublicKey: peer.publicKey.rawRepresentation, timestamp: Date())
        try await fixture.runtime.startForeground()
        let source = await fixture.networks.lastSource
        let channel = RuntimeBlockedChannel()
        try await source.offer(IncomingTransferConnection(source: peer.id, transferID: TransferID(rawValue: UUID()), channel: channel))
        await channel.entered.wait()
        _ = try await fixture.repository.revoke(peer.id)
        await channel.closeEntered.wait()
        let stop = Task { await fixture.runtime.stopForeground() }
        await fixture.networks.firstStopped.wait()
        let state = await fixture.runtime.currentSnapshot().state
        XCTAssertEqual(state, .stopping)
        let restart = Task { try await fixture.runtime.startForeground() }
        let count = await fixture.networks.count
        XCTAssertEqual(count, 1)
        await channel.release.open()
        await stop.value; try await restart.value
        await fixture.runtime.stopForeground()
    }

    func testDiscoveryFailureDoesNotChangeAuthenticatedOnlineState() async throws {
        let fixture = try await RuntimeFixture.make()
        try await fixture.runtime.startForeground()
        await fixture.runtime.setLocalDiscoveryEnabled(true)
        let snapshot = await fixture.runtime.currentSnapshot()
        XCTAssertEqual(snapshot.state, .online)
        XCTAssertFalse(snapshot.localNetworkAvailable)
        await fixture.runtime.stopForeground()
    }

    func testStopStartsIncomingCloseEvenWhileTrustPersistenceIsSuspended() async throws {
        let fixture = try await RuntimeFixture.make()
        let peer = try DeviceIdentity.loadOrCreate(keychain: RuntimeSecrets(), policy: MobileIdentityPolicy.policy)
        _ = try await fixture.repository.issueAuthorization(subject: peer.id, subjectPublicKey: peer.publicKey.rawRepresentation, timestamp: Date())
        try await fixture.runtime.startForeground()
        let source = await fixture.networks.lastSource
        let channel = RuntimeBlockedChannel()
        try await source.offer(IncomingTransferConnection(source: peer.id, transferID: TransferID(rawValue: UUID()), channel: channel))
        await channel.entered.wait()
        await fixture.trustPersistence.block()
        let refresh = Task { try await fixture.runtime.refreshTrust() }
        await fixture.trustPersistence.entered.wait()
        let stop = Task { await fixture.runtime.stopForeground() }
        await fixture.networks.firstStopped.wait()
        do { try await eventually { await channel.closeEntered.isOpen } }
        catch { XCTFail("Stop must initiate incoming close before suspended trust persistence returns") }
        await channel.release.open()
        await fixture.trustPersistence.release.open()
        try await refresh.value; await stop.value
    }

    func testStopCancelsActiveQueuedAndPausedTransfers() async throws {
        let fixture = try await RuntimeFixture.make()
        await fixture.persistence.release.open(); await fixture.accounting.release.open()
        try await fixture.runtime.startForeground()
        let peer = fixture.peer
        let first = try await fixture.runtime.send(items: [fixture.file], to: peer)
        let second = try await fixture.runtime.send(items: [fixture.file], to: peer)
        let paused = try await fixture.runtime.send(items: [fixture.file], to: peer)
        let queued = try await fixture.runtime.send(items: [fixture.file], to: peer)
        try await fixture.runtime.pause(paused)
        try await fixture.runtime.resume(paused)
        try await fixture.runtime.pause(paused)
        await fixture.runtime.stopForeground()
        let ids: Set<TransferID> = [first, second, paused, queued]
        try await eventually {
            let history = try await fixture.persistence.database.history()
            return Set(history.filter { $0.phase == .cancelled }.map(\.id)).isSuperset(of: ids)
        }
        try await fixture.runtime.startForeground()
        do { try await fixture.runtime.resume(paused); XCTFail("Cancelled IDs require a fresh send") } catch { }
        let calls = await fixture.networks.lastConnector.calls
        XCTAssertTrue(calls.isEmpty)
        await fixture.runtime.stopForeground()
    }

    func testRestoresExistingPausedPackageOnceAndBackgroundCancelsIt() async throws {
        let fixture = try await RuntimeFixture.make()
        let package = try OutgoingTransferPackage.create(items: [fixture.file], peer: fixture.peer, in: fixture.layout.stateDirectory.appendingPathComponent("outgoing"))
        try await fixture.persistence.database.persist(TransferSnapshot(id: package.id, peer: package.peer,
            phase: .paused, completedBytes: 0, totalBytes: package.totalBytes, route: .lan),
            displayFilename: package.displayFilename, expectedPhase: nil)
        try await fixture.runtime.startForeground()
        try await eventually { await fixture.runtime.currentSnapshot().transfers.contains { $0.id == package.id && $0.phase == .paused } }
        await fixture.runtime.stopForeground()
        try await fixture.runtime.startForeground()
        let restores = await fixture.probe.restores
        XCTAssertEqual(restores, 1)
        let calls = await fixture.networks.lastConnector.calls
        XCTAssertFalse(calls.contains(package.id))
        await fixture.runtime.stopForeground()
    }

    func testMultipleHiddenSendsReleasedOutOfOrderRetainBarrier() async throws {
        let fixture = try await RuntimeFixture.make()
        await fixture.persistence.blockIndividually()
        await fixture.accounting.release.open()
        try await fixture.runtime.startForeground()
        let first = Task { try await fixture.runtime.send(items: [fixture.file], to: fixture.peer) }
        try await eventually { await fixture.persistence.individual.count == 1 }
        let second = Task { try await fixture.runtime.send(items: [fixture.file], to: fixture.peer) }
        try await eventually { await fixture.persistence.individual.count == 2 }
        let stop = Task { await fixture.runtime.stopForeground() }
        await fixture.networks.firstStopped.wait()
        let restart = Task { try await fixture.runtime.startForeground() }
        try await eventually { await fixture.runtime.currentSnapshot().foregroundRequested }
        let gates = await fixture.persistence.individual
        await gates[1].open()
        _ = try? await second.value
        let count = await fixture.networks.count
        XCTAssertEqual(count, 1)
        await gates[0].open()
        _ = try? await first.value
        await stop.value; try await restart.value
        let calls = await fixture.networks.lastConnector.calls
        XCTAssertTrue(calls.isEmpty)
        await fixture.runtime.stopForeground()
    }

    func testStoppedStartCannotPublishLateOnlineOrAdmitSending() async throws {
        let fixture = try await RuntimeFixture.make()
        await fixture.networks.startControl.block()
        let start = Task { try await fixture.runtime.startForeground() }
        await fixture.networks.startControl.entered.wait()
        let stop = Task { await fixture.runtime.stopForeground() }
        await fixture.networks.firstStopped.wait()
        do { _ = try await fixture.runtime.send(items: [fixture.file], to: fixture.peer); XCTFail() }
        catch MobileRuntimeError.notForeground { }
        await fixture.networks.startControl.release.open()
        do { try await start.value; XCTFail() } catch MobileRuntimeError.interrupted { }
        await stop.value
        let snapshot = await fixture.runtime.currentSnapshot()
        XCTAssertEqual(snapshot.state, .inactive)
        XCTAssertFalse(snapshot.foregroundRequested)
    }

    func testRetryRecoversFailedGraphConstructionWithoutAnotherDatabaseOrRestore() async throws {
        let fixture = try await RuntimeFixture.make()
        await fixture.networks.failNextConstruction()
        do { try await fixture.runtime.startForeground(); XCTFail() } catch { }
        let failed = await fixture.runtime.currentSnapshot()
        XCTAssertEqual(failed.state, .failed(.network))
        await fixture.runtime.retryConnection()
        let recovered = await fixture.runtime.currentSnapshot()
        XCTAssertEqual(recovered.state, .online)
        let restores = await fixture.probe.restores
        XCTAssertEqual(restores, 1)
        await fixture.runtime.stopForeground()
    }

    private func eventually(_ predicate: @escaping () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while try await !predicate() {
            guard ContinuousClock.now < deadline else { throw RuntimeTestError.timeout }
            await Task.yield()
        }
    }

    private func observedSnapshot(from observation: Task<MobileRuntimeSnapshot?, Never>) async throws -> MobileRuntimeSnapshot? {
        let result = await withTaskGroup(of: MobileRuntimeSnapshot?.self) { group in
            group.addTask { await observation.value }
            group.addTask { try? await Task.sleep(for: .seconds(5)); return nil }
            let first = await group.next() ?? nil
            if first == nil { observation.cancel() }
            group.cancelAll()
            return first
        }
        if result == nil {
            observation.cancel()
            _ = await observation.value
            throw RuntimeTestError.timeout
        }
        return result
    }
}

private enum RuntimeTestError: Error { case timeout }

private actor RuntimeGate {
    var isOpen = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() { isOpen = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
}

private actor RuntimeAccounting {
    let entered = RuntimeGate()
    let release = RuntimeGate()
    func wait() async { await entered.open(); await release.wait() }
}

private actor RuntimePersistence: TransferSnapshotPersistence {
    let database: TransferDatabase
    let entered = RuntimeGate()
    let release = RuntimeGate()
    let terminalEntered = RuntimeGate()
    let terminalRelease = RuntimeGate()
    var blockingTerminal = false
    var individually = false
    var individual: [RuntimeGate] = []
    func blockIndividually() { individually = true }
    func blockTerminal() { blockingTerminal = true }
    init(_ database: TransferDatabase) { self.database = database }
    func persist(_ snapshot: TransferSnapshot, displayFilename: String, expectedPhase: TransferPhase?) async throws {
        if snapshot.phase == .preparing {
            await entered.open()
            if individually { let gate = RuntimeGate(); individual.append(gate); await gate.wait() }
            else { await release.wait() }
        }
        if blockingTerminal, snapshot.phase == .cancelling || snapshot.phase == .cancelled {
            await terminalEntered.open(); await terminalRelease.wait()
        }
        try await database.persist(snapshot, displayFilename: displayFilename, expectedPhase: expectedPhase)
    }
    func persistedHistory(limit: Int) async throws -> [TransferHistoryRecord] { try await database.history(limit: limit) }
}

private actor RuntimeProbe {
    var coordinator: TransferCoordinator?
    var restores = 0
    func restored(_ value: TransferCoordinator) { coordinator = value; restores += 1 }
}

private actor RuntimeConnector: RouteEscalatingPeerConnector {
    var calls: [TransferID] = []
    let release = RuntimeGate()
    var channel: (any SecureChannel)?
    func install(_ channel: any SecureChannel) { self.channel = channel }
    func connect(to device: DeviceID) async throws -> any SecureChannel { throw CancellationError() }
    func connect(to device: DeviceID, transferID: TransferID) async throws -> any SecureChannel {
        calls.append(transferID)
        if let channel { return channel }
        await release.wait(); throw CancellationError()
    }
    func connect(to device: DeviceID, transferID: TransferID, after failedRoute: ConnectionRoute?) async throws -> any SecureChannel {
        calls.append(transferID)
        if let channel { return channel }
        await release.wait(); throw CancellationError()
    }
}

private actor RuntimeHeldOutgoingChannel: SecureChannel {
    nonisolated let route: ConnectionRoute = .lan
    private nonisolated let stream = AsyncThrowingStream<Data, Error>.makeStream()
    let entered = RuntimeGate()
    let release = RuntimeGate()
    func challenge(_ id: TransferID) { stream.continuation.yield(TransferReceiverChallenge.fresh(for: id).encode()) }
    func send(_ frame: Data) async throws { await entered.open(); await release.wait(); throw CancellationError() }
    nonisolated func frames() -> AsyncThrowingStream<Data, Error> { stream.stream }
    func exportKey(label: String, context: Data, length: Int) async throws -> Data { Data(repeating: 7, count: length) }
    func close() async { stream.continuation.finish(); await release.open() }
}

private actor RuntimeSource: IncomingTransferConnectionSource {
    var continuation: AsyncThrowingStream<IncomingTransferConnection, Error>.Continuation?
    var consumers = 0
    func connections() async -> AsyncThrowingStream<IncomingTransferConnection, Error> {
        consumers += 1
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(0)) { continuation = $0 }
    }
    func stop() { continuation?.finish() }
    func offer(_ value: IncomingTransferConnection) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
            if let continuation, case .enqueued = continuation.yield(value) { return }
            guard ContinuousClock.now < deadline else { throw RuntimeTestError.timeout }
            await Task.yield()
        }
    }
}

private struct RuntimeNetwork: MobileForegroundNetwork {
    let fixtureConnector: RuntimeConnector
    let fixtureSource: RuntimeSource
    let stopped: RuntimeGate
    let state: @Sendable (MobilePresenceState) async -> Void
    let startControl: RuntimeTrustPersistence
    var connector: any RouteEscalatingPeerConnector { fixtureConnector }
    var source: any IncomingTransferConnectionSource { fixtureSource }
    func start() async { await startControl.wait(); await state(.online) }
    func stop() async { await fixtureSource.stop(); await fixtureConnector.release.open(); await stopped.open() }
    func retryConnection() async { }
    func refreshTrust() async { }
    func setLocalDiscoveryEnabled(_ enabled: Bool) async { }
}

private actor RuntimeNetworks {
    let firstStopped = RuntimeGate()
    let startControl = RuntimeTrustPersistence()
    var count = 0
    var lastConnector = RuntimeConnector()
    var lastSource = RuntimeSource()
    var failNext = false
    func failNextConstruction() { failNext = true }
    func make(state: @escaping @Sendable (MobilePresenceState) async -> Void) throws -> any MobileForegroundNetwork {
        count += 1
        if failNext { failNext = false; throw MobileRuntimeFailure.network }
        lastConnector = RuntimeConnector()
        lastSource = RuntimeSource()
        return RuntimeNetwork(fixtureConnector: lastConnector, fixtureSource: lastSource, stopped: firstStopped, state: state, startControl: startControl)
    }
}

private struct RuntimeFixture {
    let peer: DeviceID
    let runtime: MobileForegroundRuntime
    let file: URL
    let persistence: RuntimePersistence
    let accounting: RuntimeAccounting
    let networks: RuntimeNetworks
    let probe: RuntimeProbe
    let repository: TrustRepository
    let layout: MobileStorageLayout
    let trustPersistence: RuntimeTrustPersistence
    static func make(corruptIndex: Bool = false) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mobile-runtime-\(UUID())")
        let layout = MobileStorageLayout(applicationSupport: root.appendingPathComponent("Support"), documents: root.appendingPathComponent("Documents"))
        let context = try await MobileIdentityContext.load(layout: layout, secrets: RuntimeSecrets())
        let peer = try DeviceIdentity.loadOrCreate(keychain: RuntimeSecrets(), policy: MobileIdentityPolicy.policy)
        _ = try await context.repository.issueAuthorization(subject: peer.id,
            subjectPublicKey: peer.publicKey.rawRepresentation, timestamp: Date())
        if corruptIndex { try Data("invalid".utf8).write(to: layout.receivedOutputIndexFile) }
        let database = try TransferDatabase(url: layout.stateDirectory.appendingPathComponent("transfers.sqlite3"))
        let persistence = RuntimePersistence(database)
        let accounting = RuntimeAccounting()
        let networks = RuntimeNetworks()
        let probe = RuntimeProbe()
        let trustPersistence = RuntimeTrustPersistence()
        let file = layout.stagingDirectory.appendingPathComponent("fixture.txt")
        try Data("fixture".utf8).write(to: file)
        let runtime = MobileForegroundRuntime(identity: context.identity, repository: context.repository, layout: layout,
            database: database, persistence: persistence, persistTrust: { await trustPersistence.wait(); try await context.persistTrust() },
            makeNetwork: { _, state, _ in try await networks.make(state: state) },
            onRestored: { await probe.restored($0) }, beforeSendAccounting: { await accounting.wait() })
        return Self(peer: peer.id, runtime: runtime, file: file, persistence: persistence, accounting: accounting, networks: networks, probe: probe, repository: context.repository, layout: layout, trustPersistence: trustPersistence)
    }
}

private actor RuntimeTrustPersistence {
    let entered = RuntimeGate()
    let release = RuntimeGate()
    var blocked = false
    func block() { blocked = true }
    func wait() async { if blocked { await entered.open(); await release.wait() } }
}

private struct RuntimeChannel: SecureChannel {
    let route: ConnectionRoute = .lan
    let input: AsyncThrowingStream<Data, Error>
    let output: AsyncThrowingStream<Data, Error>.Continuation
    let own: AsyncThrowingStream<Data, Error>.Continuation
    func send(_ frame: Data) async throws { output.yield(frame) }
    func frames() -> AsyncThrowingStream<Data, Error> { input }
    func exportKey(label: String, context: Data, length: Int) async throws -> Data { Data(repeating: 7, count: length) }
    func close() async { output.finish(); own.finish() }
    static func pair() -> (Self, Self) {
        let a = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        let b = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        return (Self(input: a.stream, output: b.continuation, own: a.continuation),
                Self(input: b.stream, output: a.continuation, own: b.continuation))
    }
}

private struct RuntimeBlockedChannel: SecureChannel {
    let route: ConnectionRoute = .lan
    let entered = RuntimeGate()
    let release = RuntimeGate()
    let closeEntered = RuntimeGate()
    func send(_ frame: Data) async throws { }
    func frames() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream(unfolding: { await entered.open(); await release.wait(); return nil })
    }
    func exportKey(label: String, context: Data, length: Int) async throws -> Data { Data(repeating: 7, count: length) }
    func close() async { await closeEntered.open(); await release.wait() }
}

private final class RuntimeSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func data(for account: String, policy: KeychainPolicy) throws -> Data? {
        lock.lock(); defer { lock.unlock() }; return values[policy.service + account]
    }
    func store(_ data: Data, for account: String, policy: KeychainPolicy) throws {
        lock.lock(); defer { lock.unlock() }; values[policy.service + account] = data
    }
}
