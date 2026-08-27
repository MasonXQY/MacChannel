import Foundation

public actor MeshPairingHost {
    private let listener: MeshConnectionListener
    private let transport: MeshPairingTransport
    private var task: Task<Void, Never>?

    public init(listener: MeshConnectionListener, transport: MeshPairingTransport) {
        self.listener = listener
        self.transport = transport
    }

    public func start() async throws {
        guard task == nil else { return }
        try await listener.start()
        let stream = await listener.connections(for: .pairing)
        task = Task { [weak self] in
            do {
                for try await connection in stream {
                    guard let self else {
                        await connection.close()
                        break
                    }
                    let sourceKey =
                        (connection as? any MeshPairingSourceIdentifying)?.meshPairingSourceKey
                        ?? Data("unknown-mesh-peer".utf8)
                    await self.transport.acceptIncoming(
                        connection,
                        sourceKey: sourceKey
                    )
                }
            } catch {
                // Listener shutdown terminates the stream.
            }
        }
    }

    public func stop() async {
        let current = task
        task = nil
        current?.cancel()
        await listener.stop()
        if let current { await current.value }
        await transport.stop()
    }
}
