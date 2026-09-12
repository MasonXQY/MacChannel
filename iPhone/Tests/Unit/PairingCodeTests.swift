import XCTest
@testable import DropMesh

final class PairingCodeTests: XCTestCase {
    func testValidationAcceptsExactlySixASCIIDigitsIncludingLeadingZero() {
        XCTAssertEqual(PairingCode("012345")?.value, "012345")
    }

    func testValidationRejectsEmptyNonDigitShortAndLongValues() {
        XCTAssertNil(PairingCode(""))
        XCTAssertNil(PairingCode("12a456"))
        XCTAssertNil(PairingCode("１２３４５６"))
        XCTAssertNil(PairingCode("12345"))
        XCTAssertNil(PairingCode("1234567"))
    }

    @MainActor
    func testModelDisablesSubmitForInvalidAndOverlongPastedCodes() {
        let model = PairingModel(makeAttempt: { throw CancellationError() })
        for invalid in ["", "12345", "1234567", "12a456", "１２３４５６"] {
            model.code = invalid
            XCTAssertFalse(model.canSubmit, "Expected invalid code: \(invalid)")
        }
        model.code = "012345"
        XCTAssertTrue(model.canSubmit)
    }
}
