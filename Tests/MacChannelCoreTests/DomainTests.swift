import XCTest
@testable import MacChannelCore

final class DomainTests: XCTestCase {
    func testTransferStateRoundTripsThroughJSON() throws {
        let value = TransferSnapshot(
            id: TransferID(rawValue: UUID()),
            peer: DeviceID(rawValue: UUID()),
            phase: .transferring,
            completedBytes: 512,
            totalBytes: 1024,
            route: .lan
        )

        XCTAssertEqual(
            value,
            try JSONDecoder().decode(
                TransferSnapshot.self,
                from: JSONEncoder().encode(value)
            )
        )
    }
}
