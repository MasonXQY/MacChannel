import Foundation

/// Presentation only. These labels never authorize a peer or select a route.
public enum PeerConnectionPresentation: String, Equatable, Sendable {
    case statusPending = "presence.status.pending"
    case onlineNearby = "presence.online.nearby"
    case online = "presence.online"
    case syncingDevices = "presence.syncing"
    case currentlyUnreachable = "presence.unreachable"

    public static func resolve(authenticated: Bool, sync: PresenceTrustSyncState,
                               availability: DeviceAvailability?) -> Self {
        guard authenticated else { return .statusPending }
        switch availability {
        case .lan: return .onlineNearby
        case .internet: return .online
        case nil, .offline:
            switch sync {
            case .idle, .synchronizing: return .syncingDevices
            case .pendingPersistence, .needsAttention: return .statusPending
            case .synchronized: return .currentlyUnreachable
            }
        }
    }

    public static func displayName(_ savedName: String, unnamed: String) -> String {
        savedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? unnamed : savedName
    }
}
