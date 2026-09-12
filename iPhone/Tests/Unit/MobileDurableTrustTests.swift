import DropMeshMobileRuntime
import Foundation
@testable import MacChannelCore
import XCTest
@testable import DropMeshTestHost

@MainActor
final class MobileDurableTrustTests: XCTestCase {
    func testLegacyAuthenticatedBaselineIsVisibleAndConservativeDuringUnsavedMutation() async throws {
        let fixture = try await NativeTrustFixture()
        defer { fixture.remove() }
        try await fixture.pairAndSave()
        let saved = await fixture.local.persistedTrustState()
        let snapshot = try XCTUnwrap(saved?.snapshot)
        try JSONEncoder().encode(snapshot).write(to: fixture.local.layout.trustFile)
        let reloaded = try await MobileIdentityContext.load(layout: fixture.local.layout, secrets: fixture.secrets)
        let gate = MobileDurableTrust(repository: reloaded.repository,
            persistedState: { await reloaded.persistedTrustState() })
        let baseline = await gate.trustedIDs()
        XCTAssertTrue(baseline.contains(fixture.peer.id))
        let newcomer = try DeviceIdentity.ephemeral()
        _ = try await reloaded.repository.issueAuthorization(subject: newcomer.id,
            subjectPublicKey: newcomer.publicKey.rawRepresentation, timestamp: Date())
        let unsaved = await gate.trustedIDs()
        XCTAssertFalse(unsaved.contains(fixture.peer.id), "Legacy trust has no per-peer proof of unchanged membership")
        XCTAssertFalse(unsaved.contains(newcomer.id))
        try await reloaded.persistTrust()
        let refreshed = await gate.trustedIDs()
        XCTAssertTrue(refreshed.contains(fixture.peer.id))
        XCTAssertTrue(refreshed.contains(newcomer.id))
    }

    func testRealPairingPublicationStaysHiddenThroughHeldAndFailedSaveUntilRetry() async throws {
        let fixture = try await NativeTrustFixture()
        defer { fixture.remove() }
        let session = NativeTrustSession(context: fixture.local, peer: fixture.peer)
        let model = MobileAppModel(loadSession: { session })
        await model.bootstrap(initialPhase: .active)
        await model.waitForLifecycle()
        let gate = NativeSaveGate()
        fixture.secrets.failAnchor = true
        let (host, joiner) = try fixture.sessions(gate: gate)
        _ = try await joiner.join(code: host.createCode())
        let joining = Task { try await joiner.awaitApproval() }
        _ = try await host.approve()
        try await gate.entered()
        let published = await fixture.local.repository.isTrusted(fixture.peer.id)
        XCTAssertTrue(published, "Real bilateral commit has published before storage finishes")
        await model.refreshDevices()
        XCTAssertTrue(model.pairedDevices.isEmpty)
        XCTAssertFalse(model.isEligible(fixture.peer.id))
        await gate.release()
        do { _ = try await joining.value; XCTFail("Expected anchored persistence failure") }
        catch NativeTrustSecrets.Failure.anchor { }
        await model.refreshDevices()
        XCTAssertTrue(model.pairedDevices.isEmpty)
        XCTAssertFalse(model.isEligible(fixture.peer.id))
        fixture.secrets.failAnchor = false
        _ = try await joiner.retrySaving()
        await model.refreshDevices()
        XCTAssertEqual(model.pairedDevices.map(\.id), [fixture.peer.id])
        XCTAssertTrue(model.isEligible(fixture.peer.id))
        await model.close()
    }

    func testRevokedThenRepairedIDCannotReuseOldReceiptEvenWhenUpdateWasMissed() async throws {
        let fixture = try await NativeTrustFixture()
        defer { fixture.remove() }
        try await fixture.pairAndSave()
        let previous = await fixture.local.persistedTrustState()
        let session = NativeTrustSession(context: fixture.local, peer: fixture.peer)
        let model = MobileAppModel(loadSession: { session })
        await model.bootstrap(initialPhase: .active)
        await model.waitForLifecycle()
        XCTAssertTrue(model.isEligible(fixture.peer.id))
        fixture.secrets.failAnchor = true
        model.removeDevice(fixture.peer.id)
        XCTAssertFalse(model.isEligible(fixture.peer.id))
        await model.waitForRemoval()
        XCTAssertEqual(model.removalState, .saveFailed)
        let currentGate = MobileDurableTrust(repository: fixture.local.repository,
            persistedState: { await fixture.local.persistedTrustState() })
        let revoked = await currentGate.trustedIDs()
        XCTAssertFalse(revoked.contains(fixture.peer.id))
        fixture.secrets.failAnchor = false
        model.retryRemovalSave()
        await model.waitForRemoval()
        let gate = NativeSaveGate()
        let (host, joiner) = try fixture.sessions(gate: gate)
        _ = try await joiner.join(code: host.createCode())
        let joining = Task { try await joiner.awaitApproval() }
        _ = try await host.approve()
        try await gate.entered()
        let staleGate = MobileDurableTrust(repository: fixture.local.repository, persistedState: { previous })
        let staleIDs = await staleGate.trustedIDs()
        XCTAssertFalse(staleIDs.contains(fixture.peer.id), "A delayed older receipt cannot admit the new membership")
        await model.refreshDevices()
        XCTAssertTrue(model.pairedDevices.isEmpty)
        await gate.release()
        _ = try await joining.value
        await model.refreshDevices()
        XCTAssertEqual(model.pairedDevices.map(\.id), [fixture.peer.id])
        XCTAssertTrue(model.isEligible(fixture.peer.id))
        await model.close()
    }

