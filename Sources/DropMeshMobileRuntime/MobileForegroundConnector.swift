import Foundation
import MacChannelCore

/// Process-lifetime proxy for the retained TransferCoordinator. Disabling never
/// waits for a replacement graph: old attempts fail and close their late channel.
actor MobileForegroundConnector: RouteEscalatingPeerConnector {
    private var generation: UInt64 = 0
    private var connector: (any RouteEscalatingPeerConnector)?

    func install(_ connector: any RouteEscalatingPeerConnector) {
        generation += 1
        self.connector = connector
    }

    func disable() {
        generation += 1
        connector = nil
    }

    func connect(to device: DeviceID) async throws -> any SecureChannel {
        try await forward { try await $0.connect(to: device) }
    }

    func connect(to device: DeviceID, transferID: TransferID) async throws -> any SecureChannel {
        try await forward { try await $0.connect(to: device, transferID: transferID) }
    }

    func connect(
        to device: DeviceID, transferID: TransferID, after failedRoute: ConnectionRoute?
    ) async throws -> any SecureChannel {
        try await forward { try await $0.connect(to: device, transferID: transferID, after: failedRoute) }
    }

    private func forward(
        _ connect: @Sendable (any RouteEscalatingPeerConnector) async throws -> any SecureChannel
    ) async throws -> any SecureChannel {
        guard let connector, !Task.isCancelled else { throw CancellationError() }
        let token = generation
        let channel: any SecureChannel
        do { channel = try await connect(connector) }
        catch {
            guard token == generation, self.connector != nil, !Task.isCancelled else {
                throw CancellationError()
            }
            throw error
        }
        guard token == generation, self.connector != nil, !Task.isCancelled else {
            await channel.close()
            throw CancellationError()
        }
        return channel
    }
}
