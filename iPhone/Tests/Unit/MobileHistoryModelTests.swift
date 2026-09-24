import XCTest
import MacChannelCore
import DropMeshMobileRuntime
import UIKit
@testable import DropMeshTestHost

@MainActor
final class MobileHistoryModelTests: XCTestCase {
    func testSentSourceBookmarkResolvesAfterRelaunchAndCleansActionCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let state = root.appendingPathComponent("state", isDirectory: true)
        let actions = state.appendingPathComponent("actions", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original.txt")
        try Data("durable".utf8).write(to: source)
        let bookmark = try source.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let transfer = TransferID(rawValue: UUID())
        await MobileSentSourceStore(url: state.appendingPathComponent("refs.json"), actions: actions)
            .record([MobileSentHistorySource(name: source.lastPathComponent, bookmark: bookmark)], transfer: transfer)

        let reopened = MobileSentSourceStore(url: state.appendingPathComponent("refs.json"), actions: actions)
        let item = MobileHistoryFileID(rawValue: transfer.rawValue)
        let resolvedValue = await reopened.resolve(transfer: transfer, item: item)
        let resolved = try XCTUnwrap(resolvedValue)
        XCTAssertEqual(try Data(contentsOf: resolved), Data("durable".utf8))
        await reopened.release(resolved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: resolved.path))
        try FileManager.default.removeItem(at: source)
        let missing = await reopened.resolve(transfer: transfer, item: item)
        XCTAssertNil(missing)
    }
    func testBatchActionsResolveEachItemAgainAndRejectUnknownIDs() async {
        let session = InertMobileSession()
        let first = MobileHistoryFileID(rawValue: UUID())
        let second = MobileHistoryFileID(rawValue: UUID())
        var row = historyRow(named: "Batch", peer: session.peer.id)
        row.files = [
            MobileTransferHistoryFile(id: first, name: "a.txt", size: 1, isDirectory: false, isAvailable: true, availableURL: nil),
            MobileTransferHistoryFile(id: second, name: "b.txt", size: 1, isDirectory: false, isAvailable: true, availableURL: nil)
        ]
        row.isLegacy = false
        await session.setHistory([row])
        let url = URL(fileURLWithPath: "/fixture/a.txt")
        await session.setHistoryFileURLs([first: url])
        let model = MobileHistoryModel(session: session, canPreview: { _ in true })
        await model.refresh()
        await model.perform(.preview, for: row.id, itemID: first)
        XCTAssertEqual(model.presentation?.url, url)
        model.presentation = nil
        await session.setHistoryFileURLs([:])
        await model.perform(.preview, for: row.id, itemID: first)
        XCTAssertNil(model.presentation)
        XCTAssertEqual(model.actionMessage, .unavailable)
        await model.perform(.preview, for: row.id, itemID: MobileHistoryFileID(rawValue: UUID()))
        XCTAssertNil(model.presentation)
    }
    func testReadMarkersPersistOnlyViewedRecords() async {
        let session = InertMobileSession()
        let suite = "history-read-test-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = historyRow(named: "a", peer: session.peer.id)
        let second = historyRow(named: "b", peer: session.peer.id)
        await session.setHistory([first, second])
        let model = MobileHistoryModel(session: session, readDefaults: defaults)
        await model.refresh()
        XCTAssertEqual(model.unreadCount, 2)
        model.markRead(first)
        XCTAssertEqual(model.unreadCount, 1)
        let restored = MobileHistoryModel(session: session, readDefaults: defaults)
        await restored.refresh()
        XCTAssertFalse(restored.isUnread(first))
        XCTAssertTrue(restored.isUnread(second))
    }
    func testUnsupportedPerFilePreviewReleasesTemporaryAction() async {
        let (session, model, row, item, url) = await actionFixture(canPreview: false)
        await model.perform(.preview, for: row.id, itemID: item)
        let released = await session.releasedHistoryURLs
        XCTAssertEqual(released, [url])
        XCTAssertNil(model.presentation)
        XCTAssertEqual(model.actionMessage, .unsupported)
    }
    func testCloseDuringPerFileResolutionReleasesLateTemporaryAction() async {
        let (session, model, row, item, url) = await actionFixture(canPreview: true)
        let gate = HistoryReadGate()
        await session.setBeforeHistoryFile { await gate.waitOnce() }
        let action = Task { await model.perform(.preview, for: row.id, itemID: item) }
        await gate.waitUntilEntered()
        model.close()
        await gate.release()
        await action.value
        let released = await session.releasedHistoryURLs
        XCTAssertEqual(released, [url])
        XCTAssertNil(model.presentation)
    }
    func testDismissPerFilePresentationReleasesActionExactlyOnce() async {
        let (session, model, row, item, url) = await actionFixture(canPreview: true)
        await model.perform(.share, for: row.id, itemID: item)
        XCTAssertEqual(model.presentation?.url, url)
        model.dismissPresentation()
        model.dismissPresentation()
        let deadline = ContinuousClock.now + .seconds(2)
        while await session.releasedHistoryURLs.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
        let released = await session.releasedHistoryURLs
        XCTAssertEqual(released, [url])
    }
    private func actionFixture(canPreview: Bool) async -> (InertMobileSession, MobileHistoryModel, MobileHistoryEntry, MobileHistoryFileID, URL) {
        let session = InertMobileSession()
        let item = MobileHistoryFileID(rawValue: UUID())
        let url = URL(fileURLWithPath: "/fixture/action-copy.txt")
        var row = historyRow(named: "Source.txt", peer: session.peer.id)
        row.files = [MobileTransferHistoryFile(id: item, name: "Source.txt", size: 1,
            isDirectory: false, isAvailable: true, availableURL: nil)]
        await session.setHistory([row])
        await session.setHistoryFileURLs([item: url])
        let model = MobileHistoryModel(session: session, canPreview: { _ in canPreview })
        await model.refresh()
        return (session, model, row, item, url)
    }
    func testHistoryUsesSnapshotPeerNameAndUnknownFallback() async {
        let session = InertMobileSession()
        let unknown = DeviceID(rawValue: UUID())
        let model = MobileHistoryModel(session: session)
        var snapshot = await session.snapshot()
        snapshot.names = [session.peer.id: "Studio Mac", unknown: " \n "]

        model.update(snapshot)

        XCTAssertEqual(model.peerName(for: session.peer.id), "Studio Mac")
        XCTAssertEqual(model.peerName(for: unknown), String(localized: "history.peer.unknown"))
    }

    func testThumbnailResolvesFreshURLByTransferIDWithoutRetainingURL() async {
        let session = InertMobileSession()
        let id = TransferID(rawValue: UUID())
        let first = URL(fileURLWithPath: "/fixture/first.png")
        let second = URL(fileURLWithPath: "/fixture/second.png")
        await session.setReceivedURL(first)
        await session.setHistory([MobileHistoryEntry(id: id, peer: session.peer.id,
            displayName: "fixture.png", aggregateSize: 3, completedBytes: 3,
            updatedAt: Date(), route: .lan, phase: .completed,
            direction: .inbound, isAvailable: true)])
        let recorder = ThumbnailRecorder()
        let model = MobileHistoryModel(session: session, thumbnailLoader: { url in
            await recorder.record(url)
            return MobileHistoryThumbnail(image: UIImage())
        })
        await model.refresh()

        _ = await model.thumbnail(for: id)
        await session.setReceivedURL(second)
        _ = await model.thumbnail(for: id)

        let loadedURLs = await recorder.urls
        let resolvedIDs = await session.resolvedHistoryIDs
        XCTAssertEqual(loadedURLs, [first, second])
        XCTAssertEqual(resolvedIDs, [id, id])
    }

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
        let deadline = ContinuousClock.now + .seconds(3)
        while model.entries.map(\.id) != [row.id], ContinuousClock.now < deadline {
            await Task.yield()
        }
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

private actor ThumbnailRecorder {
    private(set) var urls: [URL] = []
    func record(_ url: URL) { urls.append(url) }
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