    func testUnrelatedUnsavedMutationDoesNotPromoteNewIDOrHideDurablePeer() async throws {
        let fixture = try await NativeTrustFixture()
        defer { fixture.remove() }
        try await fixture.pairAndSave()
        let peer = try DeviceIdentity.ephemeral()
        _ = try await fixture.local.repository.issueAuthorization(subject: peer.id,
            subjectPublicKey: peer.publicKey.rawRepresentation, timestamp: Date())
        let gate = MobileDurableTrust(repository: fixture.local.repository,
            persistedState: { await fixture.local.persistedTrustState() })
        let ids = await gate.trustedIDs()
        XCTAssertTrue(ids.contains(fixture.peer.id))
        XCTAssertFalse(ids.contains(peer.id))
    }
}

private struct NativeTrustFixture: Sendable {
    let root: URL
    let local: MobileIdentityContext<NativeTrustSecrets>
    let host: MobileIdentityContext<NativeTrustSecrets>
    let secrets: NativeTrustSecrets
    let peer: DeviceSummary
    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        secrets = NativeTrustSecrets()
        local = try await MobileIdentityContext.load(layout: MobileStorageLayout(
            applicationSupport: root.appendingPathComponent("local-support"),
            documents: root.appendingPathComponent("local-documents")), secrets: secrets)
        host = try await MobileIdentityContext.load(layout: MobileStorageLayout(
            applicationSupport: root.appendingPathComponent("host-support"),
            documents: root.appendingPathComponent("host-documents")), secrets: NativeTrustSecrets())
        peer = DeviceSummary(id: host.identity.id, displayName: "Fixture Mac", availability: .internet)
    }
    func sessions(gate: NativeSaveGate? = nil) throws -> (MobilePairingSession, MobilePairingSession) {
        let server = MemoryPairingServer()
        let hostSession = try host.makePairingSession(displayName: "Fixture Mac",
            transport: MemoryPairingTransport(server: server, observedSource: "host"))
        let coordinator = try local.makePairingCoordinator(displayName: "Fixture iPhone",
            transport: MemoryPairingTransport(server: server, observedSource: "phone"))
        let local = local
        return (hostSession, MobilePairingSession(coordinator: coordinator, persistTrust: {
            try await gate?.wait()
            try await local.persistTrust()
        }))
    }
    func pairAndSave() async throws {
        let (host, joiner) = try sessions()
        _ = try await joiner.join(code: host.createCode())
        let joining = Task { try await joiner.awaitApproval() }
        _ = try await host.approve()
        _ = try await joining.value
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private actor NativeTrustSession: MobileAppSession {
    let context: MobileIdentityContext<NativeTrustSecrets>
    let peer: DeviceSummary
    let trust: MobileDurableTrust
    init(context: MobileIdentityContext<NativeTrustSecrets>, peer: DeviceSummary) {
        self.context = context; self.peer = peer
        trust = MobileDurableTrust(repository: context.repository,
            persistedState: { await context.persistedTrustState() })
    }
    func snapshot() async -> MobileAppSnapshot {
        MobileAppSnapshot(state: .online, localID: context.identity.id,
            trustedIDs: await trust.trustedIDs(), reachable: [peer])
    }
    func observe(_ changed: @escaping @Sendable () async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in await self.context.repository.updates() {
                    if Task.isCancelled { break }
                    await changed()
                }
            }
            group.addTask {
                for await _ in await self.context.persistedTrustUpdates() {
                    if Task.isCancelled { break }
                    await changed()
                }
            }
            await group.waitForAll()
        }
    }
    func startForeground() {}
    func stopForeground() {}
    func refreshTrust() {}
    func retryConnection() {}
    func makePairingAttempt() throws -> any PairingAttempt { throw CancellationError() }
    func rememberConfirmedPeer(_ peer: DeviceSummary) {}
    func revoke(_ id: DeviceID) async throws { try await context.repository.revoke(id) }
    func persistTrust() async throws { try await context.persistTrust() }
}

private actor NativeSaveGate {
    private var waiting = false
    private var released = false
    func wait() async throws {
        waiting = true
        let deadline = ContinuousClock.now + .seconds(3)
        while !released && ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
        }
        guard released else { throw CancellationError() }
    }
    func entered() async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !waiting && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard waiting else { throw CancellationError() }
    }
    func release() { released = true }
}

private final class NativeTrustSecrets: SecretStore, @unchecked Sendable {
    enum Failure: Error { case anchor }
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var failing = false
    var failAnchor: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }
    func data(for account: String, policy: KeychainPolicy) throws -> Data? {
        lock.withLock { values[policy.service + ":" + account] }
    }
    func store(_ data: Data, for account: String, policy: KeychainPolicy) throws {
        try lock.withLock {
            if account == "trust-snapshot-generation", failing { throw Failure.anchor }
            values[policy.service + ":" + account] = data
        }
    }
}
