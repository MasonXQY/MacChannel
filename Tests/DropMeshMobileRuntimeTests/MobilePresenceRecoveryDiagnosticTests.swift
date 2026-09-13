import Foundation
import XCTest
@testable import DropMeshMobileRuntime

final class MobilePresenceRecoveryDiagnosticTests: XCTestCase {
    func testPresenceDiagnosticUsesOnlyClosedAvailabilityCategory() {
        XCTAssertEqual(MobileRuntimeConfiguration.diagnosticFrame(Data(#"{"type":"presence","availability":"internet","deviceID":"private-device-marker"}"#.utf8)), "peer_online")
        XCTAssertEqual(MobileRuntimeConfiguration.diagnosticFrame(Data(#"{"type":"presence","availability":"offline","deviceID":"private-device-marker"}"#.utf8)), "peer_offline")
        XCTAssertEqual(MobileRuntimeConfiguration.diagnosticFrame(Data(#"{"type":"presence","availability":"private-marker"}"#.utf8)), "other")
    }
}
