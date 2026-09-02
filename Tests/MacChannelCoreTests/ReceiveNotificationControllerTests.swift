import Foundation
import XCTest
@testable import MacChannelAppKit
@testable import MacChannelCore

@MainActor
final class ReceiveNotificationControllerTests: XCTestCase {
    func testSingleFileNotificationUsesFilenameAndCanRevealIt() async throws {
        let center = RecordingReceiveNotificationCenter(status: .authorized)
        let finder = RecordingReceiveTargetRevealer()
        let controller = ReceiveNotificationController(center: center, revealer: finder)
        let file = URL(fileURLWithPath: "/tmp/Downloads/plan.pdf")

        await controller.notify(receive: TransferReceiveResult(
            transferID: TransferID(rawValue: UUID()),
            receivedURLs: [file]
        ))

        XCTAssertEqual(center.requests.count, 1)
        XCTAssertEqual(center.requests[0].content.title, "已收到新文件")
        XCTAssertTrue(center.requests[0].content.body.contains("plan.pdf"))
        XCTAssertFalse(center.requests[0].content.body.contains(file.path))
        XCTAssertTrue(center.requests[0].content.userInfo.isEmpty)
        controller.openNotification(identifier: center.requests[0].identifier)
        XCTAssertEqual(finder.revealedURLs, [[file]])
    }

    func testMultipleFilesNotificationUsesCountAndRevealsTheirParentDirectory() async {
        let center = RecordingReceiveNotificationCenter(status: .authorized)
        let finder = RecordingReceiveTargetRevealer()
        let controller = ReceiveNotificationController(center: center, revealer: finder)
        let directory = URL(fileURLWithPath: "/tmp/Downloads")
        let first = directory.appendingPathComponent("plan.pdf")
        let second = directory.appendingPathComponent("notes.txt")

        await controller.notify(receive: TransferReceiveResult(
            transferID: TransferID(rawValue: UUID()),
            receivedURLs: [first, second]
        ))

        XCTAssertEqual(center.requests.count, 1)
        XCTAssertTrue(center.requests[0].content.body.contains("已收到 2 个文件"))
        controller.openNotification(identifier: center.requests[0].identifier)
        XCTAssertEqual(finder.revealedURLs, [[directory]])
    }

    func testPrepareRequestsUndeterminedAuthorizationOnlyOnce() async {
        let center = RecordingReceiveNotificationCenter(
            status: .notDetermined,
            requestedStatus: .authorized
        )
        let controller = ReceiveNotificationController(
            center: center,
            revealer: RecordingReceiveTargetRevealer()
        )

        await controller.prepare()
        await controller.prepare()

        XCTAssertEqual(center.authorizationRequestCount, 1)
    }

    func testDeniedAuthorizationSendsNothingAndPublishesDeniedState() async {
        let center = RecordingReceiveNotificationCenter(status: .denied)
        let controller = ReceiveNotificationController(
            center: center,
            revealer: RecordingReceiveTargetRevealer()
        )
        let snapshots = controller.snapshots()

        await controller.notify(receive: TransferReceiveResult(
            transferID: TransferID(rawValue: UUID()),
            receivedURLs: [URL(fileURLWithPath: "/tmp/Downloads/plan.pdf")]
        ))

        XCTAssertTrue(center.requests.isEmpty)
        var iterator = snapshots.makeAsyncIterator()
        let observedSnapshot = await iterator.next()
        XCTAssertEqual(observedSnapshot?.authorizationState, .denied)
    }

    func testRefreshingAuthorizationRequeriesTheSystemAndPublishesExternalChanges() async {
        let center = RecordingReceiveNotificationCenter(status: .denied)
        let controller = ReceiveNotificationController(
            center: center,
            revealer: RecordingReceiveTargetRevealer()
        )
        var snapshots = controller.snapshots().makeAsyncIterator()

        let initial = await snapshots.next()
        XCTAssertEqual(initial?.authorizationState, .notDetermined)

        center.setAuthorizationState(.authorized)
        await controller.refreshAuthorizationState()
        let authorized = await snapshots.next()
        XCTAssertEqual(authorized?.authorizationState, .authorized)

        center.setAuthorizationState(.denied)
        await controller.refreshAuthorizationState()
        let denied = await snapshots.next()
        XCTAssertEqual(denied?.authorizationState, .denied)
    }

