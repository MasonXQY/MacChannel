import Foundation
import XCTest

@testable import MacChannelAppKit
@testable import MacChannelCore

final class ReceiveEventSourceTests: XCTestCase {
    func testBurstLargerThanLegacyBufferIsDeliveredWithoutLoss() async {
        let source = RuntimeReceiveEventSource()
        let stream = await source.stream()
        let expected = (0..<32).map { index in
            TransferReceiveResult(
                transferID: TransferID(rawValue: UUID()),
                receivedURLs: [URL(fileURLWithPath: "/tmp/received-\(index).bin")]
            )
        }

        for result in expected {
            await source.publish(result)
        }
        await source.finish()

        var observed: [TransferReceiveResult] = []
        for await result in stream {
            observed.append(result)
        }
        XCTAssertEqual(observed, expected)
    }

    func testEverySubscriptionReceivesEventsPublishedAfterItStarts() async throws {
        let source = RuntimeReceiveEventSource()
        let first = await source.stream()
        let firstTask = Task { await first.first(where: { _ in true }) }
        let firstResult = TransferReceiveResult(
            transferID: TransferID(rawValue: UUID()),
            receivedURLs: [URL(fileURLWithPath: "/tmp/report.pdf")]
        )

        await source.publish(firstResult)
        let observedFirstResult = await firstTask.value
        XCTAssertEqual(observedFirstResult, firstResult)

        let second = await source.stream()
        let secondTask = Task { await second.first(where: { _ in true }) }
        let secondResult = TransferReceiveResult(
            transferID: TransferID(rawValue: UUID()),
            receivedURLs: [URL(fileURLWithPath: "/tmp/second-report.pdf")]
        )

        await source.publish(secondResult)
        let observedSecondResult = await secondTask.value
        XCTAssertEqual(observedSecondResult, secondResult)
        XCTAssertNotEqual(observedSecondResult, firstResult)
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
