import Foundation
import XCTest
@testable import MacChannelCore
@testable import DropMeshMobileRuntime

final class MobilePairingSessionTests: XCTestCase {
    private func sessions(observeHost: (PairingCoordinator) -> Void = { _ in }) throws -> (MobilePairingSession, MobilePairingSession, SaveProbe, SaveProbe) {
        let server = MemoryPairingServer()
        let hostIdentity = try DeviceIdentity.ephemeral()
        let joinIdentity = try DeviceIdentity.ephemeral()
        let hostRepository = try TrustRepository(ownerIdentity: hostIdentity, trustStore: TrustStore(owner: hostIdentity.id), persistedGeneration: 0)
        let joinRepository = try TrustRepository(ownerIdentity: joinIdentity, trustStore: TrustStore(owner: joinIdentity.id), persistedGeneration: 0)
        let host = try PairingCoordinator(identity: hostIdentity, displayName: "Mac", trustRepository: hostRepository,
            transport: MemoryPairingTransport(server: server, observedSource: "host"))
        let joiner = try PairingCoordinator(identity: joinIdentity, displayName: "iPhone", trustRepository: joinRepository,
            transport: MemoryPairingTransport(server: server, observedSource: "joiner"))
        let hostSave = SaveProbe()
        let joinSave = SaveProbe()
        observeHost(host)
        return (MobilePairingSession(coordinator: host, persistTrust: { try await hostSave.save() }),
                MobilePairingSession(coordinator: joiner, persistTrust: { try await joinSave.save() }), hostSave, joinSave)
    }

    func testBothSidesReportPairedOnlyAfterSaving() async throws {
        let (host, joiner, hostSave, joinSave) = try sessions()
        _ = try await joiner.join(code: host.createCode())
        let before = await host.currentState()
        guard case .active(.approvalRequested) = before else { return XCTFail("Must require approval") }
        let joining = Task { try await joiner.awaitApproval() }
        let joinedPeer = try await host.approve()
        let hostPeer = try await joining.value
        let hostState = await host.currentState()
        let joinState = await joiner.currentState()
        XCTAssertEqual(hostState, .paired(joinedPeer))
        XCTAssertEqual(joinState, .paired(hostPeer))
        let hostCalls = await hostSave.calls
        let joinCalls = await joinSave.calls
        XCTAssertEqual(hostCalls, 1)
        XCTAssertEqual(joinCalls, 1)
    }

    func testSaveFailureNeverReportsPairedAndCanRetry() async throws {
        let (host, joiner, hostSave, _) = try sessions()
        await hostSave.setFail(true)
        _ = try await joiner.join(code: host.createCode())
        let joining = Task { try await joiner.awaitApproval() }
        do { _ = try await host.approve(); XCTFail("Expected save error") }
        catch SaveProbe.Failure.disk { }
        _ = try await joining.value
        let failed = await host.currentState()
        guard case let .saveFailed(peer) = failed else { return XCTFail("Must expose storage failure") }
        await hostSave.setFail(false)
        let saved = try await host.retrySaving()
        XCTAssertEqual(saved, peer)
        let state = await host.currentState()
        XCTAssertEqual(state, .paired(peer))
    }

    func testRejectDoesNotPersistOrReportSuccess() async throws {
        let (host, joiner, hostSave, _) = try sessions()
        _ = try await joiner.join(code: host.createCode())
        try await host.reject()
        let state = await host.currentState()
        let calls = await hostSave.calls
        XCTAssertEqual(state, .active(.idle))
        XCTAssertEqual(calls, 0)
    }

    func testCancelPendingJoinDoesNotPersist() async throws {
        let (host, joiner, _, joinSave) = try sessions()
        _ = try await joiner.join(code: host.createCode())
        try await joiner.cancel()
        let state = await joiner.currentState()
        let calls = await joinSave.calls
        XCTAssertEqual(state, .active(.idle))
        XCTAssertEqual(calls, 0)
    }

    func testCancelAfterCompletionDoesNotLoseDurableSuccess() async throws {
        let (host, joiner, _, _) = try sessions()
        _ = try await joiner.join(code: host.createCode())
        let joining = Task { try await joiner.awaitApproval() }
        let peer = try await host.approve()
        _ = try await joining.value
        try await host.cancel()
        let state = await host.currentState()
        XCTAssertEqual(state, .paired(peer))
    }

    func testConfirmedCoreWithoutActiveSaveCanRecoverWithoutNewAuthorization() async throws {
        var rawHost: PairingCoordinator?
        let (host, joiner, _, _) = try sessions { rawHost = $0 }
        _ = try await joiner.join(code: host.createCode())
        let joining = Task { try await joiner.awaitApproval() }
        let peer = try await host.approve()
        _ = try await joining.value
        let recovered = MobilePairingSession(coordinator: try XCTUnwrap(rawHost), persistTrust: {})
        let pending = await recovered.currentState()
        XCTAssertEqual(pending, .saveFailed(peer))
        let saved = try await recovered.retrySaving()
        XCTAssertEqual(saved, peer)
    }
}

private actor SaveProbe {
    enum Failure: Error { case disk }
    var calls = 0
    private var failing = false
    func setFail(_ value: Bool) { failing = value }
    func save() throws {
        calls += 1
        if failing { throw Failure.disk }
    }
}
