import Foundation
import Network

public enum MeshTransferConnectionError: Error, Equatable, Sendable {
    case untrustedPeer
    case unavailablePeer
    case staleEndpoint
    case unknownRoute
    case invalidPrelude
}

public protocol MeshPeerCandidateProviding: Sendable {
    func candidate(for device: DeviceID) async -> MeshPeerCandidate?
}

extension MeshPeerDirectory: MeshPeerCandidateProviding {}

public protocol MeshRouteEvidenceProviding: Sendable {
    func connectionKind(to nodeID: String) async throws -> TailscaleConnectionKind
}

extension TailscaleCommandClient: MeshRouteEvidenceProviding {}

public protocol MeshTransferConnectionOpening: Sendable {
    func open(endpoint: NWEndpoint) async throws -> any MeshByteConnection
}

public struct NWMeshTransferConnectionOpener: MeshTransferConnectionOpening {
    public init() {}

    public func open(endpoint: NWEndpoint) async throws -> any MeshByteConnection {
        NWMeshByteConnection(connection: NWConnection(to: endpoint, using: .tcp))
    }
}

public actor MeshTransferConnector: TransferAwarePeerConnector {
    private let identity: DeviceIdentity
    private let trustRepository: TrustRepository
    private let directory: any MeshPeerCandidateProviding
    private let routes: any MeshRouteEvidenceProviding
    private let opener: any MeshTransferConnectionOpening
    private let registry: MeshConnectionRegistry

    public init(
        identity: DeviceIdentity,
        trustRepository: TrustRepository,
        directory: any MeshPeerCandidateProviding,
        routes: any MeshRouteEvidenceProviding,
        opener: any MeshTransferConnectionOpening = NWMeshTransferConnectionOpener(),
        registry: MeshConnectionRegistry
    ) {
        self.identity = identity
        self.trustRepository = trustRepository
        self.directory = directory
        self.routes = routes
        self.opener = opener
        self.registry = registry
    }

    public func connect(to device: DeviceID) async throws -> any SecureChannel {
        try await connect(to: device, transferID: TransferID(rawValue: UUID()))
    }

    public func connect(
        to device: DeviceID,
        transferID: TransferID
    ) async throws -> any SecureChannel {
        guard await trustRepository.publicKey(for: device) != nil else {
            throw MeshTransferConnectionError.untrustedPeer
        }
        guard let candidate = await directory.candidate(for: device) else {
            throw MeshTransferConnectionError.unavailablePeer
        }
        let transport = try await opener.open(endpoint: candidate.endpoint)
        let rawToken: MeshConnectionRegistry.Token
        do {
            rawToken = try await registry.claim(device: device, ownership: .handshake) {
                await transport.close()
            }
        } catch {
            await transport.close()
            throw error
        }

        do {
            let route = try Self.connectionRoute(
                for: await routes.connectionKind(to: candidate.nodeID))
            guard await trustRepository.publicKey(for: device) != nil else {
                throw MeshTransferConnectionError.untrustedPeer
            }
            guard await directory.candidate(for: device) == candidate else {
                throw MeshTransferConnectionError.staleEndpoint
            }
            let framed = MeshFramedConnection(transport: transport)
            let prelude = try MeshTransferPreludeCodec.encode(
                MeshTransferPrelude(source: identity.id, transferID: transferID)
            )
            try await framed.send(
                MeshWireFrame(purpose: .transfer, payload: prelude),
                limit: .preauthentication
            )
            let secure = try await Self.establishSecureChannel(
                transport: transport,
                identity: identity,
                remoteDevice: device,
                transferID: transferID,
                role: .initiator,
                trustRepository: trustRepository,
                route: route
            )
            let secureToken = try await registry.claim(device: device, ownership: .activeTransfer) {
                await secure.close()
            }
            await registry.release(rawToken)
            return RegisteredMeshSecureChannel(
                channel: secure,
                registry: registry,
                token: secureToken
            )
        } catch {
            await registry.release(rawToken)
            await transport.close()
            throw error
        }
    }

    static func connectionRoute(for kind: TailscaleConnectionKind) throws -> ConnectionRoute {
        switch kind {
        case .direct:
            .directInternet
        case .derp, .peerRelay:
            .relay
        case .unknown:
            throw MeshTransferConnectionError.unknownRoute
        }
    }

    static func establishSecureChannel(
        transport: any MeshByteConnection,
        identity: DeviceIdentity,
        remoteDevice: DeviceID,
        transferID: TransferID,
        role: MeshSecureRole,
        trustRepository: TrustRepository,
        route: ConnectionRoute
    ) async throws -> MeshSecureChannel {
        try await withThrowingTaskGroup(of: MeshSecureChannel.self) { group in
            group.addTask {
                try await MeshSecureChannel.connect(
                    over: transport,
                    identity: identity,
                    remoteDevice: remoteDevice,
                    transferID: transferID,
                    role: role,
                    trustRepository: trustRepository,
                    route: route
                )
            }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                throw MeshTransferConnectionError.unavailablePeer
            }
            defer { group.cancelAll() }
            guard let channel = try await group.next() else {
                throw MeshTransferConnectionError.unavailablePeer
            }
            return channel
        }
    }
}

struct MeshTransferPrelude: Codable, Equatable, Sendable {
    let version: Int
    let source: DeviceID
    let transferID: TransferID

    init(version: Int = 1, source: DeviceID, transferID: TransferID) {
        self.version = version
        self.source = source
        self.transferID = transferID
    }
}

enum MeshTransferPreludeCodec {
    static func encode(_ value: MeshTransferPrelude) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= MeshFrameLimit.preauthentication.rawValue else {
            throw MeshTransferConnectionError.invalidPrelude
        }
        return data
    }

    static func decode(_ data: Data) throws -> MeshTransferPrelude {
        guard data.count <= MeshFrameLimit.preauthentication.rawValue,
            let value = try? JSONDecoder().decode(MeshTransferPrelude.self, from: data),
            value.version == 1
        else { throw MeshTransferConnectionError.invalidPrelude }
        return value
    }
}
