import XCTest
import MacChannelCore
import DropMeshMobileRuntime
@testable import DropMeshTestHost

@MainActor
final class MobileHistoryModelTests: XCTestCase {
    func testInboundCompletionRefreshesHistoryWhenTransfersAreUnchanged() async {
        let session = InertMobileSession()
        let model = MobileHistoryModel(session: session)
        let row = historyRow(named: "Received.txt", peer: session.peer.id)
        await session.setHistory([row])

        var snapshot = await session.snapshot()
        model.update(snapshot)
        snapshot.receivedCompletionIDs = [row.id]
        model.update(snapshot)
        await waitForHistoryReads(1, session: session)

        XCTAssertEqual(model.entries.map(\.id), [row.id])
        let reads = await session.historyReadCount
        XCTAssertEqual(reads, 1)
    }

    func testUnchangedInboundCompletionSignalDoesNotReloadHistory() async {
        let session = InertMobileSession()
        let model = MobileHistoryModel(session: session)
        var snapshot = await session.snapshot()
        snapshot.receivedCompletionIDs = [TransferID(rawValue: UUID())]

        model.update(snapshot)
        await waitForHistoryReads(1, session: session)
        model.update(snapshot)
        try? await Task.sleep(for: .milliseconds(100))

        let reads = await session.historyReadCount
        XCTAssertEqual(reads, 1)
    }

    func testRollingInboundCompletionIDsRefreshWithSameCount() async {
        let session = InertMobileSession()
        let model = MobileHistoryModel(session: session)
        var snapshot = await session.snapshot()
        snapshot.receivedCompletionIDs = (0..<200).map { _ in TransferID(rawValue: UUID()) }
        model.update(snapshot)
        await waitForHistoryReads(1, session: session)

        snapshot.receivedCompletionIDs.removeFirst()
        snapshot.receivedCompletionIDs.append(TransferID(rawValue: UUID()))
        model.update(snapshot)
        await waitForHistoryReads(2, session: session)

        let reads = await session.historyReadCount
        XCTAssertEqual(reads, 2)
    }

    func testOlderSnapshotCannotRevertSuccessfullySavedDiscoveryChoice() async {
        let session = InertMobileSession()
        let model = MobileSettingsModel(session: session)
        let beforeWrite = await session.snapshot()
        await model.setDiscovery(true)
        model.update(beforeWrite)
        XCTAssertTrue(model.discoveryEnabled)
    }
    func testDirectoryOffersFilesFallbackEvenWhenPreviewProviderClaimsSupport() async throws {
        let session = InertMobileSession()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let row = MobileHistoryEntry(id: TransferID(rawValue: UUID()), peer: session.peer.id,
            displayName: "Folder", aggregateSize: 3, completedBytes: 3,
            updatedAt: Date(), route: .lan, phase: .completed, direction: .inbound, isAvailable: true)
        await session.setHistory([row]); await session.setReceivedURL(root)
        let model = MobileHistoryModel(session: session, canPreview: { _ in true })
        await model.refresh()
        await model.perform(.preview, for: row.id)
        XCTAssertNil(model.presentation)
        XCTAssertEqual(model.actionMessage, .unsupported)
    }
    func testAppRetainsHistoryAndRefreshesForegroundAndCompletion() async {
        let session = InertMobileSession()
        let app = MobileAppModel(loadSession: { session })
        await app.bootstrap(initialPhase: .background)
        XCTAssertNotNil(app.history)
        XCTAssertNotNil(app.settings)
        let row = MobileHistoryEntry(id: TransferID(rawValue: UUID()), peer: session.peer.id,
            displayName: "New.txt", aggregateSize: 3, completedBytes: 3,
            updatedAt: Date(), route: .lan, phase: .completed, direction: .inbound, isAvailable: false)
        await session.setHistory([row])
        app.scenePhaseChanged(.active)
        await app.waitForLifecycle()
        XCTAssertEqual(app.history?.entries.map(\.id), [row.id])
        await session.setHistory([])
        await session.setTransfers([TransferSnapshot(id: row.id, peer: row.peer, phase: .completed,
            completedBytes: 3, totalBytes: 3, route: .lan)])
        await app.refreshDevices()
        let deadline = ContinuousClock.now + .seconds(3)
        while app.history?.entries.isEmpty == false, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(app.history?.entries.count, 0)
        await app.close()
    }
    func testLateRefreshCannotReplaceNewerHistory() async {
        let session = InertMobileSession()
        let gate = HistoryReadGate()
        await session.setBeforeHistory { await gate.waitOnce() }
        let model = MobileHistoryModel(session: session)
        let old = Task { await model.refresh() }
        await gate.waitUntilEntered()
        let row = MobileHistoryEntry(id: TransferID(rawValue: UUID()), peer: session.peer.id,
            displayName: "New.txt", aggregateSize: 3, completedBytes: 3,
            updatedAt: Date(), route: .lan, phase: .completed, direction: .inbound, isAvailable: false)
        await session.setHistory([row])
        await model.refresh()
        await gate.release()
        await old.value
        XCTAssertEqual(model.entries.map(\.id), [row.id])
    }

