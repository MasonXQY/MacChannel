import AppKit
import XCTest
@testable import MacChannelCore

final class DropIntentTests: XCTestCase {
    func testDropIntentAcceptsFileURLsAndRejectsRemoteURLs() throws {
        XCTAssertEqual(
            try DropIntent(items: [.fileURL(URL(fileURLWithPath: "/tmp/a"))]).urls,
            [URL(fileURLWithPath: "/tmp/a")]
        )
        XCTAssertThrowsError(
            try DropIntent(items: [.url(URL(string: "https://example.com")!)])
        )
        XCTAssertThrowsError(
            try DropIntent(items: [.fileURL(URL(string: "file://server/share/a")!)])
        )
    }

    @MainActor
    func testPasteboardAcceptsOnlyReadableLocalFileURLs() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let first = URL(fileURLWithPath: "/tmp/first.txt")
        let second = URL(fileURLWithPath: "/tmp/second.txt")

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([first as NSURL, second as NSURL]))

        XCTAssertEqual(try DropIntent(pasteboard: pasteboard).urls, [first, second])
    }

    @MainActor
    func testPasteboardRejectsRemoteAndEmptyPayloads() {
        let remotePasteboard = NSPasteboard.withUniqueName()
        defer { remotePasteboard.releaseGlobally() }
        remotePasteboard.clearContents()
        remotePasteboard.setString("https://example.com/file", forType: .URL)

        XCTAssertThrowsError(try DropIntent(pasteboard: remotePasteboard))

        let emptyPasteboard = NSPasteboard.withUniqueName()
        defer { emptyPasteboard.releaseGlobally() }
        XCTAssertThrowsError(try DropIntent(pasteboard: emptyPasteboard))
    }

    @MainActor
    func testDragExitCancelsReadySessionWithoutClaimingSource() throws {
        let intent = try DropIntent(items: [.fileURL(URL(fileURLWithPath: "/tmp/a"))])
        var state = StatusItemDropStateMachine()

        let token = try XCTUnwrap(state.begin(intent: intent))
        XCTAssertEqual(state.phase, .ready)

        state.cancelDrag(token: token)

        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.claimDrop(token: token, target: DeviceID(rawValue: UUID())))
    }

    @MainActor
    func testValidTargetCanClaimDropExactlyOnce() throws {
        let url = URL(fileURLWithPath: "/tmp/a")
        let target = DeviceID(rawValue: UUID())
        var state = StatusItemDropStateMachine()
        let token = try XCTUnwrap(
            state.begin(intent: DropIntent(items: [.fileURL(url)]))
        )

        XCTAssertEqual(
            state.claimDrop(token: token, target: target),
            StatusItemDropClaim(token: token, urls: [url], target: target)
        )
        XCTAssertEqual(state.phase, .transferring(progress: 0))
        XCTAssertNil(state.claimDrop(token: token, target: target))

        state.cancelDrag(token: token)
        XCTAssertEqual(state.phase, .transferring(progress: 0))

        state.updateProgress(token: token, progress: 0.42)
        XCTAssertEqual(state.phase, .transferring(progress: 0.42))
        state.finishTransfer(token: token)
        XCTAssertEqual(state.phase, .idle)
    }

    @MainActor
    func testReentrantBeginInvalidatesStaleCallbacks() throws {
        let first = try DropIntent(items: [.fileURL(URL(fileURLWithPath: "/tmp/first"))])
        let second = try DropIntent(items: [.fileURL(URL(fileURLWithPath: "/tmp/second"))])
        let target = DeviceID(rawValue: UUID())
        var state = StatusItemDropStateMachine()

        let staleToken = try XCTUnwrap(state.begin(intent: first))
        let currentToken = try XCTUnwrap(state.begin(intent: second))
        state.cancelDrag(token: staleToken)

        XCTAssertEqual(state.phase, .ready)
        XCTAssertNil(state.claimDrop(token: staleToken, target: target))
        XCTAssertEqual(
            state.claimDrop(token: currentToken, target: target)?.urls,
            second.urls
        )

        state.finishTransfer(token: staleToken)
        XCTAssertEqual(state.phase, .transferring(progress: 0))
    }

    func testStatusItemPresentationIsTextualAndAccessibleForEveryPhase() {
        XCTAssertEqual(StatusItemPhase.idle.presentation.accessibilityValue, "Idle")
        XCTAssertEqual(StatusItemPhase.ready.presentation.title, "Ready")
        XCTAssertEqual(
            StatusItemPhase.ready.presentation.accessibilityValue,
            "Ready to choose a device"
        )

        let transfer = StatusItemPhase.transferring(progress: 0.42).presentation
        XCTAssertEqual(transfer.title, "42%")
        XCTAssertEqual(transfer.accessibilityValue, "Transferring, 42 percent")
        XCTAssertEqual(transfer.progress, 0.42)
    }
}
