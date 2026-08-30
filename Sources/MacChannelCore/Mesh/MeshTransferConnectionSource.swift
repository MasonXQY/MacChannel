#if MACCHANNEL_LEGACY_MESH
import Foundation

public actor MeshTransferConnectionSource: IncomingTransferConnectionSource {
    private let listener: MeshConnectionListener
    private let identity: DeviceIdentity
    private let trustRepository: TrustRepository
    private let directory: any MeshPeerCandidateProviding
    private let routes: any MeshRouteEvidenceProviding
    private let registry: MeshConnectionRegistry
    private var readerTask: Task<Void, Never>?
    private var stopped = false

    public init(
        listener: MeshConnectionListener,
        identity: DeviceIdentity,
        trustRepository: TrustRepository,
        directory: any MeshPeerCandidateProviding,
        routes: any MeshRouteEvidenceProviding,
        registry: MeshConnectionRegistry
    ) {
        self.listener = listener
        self.identity = identity
        self.trustRepository = trustRepository
        self.directory = directory
        self.routes = routes
        self.registry = registry
    }

    public func connections() async -> AsyncThrowingStream<IncomingTransferConnection, Error> {
        guard !stopped, readerTask == nil else {
            return AsyncThrowingStream { $0.finish() }
        }
        let upstream = await listener.connections(for: .transfer)
        var continuation: AsyncThrowingStream<IncomingTransferConnection, Error>.Continuation!
        let stream = AsyncThrowingStream<IncomingTransferConnection, Error>(
            bufferingPolicy: .bufferingOldest(0)
        ) { continuation = $0 }
        readerTask = Task { [weak self] in
            do {
                for try await transport in upstream {
                    guard let self else {
                        await transport.close()
                        break
                    }
                    do {
                        let connection = try await self.authenticate(transport)
                        switch continuation.yield(connection) {
                        case .enqueued:
                            break
                        case .dropped(let rejected):
                            await rejected.channel.close()
                        case .terminated:
                            await connection.channel.close()
                            await transport.close()
                            continuation.finish()
                            return
                        @unknown default:
                            await connection.channel.close()
                        }
                    } catch {
                        await transport.close()
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
            await self?.readerFinished()
        }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.cancelReader() }
        }
        return stream
    }

    public func stop() async {
        guard !stopped else { return }
        stopped = true
        let reader = readerTask
        readerTask = nil
        reader?.cancel()
        await listener.stop()
        await reader?.value
    }

    private func authenticate(
        _ transport: any MeshByteConnection
    ) async throws -> IncomingTransferConnection {
        let framed = MeshFramedConnection(transport: transport)
        let frame = try await framed.receive(limit: .preauthentication)
        guard frame.purpose == .transfer else { throw MeshTransferConnectionError.invalidPrelude }
        let prelude = try MeshTransferPreludeCodec.decode(frame.payload)
        guard await trustRepository.publicKey(for: prelude.source) != nil else {
            throw MeshTransferConnectionError.untrustedPeer
        }
        guard let candidate = await directory.candidate(for: prelude.source) else {
            throw MeshTransferConnectionError.unavailablePeer
        }
        let token = try await registry.claim(device: prelude.source, ownership: .handshake) {
            await transport.close()
        }
        do {
            let route = try MeshTransferConnector.connectionRoute(
                for: await routes.connectionKind(to: candidate.nodeID)
            )
            guard await trustRepository.publicKey(for: prelude.source) != nil else {
                throw MeshTransferConnectionError.untrustedPeer
            }
            guard await directory.candidate(for: prelude.source) == candidate else {
                throw MeshTransferConnectionError.staleEndpoint
            }
            let secure = try await MeshTransferConnector.establishSecureChannel(
                transport: transport,
                identity: identity,
                remoteDevice: prelude.source,
                transferID: prelude.transferID,
                role: .responder,
                trustRepository: trustRepository,
                route: route
            )
            let secureToken = try await registry.claim(
                device: prelude.source,
                ownership: .queuedTransfer
            ) {
                await secure.close()
            }
            await registry.release(token)
            return IncomingTransferConnection(
                source: prelude.source,
                transferID: prelude.transferID,
                channel: RegisteredMeshSecureChannel(
                    channel: secure,
                    registry: registry,
                    token: secureToken
                )
            )
        } catch {
            await registry.release(token)
            throw error
        }
    }

    private func readerFinished() { readerTask = nil }

    private func cancelReader() {
        readerTask?.cancel()
    }
}
#endif
