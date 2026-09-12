@testable import DropMeshMobileRuntime
import Foundation
import XCTest
import UIKit
@testable import DropMeshTestHost

final class MobileImportAdapterTests: XCTestCase {
    func testPinnedRootOpenFailureDoesNotPoisonLaterAttempt() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.staging)
        let service = MobileImportService(makeStager: { fixture.stager() })
        let first = try await service.begin()
        do { _ = try await service.importFiles([fixture.source], in: first); XCTFail("Missing root imported") }
        catch { XCTAssertEqual(error as? MobileImportError, .unavailable) }
        try await service.discard(first)
        try FileManager.default.createDirectory(at: fixture.staging, withIntermediateDirectories: true)
        let second = try await service.begin()
        let file = try await service.importFiles([fixture.source], in: second)[0]
        XCTAssertEqual(try Data(contentsOf: file.url), fixture.bytes)
        try await service.discard(second)
    }

    func testCleanupFailureRemovesOtherCopiesAndRetainsOnlyFailedCopy() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let stager = RetryDiscardStager(base: fixture.stager())
        let service = MobileImportService(makeStager: { stager })
        let attempt = try await service.begin()
        let files = try await service.importFiles([fixture.source, fixture.source, fixture.source], in: attempt)
        do { try await service.discard(attempt); XCTFail("Cleanup failure hidden") }
        catch { XCTAssertEqual(error as? MobileImportError, .cleanupFailed) }
        XCTAssertEqual(files.filter { FileManager.default.fileExists(atPath: $0.url.path) }.count, 1)
        try await service.discard(attempt)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path), [])
    }

    @MainActor
    func testPickerCancellationDuringCopyJoinsAndCanRetryCleanup() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let gate = ImportGate()
        let stager = RetryDiscardStager(base: GatedImportStager(base: fixture.stager(), gate: gate))
        let service = MobileImportService(makeStager: { stager })
        let picker = try await MobileFilesPicker.make(service: service)
        picker.documentPicker(picker.controller, didPickDocumentsAt: [fixture.source])
        try await gate.waitUntilEntered()
        picker.documentPickerWasCancelled(picker.controller)
        XCTAssertEqual(picker.phase, .cancelling)
        await gate.release()
        do { try await picker.cancelAndWait(); XCTFail("Cleanup failure hidden") }
        catch { XCTAssertEqual(error as? MobileImportError, .cleanupFailed) }
        XCTAssertEqual(picker.failure, .cleanupFailed)
        XCTAssertEqual(picker.files.count, 0)
        try await picker.cancelAndWait()
        XCTAssertEqual(picker.phase, .cancelled)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path), [])
    }

    func testCoarseErrorsHaveBothLocalizationsWithoutProviderDetails() throws {
        let bundle = Bundle(for: MobileFilesPicker.self)
        for language in ["en", "zh-Hans"] {
            let localized = try XCTUnwrap(bundle.path(forResource: language, ofType: "lproj"))
            let languageBundle = try XCTUnwrap(Bundle(path: localized))
            for key in ["busy", "cancelled", "unavailable", "storage", "unsupported", "cleanup"] {
                let name = "import.error.\(key)"
                XCTAssertNotEqual(languageBundle.localizedString(forKey: name, value: nil, table: nil), name)
            }
        }
        XCTAssertEqual(MobileImportError.category(CocoaError(.fileWriteOutOfSpace)), .storage)
    }

    func testPhotoCallbackReturnsOnlyOwnedBytesAndRejectsOldOperationDuringCancellation() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let service = MobileImportService(makeStager: { fixture.stager() })
        let attempt = try await service.begin()
        let provider = ControlledPhotoProvider()
        let load = Task { try await service.importPhoto(in: attempt, start: provider.start) }
        try await provider.waitUntilStarted()
        let file = try await service.importPhotoFile(fixture.source)
        try FileManager.default.removeItem(at: fixture.source)
        provider.complete(.success(file))
        let delivered = try await load.value
        XCTAssertEqual(try Data(contentsOf: delivered.url), fixture.bytes)
        await service.cancel(attempt)
        do { _ = try await service.importPhotoFile(fixture.source); XCTFail("Late callback accepted") }
        catch { XCTAssertEqual(error as? MobileImportError, .cancelled) }
        try await service.discard(attempt)
    }

    func testCancelDuringRealStreamingCopyJoinsWorkerAndRemovesPartial() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let gate = BlockingImportGate()
        let service = MobileImportService(makeStager: {
            WorkerGateStager(stager: MobileImportStager(directory: fixture.staging, didCopyFirstChunk: { gate.wait() }))
        })
        let attempt = try await service.begin()
        let importTask = Task { try await service.importFiles([fixture.source], in: attempt) }
        try await gate.waitUntilEntered()
        await service.cancel(attempt)
        gate.release()
        do { _ = try await importTask.value; XCTFail("Cancelled copy succeeded") }
        catch { XCTAssertEqual(error as? MobileImportError, .cancelled) }
        try await service.discard(attempt)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path), [])
    }

    func testCancelBeforeStagerRegistrationPreventsCopyAfterFactoryReturns() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let gate = ImportGate()
        let service = MobileImportService(makeStager: { await gate.wait(); return fixture.stager() })
        let attempt = try await service.begin()
        let importTask = Task { try await service.importFiles([fixture.source], in: attempt) }
        try await gate.waitUntilEntered()
        await service.cancel(attempt)
        await gate.release()
        do { _ = try await importTask.value; XCTFail("Late factory allowed copy") }
        catch { XCTAssertEqual(error as? MobileImportError, .cancelled) }
        try await service.discard(attempt)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path), [])
    }

    func testProviderCancellationBeforeProgressRegistrationIsRemembered() async throws {
        let provider = ControlledPhotoProvider()
        let load = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MobilePhotoImport.load(start: provider.start)
        }
        try await provider.waitUntilStarted()
        try await provider.waitUntilCancelled()
        provider.complete(.failure(CancellationError()))
        do { _ = try await load.value; XCTFail("Cancelled provider succeeded") }
        catch { XCTAssertEqual(error as? MobileImportError, .cancelled) }
    }

    @MainActor
    func testFilesPickerPartialFailureCleansAndShowsCoarseFailure() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let service = MobileImportService(makeStager: { fixture.stager() })
        let picker = try await MobileFilesPicker.make(service: service)
        picker.documentPicker(picker.controller, didPickDocumentsAt: [fixture.source, fixture.root.appendingPathComponent("missing")])
        await picker.waitForImport()
        XCTAssertEqual(picker.phase, .failed)
        XCTAssertEqual(picker.failure, .unavailable)
        XCTAssertEqual(picker.files.count, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path), [])
        _ = try await service.begin()
    }

    func testCallerCancellationCancelsProviderBeforeExplicitDiscard() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let service = MobileImportService(makeStager: { fixture.stager() })
        let attempt = try await service.begin()
        let provider = ControlledPhotoProvider()
        let load = Task { try await service.importPhoto(in: attempt, start: provider.start) }
        try await provider.waitUntilStarted()
        load.cancel()
        try await provider.waitUntilCancelled()
        provider.complete(.failure(CancellationError()))
        _ = await load.result
        try await service.discard(attempt)
    }

    @MainActor
    func testFilesPickerImportsConfiguredMultipleSelectionAndRejectsDuplicateCallback() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let second = fixture.root.appendingPathComponent("second.bin")
        try fixture.bytes.write(to: second)
        let service = MobileImportService(makeStager: { fixture.stager() })
        let picker = try await MobileFilesPicker.make(service: service)
        XCTAssertTrue(picker.controller.allowsMultipleSelection)
        picker.documentPicker(picker.controller, didPickDocumentsAt: [fixture.source, second])
        picker.documentPicker(picker.controller, didPickDocumentsAt: [fixture.source])
        await picker.waitForImport()
        XCTAssertEqual(picker.files.count, 2)
        let files = picker.files
        for file in files { XCTAssertEqual(try Data(contentsOf: file.url), fixture.bytes) }
        try await picker.cancelAndWait()
        for file in files { XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path)) }
    }

    @MainActor
    func testAbandonedFilesPickerJoinsCleanupAndAllowsNewSelection() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let service = MobileImportService(makeStager: { fixture.stager() })
        let picker = try await MobileFilesPicker.make(service: service)
        picker.documentPickerWasCancelled(picker.controller)
        try await picker.cancelAndWait()
        _ = try await service.begin()
    }

    func testPhotoNilIsUnsupportedAndCancelledProviderKeepsAdmissionUntilCompletion() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let service = MobileImportService(makeStager: { fixture.stager() })
        let attempt = try await service.begin()
        let provider = ControlledPhotoProvider()
        let load = Task { try await service.importPhoto(in: attempt, start: provider.start) }
        try await provider.waitUntilStarted()
        await service.cancel(attempt)
        let cleanup = Task { try await service.discard(attempt) }
        do { _ = try await service.begin(); XCTFail("Unfinished callback released admission") }
        catch { XCTAssertEqual(error as? MobileImportError, .busy) }
        try await provider.waitUntilCancelled()
        provider.complete(.success(nil))
        do { _ = try await load.value; XCTFail("nil accepted") }
        catch { XCTAssertEqual(error as? MobileImportError, .unsupported) }
        try await cleanup.value
        _ = try await service.begin()
    }

    func testLatePhotoSuccessIsOwnedEvenWhenProviderReportsCancellation() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let gate = ImportGate()
        let stager = GatedImportStager(base: fixture.stager(), gate: gate)
        let service = MobileImportService(makeStager: { stager })
        let attempt = try await service.begin()
        let provider = ControlledPhotoProvider()
        let load = Task { try await service.importPhoto(in: attempt, start: provider.start) }
        try await provider.waitUntilStarted()
        let importing = Task { try await service.importPhotoFile(fixture.source) }
        try await gate.waitUntilEntered()
        await service.cancel(attempt)
        provider.complete(.failure(CancellationError()))
        let cleanup = Task { try await service.discard(attempt) }
        do { _ = try await service.begin(); XCTFail("Outstanding copy released admission") }
        catch { XCTAssertEqual(error as? MobileImportError, .busy) }
        await gate.release()
        let file = try await importing.value
        _ = await load.result
        try await cleanup.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path), [])
    }

    func testFailedCleanupRetainsExactStagerAndAdmissionForRetry() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let stager = RetryDiscardStager(base: fixture.stager())
        let service = MobileImportService(makeStager: { stager })
        let attempt = try await service.begin()
        let file = try await service.importFiles([fixture.source], in: attempt)[0]
        do { try await service.discard(attempt); XCTFail("Cleanup failure hidden") }
        catch { XCTAssertEqual(error as? MobileImportError, .cleanupFailed) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
        do { _ = try await service.begin(); XCTFail("Lost cleanup ownership") }
        catch { XCTAssertEqual(error as? MobileImportError, .busy) }
        try await service.discard(attempt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testFailedRootSetupIsRetriedWithFreshStager() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let factory = RetryImportFactory(directory: fixture.staging)
        let service = MobileImportService(makeStager: { try await factory.make() })
        let first = try await service.begin()
        do { _ = try await service.importFiles([fixture.source], in: first); XCTFail("Setup succeeded unexpectedly") }
        catch { XCTAssertEqual(error as? MobileImportError, .storage) }
        try await service.discard(first)
        let second = try await service.begin()
        let files = try await service.importFiles([fixture.source], in: second)
        XCTAssertEqual(try Data(contentsOf: files[0].url), fixture.bytes)
        try await service.discard(second)
    }

    func testCoordinatedFilesOwnBytesUntilExplicitDiscard() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let service = MobileImportService(makeStager: { fixture.stager() })
        let attempt = try await service.begin()
        let files = try await service.importFiles([fixture.source], in: attempt)
        XCTAssertEqual(files.count, 1)
        let file = try XCTUnwrap(files.first)
        try FileManager.default.removeItem(at: fixture.source)
        XCTAssertEqual(try Data(contentsOf: file.url), fixture.bytes)
        do { _ = try await service.begin(); XCTFail("Unreleased selection admitted") }
        catch { XCTAssertEqual(error as? MobileImportError, .busy) }
        try await service.discard(attempt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
        _ = try await service.begin()
    }

    func testCancellationBeforeCopyRejectsAndReleasesAdmission() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let service = MobileImportService(makeStager: { fixture.stager() })
        let attempt = try await service.begin()
        await service.cancel(attempt)
        do { _ = try await service.importFiles([fixture.source], in: attempt); XCTFail("Cancelled import ran") }
        catch { XCTAssertEqual(error as? MobileImportError, .cancelled) }
        try await service.discard(attempt)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path), [])
    }

    func testMultipleFilesAndPartialFailureRetainExactCleanupOwnership() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let service = MobileImportService(makeStager: { fixture.stager() })
        let attempt = try await service.begin()
        do {
            _ = try await service.importFiles([fixture.source, fixture.root.appendingPathComponent("missing")], in: attempt)
            XCTFail("Missing second file was ignored")
        } catch { XCTAssertEqual(error as? MobileImportError, .unavailable) }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path).isEmpty)
        try await service.discard(attempt)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path), [])
    }
}

