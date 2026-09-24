import Foundation
import XCTest
@testable import MacChannelCore

final class PairingHostConfirmationTests: XCTestCase {
    func testSnapshotIsReadOnlyAndBindsEveryFieldBeforeExistingApprovalFlow() async throws {
        let fixture = try HostFixture()
        let joined = try await fixture.join.join(code: fixture.host.createCode())
        let value = await fixture.host.pendingHostConfirmation()
        let snapshot = try XCTUnwrap(value)
        XCTAssertEqual(snapshot.sessionID, joined.sessionID)
        XCTAssertEqual(snapshot.fingerprint, joined.fingerprint)
        let hostBefore = await fixture.hostStore.authenticationRecords()
        let joinBefore = await fixture.joinStore.authenticationRecords()
        XCTAssertTrue(hostBefore.isEmpty); XCTAssertTrue(joinBefore.isEmpty)
        let invalid = [
            PairingHostConfirmation(sessionID: PairingSessionID(), peer: snapshot.peer, fingerprint: snapshot.fingerprint, expiresAt: snapshot.expiresAt),
            PairingHostConfirmation(sessionID: snapshot.sessionID, peer: .init(id: DeviceID(rawValue: UUID()), displayName: "Foreign", availability: .offline), fingerprint: snapshot.fingerprint, expiresAt: snapshot.expiresAt),
            PairingHostConfirmation(sessionID: snapshot.sessionID, peer: snapshot.peer, fingerprint: "wrong", expiresAt: snapshot.expiresAt),
            PairingHostConfirmation(sessionID: snapshot.sessionID, peer: snapshot.peer, fingerprint: snapshot.fingerprint, expiresAt: snapshot.expiresAt.addingTimeInterval(1))
        ]
        for other in invalid {
            do { _ = try await fixture.host.approvePendingPairing(other); XCTFail("Foreign snapshot accepted") }
            catch PairingError.staleOperation { }
        }
        do { _ = try await fixture.join.approvePendingPairing(snapshot); XCTFail("Joiner approved as host") } catch { }
        let after = await fixture.hostStore.authenticationRecords()
        XCTAssertEqual(after, hostBefore)
        _ = try await fixture.host.approvePendingPairing(snapshot)
        _ = try await fixture.join.awaitHostApproval()
        let trusted = await fixture.joinStore.isTrusted(joined.peer.id)
        XCTAssertTrue(trusted)
        let records = await fixture.joinStore.authenticationRecords()
        XCTAssertEqual(records.count, 1)
        let confirmed = await fixture.host.currentState()
        try await fixture.host.cancelPendingPairing()
        let afterCancellation = await fixture.host.currentState()
        XCTAssertEqual(afterCancellation, confirmed, "Cancellation must preserve existing completed Mac semantics")
    }

    func testReplacedAndExpiredRequestsCannotBeApproved() async throws {
        let fixture = try HostFixture()
        _ = try await fixture.join.join(code: fixture.host.createCode())
        let pending = await fixture.host.pendingHostConfirmation()
        let snapshot = try XCTUnwrap(pending)
        _ = try await fixture.host.createCode()
        do { _ = try await fixture.host.approvePendingPairing(snapshot); XCTFail("Replaced request approved") } catch { }
        try await fixture.join.cancelPendingPairing()
        _ = try await fixture.join.join(code: fixture.host.createCode())
        let next = await fixture.host.pendingHostConfirmation()
        let expiring = try XCTUnwrap(next)
        fixture.clock.advance(301)
        let expired = await fixture.host.pendingHostConfirmation()
        XCTAssertNil(expired)
        do { _ = try await fixture.host.approvePendingPairing(expiring); XCTFail("Expired request approved") } catch { }
        let records = await fixture.hostStore.authenticationRecords()
        XCTAssertTrue(records.isEmpty)
    }

    func testCancellingUnjoinedHostRevokesCode() async throws {
        let fixture = try HostFixture()
        let code = try await fixture.host.createCode()
        try await fixture.host.cancelPendingPairing()
        do { _ = try await fixture.join.join(code: code); XCTFail("Dismissed code remains usable") } catch { }
        let state = await fixture.host.currentState()
        XCTAssertEqual(state, .idle)
    }
}

private struct HostFixture {
    let clock = HostClock()
    let hostStore: TrustRepository
    let joinStore: TrustRepository
    let host: PairingCoordinator
    let join: PairingCoordinator
    init() throws {
        let server = MemoryPairingServer(clock: clock)
        let h = try DeviceIdentity.ephemeral(), j = try DeviceIdentity.ephemeral()
        hostStore = try TrustRepository(ownerIdentity: h, trustStore: TrustStore(owner: h.id), persistedGeneration: 0)
        joinStore = try TrustRepository(ownerIdentity: j, trustStore: TrustStore(owner: j.id), persistedGeneration: 0)
        host = try PairingCoordinator(identity: h, trustRepository: hostStore,
            transport: MemoryPairingTransport(server: server, observedSource: "snapshot-host"), clock: clock)
        join = try PairingCoordinator(identity: j, trustRepository: joinStore,
            transport: MemoryPairingTransport(server: server, observedSource: "snapshot-join"), clock: clock)
    }
}

private final class HostClock: PairingClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}
