import CryptoKit
import Foundation

public enum TransferDirection: UInt8, Sendable {
    case senderToReceiver = 1
    case receiverToSender = 2
}

public struct EncryptedTransferFrame: Sendable {
    public let transferID: TransferID
    public let sequence: UInt64
    public let direction: TransferDirection
    public let nonceEpoch: Data
    public var ciphertext: Data
    public let tag: Data

    public var wireData: Data {
        var output = ChunkCipher.wireHeader(
            transfer: transferID,
            sequence: sequence,
            direction: direction,
            nonceEpoch: nonceEpoch
        )
        output.append(ciphertext)
        output.append(tag)
        return output
    }

    init(
        transferID: TransferID,
        sequence: UInt64,
        direction: TransferDirection,
        nonceEpoch: Data,
        ciphertext: Data,
        tag: Data
    ) {
        self.transferID = transferID
        self.sequence = sequence
        self.direction = direction
        self.nonceEpoch = nonceEpoch
        self.ciphertext = ciphertext
        self.tag = tag
    }
}

public struct ChunkCipher: Sendable {
    private static let magic = Data([0x4d, 0x43, 0x58, 0x46])  // MCXF
    private static let version: UInt8 = 1
    private static let headerBytes = 46
    private static let tagBytes = 16
    private static let nonceLabel = Data("macchannel-transfer-nonce-v1".utf8)

    private let key: SymmetricKey
    private let sealingNonceEpoch: Data

    public init(key: Data) throws {
        guard key.count == 32 else { throw TransferProtocolError.authenticationFailed }
        self.key = SymmetricKey(data: key)
        sealingNonceEpoch = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
    }

    public func seal(
        _ plaintext: Data,
        transfer: TransferID,
        sequence: UInt64,
        direction: TransferDirection
    ) throws -> EncryptedTransferFrame {
        guard
            plaintext.count <= TransferProtocolLimits.maximumWireFrameBytes
                - Self.headerBytes - Self.tagBytes
        else { throw TransferProtocolError.frameTooLarge }
        let nonceEpoch = sealingNonceEpoch
        let header = Self.wireHeader(
            transfer: transfer,
            sequence: sequence,
            direction: direction,
            nonceEpoch: nonceEpoch
        )
        do {
            let sealed = try AES.GCM.seal(
                plaintext,
                using: key,
                nonce: try nonce(
                    transfer: transfer,
                    sequence: sequence,
                    direction: direction,
                    nonceEpoch: nonceEpoch
                ),
                authenticating: header
            )
            return EncryptedTransferFrame(
                transferID: transfer,
                sequence: sequence,
                direction: direction,
                nonceEpoch: nonceEpoch,
                ciphertext: sealed.ciphertext,
                tag: sealed.tag
            )
        } catch {
            throw TransferProtocolError.authenticationFailed
        }
    }

    public func open(_ frame: EncryptedTransferFrame) throws -> Data {
        guard frame.tag.count == Self.tagBytes,
            frame.nonceEpoch.count == 16,
            frame.wireData.count <= TransferProtocolLimits.maximumWireFrameBytes
        else { throw TransferProtocolError.invalidFrame }
        let header = Self.wireHeader(
            transfer: frame.transferID,
            sequence: frame.sequence,
            direction: frame.direction,
            nonceEpoch: frame.nonceEpoch
        )
        do {
            let box = try AES.GCM.SealedBox(
                nonce: nonce(
                    transfer: frame.transferID,
                    sequence: frame.sequence,
                    direction: frame.direction,
                    nonceEpoch: frame.nonceEpoch
                ),
                ciphertext: frame.ciphertext,
                tag: frame.tag
            )
            return try AES.GCM.open(box, using: key, authenticating: header)
        } catch {
            throw TransferProtocolError.authenticationFailed
        }
    }

