import Foundation
import XCTest
@testable import MacChannelAppKit
@testable import MacChannelCore
@preconcurrency import UserNotifications

@MainActor
final class ReceiveNotificationControllerTests: XCTestCase {
    func testForegroundNotificationUsesModernPresentationSurfacesAndCompletesOnce() {
        var completionCount = 0
        var observedOptions: UNNotificationPresentationOptions = []

        SystemReceiveNotificationCenter.dispatchForegroundPresentation {
            completionCount += 1
            observedOptions = $0
        }

        XCTAssertEqual(completionCount, 1)
        XCTAssertTrue(observedOptions.contains(.banner))
        XCTAssertTrue(observedOptions.contains(.list))
        XCTAssertTrue(observedOptions.contains(.sound))
        XCTAssertEqual(observedOptions, [.banner, .list, .sound])
    }

    func testSingleFileNotificationUsesFilenameAndCanRevealIt() async throws {
        let center = RecordingReceiveNotificationCenter(status: .authorized)
        let finder = RecordingReceiveTargetRevealer()
        let controller = ReceiveNotificationController(center: center, revealer: finder)
        let file = URL(fileURLWithPath: "/tmp/Downloads/plan.pdf")
        let result = TransferReceiveResult(
            transferID: TransferID(rawValue: UUID()),
            receivedURLs: [file]
        )
        var opened: [TransferID] = []
        controller.onReceiveOpened = { opened.append($0) }

        await controller.notify(receive: result)

        XCTAssertEqual(center.requests.count, 1)
        XCTAssertEqual(center.requests[0].content.title, "已收到新文件")
        XCTAssertTrue(center.requests[0].content.body.contains("plan.pdf"))
        XCTAssertFalse(center.requests[0].content.body.contains(file.path))
        XCTAssertTrue(center.requests[0].content.userInfo.isEmpty)
        controller.openNotification(identifier: center.requests[0].identifier)
        XCTAssertEqual(finder.revealedURLs, [[file]])
        XCTAssertEqual(opened, [result.transferID])
    }

