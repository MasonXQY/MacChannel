import XCTest
import MacChannelCore
@testable import DropMeshTestHost

@MainActor
final class MobileHistoryDeletionTests: XCTestCase {
    func testClearAllKeepsActiveTransfer() async {
        let session = InertMobileSession()
        let finished = row(peer: session.peer.id)
        let active = row(peer: session.peer.id, phase: .transferring)
        await session.setHistory([finished, active])
        let model = MobileHistoryModel(session: session)
        await model.refresh()
        let deleted = await model.deleteRecords(ids: nil)
        XCTAssertTrue(deleted)
        XCTAssertEqual(model.entries.map(\.id), [active.id])
    }
    func testOlderRefreshCannotRestoreDeletedRecord() async {
        let session = InertMobileSession()
        await session.setHistory([row(peer: session.peer.id)])
        let model = MobileHistoryModel(session: session)
        await model.refresh()
        let gate = DeletionRefreshGate()
        await session.setBeforeHistory { await gate.waitOnce() }
        let stale = Task { await model.refresh() }
        await gate.waitForEntry()
        let deleted = await model.deleteRecords(ids: nil)
        XCTAssertTrue(deleted)
        await gate.release()
        await stale.value
        XCTAssertTrue(model.entries.isEmpty)
    }
    func testDeleteSelectedRemovesOnlyConfirmedRecord() async {
        let session = InertMobileSession()
        let first = row(peer: session.peer.id)
        let second = row(peer: session.peer.id)
        await session.setHistory([first, second])
        let model = MobileHistoryModel(session: session)
        await model.refresh()
        let deleted = await model.deleteRecords(ids: [first.id])
        XCTAssertTrue(deleted)
        XCTAssertEqual(model.entries.map(\.id), [second.id])
        await model.refresh()
        XCTAssertEqual(model.entries.map(\.id), [second.id])
    }
    func testDeleteFailurePreservesHistoryAndShowsError() async {
        let session = InertMobileSession()
        let first = row(peer: session.peer.id)
        await session.setHistory([first])
        await session.setHistoryDeleteFailure(true)
        let model = MobileHistoryModel(session: session)
        await model.refresh()
        let deleted = await model.deleteRecords(ids: nil)
        XCTAssertFalse(deleted)
        XCTAssertTrue(model.deleteFailed)
        XCTAssertEqual(model.entries.map(\.id), [first.id])
    }
    private func row(peer: DeviceID, phase: TransferPhase = .completed) -> MobileHistoryEntry {
        MobileHistoryEntry(id: TransferID(rawValue: UUID()), peer: peer, displayName: "kept-file.txt",
            aggregateSize: 1, completedBytes: 1, updatedAt: Date(), route: .lan,
            phase: phase, direction: .inbound, isAvailable: true)
    }
}

private actor DeletionRefreshGate {
    private var entered = false
    private var released = false
    func waitOnce() async {
        guard !entered else { return }; entered = true
        let deadline = ContinuousClock.now + .seconds(5)
        while !released && ContinuousClock.now < deadline { await Task.yield() }
    }
    func waitForEntry() async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !entered && ContinuousClock.now < deadline { await Task.yield() }
    }
    func release() { released = true }
}