private actor RetryImportFactory {
    let directory: URL
    var failed = false
    init(directory: URL) { self.directory = directory }
    func make() throws -> any MobileImportStaging {
        XCTAssertFalse(Thread.isMainThread)
        if !failed { failed = true; throw MobileImportError.storage }
        return MobileSystemImportStager(directory: directory)
    }
}

private struct WorkerGateStager: MobileImportStaging {
    let stager: MobileImportStager
    func stage(_ source: URL, coordinated: Bool) async throws -> URL {
        if coordinated { return try await stager.stageCoordinated(file: source) }
        return try await stager.stage(file: source)
    }
    func discard(_ url: URL) async throws { try await stager.discard(url) }
}

private final class BlockingImportGate: @unchecked Sendable {
    let condition = NSCondition()
    var entered = false
    var released = false
    func wait() {
        condition.lock()
        entered = true
        let deadline = Date().addingTimeInterval(5)
        while !released && condition.wait(until: deadline) {}
        condition.unlock()
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    func hasEntered() -> Bool { condition.lock(); defer { condition.unlock() }; return entered }
    func waitUntilEntered() async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !hasEntered() && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(hasEntered())
    }
}

private actor RetryDiscardStager: MobileImportStaging {
    let base: any MobileImportStaging
    var failed = false
    init(base: any MobileImportStaging) { self.base = base }
    func stage(_ source: URL, coordinated: Bool) async throws -> URL { try await base.stage(source, coordinated: coordinated) }
    func discard(_ url: URL) async throws {
        if !failed { failed = true; throw CocoaError(.fileWriteNoPermission) }
        try await base.discard(url)
    }
}

