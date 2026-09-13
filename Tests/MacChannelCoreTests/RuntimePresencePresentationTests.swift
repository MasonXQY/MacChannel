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
        var release: CheckedContinuation<Void, Never>?
        var didPublish = false
        let saving = Task {
            await owner.run(save: { await withCheckedContinuation { release = $0 } },
                completed: { _ in didPublish = true })
        }
        while release == nil { await Task.yield() }
        var stopped = false
        let stopping = Task { await owner.stop(); stopped = true }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(stopped)
        release?.resume()
        await stopping.value
        await saving.value
        XCTAssertTrue(stopped)
        XCTAssertFalse(didPublish)
    }
}