    func testSettingsSaveFailurePreservesChoiceAndCapabilityIsNotPermissionDenial() async {
        let session = InertMobileSession()
        let model = MobileSettingsModel(session: session)
        model.update(MobileAppSnapshot(localID: session.peer.id, localDiscoveryEnabled: true))
        XCTAssertTrue(model.discoveryEnabled)
        XCTAssertFalse(model.localNetworkAvailable)
        await session.setDiscoverySaveFailure(true)
        await model.setDiscovery(false)
        XCTAssertTrue(model.discoveryEnabled)
        XCTAssertTrue(model.saveFailed)
        await session.setDiscoverySaveFailure(false)
        await model.setDiscovery(false)
        XCTAssertFalse(model.discoveryEnabled)
        XCTAssertFalse(model.saveFailed)
    }
    func testDisappearedFileRemainsCompletedAndResolvesAgainAtEachTap() async {
        let session = InertMobileSession()
        let row = MobileHistoryEntry(id: TransferID(rawValue: UUID()), peer: session.peer.id,
            displayName: "Delivered.pdf", aggregateSize: 10, completedBytes: 10,
            updatedAt: Date(), route: .lan, phase: .completed, direction: .inbound, isAvailable: true)
        await session.setHistory([row])
        let model = MobileHistoryModel(session: session, canPreview: { _ in true })
        await model.refresh()
        await model.perform(.preview, for: row.id)
        XCTAssertNil(model.presentation)
        XCTAssertEqual(model.actionMessage, .unavailable)
        XCTAssertEqual(model.entries.first?.phase, .completed)
        XCTAssertEqual(model.entries.first?.isAvailable, false)
        let fresh = URL(fileURLWithPath: "/fixture/fresh.pdf")
        await session.setReceivedURL(fresh)
        await model.perform(.share, for: row.id)
        XCTAssertEqual(model.presentation?.url, fresh)
        let resolved = await session.resolvedHistoryIDs
        XCTAssertEqual(resolved, [row.id, row.id])
    }

    func testUnsupportedPreviewPreservesDeliveryAndDiagnosticIsIndependent() async {
        let session = InertMobileSession()
        let row = MobileHistoryEntry(id: TransferID(rawValue: UUID()), peer: session.peer.id,
            displayName: "Archive", aggregateSize: 10, completedBytes: 10,
            updatedAt: Date(), route: .lan, phase: .completed, direction: .inbound, isAvailable: true)
        await session.setHistory([row])
        await session.setReceivedURL(URL(fileURLWithPath: "/fixture/archive"))
        let model = MobileHistoryModel(session: session, canPreview: { _ in false })
        await model.refresh()
        XCTAssertFalse(model.availabilityWarning)
        await session.setHistoryDiagnostic(true)
        await model.perform(.preview, for: row.id)
        XCTAssertEqual(model.actionMessage, .unsupported)
        XCTAssertNil(model.presentation)
        XCTAssertTrue(model.availabilityWarning)
        XCTAssertEqual(model.entries.first?.phase, .completed)
    }

    func testPreferencePersistsPrivatelyAndVersionComesFromBundleValues() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("discovery.json")
        let store = MobileDiscoveryPreference(url: url)
        XCTAssertFalse(try store.load())
        try store.save(true)
        XCTAssertTrue(try MobileDiscoveryPreference(url: url).load())
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(MobileSettingsModel.versionDescription(info: ["CFBundleShortVersionString": "7.2", "CFBundleVersion": "19"]), "7.2 (19)")
    }

    private func historyRow(named name: String, peer: DeviceID) -> MobileHistoryEntry {
        MobileHistoryEntry(id: TransferID(rawValue: UUID()), peer: peer,
            displayName: name, aggregateSize: 3, completedBytes: 3,
            updatedAt: Date(), route: .lan, phase: .completed,
            direction: .inbound, isAvailable: true)
    }

    private func waitForHistoryReads(_ count: Int, session: InertMobileSession) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while await session.historyReadCount < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor HistoryReadGate {
    private var entered = false
    private var released = false
    func waitOnce() async {
        guard !entered else { return }
        entered = true
        let deadline = ContinuousClock.now + .seconds(5)
        while !released && ContinuousClock.now < deadline { await Task.yield() }
    }
    func waitUntilEntered() async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !entered && ContinuousClock.now < deadline { await Task.yield() }
    }
    func release() { released = true }
}
