import XCTest
import MacChannelCore
@testable import DropMeshTestHost

final class MobileAccountConfigurationTests: XCTestCase {
    func testGroupsOnlyConfigurationCannotCreateAccountAuthorizationProducer() throws {
        let f = try AccountGroupEvidenceFixture()
        let owner = PeerAuthorizationOwner.live(identity: f.identity)
        var info: [String: Any] = ["DropMeshAccountServiceOrigin": f.binding.origin.absoluteString,
                                   "DropMeshAccountGroupsEnabled": true]
        let groupsOnly = try XCTUnwrap(MobileAccountConfiguration.load(info: info, bundleIdentifier: f.binding.audience))
        XCTAssertNil(try groupsOnly.makePeerAuthorization(owner: owner, identity: f.identity))
        XCTAssertTrue(owner.snapshot().peers.isEmpty)
        XCTAssertThrowsError(try owner.acquire(for: DeviceID(rawValue: UUID())))
        info["DropMeshAccountTransportOrigin"] = f.binding.origin.absoluteString
        let explicit = try XCTUnwrap(MobileAccountConfiguration.load(info: info, bundleIdentifier: f.binding.audience))
        XCTAssertNotNil(try explicit.makePeerAuthorization(owner: owner, identity: f.identity))
        XCTAssertTrue(owner.snapshot().peers.isEmpty, "Configuration alone must never mint account authority")
    }
    func testTransportIsExplicitAndMustMatchAccountOriginWithGroupsEnabled() throws {
        let origin = "https://accounts.example.com"
        let base: [String: Any] = ["DropMeshAccountServiceOrigin": origin, "DropMeshAccountGroupsEnabled": true]
        XCTAssertNil(try MobileAccountConfiguration.load(info: base, bundleIdentifier: "com.example.app")?.transportOrigin)
        var info = base
        info["DropMeshAccountTransportOrigin"] = origin
        XCTAssertEqual(try MobileAccountConfiguration.load(info: info, bundleIdentifier: "com.example.app")?.transportOrigin,
                       URL(string: origin))
        for value: Any in ["https://different.example.com", "http://accounts.example.com", "", 1] {
            info["DropMeshAccountTransportOrigin"] = value
            XCTAssertThrowsError(try MobileAccountConfiguration.load(info: info, bundleIdentifier: "com.example.app"))
        }
        info["DropMeshAccountTransportOrigin"] = origin
        info["DropMeshAccountGroupsEnabled"] = false
        XCTAssertThrowsError(try MobileAccountConfiguration.load(info: info, bundleIdentifier: "com.example.app"))
        XCTAssertThrowsError(try MobileAccountConfiguration.load(info: ["DropMeshAccountTransportOrigin": origin],
                                                                bundleIdentifier: "com.example.app"))
    }
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
