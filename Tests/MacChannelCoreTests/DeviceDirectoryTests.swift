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

    func testRevokedPeersDisappearImmediately() async {
        let peer = DeviceID(rawValue: UUID())
        let directory = DeviceDirectory(trust: .allowing(peer))

        await directory.apply(.internet(peer, online: true))
        await directory.apply(.revoked(peer))

        let snapshot = await directory.snapshot()
        XCTAssertTrue(snapshot.isEmpty)
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

        await client.receive(.availability(device: peer, isOnline: true))
        let onlineSnapshot = await directory.snapshot()
        XCTAssertEqual(onlineSnapshot.first?.availability, .internet)
        await client.receive(.availability(device: peer, isOnline: false))

        let offlineSnapshot = await directory.snapshot()
        XCTAssertTrue(offlineSnapshot.isEmpty)
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
