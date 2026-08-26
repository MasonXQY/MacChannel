import Foundation

/// An event from the already authenticated rendezvous WebSocket. Authentication
/// belongs to the WebSocket adapter; this type deliberately accepts no unauthenticated
/// wire data or peer-provided presentation metadata.
public enum RendezvousPresenceEvent: Equatable, Sendable {
    case availability(device: DeviceID, isOnline: Bool)
    case revoked(DeviceID)
}

/// Seam for the authenticated `/v1/ws` adapter, which is introduced with the
/// transport layer. It lets presence merging remain independent of HTTP details.
public protocol RendezvousPresenceEventSource: Sendable {
    func events() -> AsyncStream<RendezvousPresenceEvent>
}

public actor PresenceClient {
    private let directory: DeviceDirectory

    public init(directory: DeviceDirectory) {
        self.directory = directory
    }

    public func receive(_ event: RendezvousPresenceEvent) async {
        switch event {
        case let .availability(device, isOnline):
            await directory.apply(.internet(device, online: isOnline))
        case let .revoked(device):
            await directory.apply(.revoked(device))
        }
    }

    public func consume(_ source: any RendezvousPresenceEventSource) async {
        for await event in source.events() {
            await receive(event)
        }
    }
}
