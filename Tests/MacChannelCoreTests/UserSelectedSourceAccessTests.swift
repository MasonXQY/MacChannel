import Foundation
import XCTest
@testable import MacChannelAppKit
@testable import MacChannelCore

final class UserSelectedSourceAccessTests: XCTestCase {
    func testLeaseSurvivesCancellationUntilAdmissionActuallyReturns() async throws {
        let calls = ScopeCalls()
        let delegate = HeldAdmission()
        let wrapper = SourceAccessTransferCoordinator(coordinator: delegate, access: UserSelectedSourceAccess(start: { calls.start($0); return true }, stop: { calls.stop($0) }, readable: { _ in true }))
        let send = Task { try await wrapper.send(items: [URL(fileURLWithPath: "/tmp/a")], to: DeviceID(rawValue: UUID())) }
        await delegate.waitForAdmission()
        XCTAssertEqual(calls.counts, [1, 0])
        send.cancel()
        await Task.yield()
        XCTAssertEqual(calls.counts, [1, 0])
        await delegate.finish()
        _ = try await send.value
        XCTAssertEqual(calls.counts, [1, 1])
    }

    func testDelegateThrowReleasesScope() async {
        let calls = ScopeCalls()
        let wrapper = SourceAccessTransferCoordinator(coordinator: UnavailableTransferCoordinator(), access: UserSelectedSourceAccess(start: { calls.start($0); return true }, stop: { calls.stop($0) }, readable: { _ in true }))
        do { _ = try await wrapper.send(items: [URL(fileURLWithPath: "/tmp/a")], to: DeviceID(rawValue: UUID())); XCTFail("Expected admission failure") } catch {}
        XCTAssertEqual(calls.counts, [1, 1])
    }
    func testCanonicalDuplicatesAreStartedAndStoppedOnce() throws {
        let calls = ScopeCalls()
        let access = UserSelectedSourceAccess(start: { calls.start($0); return true }, stop: { calls.stop($0) }, readable: { _ in true })
        let lease = try access.acquire([URL(fileURLWithPath: "/tmp/a"), URL(fileURLWithPath: "/tmp/./a")])
        XCTAssertEqual(calls.counts, [1, 0])
        lease.release()
        lease.release()
        XCTAssertEqual(calls.counts, [1, 1])
    }

    func testUnreadableRootReleasesEverySuccessfulStart() {
        let calls = ScopeCalls()
        let access = UserSelectedSourceAccess(start: { calls.start($0); return true }, stop: { calls.stop($0) }, readable: { _ in false })
        XCTAssertThrowsError(try access.acquire([URL(fileURLWithPath: "/tmp/a")]))
        XCTAssertEqual(calls.counts, [1, 1])
    }

    func testFailedScopeStartDoesNotStopButReadableSandboxFileIsAllowed() throws {
        let calls = ScopeCalls()
        let access = UserSelectedSourceAccess(start: { calls.start($0); return false }, stop: { calls.stop($0) }, readable: { _ in true })
        let lease = try access.acquire([URL(fileURLWithPath: "/tmp/a")])
        lease.release()
        XCTAssertEqual(calls.counts, [1, 0])
    }
}

private actor HeldAdmission: TransferCoordinating {
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    func send(items: [URL], to device: DeviceID) async throws -> TransferID {
        entered = true
        await withCheckedContinuation { continuation = $0 }
        return TransferID(rawValue: UUID())
    }
    func waitForAdmission() async { while !entered { await Task.yield() } }
    func finish() { continuation?.resume(); continuation = nil }
    func pause(_ id: TransferID) async throws {}
    func resume(_ id: TransferID) async throws {}
    func cancel(_ id: TransferID) async -> TransferCancellationResult { .requested }
}

final class ScopeCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0
    func start(_ url: URL) { lock.lock(); defer { lock.unlock() }; starts += 1 }
    func stop(_ url: URL) { lock.lock(); defer { lock.unlock() }; stops += 1 }
    var counts: [Int] { lock.lock(); defer { lock.unlock() }; return [starts, stops] }
}
