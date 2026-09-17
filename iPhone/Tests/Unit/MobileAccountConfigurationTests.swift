import XCTest
@testable import DropMeshTestHost

final class MobileAccountConfigurationTests: XCTestCase {
    func testMissingOriginDisablesAccountWithoutGuessingAnEndpoint() throws {
        XCTAssertNil(try MobileAccountConfiguration.load(info: [:], bundleIdentifier: "com.example.app"))
    }

    func testPresentEmptyOrNonStringOriginFailsClosed() {
        XCTAssertThrowsError(try MobileAccountConfiguration.load(
            info: ["DropMeshAccountServiceOrigin": ""], bundleIdentifier: "com.example.app"))
        XCTAssertThrowsError(try MobileAccountConfiguration.load(
            info: ["DropMeshAccountServiceOrigin": 42], bundleIdentifier: "com.example.app"))
    }

    func testConfiguredOriginUsesBundleIdentifierAsAudience() throws {
        let value = try XCTUnwrap(MobileAccountConfiguration.load(
            info: ["DropMeshAccountServiceOrigin": "https://accounts.example.com"],
            bundleIdentifier: "com.example.app"))
        XCTAssertEqual(value.origin, URL(string: "https://accounts.example.com"))
        XCTAssertEqual(value.audience, "com.example.app")
    }

    func testInvalidOriginOrAudienceFailsClosed() {
        XCTAssertThrowsError(try MobileAccountConfiguration.load(
            info: ["DropMeshAccountServiceOrigin": "http://accounts.example.com"], bundleIdentifier: "com.example.app"))
        XCTAssertThrowsError(try MobileAccountConfiguration.load(
            info: ["DropMeshAccountServiceOrigin": "https://accounts.example.com/path"], bundleIdentifier: ""))
    }
}
