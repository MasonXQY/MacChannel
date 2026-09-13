import Foundation
import MacChannelCore
import DropMeshMobileRuntime
import XCTest
@testable import DropMeshTestHost

@MainActor
final class MobileSendModelTests: XCTestCase {
    func testFilesResultReachesModelWithoutPresentationObservation() async throws {
        let fixture = try SendFixture(); defer { fixture.remove() }
        let model = MobileSendModel(session: InertMobileSession(), service: fixture.service())
        model.setForeground(true); model.openFiles(); await model.waitForWork()
        let picker = try XCTUnwrap(model.filesPicker)
        picker.documentPicker(picker.controller, didPickDocumentsAt: [fixture.source])
        await picker.waitForImport(); await model.waitForWork()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.files.count, 1)
        XCTAssertNil(model.presentation)
        await model.cancelAndWait()
    }

    func testFilesSelectionAfterPresentationDisappearsIsNotCancellation() async throws {
        let fixture = try SendFixture(); defer { fixture.remove() }
        let model = MobileSendModel(session: InertMobileSession(), service: fixture.service())
        model.setForeground(true); model.openFiles(); await model.waitForWork()
        let picker = try XCTUnwrap(model.filesPicker)
        let id = try XCTUnwrap(model.presentation?.id)
        model.presentationDismissed(id)
        picker.documentPicker(picker.controller, didPickDocumentsAt: [fixture.source])
        await picker.waitForImport(); await model.waitForWork()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.files.count, 1)
        if let file = model.files.first {
            XCTAssertEqual(try Data(contentsOf: file.url), try Data(contentsOf: fixture.source))
        }
        await model.cancelAndWait()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path), [])
    }

    func testFilesDelegateCancellationReachesModelWithoutPresentationObservation() async throws {
        let fixture = try SendFixture(); defer { fixture.remove() }
        let model = MobileSendModel(session: InertMobileSession(), service: fixture.service())
        model.setForeground(true); model.openFiles(); await model.waitForWork()
        let picker = try XCTUnwrap(model.filesPicker)
        picker.documentPickerWasCancelled(picker.controller)
        try await picker.cancelAndWait()
        await model.waitForWork()
        XCTAssertNotEqual(model.phase, .selecting)
        await model.cancelAndWait()
        XCTAssertNil(model.filesPicker)
    }

    func testFullByteTransferIsConfirmingNotCompleted() {
        func snapshot(_ phase: TransferPhase, _ completed: Int64, _ total: Int64) -> TransferSnapshot {
            TransferSnapshot(id: TransferID(rawValue: UUID()), peer: DeviceID(rawValue: UUID()),
                phase: phase, completedBytes: completed, totalBytes: total, route: .lan)
        }
        XCTAssertEqual(MobileTransferStatus.key(for: snapshot(.transferring, 10, 10)), "transfer.phase.confirming")
        XCTAssertEqual(MobileTransferStatus.key(for: snapshot(.transferring, 11, 10)), "transfer.phase.confirming")
        XCTAssertEqual(MobileTransferStatus.key(for: snapshot(.transferring, 9, 10)), "transfer.phase.transferring")
        XCTAssertEqual(MobileTransferStatus.key(for: snapshot(.transferring, 0, 0)), "transfer.phase.transferring")
        for phase in [TransferPhase.preparing, .connecting, .paused, .verifying, .cancelling, .completed, .failed, .cancelled] {
            XCTAssertEqual(MobileTransferStatus.key(for: snapshot(phase, 10, 10)), "transfer.phase." + phase.rawValue)
        }
    }

    func testConfirmationLabelHasBothLocalizations() throws {
        let bundle = Bundle(for: MobileFilesPicker.self)
        for (language, expected) in [("en", "Confirming completion…"), ("zh-Hans", "正在确认完成…")] {
            let path = try XCTUnwrap(bundle.path(forResource: language, ofType: "lproj"))
            let localized = try XCTUnwrap(Bundle(path: path))
            XCTAssertEqual(localized.localizedString(forKey: "transfer.phase.confirming", value: nil, table: nil), expected)
        }
    }

    func testLateAndRestoredFailuresOfferExplicitOriginalReselectionWithoutSending() async throws {
        for restored in [false, true] {
            let fixture = try SendFixture(); defer { fixture.remove() }
            let session = InertMobileSession()
            let model = MobileSendModel(session: session, service: fixture.service())
            model.setForeground(true)
            let id = TransferID(rawValue: UUID())
            if !restored {
                await session.setTransfers([TransferSnapshot(id: id, peer: session.peer.id,
                    phase: .transferring, completedBytes: 1, totalBytes: 3, route: .lan)])
                model.update(await session.snapshot())
            }
            await session.setTransfers([TransferSnapshot(id: id, peer: session.peer.id,
                phase: .failed, completedBytes: 1, totalBytes: 3, route: .lan)])
            model.update(await session.snapshot())
            model.reselectOriginals(for: id, kind: .photos)
            XCTAssertEqual(model.presentation?.kind, .photos)
            XCTAssertEqual(model.transfers.first?.phase, .failed)
            XCTAssertNil(model.selectedRecipient)
            let sends = await session.sendCount
            XCTAssertEqual(sends, 0)
            await model.cancelAndWait()
        }
    }

    func testFilesSelectionDismissalKeepsEveryOwnedCopyUntilExplicitAbandonment() async throws {
        let fixture = try SendFixture()
        defer { fixture.remove() }
        let model = MobileSendModel(session: InertMobileSession(), service: fixture.service())
        model.setForeground(true); model.openFiles(); await model.waitForWork()
        let picker = try XCTUnwrap(model.filesPicker)
        let id = try XCTUnwrap(model.presentation?.id)
        picker.documentPicker(picker.controller, didPickDocumentsAt: [fixture.source, fixture.source])
        model.presentationDismissed(id)
        await model.waitForWork()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.files.count, 2)
        XCTAssertTrue(model.files.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
        await model.cancelAndWait()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path), [])
    }

    func testFreshRuntimeSnapshotCannotClearPendingLocalRevocation() async throws {
        let fixture = try SendFixture()
        defer { fixture.remove() }
        let service = fixture.service()
        let session = InertMobileSession()
        await session.setPresence(.online, peers: [session.peer])
        let model = MobileSendModel(session: session, service: service)
        model.setForeground(true)
        model.revokeLocally(session.peer.id)
        model.update(await session.snapshot())
        model.openPhotos()
        let id = try XCTUnwrap(model.presentation?.id)
        model.selectPhoto(generation: id) { try await service.importFiles([fixture.source], in: $0)[0] }
        model.commitPhotos(id); await model.waitForWork()
        model.selectRecipient(session.peer.id); model.send(); await model.waitForWork()
        let count = await session.sendCount
        XCTAssertEqual(count, 0)
        XCTAssertEqual(model.failureKey, "send.error.recipient")
    }

    func testOfflineRecipientAtSendTimeCannotCreateTransfer() async throws {
        let fixture = try SendFixture()
        defer { fixture.remove() }
        let service = fixture.service()
        let session = InertMobileSession()
        await session.setPresence(.online, peers: [])
        let model = MobileSendModel(session: session, service: service)
        model.setForeground(true); model.openPhotos()
        let id = try XCTUnwrap(model.presentation?.id)
        model.selectPhoto(generation: id) { try await service.importFiles([fixture.source], in: $0)[0] }
        model.commitPhotos(id); await model.waitForWork()
        model.selectRecipient(session.peer.id); model.send(); await model.waitForWork()
        XCTAssertEqual(model.failureKey, "send.error.recipient")
        let count = await session.sendCount
        XCTAssertEqual(count, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path), [])
    }

    func testDurablyRepairedRecipientIsNotPermanentlyBlockedByLocalRemoval() async throws {
        let fixture = try SendFixture()
        defer { fixture.remove() }
        let session = InertMobileSession()
        let service = fixture.service()
        let model = MobileSendModel(session: session, service: service)
        model.setForeground(true)
        model.revokeLocally(session.peer.id)
        await session.setTrustedIDs([])
        model.update(await session.snapshot(), blockedIDs: [])
        await session.setTrustedIDs([session.peer.id])
        await session.setPresence(.online, peers: [session.peer])
        model.update(await session.snapshot())
        model.openPhotos()
        let id = try XCTUnwrap(model.presentation?.id)
        model.selectPhoto(generation: id) { try await service.importFiles([fixture.source], in: $0)[0] }
        model.commitPhotos(id); await model.waitForWork()
        model.selectRecipient(session.peer.id); model.send(); await model.waitForWork()
        XCTAssertNil(model.failureKey)
        let count = await session.sendCount
        XCTAssertEqual(count, 1)
    }

    func testNetworkStopStartsWhileCommittedProviderIsStillDraining() async throws {
        let session = InertMobileSession()
        let app = MobileAppModel(loadSession: { session })
        await app.bootstrap(initialPhase: .active); await app.waitForLifecycle()
        let model = try XCTUnwrap(app.send)
        let gate = SendGate()
        model.openPhotos()
        let id = try XCTUnwrap(model.presentation?.id)
        model.selectPhoto(generation: id) { _ in await gate.wait(); throw MobileImportError.cancelled }
        model.commitPhotos(id)
        await gate.waitUntilEntered()
        app.scenePhaseChanged(.background)
        let deadline = ContinuousClock.now + .seconds(1)
        while await session.stopCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let stops = await session.stopCount
        XCTAssertGreaterThan(stops, 0)
        XCTAssertEqual(model.phase, .cleaning)
        await gate.release()
        await app.waitForLifecycle()
        await app.close()
    }

    func testFilesAcquisitionCancelledBeforeOwnerReturnDoesNotLeakAdmission() async throws {
        let service = MobileImportService(makeStager: { throw MobileImportError.storage })
        let model = MobileSendModel(session: InertMobileSession(), service: service)
        model.setForeground(true); model.openFiles(); model.requestCancellation()
        await model.cancelAndWait()
        XCTAssertNil(model.filesPicker)
        let next = try await service.begin()
        try await service.discard(next)
    }

    func testAppRetainsSendOwnerAndBackgroundStartsNetworkStop() async throws {
        let session = InertMobileSession()
        let app = MobileAppModel(loadSession: { session })
        await app.bootstrap(initialPhase: .active)
        await app.waitForLifecycle()
        let sender = try XCTUnwrap(app.send)
        sender.openPhotos()
        app.scenePhaseChanged(.background)
        XCTAssertNil(sender.presentation)
        await app.waitForLifecycle()
        XCTAssertTrue(app.send === sender)
        let stops = await session.stopCount
        XCTAssertGreaterThan(stops, 0)
        await app.close()
    }

    func testFilesCancellationReachesCopyBeforeWaitingForImport() async throws {
        let fixture = try SendFixture()
        defer { fixture.remove() }
        let gate = SendGate()
        let stager = SendHeldStager(base: MobileSystemImportStager(directory: fixture.staging), gate: gate)
        let service = MobileImportService(makeStager: { stager })
        let model = MobileSendModel(session: InertMobileSession(), service: service)
        model.setForeground(true); model.openFiles()
        await model.waitForWork()
        let picker = try XCTUnwrap(model.filesPicker)
        let token = try XCTUnwrap(model.presentation?.id)
        picker.documentPicker(picker.controller, didPickDocumentsAt: [fixture.source])
        model.filesChanged(token)
        await gate.waitUntilEntered()
        model.requestCancellation()
        let deadline = ContinuousClock.now + .seconds(1)
        while !(await gate.wasCancelled), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let cancelled = await gate.wasCancelled
        XCTAssertTrue(cancelled, "Cancellation must reach the copy before the owner joins it")
        await gate.release()
        await model.cancelAndWait()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path), [])
    }

    func testCancelBeforePhotoAdmissionRecordsLateUUIDAndNeverLoads() async throws {
        let service = MobileImportService(makeStager: { throw MobileImportError.storage })
        let model = MobileSendModel(session: InertMobileSession(), service: service)
        model.setForeground(true); model.openPhotos()
        let token = try XCTUnwrap(model.presentation?.id)
        model.selectPhoto(generation: token) { _ in
            XCTFail("Cancelled commitment must not start provider")
            throw MobileImportError.unsupported
        }
        model.commitPhotos(token)
        model.setForeground(false)
        await model.cancelAndWait()
        let next = try await service.begin()
        try await service.discard(next)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.failureKey, "send.error.foreground")
    }

    func testCleanupFailureIsRetryableAndDoesNotRelabelCompletedTransfer() async throws {
        let fixture = try SendFixture()
        defer { fixture.remove() }
        let stager = SendRetryStager(base: MobileSystemImportStager(directory: fixture.staging))
        let service = MobileImportService(makeStager: { stager })
        let session = InertMobileSession()
        await session.setPresence(.online, peers: [session.peer])
        let model = MobileSendModel(session: session, service: service)
        model.setForeground(true); model.openPhotos()
        let token = try XCTUnwrap(model.presentation?.id)
        model.selectPhoto(generation: token) { try await service.importFiles([fixture.source], in: $0)[0] }
        model.commitPhotos(token); await model.waitForWork()
        model.selectRecipient(session.peer.id); model.send(); await model.waitForWork()
        XCTAssertEqual(model.phase, .cleanupFailed)
        XCTAssertEqual(model.transfers.first?.phase, .completed)
        XCTAssertNil(model.failureKey)
        model.openPhotos(); XCTAssertNil(model.presentation)
        model.retryCleanup(); await model.cancelAndWait()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.transfers.first?.phase, .completed)
    }

    func testRequestedTransferCancellationDoesNotInventTerminalSnapshot() async throws {
        let session = InertMobileSession()
        let id = TransferID(rawValue: UUID())
        await session.setTransfers([TransferSnapshot(id: id, peer: session.peer.id, phase: .transferring,
            completedBytes: 3, totalBytes: 10, route: .lan)])
        await session.setCancelResult(.requested)
        let model = MobileSendModel(session: session)
        model.update(await session.snapshot())
        model.cancelTransfer(id)
        await model.waitForActions()
        XCTAssertEqual(model.transfers.first?.phase, .transferring)
        XCTAssertEqual(model.cancellationResults[id], .requested)
    }

    func testCommittedPhotoDismissalKeepsImportAndCleanupWaitsForSendReturn() async throws {
        let fixture = try SendFixture()
        defer { fixture.remove() }
        let session = InertMobileSession()
        await session.setPresence(.online, peers: [session.peer])
        let gate = SendGate()
        await session.setBeforeSend { await gate.wait() }
        let service = fixture.service()
        let model = MobileSendModel(session: session, service: service)
        model.setForeground(true)
        model.openPhotos()
        let id = try XCTUnwrap(model.presentation?.id)
        model.selectPhoto(generation: id) { attempt in
            try await service.importFiles([fixture.source], in: attempt)[0]
        }
        model.commitPhotos(id)
        model.commitPhotos(id)
        model.presentationDismissed(id)
        await model.waitForWork()
        XCTAssertEqual(model.phase, .ready)
        let copy = try XCTUnwrap(model.files.first?.url)
        model.selectRecipient(session.peer.id)
        model.send()
        model.send()
        await gate.waitUntilEntered()
        model.setForeground(false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        await gate.release()
        await model.cancelAndWait()
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        let count = await session.sendCount
        XCTAssertEqual(count, 1)
        let next = try await service.begin()
        try await service.discard(next)
    }

    func testRevokedRecipientAtSendTimeCreatesNoTransferAndReleasesCopy() async throws {
        let fixture = try SendFixture()
        defer { fixture.remove() }
        let session = InertMobileSession()
        await session.setPresence(.online, peers: [session.peer])
        let service = fixture.service()
        let model = MobileSendModel(session: session, service: service)
        model.setForeground(true)
        model.openPhotos()
        let id = try XCTUnwrap(model.presentation?.id)
        model.selectPhoto(generation: id) { attempt in
            try await service.importFiles([fixture.source], in: attempt)[0]
        }
        model.commitPhotos(id)
        await model.waitForWork()
        model.selectRecipient(session.peer.id)
        await session.setTrustedIDs([])
        model.send()
        await model.waitForWork()
        XCTAssertEqual(model.failureKey, "send.error.recipient")
        let count = await session.sendCount
        XCTAssertEqual(count, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path), [])
    }

    func testPhotoBrowsingReservesOnlyLocalActionAndRejectsLateDismissal() async throws {
        let session = InertMobileSession()
        let service = MobileImportService(makeStager: { throw MobileImportError.storage })
        let model = MobileSendModel(session: session, service: service)
        model.setForeground(true)
        model.openPhotos()
        let first = try XCTUnwrap(model.presentation?.id)
        model.openPhotos()
        XCTAssertEqual(model.presentation?.id, first)
        let admission = try await service.begin()
        try await service.discard(admission)
        model.presentationDismissed(first)
        await model.cancelAndWait()
        model.openPhotos()
        let second = try XCTUnwrap(model.presentation?.id)
        XCTAssertNotEqual(first, second)
        model.presentationDismissed(first)
        XCTAssertEqual(model.presentation?.id, second)
        await model.cancelAndWait()
    }

    func testBackgroundSynchronouslyClosesBrowsingAndBlocksNewSelection() async throws {
        let model = MobileSendModel(session: InertMobileSession())
        model.setForeground(true)
        model.openPhotos()
        XCTAssertNotNil(model.presentation)
        model.setForeground(false)
        XCTAssertNil(model.presentation)
        model.openPhotos()
        XCTAssertNil(model.presentation)
        await model.cancelAndWait()
    }
}

