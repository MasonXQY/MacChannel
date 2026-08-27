import Foundation

public actor MeshProbeHost {
    private let listener: MeshConnectionListener
    private let device: DeviceID
    private let displayName: String
    private var task: Task<Void, Never>?

    public init(listener: MeshConnectionListener, device: DeviceID, displayName: String) {
        self.listener = listener
        self.device = device
        self.displayName = displayName
    }

    public func start() async throws {
        guard task == nil else { return }
        try await listener.start()
        let stream = await listener.connections(for: .probe)
        task = Task { [weak self] in
            do {
                for try await connection in stream {
                    guard let self else {
                        await connection.close()
                        return
                    }
                    await self.respond(connection)
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
        await current?.value
    }

    private func respond(_ connection: any MeshByteConnection) async {
        do {
            let framed = MeshFramedConnection(transport: connection)
            let frame = try await framed.receive(limit: .preauthentication)
            guard frame.purpose == .probe,
                let request = try? JSONDecoder().decode(
                    MeshPeerProbeRequest.self, from: frame.payload),
                request.version == 1,
                request.nonce.count == 32
            else { throw MeshPeerDirectoryError.invalidProbeResponse }
            let response = MeshPeerProbeResponse(
                version: 1,
                nonce: request.nonce,
                deviceIDHash: MeshPeerDirectory.deviceIDHash(for: device),
                displayName: displayName
            )
            try await framed.send(
                MeshWireFrame(purpose: .probe, payload: try MeshPeerProbeCodec.encode(response)),
                limit: .preauthentication
            )
        } catch {
            // Invalid and disconnected probes receive no response.
        }
        await connection.close()
    }
}
