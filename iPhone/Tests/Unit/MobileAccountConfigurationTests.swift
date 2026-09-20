import XCTest
@testable import DropMeshTestHost

final class MobileAccountConfigurationTests: XCTestCase {
    func testGroupCapabilityDefaultsOffAndAcceptsOnlyBoolean() throws {
        let origin = "https://accounts.example.com"
        for enabled in [true, false] {
            let value = try XCTUnwrap(MobileAccountConfiguration.load(info: [
                "DropMeshAccountServiceOrigin": origin, "DropMeshAccountGroupsEnabled": enabled
            ], bundleIdentifier: "com.example.app"))
            XCTAssertEqual(value.groupsEnabled, enabled)
        }
        let absent = try XCTUnwrap(MobileAccountConfiguration.load(info: ["DropMeshAccountServiceOrigin": origin],
                                                                  bundleIdentifier: "com.example.app"))
        XCTAssertFalse(absent.groupsEnabled)
        XCTAssertNil(try MobileAccountConfiguration.load(info: ["DropMeshAccountGroupsEnabled": "true"],
                                                        bundleIdentifier: "com.example.app"))
    }
    func testGroupCapabilityRejectsStringsAndNumbers() {
        for value: Any in ["true", "false", 1, 0, NSNumber(value: 1), NSNull()] {
            XCTAssertThrowsError(try MobileAccountConfiguration.load(info: [
                "DropMeshAccountServiceOrigin": "https://accounts.example.com",
                "DropMeshAccountGroupsEnabled": value
            ], bundleIdentifier: "com.example.app"))
        }
    }
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