private struct SendFixture: Sendable {
    let root: URL
    let staging: URL
    let source: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        staging = root.appendingPathComponent("staging")
        source = root.appendingPathComponent("small-video.mov")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("owned bytes".utf8).write(to: source)
    }
    func service() -> MobileImportService {
        MobileImportService(makeStager: { MobileSystemImportStager(directory: staging) })
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private actor SendGate {
    private(set) var wasCancelled = false
    func markCancelled() { wasCancelled = true }
    private var entered = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        entryWaiters.forEach { $0.resume() }; entryWaiters = []
        if !released { await withCheckedContinuation { waiter = $0 } }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entryWaiters.append($0) } }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

private struct SendHeldStager: MobileImportStaging {
    let base: MobileSystemImportStager
    let gate: SendGate
    func stage(_ source: URL, coordinated: Bool) async throws -> URL {
        let copy = try await base.stage(source, coordinated: coordinated)
        await withTaskCancellationHandler { await gate.wait() } onCancel: {
            Task { await gate.markCancelled() }
        }
        return copy
    }
    func discard(_ url: URL) async throws { try await base.discard(url) }
}

private actor SendRetryStager: MobileImportStaging {
    let base: MobileSystemImportStager
    private var first = true
    init(base: MobileSystemImportStager) { self.base = base }
    func stage(_ source: URL, coordinated: Bool) async throws -> URL {
        try await base.stage(source, coordinated: coordinated)
    }
    func discard(_ url: URL) async throws {
        if first { first = false; throw MobileImportError.cleanupFailed }
        try await base.discard(url)
    }
}
