import Foundation
import XCTest
@testable import MacChannelCore
@testable import DropMeshMobileRuntime

final class MobileDualPlaneTests: XCTestCase {
    func testManualOverlapPrefersLegacyAndNeverFallsBackOnFailure() async throws {
        let f = try await PlaneFixture.make(manual: true)
        let legacy = PlaneConnector(fail: true), candidate = PlaneConnector()
        let connector = MobileDualPlaneConnector(repository: f.repository, authorization: f.owner,
            legacy: legacy, account: candidate)
        do { _ = try await connector.connect(to: f.peer.id); XCTFail("Expected legacy failure") } catch {}
        let legacyCalls = await legacy.calls, accountCalls = await candidate.calls
        XCTAssertEqual(legacyCalls, 1)
        XCTAssertEqual(accountCalls, 0)
    }

    func testAccountOnlyUsesCandidateAndStopClosesLateResult() async throws {
        let f = try await PlaneFixture.make(manual: false)
        let gate = PlaneGate()
        let legacy = PlaneConnector(), candidate = PlaneConnector(gate: gate)
        let connector = MobileDualPlaneConnector(repository: f.repository, authorization: f.owner,
            legacy: legacy, account: candidate)
        let task = Task { try await connector.connect(to: f.peer.id, transferID: TransferID(rawValue: UUID()), after: .lan) }
        try await gate.waitUntilEntered()
        await connector.closeAdmission()
        await gate.open()
        do { _ = try await task.value; XCTFail("Late graph result survived stop") } catch {}
        let legacyCalls = await legacy.calls, candidateCalls = await candidate.calls
        let closed = await candidate.channel.closed
        XCTAssertEqual(legacyCalls, 0)
        XCTAssertEqual(candidateCalls, 1)
        XCTAssertTrue(closed)
    }

    func testPlaneProjectionRequiresSelectedInternetSourceAndSharesOnlyLAN() async throws {
        let f = try await PlaneFixture.make(manual: true)
        let legacy = DeviceDirectory(trust: .allowing(f.peer.id))
        let account = DeviceDirectory(trust: .allowing(f.peer.id))
        let projection = MobileDualPlaneProjection(legacy: legacy, account: account,
            repository: f.repository, authorization: f.owner)
        await account.apply(.internet(f.peer.id, online: true))
        var devices = await projection.snapshot()
        XCTAssertTrue(devices.isEmpty, "Overlap cannot advertise candidate when outgoing selects legacy")
        await legacy.apply(.internet(f.peer.id, online: true))
        devices = await projection.snapshot()
        XCTAssertEqual(devices.map(\.id), [f.peer.id])
        await account.apply(.internet(f.peer.id, online: false))
        devices = await projection.snapshot()
        XCTAssertEqual(devices.map(\.id), [f.peer.id])
        _ = try await f.repository.revoke(f.peer.id)
        await account.apply(.internet(f.peer.id, online: true))
        await legacy.apply(.internet(f.peer.id, online: false))
        await legacy.apply(.lan(f.peer.id, host: "127.0.0.1", port: 1234))
        devices = await projection.snapshot()
        XCTAssertEqual(devices.first?.availability, .lan)
        await projection.stop()
    }

    func testCandidateICEFetchesFreshCredentialsPerAttemptAndKeepsDirectRelaySeparate() async throws {
        let fetcher = PlaneTURNFetcher()
        let ice = MobileAccountICEProvider(fetcher: fetcher)
        let lan = try await ice.configuration(for: .lan)
        XCTAssertTrue(lan.turnServers.isEmpty)
        let direct = try await ice.configuration(for: .directInternet)
        XCTAssertEqual(direct.stunURLs, ["stun:candidate.test:3478"])
        XCTAssertTrue(direct.turnServers.isEmpty)
        let relay = try await ice.configuration(for: .relay)
        XCTAssertEqual(relay.turnServers.count, 1)
        let calls = await fetcher.calls
        XCTAssertEqual(calls, 2, "No cached credentials may bypass a changed controller epoch")
    }
}

private struct PlaneFixture {
    let peer: DeviceIdentity
    let repository: TrustRepository
    let owner: PeerAuthorizationOwner
    static func make(manual: Bool) async throws -> Self {
        let local = try DeviceIdentity.ephemeral(), peer = try DeviceIdentity.ephemeral()
        let repository = try TrustRepository(ownerIdentity: local, trustStore: TrustStore(owner: local.id), persistedGeneration: 0)
        if manual { _ = try await repository.issueAuthorization(subject: peer.id,
            subjectPublicKey: peer.publicKey.rawRepresentation, timestamp: Date()) }
        let owner = PeerAuthorizationOwner.live(identity: local)
        // Isolate route-selection behavior from the separately tested account producer.
        try owner.replaceManual([peer.id: peer.publicKey.rawRepresentation])
        return Self(peer: peer, repository: repository, owner: owner)
    }
}

private actor PlaneGate {
    var entered = false
    var waiter: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { waiter = $0 } }
    func waitUntilEntered() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !entered {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            await Task.yield()
        }
    }
    func open() { waiter?.resume(); waiter = nil }
}
private actor PlaneConnector: RouteEscalatingPeerConnector {
    let fail: Bool
    let gate: PlaneGate?
    let channel = PlaneChannel()
    var calls = 0
    init(fail: Bool = false, gate: PlaneGate? = nil) { self.fail = fail; self.gate = gate }
    func connect(to device: DeviceID) async throws -> any SecureChannel {
        calls += 1
        if fail { throw ConnectionCoordinatorError.peerUnavailable }
        await gate?.wait()
        return channel
    }
    func connect(to device: DeviceID, transferID: TransferID) async throws -> any SecureChannel { try await connect(to: device) }
    func connect(to device: DeviceID, transferID: TransferID, after failedRoute: ConnectionRoute?) async throws -> any SecureChannel { try await connect(to: device) }
}
private actor PlaneChannel: SecureChannel {
    nonisolated let route: ConnectionRoute = .directInternet
    var closed = false
    func send(_ frame: Data) async throws {}
    nonisolated func frames() -> AsyncThrowingStream<Data, Error> { AsyncThrowingStream { $0.finish() } }
    func exportKey(label: String, context: Data, length: Int) async throws -> Data { Data(repeating: 1, count: length) }
    func close() { closed = true }
}
private actor PlaneTURNFetcher: RendezvousTURNCredentialFetching {
    var calls = 0
    func fetch() -> RendezvousTURNCredentials {
        calls += 1
        return RendezvousTURNCredentials(urls: ["stun:candidate.test:3478", "turn:candidate.test:3478"],
            username: "fixture", credential: "fixture", expiresAt: Date().addingTimeInterval(120))
    }
}
