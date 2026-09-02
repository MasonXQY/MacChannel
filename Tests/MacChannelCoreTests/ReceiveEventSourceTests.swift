import Foundation
import XCTest

@testable import MacChannelAppKit
@testable import MacChannelCore

final class ReceiveEventSourceTests: XCTestCase {
    func testEverySubscriptionReceivesEventsPublishedAfterItStarts() async throws {
        let source = RuntimeReceiveEventSource()
        let first = await source.stream()
        let firstTask = Task { await first.first(where: { _ in true }) }
        let result = TransferReceiveResult(
            transferID: TransferID(rawValue: UUID()),
            receivedURLs: [URL(fileURLWithPath: "/tmp/report.pdf")]
        )

        await source.publish(result)
        let firstResult = await firstTask.value
        XCTAssertEqual(firstResult, result)

        let second = await source.stream()
        let secondTask = Task { await second.first(where: { _ in true }) }
        await source.publish(result)
        let secondResult = await secondTask.value
        XCTAssertEqual(secondResult, result)
    }

    func testFinishedSourceEndsExistingAndFutureSubscriptions() async {
        let source = RuntimeReceiveEventSource()
        let existing = await source.stream()

        await source.finish()

        let existingResult = await existing.first(where: { _ in true })
        let future = await source.stream()
        let futureResult = await future.first(where: { _ in true })
        XCTAssertNil(existingResult)
        XCTAssertNil(futureResult)
    }

    func testContainerExposesFreshReceiveEventSubscriptions() async throws {
        let source = RuntimeReceiveEventSource()
        let receiveEvents = await MainActor.run {
            AppContainer(
                deviceDirectory: DeviceDirectory(trust: DeviceTrust(trustedIDs: [])),
                transferCoordinator: UnavailableTransferCoordinator(),
                receiveEvents: { await source.stream() }
            ).receiveEvents
        }
        let makeEvents = try XCTUnwrap(receiveEvents)
        let stream = await makeEvents()
        let result = TransferReceiveResult(
            transferID: TransferID(rawValue: UUID()),
            receivedURLs: [URL(fileURLWithPath: "/tmp/report.pdf")]
        )
        let eventTask = Task { await stream.first(where: { _ in true }) }

        await source.publish(result)

        let eventResult = await eventTask.value
        XCTAssertEqual(eventResult, result)
    }
}