    func testOutOfOrderAuthorizationRefreshPublishesOnlyNewestResult() async {
        let center = ControllableReceiveNotificationCenter()
        let controller = ReceiveNotificationController(
            center: center,
            revealer: RecordingReceiveTargetRevealer()
        )
        var snapshots = controller.snapshots().makeAsyncIterator()

        let initial = await snapshots.next()
        XCTAssertEqual(initial?.authorizationState, .notDetermined)

        let olderRefresh = Task { @MainActor in
            await controller.refreshAuthorizationState()
        }
        await waitForAuthorizationQueries(1, in: center)

        let newerRefresh = Task { @MainActor in
            await controller.refreshAuthorizationState()
        }
        await waitForAuthorizationQueries(2, in: center)

        center.resolveAuthorizationQuery(at: 1, with: .authorized)
        await newerRefresh.value
        center.resolveAuthorizationQuery(at: 0, with: .denied)
        await olderRefresh.value

        let latest = await snapshots.next()
        XCTAssertEqual(latest?.authorizationState, .authorized)
    }

    func testCancelledAuthorizationRefreshDoesNotPublishItsLateResult() async {
        let center = ControllableReceiveNotificationCenter()
        let controller = ReceiveNotificationController(
            center: center,
            revealer: RecordingReceiveTargetRevealer()
        )

        let refresh = Task { @MainActor in
            await controller.refreshAuthorizationState()
        }
        await waitForAuthorizationQueries(1, in: center)
        refresh.cancel()
        center.resolveAuthorizationQuery(at: 0, with: .denied)
        await refresh.value

        var snapshots = controller.snapshots().makeAsyncIterator()
        let current = await snapshots.next()
        XCTAssertEqual(current?.authorizationState, .notDetermined)
    }

    func testRefreshDuringAuthorizationRequestCannotSuppressFirstNotification() async {
        let center = ControllableReceiveNotificationCenter()
        let controller = ReceiveNotificationController(
            center: center,
            revealer: RecordingReceiveTargetRevealer()
        )
        let file = URL(fileURLWithPath: "/tmp/Downloads/plan.pdf")

        let notification = Task { @MainActor in
            await controller.notify(receive: TransferReceiveResult(
                transferID: TransferID(rawValue: UUID()),
                receivedURLs: [file]
            ))
        }
        await waitForAuthorizationQueries(1, in: center)
        center.resolveAuthorizationQuery(at: 0, with: .notDetermined)
        await waitForAuthorizationRequests(1, in: center)

        let refresh = Task { @MainActor in
            await controller.refreshAuthorizationState()
        }
        for _ in 0..<100 {
            await Task.yield()
        }

        let refreshStartedASecondQuery = center.authorizationQueryCount > 1
        if refreshStartedASecondQuery {
            center.resolveAuthorizationQuery(at: 1, with: .notDetermined)
        }
        center.resolveAuthorizationRequest(at: 0, with: .authorized)
        await notification.value
        await refresh.value

        XCTAssertFalse(refreshStartedASecondQuery)
        XCTAssertEqual(center.requests.count, 1)
        XCTAssertEqual(center.requests.first?.content.body, "plan.pdf 已保存到接收文件夹")
        var snapshots = controller.snapshots().makeAsyncIterator()
        let current = await snapshots.next()
        XCTAssertEqual(current?.authorizationState, .authorized)
    }

    func testDeliveryFailurePublishesDeliveryUnavailableWithoutThrowing() async {
        let center = RecordingReceiveNotificationCenter(status: .authorized)
        center.deliveryError = TestError.deliveryUnavailable
        let controller = ReceiveNotificationController(
            center: center,
            revealer: RecordingReceiveTargetRevealer()
        )
        let snapshots = controller.snapshots()

        await controller.notify(receive: TransferReceiveResult(
            transferID: TransferID(rawValue: UUID()),
            receivedURLs: [URL(fileURLWithPath: "/tmp/Downloads/plan.pdf")]
        ))

        XCTAssertEqual(center.requests.count, 1)
        var iterator = snapshots.makeAsyncIterator()
        let observedSnapshot = await iterator.next()
        XCTAssertEqual(observedSnapshot?.authorizationState, .deliveryUnavailable)
    }

    func testUnknownNotificationIdentifierDoesNotRevealAnyTarget() {
        let finder = RecordingReceiveTargetRevealer()
        let controller = ReceiveNotificationController(
            center: RecordingReceiveNotificationCenter(status: .authorized),
            revealer: finder
        )

        controller.openNotification(identifier: "dropmesh.receive.unknown")

        XCTAssertTrue(finder.revealedURLs.isEmpty)
    }