    func testNotificationIdentifierStablyCarriesOnlyTransferAndSourceIdentity() async throws {
        let center = RecordingReceiveNotificationCenter(status: .authorized)
        let source = DeviceID(
            rawValue: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        )
        let transferID = TransferID(
            rawValue: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        )
        let privateURL = URL(fileURLWithPath: "/Users/private/Secret Report.pdf")
        let result = TransferReceiveResult(
            transferID: transferID,
            receivedURLs: [privateURL],
            source: source
        )
        let controller = ReceiveNotificationController(
            center: center,
            revealer: RecordingReceiveTargetRevealer()
        )

        await controller.notify(receive: result)
        await controller.notify(receive: result)

        let identifiers = center.requests.map(\.identifier)
        XCTAssertEqual(identifiers.count, 2)
        XCTAssertEqual(Set(identifiers).count, 1)
        let identifier = try XCTUnwrap(identifiers.first)
        XCTAssertTrue(identifier.contains(transferID.rawValue.uuidString.lowercased()))
        XCTAssertTrue(identifier.contains(source.rawValue.uuidString.lowercased()))
        XCTAssertFalse(identifier.contains("Secret"))
        XCTAssertFalse(identifier.contains("private"))
        XCTAssertTrue(center.requests.allSatisfy { $0.content.userInfo.isEmpty })
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
        XCTAssertEqual(finder.revealedURLs, [[first, second]])
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

    func testConcurrentAuthorizationRefreshesShareOneBoundedSystemQuery() async {
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
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(center.authorizationQueryCount, 1)

        center.resolveAuthorizationQuery(at: 0, with: .authorized)
        await olderRefresh.value
        await newerRefresh.value

        let latest = await snapshots.next()
        XCTAssertEqual(latest?.authorizationState, .authorized)
    }

    func testCancellingOneSharedAuthorizationRefreshDoesNotCancelTheSurvivingWaiter() async {
        let center = ControllableReceiveNotificationCenter()
        let controller = ReceiveNotificationController(
            center: center,
            revealer: RecordingReceiveTargetRevealer(),
            authorizationStatusTimeout: .seconds(30)
        )
        let cancelled = Task { @MainActor in
            await controller.refreshAuthorizationState()
        }
        await waitForAuthorizationQueries(1, in: center)
        let surviving = Task { @MainActor in
            await controller.refreshAuthorizationState()
        }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(center.authorizationQueryCount, 1)

        cancelled.cancel()
        await cancelled.value
        center.resolveAuthorizationQuery(at: 0, with: .authorized)
        await surviving.value

        var snapshots = controller.snapshots().makeAsyncIterator()
        let authorized = await snapshots.next()
        XCTAssertEqual(authorized?.authorizationState, .authorized)
        XCTAssertEqual(center.authorizationQueryCount, 1)
    }

    func testCancellingOneSharedAuthorizationRequestDoesNotSuppressWaitingNotification()
        async
    {
        let center = ControllableReceiveNotificationCenter()
        let controller = ReceiveNotificationController(
            center: center,
            revealer: RecordingReceiveTargetRevealer(),
            authorizationPromptTimeout: .seconds(30)
        )
        let cancelledPrepare = Task { @MainActor in
            await controller.prepare()
        }
        await waitForAuthorizationQueries(1, in: center)
        center.resolveAuthorizationQuery(at: 0, with: .notDetermined)
        await waitForAuthorizationRequests(1, in: center)

        let survivingNotification = Task { @MainActor in
            await controller.notify(receive: self.receiveResult(named: "survivor.pdf"))
        }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(center.authorizationRequestCount, 1)

        cancelledPrepare.cancel()
        await cancelledPrepare.value
        center.resolveAuthorizationRequest(at: 0, with: .authorized)
        await survivingNotification.value

        XCTAssertEqual(center.authorizationRequestCount, 1)
        XCTAssertEqual(center.requests.count, 1)
        XCTAssertEqual(center.requests.first?.content.body, "survivor.pdf 已保存到接收文件夹")
        var snapshots = controller.snapshots().makeAsyncIterator()
        let authorized = await snapshots.next()
        XCTAssertEqual(authorized?.authorizationState, .authorized)
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

    func testDeliveryFailurePreservesAuthorizationAndPublishesTransientFailure() async {
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
        XCTAssertEqual(observedSnapshot?.authorizationState, .authorized)
        XCTAssertEqual(observedSnapshot?.deliveryState, .temporarilyUnavailable)

        center.deliveryError = nil
        await controller.notify(receive: TransferReceiveResult(
            transferID: TransferID(rawValue: UUID()),
            receivedURLs: [URL(fileURLWithPath: "/tmp/Downloads/retry.pdf")]
        ))
        let recoveredSnapshot = await iterator.next()
        XCTAssertEqual(recoveredSnapshot?.authorizationState, .authorized)
        XCTAssertEqual(recoveredSnapshot?.deliveryState, .available)
    }

    func testBlockedDeliveryTimesOutAndKeepsOnlyOneSystemOperationInFlight() async {
        let center = BlockingReceiveNotificationCenter()
        let controller = ReceiveNotificationController(
            center: center,
            revealer: RecordingReceiveTargetRevealer(),
            deliveryTimeout: .milliseconds(20)
        )
        let firstFinished = expectation(description: "first notification returns at boundary")
        let first = Task { @MainActor in
            await controller.notify(receive: receiveResult(named: "first.pdf"))
            firstFinished.fulfill()
        }
        await center.waitUntilDeliveryStarts()

        await fulfillment(of: [firstFinished], timeout: 1)
        XCTAssertEqual(center.deliveryStartCount, 1)

        let secondFinished = expectation(description: "busy delivery fails without queueing")
        await controller.notify(receive: receiveResult(named: "second.pdf"))
        secondFinished.fulfill()
        await fulfillment(of: [secondFinished], timeout: 1)
        XCTAssertEqual(center.deliveryStartCount, 1)

        center.releaseDelivery()
        await first.value
        await center.waitUntilDeliveryFinishes()

        await controller.notify(receive: receiveResult(named: "third.pdf"))
        XCTAssertEqual(center.deliveryStartCount, 2)
        XCTAssertEqual(center.maximumConcurrentDeliveries, 1)
    }

    func testCancellingBlockedAuthorizationQueryReturnsWithoutWaitingForSystemCallback() async {
        let center = BlockingAuthorizationReceiveNotificationCenter()
        let controller = ReceiveNotificationController(
            center: center,
            revealer: RecordingReceiveTargetRevealer(),
            authorizationStatusTimeout: .seconds(30)
        )
        let refreshFinished = expectation(description: "cancelled refresh returns")
        let refresh = Task { @MainActor in
            await controller.refreshAuthorizationState()
            refreshFinished.fulfill()
        }
        await center.waitUntilAuthorizationQueryStarts()

        refresh.cancel()

        await fulfillment(of: [refreshFinished], timeout: 1)
        XCTAssertEqual(center.authorizationQueryCount, 1)
        center.releaseAuthorizationQuery(with: .authorized)
        await refresh.value
    }

    func testAuthorizationQueryTimeoutKeepsOneResidualSystemOperation() async {
        let center = ControllableReceiveNotificationCenter()
        let controller = ReceiveNotificationController(
            center: center,
            revealer: RecordingReceiveTargetRevealer(),
            authorizationStatusTimeout: .milliseconds(20)
        )

        await controller.refreshAuthorizationState()
        await controller.refreshAuthorizationState()

        XCTAssertEqual(center.authorizationQueryCount, 1)
        center.resolveAuthorizationQuery(at: 0, with: .denied)
        for _ in 0..<100 { await Task.yield() }

        let recovered = Task { @MainActor in
            await controller.refreshAuthorizationState()
        }
        await waitForAuthorizationQueries(2, in: center)
        center.resolveAuthorizationQuery(at: 1, with: .authorized)
        await recovered.value

        XCTAssertEqual(center.authorizationQueryCount, 2)
        var snapshots = controller.snapshots().makeAsyncIterator()
        let current = await snapshots.next()
        XCTAssertEqual(current?.authorizationState, .authorized)
    }

    func testAuthorizationRequestTimeoutKeepsOneResidualSystemOperation() async {
        let center = ControllableReceiveNotificationCenter()
        let controller = ReceiveNotificationController(
            center: center,
            revealer: RecordingReceiveTargetRevealer(),
            authorizationPromptTimeout: .milliseconds(20)
        )

        let first = Task { @MainActor in
            await controller.prepare()
        }
        await waitForAuthorizationQueries(1, in: center)
        center.resolveAuthorizationQuery(at: 0, with: .notDetermined)
        await waitForAuthorizationRequests(1, in: center)
        await first.value

        await controller.prepare()
        XCTAssertEqual(center.authorizationRequestCount, 1)
        center.resolveAuthorizationRequest(at: 0, with: .authorized)
        for _ in 0..<100 { await Task.yield() }

        XCTAssertEqual(center.authorizationRequestCount, 1)
    }

    func testWorkspaceRevealerSelectsAnExistingSingleFile() {
        let workspace = RecordingReceiveWorkspace()
        let file = URL(fileURLWithPath: "/Downloads/report.pdf")
        let revealer = WorkspaceReceiveTargetRevealer(
            workspace: workspace,
            fileExists: { $0 == file }
        )

        XCTAssertTrue(revealer.reveal([file], fallbackDirectory: nil))

        XCTAssertEqual(workspace.selectedURLs, [[file]])
        XCTAssertTrue(workspace.openedURLs.isEmpty)
    }

    func testWorkspaceRevealerOpensCommonDirectoryForMultipleFiles() {
        let workspace = RecordingReceiveWorkspace()
        let directory = URL(fileURLWithPath: "/Downloads")
        let first = directory.appendingPathComponent("report.pdf")
        let second = directory.appendingPathComponent("notes.txt")
        let revealer = WorkspaceReceiveTargetRevealer(
            workspace: workspace,
            fileExists: { $0 == directory || $0 == first || $0 == second }
        )

        XCTAssertTrue(revealer.reveal([first, second], fallbackDirectory: nil))

        XCTAssertTrue(workspace.selectedURLs.isEmpty)
        XCTAssertEqual(workspace.openedURLs, [directory])
    }

    func testWorkspaceRevealerUsesCurrentReceiveDirectoryWhenSingleFileIsMissing() {
        let workspace = RecordingReceiveWorkspace()
        let oldDirectory = URL(fileURLWithPath: "/Downloads/Old")
        let currentDirectory = URL(fileURLWithPath: "/Volumes/Current Receives")
        let movedFile = oldDirectory.appendingPathComponent("moved.pdf")
        let revealer = WorkspaceReceiveTargetRevealer(
            workspace: workspace,
            fileExists: {
                $0.standardizedFileURL.path == currentDirectory.path
                    || $0.standardizedFileURL.path == oldDirectory.path
            }
        )

        XCTAssertTrue(
            revealer.reveal([movedFile], fallbackDirectory: currentDirectory)
        )

        XCTAssertTrue(workspace.selectedURLs.isEmpty)
        XCTAssertEqual(workspace.openedURLs.map(\.path), [currentDirectory.path])
    }

    func testWorkspaceRevealerUsesCurrentDirectoryWhenAnyFileInBatchIsMissing() {
        let workspace = RecordingReceiveWorkspace()
        let oldDirectory = URL(fileURLWithPath: "/Downloads/Old")
        let currentDirectory = URL(fileURLWithPath: "/Downloads/Current")
        let present = oldDirectory.appendingPathComponent("present.pdf")
        let missing = oldDirectory.appendingPathComponent("missing.pdf")
        let revealer = WorkspaceReceiveTargetRevealer(
            workspace: workspace,
            fileExists: { $0 == oldDirectory || $0 == present || $0 == currentDirectory }
        )

        XCTAssertTrue(
            revealer.reveal([present, missing], fallbackDirectory: currentDirectory)
        )

        XCTAssertTrue(workspace.selectedURLs.isEmpty)
        XCTAssertEqual(workspace.openedURLs, [currentDirectory])
    }

    func testWorkspaceRevealerUsesCurrentDirectoryWhenEveryFileInBatchIsMissing() {
        let workspace = RecordingReceiveWorkspace()
        let oldDirectory = URL(fileURLWithPath: "/Downloads/Old")
        let currentDirectory = URL(fileURLWithPath: "/Downloads/Current")
        let revealer = WorkspaceReceiveTargetRevealer(
            workspace: workspace,
            fileExists: { $0 == oldDirectory || $0 == currentDirectory }
        )

        XCTAssertTrue(
            revealer.reveal(
                [
                    oldDirectory.appendingPathComponent("first.pdf"),
                    oldDirectory.appendingPathComponent("second.pdf"),
                ],
                fallbackDirectory: currentDirectory
            )
        )

        XCTAssertEqual(workspace.openedURLs, [currentDirectory])
    }

    func testWorkspaceRevealerFailsOnlyWhenFilesAndCurrentDirectoryAreUnavailable() {
        let workspace = RecordingReceiveWorkspace()
        let revealer = WorkspaceReceiveTargetRevealer(
            workspace: workspace,
            fileExists: { _ in false }
        )

        XCTAssertFalse(
            revealer.reveal(
                [URL(fileURLWithPath: "/Downloads/missing.pdf")],
                fallbackDirectory: URL(fileURLWithPath: "/Downloads/Current")
            )
        )
        XCTAssertTrue(workspace.selectedURLs.isEmpty)
        XCTAssertTrue(workspace.openedURLs.isEmpty)
    }

    func testUnknownNotificationIdentifierDoesNotRevealAnyTarget() {
        let finder = RecordingReceiveTargetRevealer()
        let controller = ReceiveNotificationController(
            center: RecordingReceiveNotificationCenter(status: .authorized),
            revealer: finder
        )
        var opened: [TransferID] = []
        controller.onReceiveOpened = { opened.append($0) }

        controller.openNotification(identifier: "dropmesh.receive.unknown")

        XCTAssertTrue(finder.revealedURLs.isEmpty)
        XCTAssertTrue(opened.isEmpty)
    }

    func testNotificationIdentifierCanRevealItsTargetOnlyOnce() async throws {
        let center = RecordingReceiveNotificationCenter(status: .authorized)
        let finder = RecordingReceiveTargetRevealer()
        let controller = ReceiveNotificationController(center: center, revealer: finder)
        let file = URL(fileURLWithPath: "/tmp/Downloads/plan.pdf")
        let result = TransferReceiveResult(
            transferID: TransferID(rawValue: UUID()),
            receivedURLs: [file]
        )
        var opened: [TransferID] = []
        controller.onReceiveOpened = { opened.append($0) }

        await controller.notify(receive: result)

        let identifier = try XCTUnwrap(center.requests.first?.identifier)
        controller.openNotification(identifier: identifier)
        controller.openNotification(identifier: identifier)

        XCTAssertEqual(finder.revealedURLs, [[file]])
        XCTAssertEqual(opened, [result.transferID])
    }

    func testNotificationAcknowledgesOnceWhenFinderCannotRevealTheTarget() async throws {
        let center = RecordingReceiveNotificationCenter(status: .authorized)
        let finder = RecordingReceiveTargetRevealer(revealResult: false)
        let controller = ReceiveNotificationController(center: center, revealer: finder)
        let result = TransferReceiveResult(
            transferID: TransferID(rawValue: UUID()),
            receivedURLs: [URL(fileURLWithPath: "/tmp/Downloads/plan.pdf")]
        )
        var opened: [TransferID] = []
        controller.onReceiveOpened = { opened.append($0) }

        await controller.notify(receive: result)
        let identifier = try XCTUnwrap(center.requests.first?.identifier)
        controller.openNotification(identifier: identifier)
        controller.openNotification(identifier: identifier)

        XCTAssertEqual(finder.revealedURLs, [result.receivedURLs])
        XCTAssertEqual(opened, [result.transferID])
    }

    func testNotificationBeyondURLCacheCapacityAcknowledgesAndOpensSourceDirectory() async throws {
        let center = RecordingReceiveNotificationCenter(status: .authorized)
        let finder = RecordingReceiveTargetRevealer()
        let source = DeviceID(rawValue: UUID())
        let fallback = URL(fileURLWithPath: "/Downloads/Source Override")
        let resolver = RecordingReceiveDirectoryResolver(directories: [source: fallback])
        let controller = ReceiveNotificationController(
            center: center,
            revealer: finder,
            receiveDirectoryResolver: resolver,
            notificationTargetCapacity: 2
        )
        var results: [TransferReceiveResult] = []
        var opened: [TransferID] = []
        controller.onReceiveOpened = { opened.append($0) }

        for index in 0..<3 {
            let result = TransferReceiveResult(
                transferID: TransferID(rawValue: UUID()),
                receivedURLs: [URL(fileURLWithPath: "/tmp/Downloads/\(index).bin")],
                source: source
            )
            results.append(result)
            await controller.notify(receive: result)
        }

        controller.openNotification(identifier: center.requests[0].identifier)
        controller.openNotification(identifier: center.requests[0].identifier)

        XCTAssertEqual(finder.requests.map(\.urls), [[]])
        XCTAssertEqual(finder.requests.map(\.fallbackDirectory), [fallback])
        XCTAssertEqual(resolver.requestedSources, [source])
        XCTAssertEqual(opened, [results[0].transferID])
    }

    func testNotificationAfterURLCacheTTLStillAcknowledgesOnceAndOpensCurrentDirectory()
        async throws
    {
        var now = Date(timeIntervalSince1970: 1_000)
        let center = RecordingReceiveNotificationCenter(status: .authorized)
        let finder = RecordingReceiveTargetRevealer()
        let fallback = URL(fileURLWithPath: "/Downloads/Current")
        let resolver = RecordingReceiveDirectoryResolver(defaultDirectory: fallback)
        let controller = ReceiveNotificationController(
            center: center,
            revealer: finder,
            receiveDirectoryResolver: resolver,
            notificationTargetTTL: 60,
            now: { now }
        )
        let result = TransferReceiveResult(
            transferID: TransferID(rawValue: UUID()),
            receivedURLs: [URL(fileURLWithPath: "/tmp/Downloads/plan.pdf")]
        )
        var opened: [TransferID] = []
        controller.onReceiveOpened = { opened.append($0) }
        await controller.notify(receive: result)
        let identifier = try XCTUnwrap(center.requests.first?.identifier)

        now.addTimeInterval(61)
        controller.openNotification(identifier: identifier)
        controller.openNotification(identifier: identifier)

        XCTAssertEqual(finder.requests.map(\.urls), [[]])
        XCTAssertEqual(finder.requests.map(\.fallbackDirectory), [fallback])
        XCTAssertEqual(opened, [result.transferID])
    }

    func testNotificationCanBeHandledAfterControllerReconstruction() async throws {
        let center = RecordingReceiveNotificationCenter(status: .authorized)
        let source = DeviceID(rawValue: UUID())
        let transferID = TransferID(rawValue: UUID())
        let sourceDirectory = URL(fileURLWithPath: "/Downloads/Source Override")
        let result = TransferReceiveResult(
            transferID: transferID,
            receivedURLs: [URL(fileURLWithPath: "/private/old/file.pdf")],
            source: source
        )
        let deliveringController = ReceiveNotificationController(
            center: center,
            revealer: RecordingReceiveTargetRevealer()
        )
        await deliveringController.notify(receive: result)
        let identifier = try XCTUnwrap(center.requests.first?.identifier)

        let finder = RecordingReceiveTargetRevealer()
        let resolver = RecordingReceiveDirectoryResolver(directories: [source: sourceDirectory])
        let reconstructedController = ReceiveNotificationController(
            center: center,
            revealer: finder,
            receiveDirectoryResolver: resolver
        )
        var opened: [TransferID] = []
        reconstructedController.onReceiveOpened = { opened.append($0) }

        reconstructedController.openNotification(identifier: identifier)
        reconstructedController.openNotification(identifier: identifier)

        XCTAssertEqual(finder.requests.map(\.urls), [[]])
        XCTAssertEqual(finder.requests.map(\.fallbackDirectory), [sourceDirectory])
        XCTAssertEqual(resolver.requestedSources, [source])
        XCTAssertEqual(opened, [transferID])
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

    private func receiveResult(named name: String) -> TransferReceiveResult {
        TransferReceiveResult(
            transferID: TransferID(rawValue: UUID()),
            receivedURLs: [URL(fileURLWithPath: "/tmp/Downloads/\(name)")]
        )
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
    struct Request: Equatable {
        let urls: [URL]
        let fallbackDirectory: URL?
    }

    private(set) var requests: [Request] = []
    var revealedURLs: [[URL]] { requests.map(\.urls) }
    private let revealResult: Bool

    init(revealResult: Bool = true) {
        self.revealResult = revealResult
    }

    func reveal(_ urls: [URL], fallbackDirectory: URL?) -> Bool {
        requests.append(Request(urls: urls, fallbackDirectory: fallbackDirectory))
        return revealResult
    }
}

@MainActor
private final class RecordingReceiveDirectoryResolver: ReceiveDirectoryResolving {
    private let defaultDirectory: URL?
    private let directories: [DeviceID: URL]
    private(set) var requestedSources: [DeviceID?] = []

    init(defaultDirectory: URL? = nil, directories: [DeviceID: URL] = [:]) {
        self.defaultDirectory = defaultDirectory
        self.directories = directories
    }

    func currentReceiveDirectory(for source: DeviceID?) -> URL? {
        requestedSources.append(source)
        return source.flatMap { directories[$0] } ?? defaultDirectory
    }
}

@MainActor
private final class RecordingReceiveWorkspace: ReceiveWorkspaceOpening {
    private(set) var selectedURLs: [[URL]] = []
    private(set) var openedURLs: [URL] = []

    func select(_ urls: [URL]) {
        selectedURLs.append(urls)
    }

    func open(_ url: URL) {
        openedURLs.append(url)
    }
}

@MainActor
private final class BlockingReceiveNotificationCenter: ReceiveNotificationCenter {
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private var released = false
    private var firstDelivery = true
    private var activeDeliveries = 0
    private(set) var deliveryStartCount = 0
    private(set) var maximumConcurrentDeliveries = 0

    func authorizationState() async -> ReceiveNotificationAuthorizationState { .authorized }
    func requestAuthorization() async -> ReceiveNotificationAuthorizationState { .authorized }

    func deliver(_ request: ReceiveNotificationRequest) async throws {
        deliveryStartCount += 1
        activeDeliveries += 1
        maximumConcurrentDeliveries = max(maximumConcurrentDeliveries, activeDeliveries)
        if firstDelivery {
            firstDelivery = false
            startContinuation?.resume()
            startContinuation = nil
            if !released {
                await withCheckedContinuation { releaseContinuation = $0 }
            }
        }
        activeDeliveries -= 1
        finishContinuation?.resume()
        finishContinuation = nil
    }

    func waitUntilDeliveryStarts() async {
        guard deliveryStartCount == 0 else { return }
        await withCheckedContinuation { startContinuation = $0 }
    }

    func releaseDelivery() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func waitUntilDeliveryFinishes() async {
        guard activeDeliveries > 0 else { return }
        await withCheckedContinuation { finishContinuation = $0 }
    }

    func openSystemSettings() {}
}

@MainActor
private final class BlockingAuthorizationReceiveNotificationCenter: ReceiveNotificationCenter {
    private var queryContinuation: CheckedContinuation<ReceiveNotificationAuthorizationState, Never>?
    private var startContinuation: CheckedContinuation<Void, Never>?
    private(set) var authorizationQueryCount = 0

    func authorizationState() async -> ReceiveNotificationAuthorizationState {
        authorizationQueryCount += 1
        startContinuation?.resume()
        startContinuation = nil
        return await withCheckedContinuation { queryContinuation = $0 }
    }

    func waitUntilAuthorizationQueryStarts() async {
        guard authorizationQueryCount == 0 else { return }
        await withCheckedContinuation { startContinuation = $0 }
    }

    func releaseAuthorizationQuery(with state: ReceiveNotificationAuthorizationState) {
        queryContinuation?.resume(returning: state)
        queryContinuation = nil
    }

    func requestAuthorization() async -> ReceiveNotificationAuthorizationState { .denied }
    func deliver(_ request: ReceiveNotificationRequest) async throws {}
    func openSystemSettings() {}
}

private enum TestError: Error {
    case deliveryUnavailable
}
