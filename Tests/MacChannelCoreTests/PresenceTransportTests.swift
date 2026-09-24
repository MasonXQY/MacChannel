import XCTest
@testable import MacChannelCore

final class PresenceTransportTests: XCTestCase {
    func testPingCompletionResumesOnlyOnceWhenURLSessionCallsBackTwice() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let completion = PresencePingCompletion(continuation)
            XCTAssertTrue(completion.resume(error: nil))
            XCTAssertFalse(completion.resume(error: PresenceTransportTestError.lateCancellation))
        }
    }
}

private enum PresenceTransportTestError: Error {
    case lateCancellation
}
