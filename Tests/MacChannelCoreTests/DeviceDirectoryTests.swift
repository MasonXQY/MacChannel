import Foundation
import Network
import XCTest
@testable import MacChannelCore

final class DeviceDirectoryTests: XCTestCase {
    func testLANPresenceWinsOverInternet() async {
        let peer = DeviceID(rawValue: UUID())
        let directory = DeviceDirectory(trust: .allowing(peer))

        await directory.apply(.internet(peer, online: true))
        await directory.apply(.lan(peer, host: "peer.local", port: 7443))

        let snapshot = await directory.snapshot()
        XCTAssertEqual(snapshot.first?.availability, .lan)
    }

    func testUntrustedPeersNeverAppear() async {
        let trusted = DeviceID(rawValue: UUID())
        let untrusted = DeviceID(rawValue: UUID())
        let directory = DeviceDirectory(trust: .allowing(trusted))

        await directory.apply(.internet(untrusted, online: true))
        await directory.apply(.lan(untrusted, host: "untrusted.local", port: 7443))

        let snapshot = await directory.snapshot()
        XCTAssertTrue(snapshot.isEmpty)
    }

    func testDirectoryDerivesItsAllowListFromTrustStore() async throws {
        let owner = try DeviceIdentity.ephemeral()
        let peer = try DeviceIdentity.ephemeral()
        let untrusted = DeviceID(rawValue: UUID())
        var store = TrustStore(owner: owner.id)
        try store.authorize(SignedTrustRecord.authorizing(peer, signedBy: owner))
        let directory = DeviceDirectory(trust: store)

        await directory.apply(.internet(peer.id, online: true))
        await directory.apply(.internet(untrusted, online: true))

        let snapshot = await directory.snapshot()
        XCTAssertEqual(snapshot.map(\.id), [peer.id])
    }

    func testRepositoryRevocationImmediatelyRemovesExistingLANSighting() async throws {
        let owner = try DeviceIdentity.ephemeral()
        let peer = try DeviceIdentity.ephemeral()
        let repository = try TrustRepository(
            ownerIdentity: owner,
            trustStore: TrustStore(owner: owner.id),
            persistedGeneration: 0
        )
        let directory = DeviceDirectory(trust: TrustStore(owner: owner.id))
        await directory.observeTrust(repository)
        _ = try await repository.issueAuthorization(
            subject: peer.id,
            subjectPublicKey: peer.publicKey.rawRepresentation,
            timestamp: Date()
        )
        await directory.waitForTrustUpdates()
        await directory.apply(.lan(peer.id, host: "peer.local", port: 7443))
        let endpointBeforeRevoke = await directory.endpoint(for: peer.id)
        XCTAssertNotNil(endpointBeforeRevoke)

        _ = try await repository.revoke(peer.id)
        await directory.waitForTrustUpdates()

        let snapshot = await directory.snapshot()
        let endpointAfterRevoke = await directory.endpoint(for: peer.id)
        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertNil(endpointAfterRevoke)
    }

    func testLANExpiryFallsBackToInternetEndpoint() async {
        let peer = DeviceID(rawValue: UUID())
        let clock = ManualDirectoryClock()
        let directory = DeviceDirectory(trust: .allowing(peer), now: { clock.now })

        await directory.apply(.internet(peer, online: true))
        await directory.apply(.lan(peer, host: "peer.local", port: 7443))
        clock.advance(by: 16)

        let snapshot = await directory.snapshot()
        let endpoint = await directory.endpoint(for: peer)
        XCTAssertEqual(snapshot.first?.availability, .internet)
        XCTAssertNil(endpoint)
    }

    func testInternetPresenceExpiresAfterFortyFiveSeconds() async {
        let peer = DeviceID(rawValue: UUID())
        let clock = ManualDirectoryClock()
        let directory = DeviceDirectory(trust: .allowing(peer), now: { clock.now })

        await directory.apply(.internet(peer, online: true))
        clock.advance(by: 46)

        let snapshot = await directory.snapshot()
        XCTAssertTrue(snapshot.isEmpty)
    }

