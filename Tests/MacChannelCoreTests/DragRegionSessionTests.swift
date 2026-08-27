import XCTest
@testable import MacChannelCore

final class DragRegionSessionTests: XCTestCase {
    @MainActor
    func testIconExitThenFanEntryPreservesLeaseUntilFanExits() throws {
        let scheduler = ManualDragRegionScheduler()
        let session = DragRegionSession(
            grace: .milliseconds(100),
            schedule: scheduler.schedule
        )
        let token = try makeToken()
        let fingerprint = StatusItemDragFingerprint(sequenceNumber: 7, pasteboardChangeCount: 11)
        var expired: [StatusItemDragToken] = []
        session.onExpired = { expired.append($0) }

        session.begin(token: token, fingerprint: fingerprint, in: .icon)
        XCTAssertTrue(session.exit(.icon, token: token, fingerprint: fingerprint))
        XCTAssertTrue(session.enter(.fan, token: token, fingerprint: fingerprint))
        scheduler.advance(by: .milliseconds(100), includingCancelled: true)
        XCTAssertTrue(expired.isEmpty)

        XCTAssertTrue(session.exit(.fan, token: token, fingerprint: fingerprint))
        scheduler.advance(by: .milliseconds(99), includingCancelled: true)
        XCTAssertTrue(expired.isEmpty)
        scheduler.advance(by: .milliseconds(1), includingCancelled: true)
        XCTAssertEqual(expired, [token])
    }

    @MainActor
    func testFanExitThenIconReentryPreservesLeaseUntilIconExits() throws {
        let scheduler = ManualDragRegionScheduler()
        let session = DragRegionSession(schedule: scheduler.schedule)
        let token = try makeToken()
        let fingerprint = StatusItemDragFingerprint(sequenceNumber: 8, pasteboardChangeCount: 12)
        var expired = false
        session.onExpired = { _ in expired = true }

        session.begin(token: token, fingerprint: fingerprint, in: .fan)
        XCTAssertTrue(session.exit(.fan, token: token, fingerprint: fingerprint))
        XCTAssertTrue(session.enter(.icon, token: token, fingerprint: fingerprint))
        scheduler.advance(by: .milliseconds(120), includingCancelled: true)
        XCTAssertFalse(expired)

        XCTAssertTrue(session.exit(.icon, token: token, fingerprint: fingerprint))
        scheduler.advance(by: .milliseconds(120), includingCancelled: true)
        XCTAssertTrue(expired)
    }

    @MainActor
    func testStaleTokenFingerprintAndExitGenerationCannotExpireCurrentLease() throws {
        let scheduler = ManualDragRegionScheduler()
        let session = DragRegionSession(schedule: scheduler.schedule)
        let firstToken = try makeToken(path: "/tmp/first")
        let currentToken = try makeToken(path: "/tmp/current")
        let firstFingerprint = StatusItemDragFingerprint(
            sequenceNumber: 1,
            pasteboardChangeCount: 1
        )
        let currentFingerprint = StatusItemDragFingerprint(
            sequenceNumber: 2,
            pasteboardChangeCount: 2
        )
        var expired: [StatusItemDragToken] = []
        session.onExpired = { expired.append($0) }

        session.begin(token: firstToken, fingerprint: firstFingerprint, in: .icon)
        _ = session.exit(.icon, token: firstToken, fingerprint: firstFingerprint)
        session.begin(token: currentToken, fingerprint: currentFingerprint, in: .icon)

        XCTAssertFalse(session.exit(.icon, token: firstToken, fingerprint: firstFingerprint))
        XCTAssertFalse(session.exit(.icon, token: currentToken, fingerprint: firstFingerprint))
        scheduler.advance(by: .milliseconds(120), includingCancelled: true)
        XCTAssertTrue(expired.isEmpty)

        XCTAssertTrue(session.exit(.icon, token: currentToken, fingerprint: currentFingerprint))
        XCTAssertTrue(session.enter(.fan, token: currentToken, fingerprint: currentFingerprint))
        scheduler.advance(by: .milliseconds(120), includingCancelled: true)
        XCTAssertTrue(expired.isEmpty)
    }

    @MainActor
    private func makeToken(path: String = "/tmp/a") throws -> StatusItemDragToken {
        var state = StatusItemDropStateMachine()
        return try XCTUnwrap(
            state.begin(
                intent: DropIntent(items: [.fileURL(URL(fileURLWithPath: path))])
            )
        )
    }
}

@MainActor
final class ManualDragRegionScheduler {
    private struct Entry {
        let deadline: Duration
        let cancellation: ManualDragRegionCancellation
        let action: @MainActor () -> Void
    }

    private var now: Duration = .zero
    private var entries: [Entry] = []

    func schedule(
        _ delay: Duration,
        _ action: @escaping @MainActor () -> Void
    ) -> any DragRegionCancellation {
        let cancellation = ManualDragRegionCancellation()
        entries.append(
            Entry(deadline: now + delay, cancellation: cancellation, action: action)
        )
        return cancellation
    }

    func advance(by duration: Duration, includingCancelled: Bool = false) {
        now += duration
        let due = entries.filter { $0.deadline <= now }
        entries.removeAll { $0.deadline <= now }
        for entry in due where includingCancelled || !entry.cancellation.isCancelled {
            entry.action()
        }
    }
}

@MainActor
final class ManualDragRegionCancellation: DragRegionCancellation {
    private(set) var isCancelled = false

    func cancel() {
        isCancelled = true
    }
}