private struct GatedImportStager: MobileImportStaging {
    let base: any MobileImportStaging
    let gate: ImportGate
    func stage(_ source: URL, coordinated: Bool) async throws -> URL {
        let result = try await base.stage(source, coordinated: coordinated)
        await gate.wait()
        return result
    }
    func discard(_ url: URL) async throws { try await base.discard(url) }
}

private actor ImportGate {
    var entered = false
    var released = false
    func wait() async {
        entered = true
        let deadline = ContinuousClock.now + .seconds(5)
        while !released && ContinuousClock.now < deadline { await Task.yield() }
    }
    func waitUntilEntered() async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !entered && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(entered)
    }
    func release() { released = true }
}

private final class ControlledPhotoProvider: @unchecked Sendable {
    let lock = NSLock()
    var completion: MobilePhotoImport.Completion?
    let progress = Progress(totalUnitCount: 1)
    @MainActor func start(_ completion: @escaping MobilePhotoImport.Completion) -> Progress {
        lock.lock(); self.completion = completion; lock.unlock()
        return progress
    }
    func complete(_ result: Result<MobileImportedFile?, Error>) {
        lock.lock(); let callback = completion; completion = nil; lock.unlock()
        callback?(result)
    }
    func hasStarted() -> Bool { lock.lock(); defer { lock.unlock() }; return completion != nil }
    func waitUntilStarted() async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !hasStarted() && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(hasStarted())
    }
    func waitUntilCancelled() async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !progress.isCancelled && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(progress.isCancelled)
    }
}

private struct ImportFixture: Sendable {
    let root: URL
    let staging: URL
    let source: URL
    let bytes = Data(repeating: 0x5A, count: 150_000)
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        staging = root.appendingPathComponent("staging")
        source = root.appendingPathComponent("owned-test.bin")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try bytes.write(to: source)
    }
    func stager() -> any MobileImportStaging { MobileSystemImportStager(directory: staging) }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
