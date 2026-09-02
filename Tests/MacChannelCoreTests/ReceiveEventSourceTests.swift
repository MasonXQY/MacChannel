import Foundation
import XCTest

@testable import MacChannelAppKit
@testable import MacChannelCore

final class ReceiveEventSourceTests: XCTestCase {
    func testBurstLargerThanLegacyBufferIsDeliveredWithoutLoss() async {
        let source = RuntimeReceiveEventSource(bufferCapacity: 4)
        let stream = await source.stream()
        let expected = (0..<32).map { index in
            TransferReceiveResult(
                transferID: TransferID(rawValue: UUID()),
                receivedURLs: [URL(fileURLWithPath: "/tmp/received-\(index).bin")]
            )
        }

        let consumer = Task { () -> [TransferReceiveResult] in
            var observed: [TransferReceiveResult] = []
            for await result in stream {
                observed.append(result)
                if observed.count == expected.count { break }
            }
            return observed
        }

        for result in expected { await source.publish(result) }
        await source.finish()

        let observed = await consumer.value
        XCTAssertEqual(observed, expected)
    }

    func testBlockedConsumerBackpressuresBeyondCapacityAndRecoversInOrder() async {
        let source = RuntimeReceiveEventSource(bufferCapacity: 2)
        let stream = await source.stream()
        let expected = (0..<3).map { index in
            TransferReceiveResult(
                transferID: TransferID(rawValue: UUID()),
                receivedURLs: [URL(fileURLWithPath: "/tmp/backpressure-\(index).bin")]
            )
        }

        await source.publish(expected[0])
        await source.publish(expected[1])
        let thirdFinished = ReceiveEventCompletionProbe()
        let blockedPublisher = Task {
            await source.publish(expected[2])
            await thirdFinished.finish()
        }
        for _ in 0..<100 { await Task.yield() }
        let finishedBeforeConsumption = await thirdFinished.isFinished()
        XCTAssertFalse(finishedBeforeConsumption)

        var iterator = stream.makeAsyncIterator()
        let firstObserved = await iterator.next()
        XCTAssertEqual(firstObserved, expected[0])
        for _ in 0..<100 where !(await thirdFinished.isFinished()) { await Task.yield() }
        let finishedAfterConsumption = await thirdFinished.isFinished()
        XCTAssertTrue(finishedAfterConsumption)
        let secondObserved = await iterator.next()
        let thirdObserved = await iterator.next()
        XCTAssertEqual(secondObserved, expected[1])
        XCTAssertEqual(thirdObserved, expected[2])

        await source.finish()
        await blockedPublisher.value
    }

    func testFinishReleasesPublisherBlockedBeforeFirstSubscription() async {
        let source = RuntimeReceiveEventSource(bufferCapacity: 1)
        await source.publish(
            TransferReceiveResult(
                transferID: TransferID(rawValue: UUID()),
                receivedURLs: [URL(fileURLWithPath: "/tmp/pending-first.bin")]
            )
        )
        let publisherFinished = ReceiveEventCompletionProbe()
        let blockedPublisher = Task {
            await source.publish(
                TransferReceiveResult(
                    transferID: TransferID(rawValue: UUID()),
                    receivedURLs: [URL(fileURLWithPath: "/tmp/pending-second.bin")]
                )
            )
            await publisherFinished.finish()
        }
        for _ in 0..<100 { await Task.yield() }
        let finishedBeforeShutdown = await publisherFinished.isFinished()
        XCTAssertFalse(finishedBeforeShutdown)

        await source.finish()

        await blockedPublisher.value
        let finishedAfterShutdown = await publisherFinished.isFinished()
        XCTAssertTrue(finishedAfterShutdown)
        let finishedStream = await source.stream()
        let finishedResult = await finishedStream.first(where: { _ in true })
        XCTAssertNil(finishedResult)
    }

    func testCancellingSubscriptionReleasesBlockedPublisher() async {
        let source = RuntimeReceiveEventSource(bufferCapacity: 1)
        let stream = await source.stream()
        await source.publish(
            TransferReceiveResult(
                transferID: TransferID(rawValue: UUID()),
                receivedURLs: [URL(fileURLWithPath: "/tmp/queued.bin")]
            )
        )
        let publisherFinished = ReceiveEventCompletionProbe()
        let blockedPublisher = Task {
            await source.publish(
                TransferReceiveResult(
                    transferID: TransferID(rawValue: UUID()),
                    receivedURLs: [URL(fileURLWithPath: "/tmp/blocked.bin")]
                )
            )
            await publisherFinished.finish()
        }
        for _ in 0..<100 { await Task.yield() }
        let finishedBeforeCancellation = await publisherFinished.isFinished()
        XCTAssertFalse(finishedBeforeCancellation)

        await stream.cancel()

        for _ in 0..<100 where !(await publisherFinished.isFinished()) { await Task.yield() }
        let finishedAfterCancellation = await publisherFinished.isFinished()
        XCTAssertTrue(finishedAfterCancellation)
        await blockedPublisher.value
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

private actor ReceiveEventCompletionProbe {
    private var finished = false

    func finish() { finished = true }
    func isFinished() -> Bool { finished }
}
