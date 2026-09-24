import Foundation
import XCTest
@testable import DropMeshMobileRuntime

final class MobileProviderImportTests: XCTestCase {
    private func fixture() throws -> (URL, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let staging = root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("video.mov")
        try Data(repeating: 42, count: 256 * 1024).write(to: source)
        return (root, staging, source)
    }

    func testWorkerRunsOutsideSwiftTaskAndMainThread() async throws {
        let (root, staging, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let stager = MobileImportStager(directory: staging) {
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertFalse(withUnsafeCurrentTask { $0 != nil })
        }
        _ = try await stager.stage(file: source)
    }

    func testSynchronousProviderCopyOwnsBytesBeforeCallbackReturns() throws {
        let (root, staging, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let stager = MobileImportStager(directory: staging)
        let result = try stager.copyProviderFile(source, cancellation: MobileImportCancellation())
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try Data(contentsOf: result).count, 256 * 1024)
    }

    func testCancelledBeforeDispatchCreatesNothing() async throws {
        let (root, staging, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let stager = MobileImportStager(directory: staging)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await stager.stage(file: source)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), [])
    }

    func testCoordinationUsesReplacementAndReleasesScopeAfterAccessor() async throws {
        for starts in [true, false] {
            let (root, staging, source) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let missing = root.appendingPathComponent("old.mov")
            let state = ProviderProbe(replacement: source, starts: starts)
            let stager = MobileImportStager(directory: staging, access: state.access,
                                          makeCoordinator: { state })
            let result = try await stager.stageCoordinated(file: missing)
            XCTAssertEqual(result.lastPathComponent, source.lastPathComponent)
            XCTAssertEqual(try Data(contentsOf: result).count, 256 * 1024)
            XCTAssertEqual(state.events, starts ? ["start", "enter", "exit", "stop"] : ["start", "enter", "exit"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        }
    }

    func testProviderFailureBalancesScopeAndCreatesNothing() async throws {
        let (root, staging, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = ProviderProbe(replacement: source, failure: CocoaError(.fileReadNoSuchFile))
        let stager = MobileImportStager(directory: staging, access: state.access, makeCoordinator: { state })
        do { _ = try await stager.stageCoordinated(file: source); XCTFail("Expected failure") } catch {}
        XCTAssertEqual(state.events, ["start", "enter", "exit", "stop"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), [])
    }

    func testCancellationDuringCoordinationWaitsForAccessorAndScopeRelease() async throws {
        let (root, staging, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = expectation(description: "coordinator pending")
        let gate = DispatchSemaphore(value: 0)
        let state = ProviderProbe(replacement: source, beforeAccessor: { entered.fulfill(); gate.wait() })
        let stager = MobileImportStager(directory: staging, access: state.access, makeCoordinator: { state })
        let task = Task { try await stager.stageCoordinated(file: source) }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        XCTAssertTrue(state.events.contains("cancel"))
        XCTAssertFalse(state.events.contains("stop"))
        gate.signal()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertEqual(state.events.last, "stop")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), [])
    }

    func testCoordinatedMidCopyCancellationCleansBeforeReturning() async throws {
        let (root, staging, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = expectation(description: "first chunk")
        let gate = DispatchSemaphore(value: 0)
        let state = ProviderProbe(replacement: source)
        let stager = MobileImportStager(directory: staging, access: state.access, makeCoordinator: { state },
                                      didCopyFirstChunk: { entered.fulfill(); gate.wait() })
        let task = Task { try await stager.stageCoordinated(file: source) }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        XCTAssertFalse(state.events.contains("stop"))
        gate.signal()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertEqual(state.events.last, "stop")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), [])
    }

    func testCompletedCopyWinsCancellationAndResultHasOwner() async throws {
        let (root, staging, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let finalized = expectation(description: "renamed")
        let gate = DispatchSemaphore(value: 0)
        let stager = MobileImportStager(directory: staging, didFinalize: { finalized.fulfill(); gate.wait() })
        let task = Task { try await stager.stage(file: source) }
        await fulfillment(of: [finalized], timeout: 2)
        task.cancel()
        gate.signal()
        let result = try await task.value
        XCTAssertEqual(try Data(contentsOf: result).count, 256 * 1024)
        try await stager.discard(result)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testPrecancelledCoordinatedImportDoesNotAcquireProvider() async throws {
        let (root, staging, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = ProviderProbe(replacement: source)
        let stager = MobileImportStager(directory: staging, access: state.access, makeCoordinator: { state })
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await stager.stageCoordinated(file: source)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertEqual(state.events, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), [])
    }

    func testProviderReportedCancellationBalancesScope() async throws {
        let (root, staging, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = ProviderProbe(replacement: source, failure: CocoaError(.userCancelled))
        let stager = MobileImportStager(directory: staging, access: state.access, makeCoordinator: { state })
        do { _ = try await stager.stageCoordinated(file: source); XCTFail("Expected provider cancellation") }
        catch { XCTAssertEqual((error as NSError).code, CocoaError.userCancelled.rawValue) }
        XCTAssertEqual(state.events, ["start", "enter", "exit", "stop"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), [])
    }

    func testCancellationDuringScopeSetupCancelsSubmittedCoordination() async throws {
        let (root, staging, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let started = expectation(description: "scope start")
        let gate = DispatchSemaphore(value: 0)
        let state = ProviderProbe(replacement: source)
        let access = MobileImportSecurityAccess(start: { _ in
            started.fulfill(); gate.wait(); return true
        }, stop: { _ in state.record("stop") })
        let stager = MobileImportStager(directory: staging, access: access, makeCoordinator: { state })
        let task = Task { try await stager.stageCoordinated(file: source) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        XCTAssertFalse(state.events.contains("cancel"), "Do not cancel a coordinator before its access is submitted")
        gate.signal()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertTrue(state.events.contains("cancel"))
        XCTAssertEqual(state.events.last, "stop")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), [])
    }

    func testSystemCoordinatorImportsRealLocalFile() async throws {
        let (root, staging, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await MobileImportStager(directory: staging).stageCoordinated(file: source)
        XCTAssertEqual(try Data(contentsOf: result), try Data(contentsOf: source))
    }

    func testSourcePathReplacementAfterOpenCannotRedirectCopy() async throws {
        let (root, staging, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = try Data(contentsOf: source)
        let stager = MobileImportStager(directory: staging) {
            do {
                try FileManager.default.removeItem(at: source)
                try Data("replacement".utf8).write(to: source)
            } catch { XCTFail("Fixture replacement failed: \(error)") }
        }
        let result = try await stager.stage(file: source)
        XCTAssertEqual(try Data(contentsOf: result), expected)
        XCTAssertEqual(try Data(contentsOf: source), Data("replacement".utf8))
    }

    func testSynchronousTokenCancelsAfterFirstChunkAndCleans() throws {
        let (root, staging, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let token = MobileImportCancellation()
        let stager = MobileImportStager(directory: staging) { token.cancel() }
        XCTAssertThrowsError(try stager.copyProviderFile(source, cancellation: token)) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
}

private final class ProviderProbe: MobileImportCoordinating, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    let replacement: URL
    let starts: Bool
    let failure: Error?
    let beforeAccessor: @Sendable () -> Void
    init(replacement: URL, starts: Bool = true, failure: Error? = nil,
         beforeAccessor: @escaping @Sendable () -> Void = {}) {
        self.replacement = replacement; self.starts = starts; self.failure = failure
        self.beforeAccessor = beforeAccessor
    }
    var events: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    func record(_ event: String) { lock.lock(); recorded.append(event); lock.unlock() }
    var access: MobileImportSecurityAccess {
        .init(start: { _ in self.record("start"); return self.starts }, stop: { _ in self.record("stop") })
    }
    func coordinate(file: URL, queue: OperationQueue,
                    accessor: @escaping @Sendable (URL, Error?) -> Void) {
        queue.addOperation {
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertFalse(withUnsafeCurrentTask { $0 != nil })
            self.beforeAccessor()
            self.record("enter")
            accessor(self.replacement, self.failure)
            self.record("exit")
            try? FileManager.default.removeItem(at: self.replacement)
        }
    }
    func cancel() { record("cancel") }
}
