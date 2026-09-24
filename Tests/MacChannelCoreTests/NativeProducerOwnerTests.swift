import Foundation
import XCTest
@testable import MacChannelCore

final class NativeProducerOwnerTests: XCTestCase {
    func testUnattachedInternalProducerCannotBypassOccupiedSlots() throws {
        let local = try DeviceIdentity.ephemeral()
        let owner = PeerAuthorizationOwner(local: local.id, now: Date.init, schedule: { _, _ in {} })
        let store = TrustStore(owner: local.id)
        let manual = try owner.attachManual(identity: local, store: store)
        XCTAssertThrowsError(try owner.replaceManual(store))
        let binding = try AccountSessionBinding(deviceID: local.id.rawValue, audience: "test", origin: URL(string: "https://example.com")!)
        let account = try owner.attachAccount(localPublicKey: local.publicKey.rawRepresentation, binding: binding)
        XCTAssertThrowsError(try owner.beginAccountSession(binding: binding, accountID: groupAccount,
            sessionID: UUID().uuidString.lowercased(), localPublicKey: local.publicKey.rawRepresentation,
            accessExpiresAt: Date().addingTimeInterval(100)))
        withExtendedLifetime((manual, account)) {}
    }

    func testLiveFactoryDeliversDeadlineWithoutConsumerPolling() async throws {
        let local = try DeviceIdentity.ephemeral(), peer = try DeviceIdentity.ephemeral()
        let owner = PeerAuthorizationOwner.live(identity: local)
        let binding = try AccountSessionBinding(deviceID: local.id.rawValue, audience: "test", origin: URL(string: "https://example.com")!)
        let epoch = try owner.beginAccountSession(binding: binding, accountID: groupAccount,
            sessionID: UUID().uuidString.lowercased(), localPublicKey: local.publicKey.rawRepresentation, accessExpiresAt: Date().addingTimeInterval(30))
        try owner.install(.init(epoch: epoch, binding: binding,
            snapshot: nativeProducerSnapshot(local, peer), freshUntil: Date().addingTimeInterval(0.1)))
        let invalidated = expectation(description: "real cancellable scheduler delivered expiry")
        let registration = try owner.claim(owner.acquire(for: peer.id)) { invalidated.fulfill() }
        await fulfillment(of: [invalidated], timeout: 3)
        XCTAssertThrowsError(try registration.requireCurrent())
    }

    func testOldAccountAttachmentReleaseCannotTouchNewSourceOrManual() throws {
        let local = try DeviceIdentity.ephemeral(), peer = try DeviceIdentity.ephemeral()
        let clock = PeerTestBox(NativeProducerFixture.start)
        let owner = PeerAuthorizationOwner(local: local.id, now: { clock.value }, schedule: { _, _ in {} })
        let binding = try AccountSessionBinding(deviceID: local.id.rawValue, audience: "test", origin: URL(string: "https://example.com")!)
        var store = TrustStore(owner: local.id)
        try store.authorize(SignedTrustRecord.authorizing(peer, signedBy: local, sequence: 1))
        let manual = try owner.attachManual(identity: local, store: store)
        let old = try owner.attachAccount(localPublicKey: local.publicKey.rawRepresentation, binding: binding)
        XCTAssertThrowsError(try owner.attachAccount(localPublicKey: local.publicKey.rawRepresentation, binding: binding))
        old.cancel()
        let replacement = try owner.attachAccount(localPublicKey: local.publicKey.rawRepresentation, binding: binding)
        old.cancel()
        XCTAssertThrowsError(try owner.beginAccountSession(binding: binding, accountID: groupAccount,
            sessionID: UUID().uuidString.lowercased(), localPublicKey: local.publicKey.rawRepresentation,
            accessExpiresAt: clock.value.addingTimeInterval(100), attachment: old))
        let epoch = try owner.beginAccountSession(binding: binding, accountID: groupAccount,
            sessionID: UUID().uuidString.lowercased(), localPublicKey: local.publicKey.rawRepresentation,
            accessExpiresAt: clock.value.addingTimeInterval(100), attachment: replacement)
        try owner.install(.init(epoch: epoch, binding: binding, snapshot: nativeProducerSnapshot(local, peer), freshUntil: clock.value.addingTimeInterval(20)))
        manual.cancel()
        old.cancel()
        XCTAssertNoThrow(try owner.acquire(for: peer.id))
        replacement.cancel()
        XCTAssertThrowsError(try owner.acquire(for: peer.id))
    }
}

private func nativeProducerSnapshot(_ local: DeviceIdentity, _ peer: DeviceIdentity) -> AccountGroupSnapshot {
    .init(accountID: groupAccount, groupID: groupID, generation: 1, sequence: 2, headHash: Data(repeating: 1, count: 32),
        members: [local, peer].map { .init(deviceID: $0.id.rawValue.uuidString.lowercased(), publicKey: $0.publicKey.rawRepresentation) })
}
