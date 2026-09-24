import XCTest
@testable import DropMeshMobileRuntime

final class MobileForegroundOwnershipTests: XCTestCase, @unchecked Sendable {
    func testSecondStopJoinsRestartWaitingForPriorDrainWithoutSelfJoin() async throws {
        let state = OwnershipState(), gate = OwnershipGate()
        let owner = MobileForegroundOwnership(startRuntime: { await state.startRuntime() },
            stopRuntime: { await state.stopRuntime() }, startAccount: { await state.startAccount() },
            stopAccount: { await gate.pause(); await state.stopAccount() })
        try await owner.start()
        let oldStop = Task { await owner.stop() }
        await gate.entered()
        let restart = Task { try await owner.start() }
        for _ in 0..<100 { await Task.yield() }
        let finalStop = Task { await owner.stop() }
        for _ in 0..<100 { await Task.yield() }
        await gate.release()
        await oldStop.value
        _ = try? await restart.value
        await finalStop.value
        let final = await state.snapshot()
        XCTAssertFalse(final.runtime)
        XCTAssertFalse(final.account)
    }

    func testNewStartJoinsBlockedOldAccountStop() async throws {
        let state = OwnershipState(), gate = OwnershipGate()
        let owner = MobileForegroundOwnership(startRuntime: { await state.startRuntime() },
            stopRuntime: { await state.stopRuntime() }, startAccount: { await state.startAccount() },
            stopAccount: { await gate.pause(); await state.stopAccount() })
        try await owner.start()
        let stop = Task { await owner.stop() }
        await gate.entered()
        let start = Task { try await owner.start() }
        for _ in 0..<100 { await Task.yield() }
        await gate.release()
        await stop.value
        try await start.value
        let final = await state.snapshot()
        XCTAssertTrue(final.runtime, "retired stop must not disable the latest foreground")
        XCTAssertTrue(final.account, "both planes must converge to the same latest intent")
    }

    func testStopJoinsNoncooperativeOldStartBeforeAcceptingRestart() async throws {
        let state = OwnershipState(), gate = OwnershipGate()
        let owner = MobileForegroundOwnership(startRuntime: { await gate.pause(); await state.startRuntime() },
            stopRuntime: { await state.stopRuntime() }, startAccount: { await state.startAccount() },
            stopAccount: { await state.stopAccount() })
        let oldStart = Task { try await owner.start() }
        await gate.entered()
        let stop = Task { await owner.stop() }
        for _ in 0..<100 { await Task.yield() }
        let newStart = Task { try await owner.start() }
        for _ in 0..<100 { await Task.yield() }
        await gate.release()
        _ = try? await oldStart.value
        await stop.value
        try await newStart.value
        let final = await state.snapshot()
        XCTAssertTrue(final.runtime)
        XCTAssertTrue(final.account)
        XCTAssertEqual(final.accountStarts, 1, "superseded startup must never start account work")
    }

    func testStopAfterBlockedStartReturnsWithBothPlanesStopped() async throws {
        let state = OwnershipState(), gate = OwnershipGate()
        let owner = MobileForegroundOwnership(startRuntime: { await gate.pause(); await state.startRuntime() },
            stopRuntime: { await state.stopRuntime() }, startAccount: { await state.startAccount() },
            stopAccount: { await state.stopAccount() })
        let start = Task { try await owner.start() }
        await gate.entered()
        let stop = Task { await owner.stop() }
        for _ in 0..<100 { await Task.yield() }
        await gate.release()
        _ = try? await start.value
        await stop.value
        let final = await state.snapshot()
        XCTAssertFalse(final.runtime)
        XCTAssertFalse(final.account)
    }
}

private actor OwnershipState {
    var runtime = false, account = false, accountStarts = 0
    func startRuntime() { runtime = true }
    func stopRuntime() { runtime = false }
    func startAccount() { account = true; accountStarts += 1 }
    func stopAccount() { account = false }
    func snapshot() -> (runtime: Bool, account: Bool, accountStarts: Int) { (runtime, account, accountStarts) }
}

private actor OwnershipGate {
    var open = false, hasEntered = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    var arrivals: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        hasEntered = true
        let arrived = arrivals; arrivals = []; for waiter in arrived { waiter.resume() }
        if !open { await withCheckedContinuation { waiters.append($0) } }
    }
    func entered() async {
        if !hasEntered { await withCheckedContinuation { arrivals.append($0) } }
    }
    func release() {
        open = true
        let pending = waiters; waiters = []; for waiter in pending { waiter.resume() }
    }
}
