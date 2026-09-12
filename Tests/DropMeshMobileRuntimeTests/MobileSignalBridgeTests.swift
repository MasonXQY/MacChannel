import Foundation
import XCTest
@testable import MacChannelCore
@testable import DropMeshMobileRuntime

final class MobileSignalBridgeTests: XCTestCase {
    func testReplacedSocketFramesAndErrorsNeverReachStableStreams() async throws {
        let bridge = MobileSignalBridge()
        let signals = await bridge.signalFrames()
        let errors = await bridge.protocolErrors()
        let oldValue = await bridge.beginSocket()
        let old = try XCTUnwrap(oldValue)
        await bridge.activate(old, sender: { _, _ in })
        let currentValue = await bridge.beginSocket()
        let current = try XCTUnwrap(currentValue)
        await bridge.activate(current, sender: { _, _ in })
        let peer = DeviceID(rawValue: UUID())
        let staleAccepted = await bridge.receive(.init(from: peer, payload: Data([1])), socket: old)
        let staleErrorAccepted = await bridge.receive(.init(code: "old"), socket: old)
        let currentAccepted = await bridge.receive(.init(from: peer, payload: Data([2])), socket: current)
        let currentErrorAccepted = await bridge.receive(.init(code: "current"), socket: current)
        XCTAssertFalse(staleAccepted)
        XCTAssertFalse(staleErrorAccepted)
        XCTAssertTrue(currentAccepted)
        XCTAssertTrue(currentErrorAccepted)
        await bridge.finish()
        var payloads: [Data] = []
        for await frame in signals { payloads.append(frame.payload) }
        var codes: [String] = []
        for await error in errors { codes.append(error.code) }
        XCTAssertEqual(payloads, [Data([2])])
        XCTAssertEqual(codes, ["current"])
    }

    func testDisconnectedSendFailsAndIsNeverReplayed() async throws {
        let bridge = MobileSignalBridge()
        do {
            try await bridge.sendSignal(Data([1]), to: DeviceID(rawValue: UUID()))
            XCTFail("Disconnected signals must fail immediately")
        } catch { }
        let sent = BridgeSendRecorder()
        let tokenValue = await bridge.beginSocket()
        let token = try XCTUnwrap(tokenValue)
        await bridge.activate(token, sender: { payload, _ in await sent.append(payload) })
        try await bridge.sendSignal(Data([2]), to: DeviceID(rawValue: UUID()))
        let values = await sent.values
        XCTAssertEqual(values, [Data([2])])
        await bridge.finish()
        let later = await bridge.beginSocket()
        XCTAssertNil(later)
    }

    func testLateSendCompletionCannotSucceedAcrossSocketReplacement() async throws {
        let bridge = MobileSignalBridge()
        let gate = BridgeSendGate()
        let oldValue = await bridge.beginSocket()
        let old = try XCTUnwrap(oldValue)
        await bridge.activate(old, sender: { _, _ in await gate.wait() })
        let send = Task { try await bridge.sendSignal(Data([1]), to: DeviceID(rawValue: UUID())) }
        await gate.waitUntilEntered()
        _ = await bridge.beginSocket()
        await gate.release()
        do {
            try await send.value
            XCTFail("Old send completion must be interrupted")
        } catch is CancellationError { }
        await bridge.finish()
    }
}

private actor BridgeSendRecorder {
    var values: [Data] = []
    func append(_ value: Data) { values.append(value) }
}

private actor BridgeSendGate {
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true; enteredWaiter?.resume(); enteredWaiter = nil
        await withCheckedContinuation { waiter = $0 }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { enteredWaiter = $0 } }
    }
    func release() { waiter?.resume(); waiter = nil }
}
