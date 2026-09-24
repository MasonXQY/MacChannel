import XCTest
@testable import MacChannelCore
@testable import MacChannelAppKit

@MainActor
final class RuntimePresencePresentationTests: XCTestCase {
    func testStorageWarningDoesNotTurnAuthenticatedSocketOffline() async {
        let source = RuntimeStatusSource()
        source.updatePresence(.online)
        source.updateTrustSync(.pendingPersistence)
        source.yield(.serviceError(.statusTrustSaveFailed))
        source.yield(.ready)
        var updates = source.presenceStream.makeAsyncIterator()
        let snapshot = await updates.next()
        XCTAssertEqual(snapshot?.authenticated, true)
        XCTAssertEqual(snapshot?.trustSync, .pendingPersistence)
        XCTAssertEqual(snapshot?.trustSaveFailed, true)
        source.updatePresence(.reconnecting)
        let reconnecting = await updates.next()
        XCTAssertEqual(reconnecting?.authenticated, false)
        XCTAssertEqual(reconnecting?.trustSync, .idle)
        source.finish()
    }

    func testManualSaveRetryIsJoinedAndCannotPublishAfterStop() async {
        let owner = RuntimeTrustSaveRetry()
        let release = AsyncStream<Void>.makeStream()
        defer { release.continuation.finish() }
        let entered = expectation(description: "save entered")
        let stopEntered = expectation(description: "stop requested")
        var didPublish = false
        let saving = Task {
            await owner.run(save: {
                entered.fulfill()
                for await _ in release.stream { break }
            },
                completed: { _ in didPublish = true })
        }
        await fulfillment(of: [entered], timeout: 2)
        var stopped = false
        let stopping = Task { stopEntered.fulfill(); await owner.stop(); stopped = true }
        await fulfillment(of: [stopEntered], timeout: 2)
        XCTAssertFalse(stopped)
        release.continuation.finish()
        await stopping.value
        await saving.value
        XCTAssertTrue(stopped)
        XCTAssertFalse(didPublish)
    }
}
