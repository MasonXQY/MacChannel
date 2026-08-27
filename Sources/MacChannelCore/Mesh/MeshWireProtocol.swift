import Foundation

public enum MeshConnectionPurpose: UInt8, CaseIterable, Codable, Sendable {
    case probe = 1
    case pairing = 2
    case transfer = 3
}

public enum MeshFrameLimit: Int, Sendable {
    case preauthentication = 8_192
    case secure = 65_536
}

public enum MeshWireError: Error, Equatable, Sendable {
    case invalidHeader
    case invalidMagic
    case unsupportedVersion
    case unknownPurpose
    case frameTooLarge
    case connectionClosed
    case transportViolation
}

public struct MeshWireHeader: Equatable, Sendable {
    public let purpose: MeshConnectionPurpose
    public let payloadLength: Int

    public init(purpose: MeshConnectionPurpose, payloadLength: Int) {
        self.purpose = purpose
        self.payloadLength = payloadLength
    }
}

public struct MeshWireFrame: Equatable, Sendable {
    public let purpose: MeshConnectionPurpose
    public let payload: Data

    public init(purpose: MeshConnectionPurpose, payload: Data) {
        self.purpose = purpose
        self.payload = payload
    }
}

public enum MeshWireProtocol {
    public static let headerLength = 8

    private static let magic: [UInt8] = [0x4D, 0x43, 0x48]
    private static let version: UInt8 = 1

    public static func encode(
        purpose: MeshConnectionPurpose,
        payload: Data,
        limit: MeshFrameLimit
    ) throws -> Data {
        var result = try header(purpose: purpose, payloadLength: payload.count, limit: limit)
        result.append(payload)
        return result
    }

    public static func header(
        purpose: MeshConnectionPurpose,
        payloadLength: Int,
        limit: MeshFrameLimit
    ) throws -> Data {
        guard payloadLength >= 0, payloadLength <= limit.rawValue, payloadLength <= 0xFF_FFFF else {
            throw MeshWireError.frameTooLarge
        }

        return Data(
            magic + [
                version,
                purpose.rawValue,
                UInt8((payloadLength >> 16) & 0xFF),
                UInt8((payloadLength >> 8) & 0xFF),
                UInt8(payloadLength & 0xFF),
            ]
        )
    }

    public static func decodeHeader(_ bytes: Data, limit: MeshFrameLimit) throws -> MeshWireHeader {
        guard bytes.count == headerLength else { throw MeshWireError.invalidHeader }
        let values = Array(bytes)
        guard Array(values[0..<3]) == magic else { throw MeshWireError.invalidMagic }
        guard values[3] == version else { throw MeshWireError.unsupportedVersion }
        guard let purpose = MeshConnectionPurpose(rawValue: values[4]) else {
            throw MeshWireError.unknownPurpose
        }

        let payloadLength = (Int(values[5]) << 16) | (Int(values[6]) << 8) | Int(values[7])
        guard payloadLength <= limit.rawValue else { throw MeshWireError.frameTooLarge }
        return MeshWireHeader(purpose: purpose, payloadLength: payloadLength)
    }
}

public protocol MeshByteConnection: Sendable {
    func send(_ bytes: Data) async throws
    func receive(minimum: Int, maximum: Int) async throws -> Data
    func close() async
}

public actor MeshFramedConnection {
    private let transport: any MeshByteConnection
    private var isClosed = false

    public init(transport: any MeshByteConnection) {
        self.transport = transport
    }

    public func send(_ frame: MeshWireFrame, limit: MeshFrameLimit) async throws {
        guard !isClosed else { throw MeshWireError.connectionClosed }
        let encoded = try MeshWireProtocol.encode(
            purpose: frame.purpose,
            payload: frame.payload,
            limit: limit
        )
        try await transport.send(encoded)
    }

    public func receive(limit: MeshFrameLimit) async throws -> MeshWireFrame {
        guard !isClosed else { throw MeshWireError.connectionClosed }
        let headerBytes = try await readExactly(MeshWireProtocol.headerLength)
        let header = try MeshWireProtocol.decodeHeader(headerBytes, limit: limit)
        let payload = try await readExactly(header.payloadLength)
        return MeshWireFrame(purpose: header.purpose, payload: payload)
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        await transport.close()
    }

    private func readExactly(_ count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        var result = Data()
        result.reserveCapacity(count)

        while result.count < count {
            let remaining = count - result.count
            let chunk = try await transport.receive(minimum: 1, maximum: remaining)
            guard !chunk.isEmpty else { throw MeshWireError.connectionClosed }
            guard chunk.count <= remaining else { throw MeshWireError.transportViolation }
            result.append(chunk)
        }
        return result
    }
}