    func openWire(
        _ wire: Data,
        expectedTransfer: TransferID,
        expectedSequence: UInt64,
        expectedDirection: TransferDirection
    ) throws -> Data {
        guard wire.count >= Self.headerBytes + Self.tagBytes,
            wire.count <= TransferProtocolLimits.maximumWireFrameBytes,
            wire.prefix(Self.magic.count) == Self.magic,
            wire[Self.magic.count] == Self.version,
            wire[Self.magic.count + 1] == expectedDirection.rawValue
        else { throw TransferProtocolError.invalidFrame }
        var reader = WireHeaderReader(Data(wire.prefix(Self.headerBytes)))
        try reader.skip(Self.magic.count + 2)
        let transfer = TransferID(rawValue: try reader.uuid())
        let sequence = try reader.uint64()
        let nonceEpoch = try reader.data(count: 16)
        guard transfer == expectedTransfer, sequence == expectedSequence else {
            throw TransferProtocolError.replayOrOutOfOrder
        }
        let ciphertext = wire.subdata(in: Self.headerBytes..<(wire.count - Self.tagBytes))
        let tag = wire.suffix(Self.tagBytes)
        return try open(
            EncryptedTransferFrame(
                transferID: transfer,
                sequence: sequence,
                direction: expectedDirection,
                nonceEpoch: nonceEpoch,
                ciphertext: ciphertext,
                tag: Data(tag)
            ))
    }

    static func wireHeader(
        transfer: TransferID,
        sequence: UInt64,
        direction: TransferDirection,
        nonceEpoch: Data
    ) -> Data {
        var output = magic
        output.append(version)
        output.append(direction.rawValue)
        var uuid = transfer.rawValue.uuid
        withUnsafeBytes(of: &uuid) { output.append(contentsOf: $0) }
        var bigSequence = sequence.bigEndian
        withUnsafeBytes(of: &bigSequence) { output.append(contentsOf: $0) }
        output.append(nonceEpoch)
        return output
    }

    private func nonce(
        transfer: TransferID,
        sequence: UInt64,
        direction: TransferDirection,
        nonceEpoch: Data
    ) throws -> AES.GCM.Nonce {
        var material = Self.nonceLabel
        material.append(
            Self.wireHeader(
                transfer: transfer,
                sequence: sequence,
                direction: direction,
                nonceEpoch: nonceEpoch
            ))
        return try AES.GCM.Nonce(data: Data(SHA256.hash(data: material).prefix(12)))
    }
}

struct TransferCryptographicContext: Sendable {
    static let exporterLabel = "macchannel-transfer-v1"

    let senderToReceiver: ChunkCipher
    let receiverToSender: ChunkCipher

    static func make(on channel: any SecureChannel, transfer: TransferID) async throws -> Self {
        let context = encodedTransferID(transfer)
        let exported = try await channel.exportKey(
            label: exporterLabel,
            context: context,
            length: 32
        )
        return try Self(
            senderToReceiver: ChunkCipher(
                key: directionalKey(
                    exported,
                    direction: .senderToReceiver
                )),
            receiverToSender: ChunkCipher(
                key: directionalKey(
                    exported,
                    direction: .receiverToSender
                ))
        )
    }

    static func encodedTransferID(_ transfer: TransferID) -> Data {
        var uuid = transfer.rawValue.uuid
        return withUnsafeBytes(of: &uuid) { Data($0) }
    }

    private static func directionalKey(
        _ exported: Data,
        direction: TransferDirection
    ) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: exported),
            salt: Data("macchannel-transfer-direction-v1".utf8),
            info: Data([direction.rawValue]),
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }
}

private struct WireHeaderReader {
    let input: Data
    var offset = 0

    init(_ input: Data) { self.input = input }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, count <= input.count - offset else {
            throw TransferProtocolError.invalidFrame
        }
        offset += count
    }

    mutating func uuid() throws -> UUID {
        let bytes = [UInt8](try data(count: 16))
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }

    mutating func uint64() throws -> UInt64 {
        let bytes = try data(count: 8)
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).bigEndian }
    }

    mutating func data(count: Int) throws -> Data {
        guard count >= 0, count <= input.count - offset else {
            throw TransferProtocolError.invalidFrame
        }
        defer { offset += count }
        return input.subdata(in: offset..<(offset + count))
    }
}
