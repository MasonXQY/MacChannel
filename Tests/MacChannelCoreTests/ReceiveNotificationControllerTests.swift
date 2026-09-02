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
