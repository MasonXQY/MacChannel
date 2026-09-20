import Foundation

/// Share one instance across the two foreground WebRTC listeners. A permit
/// accounts for an acceptance until its factory and any late channel close return.
public final class WebRTCAcceptanceBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var peers: [UUID: DeviceID] = [:]

    public init() {}

    func acquire(for peer: DeviceID) -> UUID? {
        lock.withLock {
            guard peers.count < IncomingTransferCapacity.maximumUpstreamAcceptances,
                  peers.values.filter({ $0 == peer }).count < 2 else { return nil }
            let permit = UUID()
            peers[permit] = peer
            return permit
        }
    }

    func release(_ permit: UUID) {
        _ = lock.withLock { peers.removeValue(forKey: permit) }
    }
}
