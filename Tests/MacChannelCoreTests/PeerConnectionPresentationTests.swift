import XCTest
@testable import MacChannelCore

final class PeerConnectionPresentationTests: XCTestCase {
    func testEntirePolicyTableAndStaleAvailability() {
        let states: [PresenceTrustSyncState] = [.idle, .synchronizing, .pendingPersistence, .synchronized, .needsAttention]
        for sync in states {
            for availability: DeviceAvailability? in [nil, .offline, .lan, .internet] {
                XCTAssertEqual(PeerConnectionPresentation.resolve(authenticated: false, sync: sync,
                    availability: availability), .statusPending)
            }
            XCTAssertEqual(PeerConnectionPresentation.resolve(authenticated: true, sync: sync, availability: .lan), .onlineNearby)
            XCTAssertEqual(PeerConnectionPresentation.resolve(authenticated: true, sync: sync, availability: .internet), .online)
            for availability: DeviceAvailability? in [nil, .offline] {
                let expected: PeerConnectionPresentation = switch sync {
                case .idle, .synchronizing: .syncingDevices
                case .pendingPersistence, .needsAttention: .statusPending
                case .synchronized: .currentlyUnreachable
                }
                XCTAssertEqual(PeerConnectionPresentation.resolve(authenticated: true, sync: sync,
                    availability: availability), expected)
            }
        }
    }

    func testNameFallbackDoesNotRewriteNonemptyNames() {
        XCTAssertEqual(PeerConnectionPresentation.displayName(" \n\t", unnamed: "Unnamed device"), "Unnamed device")
        XCTAssertEqual(PeerConnectionPresentation.displayName("", unnamed: "未命名设备"), "未命名设备")
        XCTAssertEqual(PeerConnectionPresentation.displayName("  Saved name  ", unnamed: "Unnamed device"), "  Saved name  ")
    }
}
