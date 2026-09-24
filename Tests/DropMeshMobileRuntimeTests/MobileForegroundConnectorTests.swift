import Foundation
import XCTest
import MacChannelCore
@testable import DropMeshMobileRuntime

final class MobileForegroundConnectorTests: XCTestCase {
    func testDisabledConnectorRejectsWithoutContactingPeer() async {
        let connector = MobileForegroundConnector()
        do {
            _ = try await connector.connect(to: DeviceID(rawValue: UUID()))
            XCTFail("An inactive foreground must not connect")
        } catch is CancellationError { } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testLateChannelClosesAfterDisableAndReentry() async throws {
        let connector = MobileForegroundConnector()
        let old = DelayedMobileConnector()
        await connector.install(old)
        let request = Task { try await connector.connect(to: DeviceID(rawValue: UUID())) }
        await old.waitUntilConnecting()
        await connector.disable()
        let current = DelayedMobileConnector()
        await connector.install(current)
        await old.release()
        do {
            _ = try await request.value
            XCTFail("A prior foreground channel must never escape")
        } catch is CancellationError { }
        let closes = await old.channel.closeCount
        XCTAssertEqual(closes, 1)
    }

    func testAllOverloadsPreserveTransferAndFailedRoute() async throws {
        let connector = MobileForegroundConnector()
        let target = DelayedMobileConnector(initiallyReleased: true)
        await connector.install(target)
        let peer = DeviceID(rawValue: UUID())
        let transfer = TransferID(rawValue: UUID())
        _ = try await connector.connect(to: peer)
        _ = try await connector.connect(to: peer, transferID: transfer)
        _ = try await connector.connect(to: peer, transferID: transfer, after: .directInternet)
        let calls = await target.calls
        XCTAssertEqual(calls, [
            .init(peer: peer, transfer: nil, route: nil),
            .init(peer: peer, transfer: transfer, route: nil),
            .init(peer: peer, transfer: transfer, route: .directInternet)
        ])
    }

    func testLateFailureIsCancellationAfterForegroundReplacement() async throws {
        let connector = MobileForegroundConnector()
        let old = DelayedMobileConnector(failOnRelease: true)
        await connector.install(old)
        let request = Task { try await connector.connect(to: DeviceID(rawValue: UUID())) }
        await old.waitUntilConnecting()
        await connector.disable()
        await connector.install(DelayedMobileConnector(initiallyReleased: true))
        await old.release()
        do { _ = try await request.value; XCTFail("Must fail") }
        catch is CancellationError { }
        catch { XCTFail("A stale failure must cancel, not become a retryable current error") }
    }
}

private actor MobileTestChannel: SecureChannel {
    nonisolated let route = ConnectionRoute.lan
    var closeCount = 0
    func send(_ frame: Data) async throws { }
    nonisolated func frames() -> AsyncThrowingStream<Data, Error> { .init { $0.finish() } }
    func exportKey(label: String, context: Data, length: Int) async throws -> Data { Data(count: length) }
    func close() { closeCount += 1 }
}

private actor DelayedMobileConnector: RouteEscalatingPeerConnector {
    struct Call: Equatable {
        let peer: DeviceID
        let transfer: TransferID?
        let route: ConnectionRoute?
    }
    let channel = MobileTestChannel()
    var calls: [Call] = []
    private var released: Bool
    private let failOnRelease: Bool
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    init(initiallyReleased: Bool = false, failOnRelease: Bool = false) {
        released = initiallyReleased; self.failOnRelease = failOnRelease
    }
    func connect(to device: DeviceID) async throws -> any SecureChannel {
        try await connect(.init(peer: device, transfer: nil, route: nil))
    }
    func connect(to device: DeviceID, transferID: TransferID) async throws -> any SecureChannel {
        try await connect(.init(peer: device, transfer: transferID, route: nil))
    }
    func connect(to device: DeviceID, transferID: TransferID, after failedRoute: ConnectionRoute?) async throws -> any SecureChannel {
        try await connect(.init(peer: device, transfer: transferID, route: failedRoute))
    }
    private func connect(_ call: Call) async throws -> any SecureChannel {
        calls.append(call)
        enteredWaiter?.resume(); enteredWaiter = nil
        if !released { await withCheckedContinuation { releaseWaiter = $0 } }
        if failOnRelease { throw MacChannelError.transferFailed }
        return channel
    }
    func waitUntilConnecting() async {
        if calls.isEmpty { await withCheckedContinuation { enteredWaiter = $0 } }
    }
    func release() { released = true; releaseWaiter?.resume(); releaseWaiter = nil }
}