    func testPresenceClientMapsAuthenticatedOnlineAndOfflineEvents() async {
        let peer = DeviceID(rawValue: UUID())
        let directory = DeviceDirectory(trust: .allowing(peer))
        let client = PresenceClient(directory: directory)

        await client.receiveAuthenticated(.availability(device: peer, isOnline: true))
        let onlineSnapshot = await directory.snapshot()
        XCTAssertEqual(onlineSnapshot.first?.availability, .internet)
        await client.receiveAuthenticated(.availability(device: peer, isOnline: false))

        let offlineSnapshot = await directory.snapshot()
        XCTAssertTrue(offlineSnapshot.isEmpty)
    }

    func testAuthenticatedPresenceSessionSignsServerChallenge() async throws {
        let identity = try DeviceIdentity.ephemeral()
        let socket = MemoryPresenceSocket(incoming: [
            try frame(["type": "challenge", "nonce": Data(repeating: 7, count: 32).base64EncodedString(), "expiresAt": 9_999_999_999_999]),
            try frame(["type": "auth-ok", "deviceID": identity.id.rawValue.uuidString.lowercased()]),
        ])
        let client = PresenceClient(directory: DeviceDirectory(trust: .allowing(identity.id)))
        let session = try AuthenticatedPresenceSession(identity: identity, origin: URL(string: "wss://rendezvous.example/v1/ws")!, socket: socket, client: client)

        try await session.connect()
        let authentication = try await socket.sentFrame()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: authentication) as? [String: Any])
        let envelope = try XCTUnwrap(object["envelope"] as? [String: Any])
        XCTAssertEqual(envelope["deviceID"] as? String, identity.id.rawValue.uuidString.lowercased())
        XCTAssertEqual(envelope["nonce"] as? String, Data(repeating: 7, count: 32).base64EncodedString())
        let canonical = WebSocketCanonical(
            deviceID: try XCTUnwrap(envelope["deviceID"] as? String),
            nonce: try XCTUnwrap(envelope["nonce"] as? String),
            payload: try XCTUnwrap(envelope["payload"] as? String),
            publicKey: try XCTUnwrap(envelope["publicKey"] as? String),
            epochMilliseconds: try XCTUnwrap((envelope["epochMilliseconds"] as? NSNumber)?.int64Value)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let signature = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(envelope["signature"] as? String)))
        XCTAssertTrue(try identity.publicKey.isValidSignature(.init(derRepresentation: signature), for: encoder.encode(canonical)))
        await session.stop()
    }

    func testAuthenticatedPresenceSessionRejectsWrongChallengeAndInvalidFrames() async throws {
        let identity = try DeviceIdentity.ephemeral()
        let client = PresenceClient(directory: DeviceDirectory(trust: .allowing(identity.id)))
        let badChallengeSocket = MemoryPresenceSocket(incoming: [try frame(["type": "challenge", "nonce": Data(repeating: 7, count: 31).base64EncodedString(), "expiresAt": 1])])
        let badChallenge = try AuthenticatedPresenceSession(identity: identity, origin: URL(string: "wss://rendezvous.example/v1/ws")!, socket: badChallengeSocket, client: client)
        await XCTAssertThrowsErrorAsync(try await badChallenge.connect()) { error in
            XCTAssertEqual(error as? AuthenticatedPresenceError, .invalidChallenge)
        }

        let invalidFrameSocket = MemoryPresenceSocket(incoming: [
            try frame(["type": "challenge", "nonce": Data(repeating: 7, count: 32).base64EncodedString(), "expiresAt": 1]),
            try frame(["type": "auth-ok", "deviceID": identity.id.rawValue.uuidString.lowercased()]),
            try frame(["type": "presence", "deviceID": identity.id.rawValue.uuidString.lowercased(), "availability": "lan"]),
        ])
        let invalidFrame = try AuthenticatedPresenceSession(identity: identity, origin: URL(string: "wss://rendezvous.example/v1/ws")!, socket: invalidFrameSocket, client: client)
        try await invalidFrame.connect()
        await XCTAssertThrowsErrorAsync(try await invalidFrame.run()) { error in
            XCTAssertEqual(error as? AuthenticatedPresenceError, .invalidFrame)
        }
        await invalidFrame.stop()
    }

    func testRendezvousSessionDeliversSignalWhilePresenceContinues() async throws {
        let identity = try DeviceIdentity.ephemeral()
        let peer = DeviceID(rawValue: UUID())
        let socket = MemoryPresenceSocket(incoming: [
            try frame(["type": "challenge", "nonce": Data(repeating: 8, count: 32).base64EncodedString(), "expiresAt": 1]),
            try frame(["type": "auth-ok", "deviceID": identity.id.rawValue.uuidString.lowercased()]),
            try frame(["type": "signal", "from": peer.rawValue.uuidString.lowercased(), "payload": Data("offer".utf8).base64EncodedString()]),
            try frame(["type": "presence", "deviceID": peer.rawValue.uuidString.lowercased(), "availability": "internet"]),
        ])
        let directory = DeviceDirectory(trust: .allowing(peer, identity.id))
        let session = try AuthenticatedPresenceSession(identity: identity, origin: URL(string: "wss://rendezvous.example/v1/ws")!, socket: socket, client: PresenceClient(directory: directory))
        let signals = await session.signalFrames()
        let presences = await session.presenceEvents()
        var signalIterator = signals.makeAsyncIterator()
        var presenceIterator = presences.makeAsyncIterator()

        try await session.connect()
        _ = try? await session.run()

        let signal = await signalIterator.next()
        let presence = await presenceIterator.next()
        XCTAssertEqual(signal, RendezvousSignalFrame(from: peer, payload: Data("offer".utf8)))
        XCTAssertEqual(presence, .availability(device: peer, isOnline: true))
        await session.stop()
    }

    func testRendezvousStreamsFinishOnTerminalReaderErrorAndStop() async throws {
        let identity = try DeviceIdentity.ephemeral()
        let peer = DeviceID(rawValue: UUID())
        let terminalSocket = MemoryPresenceSocket(incoming: [
            try frame(["type": "challenge", "nonce": Data(repeating: 9, count: 32).base64EncodedString(), "expiresAt": 1]),
            try frame(["type": "auth-ok", "deviceID": identity.id.rawValue.uuidString.lowercased()]),
        ])
        let terminal = try AuthenticatedPresenceSession(identity: identity, origin: URL(string: "wss://rendezvous.example/v1/ws")!, socket: terminalSocket, client: PresenceClient(directory: DeviceDirectory(trust: .allowing(peer))))
        let terminalStreams = (
            await terminal.presenceEvents(), await terminal.signalFrames(), await terminal.trustResults(),
            await terminal.protocolErrors(), await terminal.verifiedTrustRecords()
        )
        var presence = terminalStreams.0.makeAsyncIterator()
        var signals = terminalStreams.1.makeAsyncIterator()
        var results = terminalStreams.2.makeAsyncIterator()
        var errors = terminalStreams.3.makeAsyncIterator()
        var records = terminalStreams.4.makeAsyncIterator()
        try await terminal.connect()
        await XCTAssertThrowsErrorAsync(try await terminal.run()) { _ in }
        let completedPresence = await presence.next()
        let completedSignals = await signals.next()
        let completedResults = await results.next()
        let completedErrors = await errors.next()
        let completedRecords = await records.next()
        XCTAssertNil(completedPresence)
        XCTAssertNil(completedSignals)
        XCTAssertNil(completedResults)
        XCTAssertNil(completedErrors)
        XCTAssertNil(completedRecords)

        let stopped = try AuthenticatedPresenceSession(identity: identity, origin: URL(string: "wss://rendezvous.example/v1/ws")!, socket: MemoryPresenceSocket(incoming: []), client: PresenceClient(directory: DeviceDirectory(trust: .allowing(peer))))
        let stoppedStreams = (
            await stopped.presenceEvents(), await stopped.signalFrames(), await stopped.trustResults(),
            await stopped.protocolErrors(), await stopped.verifiedTrustRecords()
        )
        var stoppedPresence = stoppedStreams.0.makeAsyncIterator()
        var stoppedSignals = stoppedStreams.1.makeAsyncIterator()
        var stoppedResults = stoppedStreams.2.makeAsyncIterator()
        var stoppedErrors = stoppedStreams.3.makeAsyncIterator()
        var stoppedRecords = stoppedStreams.4.makeAsyncIterator()
        await stopped.stop()
        let stoppedPresenceValue = await stoppedPresence.next()
        let stoppedSignal = await stoppedSignals.next()
        let stoppedResult = await stoppedResults.next()
        let stoppedError = await stoppedErrors.next()
        let stoppedRecord = await stoppedRecords.next()
        XCTAssertNil(stoppedPresenceValue)
        XCTAssertNil(stoppedSignal)
        XCTAssertNil(stoppedResult)
        XCTAssertNil(stoppedError)
        XCTAssertNil(stoppedRecord)
    }

    func testPresenceHeartbeatRenewsOnlinePeers() async {
        let peer = DeviceID(rawValue: UUID())
        let clock = ManualDirectoryClock()
        let directory = DeviceDirectory(trust: .allowing(peer), now: { clock.now })
        let client = PresenceClient(directory: directory)
        await client.receiveAuthenticated(.availability(device: peer, isOnline: true))
        clock.advance(by: 46)
        await client.renewOnlinePresence()

        let snapshot = await directory.snapshot()
        XCTAssertEqual(snapshot.first?.availability, .internet)
    }

    func testPresenceDisconnectDrainsOnlinePeersBeforeReplacementSession() async {
        let peer = DeviceID(rawValue: UUID())
        let directory = DeviceDirectory(trust: .allowing(peer))
        let client = PresenceClient(directory: directory)

        await client.receiveAuthenticated(.availability(device: peer, isOnline: true))
        await client.disconnect()

        let snapshot = await directory.snapshot()
        XCTAssertTrue(snapshot.isEmpty)
    }

    func testDevicesStreamPublishesDeduplicatedSnapshots() async {
        let peer = DeviceID(rawValue: UUID())
        let directory = DeviceDirectory(trust: .allowing(peer))
        let stream = await directory.devices()
        var iterator = stream.makeAsyncIterator()

        let initial = await iterator.next()
        XCTAssertTrue(initial?.isEmpty == true)

        await directory.apply(.internet(peer, online: true))
        let internet = await iterator.next()
        await directory.apply(.lan(peer, host: "peer.local", port: 7443))
        let lan = await iterator.next()

        XCTAssertEqual(internet?.count, 1)
        XCTAssertEqual(internet?.first?.availability, .internet)
        XCTAssertEqual(lan?.count, 1)
        XCTAssertEqual(lan?.first?.availability, .lan)
    }

    func testRefreshPublishesExpiredPresenceToDevicesStream() async {
        let peer = DeviceID(rawValue: UUID())
        let clock = ManualDirectoryClock()
        let directory = DeviceDirectory(trust: .allowing(peer), now: { clock.now })
        let stream = await directory.devices()
        var iterator = stream.makeAsyncIterator()

        _ = await iterator.next()
        await directory.apply(.internet(peer, online: true))
        _ = await iterator.next()
        clock.advance(by: 46)
        await directory.refresh()

        let expired = await iterator.next()
        XCTAssertTrue(expired?.isEmpty == true)
    }

    func testSnapshotPurgePublishesExpiryToExistingSubscriber() async {
        let peer = DeviceID(rawValue: UUID())
        let clock = ManualDirectoryClock()
        let directory = DeviceDirectory(trust: .allowing(peer), now: { clock.now })
        let stream = await directory.devices()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        await directory.apply(.internet(peer, online: true))
        _ = await iterator.next()
        clock.advance(by: 46)

        let waitingForExpiry = Task { await iterator.next() }
        await Task.yield()
        _ = await directory.snapshot()
        let expired = await waitingForExpiry.value

        XCTAssertTrue(expired?.isEmpty == true)
    }

    func testRejectedEventStillPublishesAlreadyExpiredPresence() async {
        let peer = DeviceID(rawValue: UUID())
        let untrusted = DeviceID(rawValue: UUID())
        let clock = ManualDirectoryClock()
        let directory = DeviceDirectory(trust: .allowing(peer), now: { clock.now })
        let stream = await directory.devices()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        await directory.apply(.internet(peer, online: true))
        _ = await iterator.next()
        clock.advance(by: 46)

        let waitingForExpiry = Task { await iterator.next() }
        await Task.yield()
        await directory.apply(.internet(untrusted, online: true))
        let expired = await waitingForExpiry.value

        XCTAssertTrue(expired?.isEmpty == true)
    }

    func testBonjourBrowserPreservesEndpointRenewsAndIgnoresStaleCallbacksAfterStop() async throws {
        let peer = DeviceID(rawValue: UUID())
        let clock = ManualDirectoryClock()
        let directory = DeviceDirectory(trust: .allowing(peer), now: { clock.now })
        let browser = BonjourPeerBrowser(directory: directory, trust: .allowing(peer), renewalInterval: 0.1)
        let endpoint = NWEndpoint.service(name: "opaque", type: BonjourPeerBrowser.serviceType, domain: "local.", interface: nil)
        let record = BonjourPeerBrowser.txtRecord(for: peer)

        browser.start()
        browser.accept(endpoint: endpoint, txtRecord: record)
        try await Task.sleep(for: .milliseconds(30))
        let firstEndpoint = await directory.endpoint(for: peer)
        XCTAssertEqual(firstEndpoint, .bonjour(endpoint))
        clock.advance(by: 14)
        try await Task.sleep(for: .milliseconds(120))
        clock.advance(by: 2)
        let renewedSnapshot = await directory.snapshot()
        XCTAssertEqual(renewedSnapshot.first?.availability, .lan)

        await browser.stop()
        browser.accept(endpoint: endpoint, txtRecord: record, generation: 1)
        try await Task.sleep(for: .milliseconds(30))
        clock.advance(by: 16)
        let stoppedSnapshot = await directory.snapshot()
        XCTAssertTrue(stoppedSnapshot.isEmpty)

        browser.start()
        browser.accept(endpoint: endpoint, txtRecord: record)
        try await Task.sleep(for: .milliseconds(30))
        let restartedSnapshot = await directory.snapshot()
        XCTAssertEqual(restartedSnapshot.first?.availability, .lan)
        await browser.stop()
    }

    func testBonjourQueuedDirectoryApplyCannotRunAfterStop() async throws {
        let peer = DeviceID(rawValue: UUID())
        let directory = DeviceDirectory(trust: .allowing(peer))
        let gate = BonjourApplyGate()
        let browser = BonjourPeerBrowser(directory: directory, trust: .allowing(peer), renewalInterval: 5, beforeDirectoryApply: { await gate.block() })
        let endpoint = NWEndpoint.service(name: "opaque", type: BonjourPeerBrowser.serviceType, domain: "local.", interface: nil)

        browser.start()
        browser.accept(endpoint: endpoint, txtRecord: BonjourPeerBrowser.txtRecord(for: peer))
        await gate.waitUntilBlocked()
        await browser.stop()
        let stoppedSnapshot = await directory.snapshot()
        XCTAssertTrue(stoppedSnapshot.isEmpty)
        await gate.release()
        await Task.yield()

        let snapshot = await directory.snapshot()
        XCTAssertTrue(snapshot.isEmpty)
    }

    func testDirectoryEndSessionPurgesEarlierApplyAndRejectsLaterApply() async {
        let peer = DeviceID(rawValue: UUID())
        let directory = DeviceDirectory(trust: .allowing(peer))
        let endpoint = NWEndpoint.service(name: "opaque", type: BonjourPeerBrowser.serviceType, domain: "local.", interface: nil)
        let token = await directory.beginLANDiscoverySession()
        await directory.applyLAN(peer, endpoint: endpoint, token: token)
        let activeEndpoint = await directory.endpoint(for: peer)
        XCTAssertEqual(activeEndpoint, .bonjour(endpoint))
        await directory.endLANDiscoverySession(token)
        let endedSnapshot = await directory.snapshot()
        XCTAssertTrue(endedSnapshot.isEmpty)
        await directory.applyLAN(peer, endpoint: endpoint, token: token)
        let rejectedSnapshot = await directory.snapshot()
        XCTAssertTrue(rejectedSnapshot.isEmpty)
    }

    func testBonjourObserveTrustAndStopRemainQueueSafeUnderConcurrency() async throws {
        let owner = try DeviceIdentity.ephemeral()
        let repository = try TrustRepository(ownerIdentity: owner, trustStore: TrustStore(owner: owner.id), persistedGeneration: 0)
        let browser = BonjourPeerBrowser(directory: DeviceDirectory(trust: TrustStore(owner: owner.id)), trust: .allowing(owner.id))
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<40 {
                group.addTask { browser.observeTrust(repository) }
                group.addTask { await browser.stop() }
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(browser.state(), .stopped)
    }

    func testBonjourTXTRecordContainsOnlyHashedDeviceIDAndProtocolVersion() {
        let id = DeviceID(rawValue: UUID())

        let record = BonjourPeerBrowser.txtRecord(for: id)

        XCTAssertEqual(Set(record.keys), ["id", "version"])
        XCTAssertEqual(record["version"], "1")
        XCTAssertNotEqual(record["id"], id.rawValue.uuidString.lowercased())
    }

    func testTrustedHashLookupDoesNotAcceptUnknownBonjourPeers() {
        let trusted = DeviceID(rawValue: UUID())
        let untrusted = DeviceID(rawValue: UUID())
        let trust = DeviceTrust.allowing(trusted)

        XCTAssertEqual(
            trust.device(matchingBonjourHash: BonjourPeerBrowser.deviceIDHash(for: trusted)),
            trusted
        )
        XCTAssertNil(trust.device(matchingBonjourHash: BonjourPeerBrowser.deviceIDHash(for: untrusted)))
    }

    func testBonjourServiceAdvertisementUsesOnlyThePrivacyLimitedRecord() {
        let id = DeviceID(rawValue: UUID())

        let service = BonjourPeerBrowser.service(for: id)

        XCTAssertEqual(service.name, BonjourPeerBrowser.deviceIDHash(for: id))
        XCTAssertEqual(service.type, BonjourPeerBrowser.serviceType)
        XCTAssertEqual(service.txtRecordObject?.dictionary, BonjourPeerBrowser.txtRecord(for: id))
    }

    func testBonjourAdvertiserUsesThePrivacyLimitedService() throws {
        let id = DeviceID(rawValue: UUID())
        let advertiser = try BonjourPeerAdvertiser(device: id, port: 7443) { connection in
            connection.cancel()
        }

        XCTAssertEqual(advertiser.service.name, BonjourPeerBrowser.deviceIDHash(for: id))
        XCTAssertEqual(advertiser.service.txtRecordObject?.dictionary, BonjourPeerBrowser.txtRecord(for: id))
    }
}

private actor MemoryPresenceSocket: PresenceWebSocket {
    private var incoming: [Data]
    private var sent: [Data] = []

    init(incoming: [Data]) { self.incoming = incoming }
    func send(_ data: Data) async throws { sent.append(data) }
    func receive() async throws -> Data {
        guard !incoming.isEmpty else { throw AuthenticatedPresenceError.transport("no_frame") }
        return incoming.removeFirst()
    }
    func close() async {}
    func sentFrame() throws -> Data { try XCTUnwrap(sent.first) }
}

private actor BonjourApplyGate {
    private var blocked = false
    private var released = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func block() async {
        blocked = true
        let waiters = blockedWaiters
        blockedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilBlocked() async {
        guard !blocked else { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private func frame(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private struct WebSocketCanonical: Encodable {
    let deviceID: String
    let nonce: String
    let payload: String
    let publicKey: String
    let epochMilliseconds: Int64
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void
) async {
    do { _ = try await expression(); XCTFail("Expected error") }
    catch { handler(error) }
}

private final class ManualDirectoryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 0)

    var now: Date {
        lock.withLock { value }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock {
            value = value.addingTimeInterval(interval)
        }
    }
}