    func testNotificationIdentifierCanRevealItsTargetOnlyOnce() async throws {
        let center = RecordingReceiveNotificationCenter(status: .authorized)
        let finder = RecordingReceiveTargetRevealer()
        let controller = ReceiveNotificationController(center: center, revealer: finder)
        let file = URL(fileURLWithPath: "/tmp/Downloads/plan.pdf")

        await controller.notify(receive: TransferReceiveResult(
            transferID: TransferID(rawValue: UUID()),
            receivedURLs: [file]
        ))

        let identifier = try XCTUnwrap(center.requests.first?.identifier)
        controller.openNotification(identifier: identifier)
        controller.openNotification(identifier: identifier)

        XCTAssertEqual(finder.revealedURLs, [[file]])
    }

    func testSystemResponseCompletesAfterItsMainActorHandler() async {
        let completion = expectation(description: "system response completion")
        var handledIdentifiers: [String] = []

        SystemReceiveNotificationCenter.dispatchNotificationResponse(
            identifier: "dropmesh.receive.test",
            responseHandler: { identifier in
                handledIdentifiers.append(identifier)
            },
            completionHandler: {
                XCTAssertEqual(handledIdentifiers, ["dropmesh.receive.test"])
                completion.fulfill()
            }
        )

        await fulfillment(of: [completion], timeout: 1)
    }

    private func waitForAuthorizationQueries(
        _ count: Int,
        in center: ControllableReceiveNotificationCenter
    ) async {
        for _ in 0..<100 where center.authorizationQueryCount < count {
            await Task.yield()
        }
        XCTAssertEqual(center.authorizationQueryCount, count)
    }

    private func waitForAuthorizationRequests(
        _ count: Int,
        in center: ControllableReceiveNotificationCenter
    ) async {
        for _ in 0..<100 where center.authorizationRequestCount < count {
            await Task.yield()
        }
        XCTAssertEqual(center.authorizationRequestCount, count)
    }
}

@MainActor
private final class ControllableReceiveNotificationCenter: ReceiveNotificationCenter {
    private(set) var authorizationQueryCount = 0
    private(set) var authorizationRequestCount = 0
    private(set) var requests: [ReceiveNotificationRequest] = []
    private var pendingQueries: [CheckedContinuation<ReceiveNotificationAuthorizationState, Never>?] = []
    private var pendingAuthorizationRequests: [CheckedContinuation<ReceiveNotificationAuthorizationState, Never>?] = []

    func authorizationState() async -> ReceiveNotificationAuthorizationState {
        authorizationQueryCount += 1
        return await withCheckedContinuation { continuation in
            pendingQueries.append(continuation)
        }
    }

    func resolveAuthorizationQuery(
        at index: Int,
        with state: ReceiveNotificationAuthorizationState
    ) {
        let continuation = pendingQueries[index]
        pendingQueries[index] = nil
        continuation?.resume(returning: state)
    }

    func requestAuthorization() async -> ReceiveNotificationAuthorizationState {
        authorizationRequestCount += 1
        return await withCheckedContinuation { continuation in
            pendingAuthorizationRequests.append(continuation)
        }
    }

    func resolveAuthorizationRequest(
        at index: Int,
        with state: ReceiveNotificationAuthorizationState
    ) {
        let continuation = pendingAuthorizationRequests[index]
        pendingAuthorizationRequests[index] = nil
        continuation?.resume(returning: state)
    }

    func deliver(_ request: ReceiveNotificationRequest) async throws {
        requests.append(request)
    }
    func openSystemSettings() {}
}

@MainActor
private final class RecordingReceiveNotificationCenter: ReceiveNotificationCenter {
    private(set) var status: ReceiveNotificationAuthorizationState
    private let requestedStatus: ReceiveNotificationAuthorizationState
    private(set) var authorizationRequestCount = 0
    private(set) var requests: [ReceiveNotificationRequest] = []
    var deliveryError: Error?

    init(
        status: ReceiveNotificationAuthorizationState,
        requestedStatus: ReceiveNotificationAuthorizationState? = nil
    ) {
        self.status = status
        self.requestedStatus = requestedStatus ?? status
    }

    func authorizationState() async -> ReceiveNotificationAuthorizationState {
        status
    }

    func requestAuthorization() async -> ReceiveNotificationAuthorizationState {
        authorizationRequestCount += 1
        status = requestedStatus
        return status
    }

    func setAuthorizationState(_ status: ReceiveNotificationAuthorizationState) {
        self.status = status
    }

    func deliver(_ request: ReceiveNotificationRequest) async throws {
        requests.append(request)
        if let deliveryError {
            throw deliveryError
        }
    }

    func openSystemSettings() {}
}

@MainActor
private final class RecordingReceiveTargetRevealer: ReceiveTargetRevealing {
    private(set) var revealedURLs: [[URL]] = []

    func reveal(_ urls: [URL]) {
        revealedURLs.append(urls)
    }
}

private enum TestError: Error {
    case deliveryUnavailable
}
