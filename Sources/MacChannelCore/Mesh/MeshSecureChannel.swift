import CryptoKit
import Foundation

public enum MeshSecureRole: UInt8, Sendable {
    case initiator = 1
    case responder = 2

    fileprivate var opposite: MeshSecureRole { self == .initiator ? .responder : .initiator }
}

public enum MeshSecureChannelError: Error, Equatable, Sendable {
    case messageTooLarge
    case authenticationFailed
    case untrustedPeer
    case invalidKeyRequest
    case transportClosed
    case overloaded
    case sequenceViolation
    case decryptionFailed
    case protocolViolation
}

public actor MeshSecureChannel: SecureChannel {
    public static let maximumMessageBytes = 64 * 1_024
    public static let maximumPendingSends = 128
    public static let maximumPendingSendBytes = 4 * 1_024 * 1_024

    public nonisolated let route: ConnectionRoute

    private struct HandshakeResult: Sendable {
        let remotePublicKey: Data
        let agreementKey: P256.KeyAgreement.PrivateKey
        let remoteAgreementKey: P256.KeyAgreement.PublicKey
        let transcriptHash: Data
        let sendKey: SymmetricKey
        let receiveKey: SymmetricKey
        let sendNoncePrefix: Data
        let receiveNoncePrefix: Data
    }

    private struct SendWaiter {
        let continuation: CheckedContinuation<Void, Error>
    }

    private let transport: any MeshByteConnection
    private let remoteDevice: DeviceID
    private let trustRepository: TrustRepository
    private let remotePublicKey: Data
    private let agreementKey: P256.KeyAgreement.PrivateKey
    private let remoteAgreementKey: P256.KeyAgreement.PublicKey
    private let transcriptHash: Data
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private let sendNoncePrefix: Data
    private let receiveNoncePrefix: Data
    private let localRole: MeshSecureRole
    private let frameStream: AsyncThrowingStream<Data, Error>
    private let frameContinuation: AsyncThrowingStream<Data, Error>.Continuation

    private var readerTask: Task<Void, Never>?
    private var transportCloseTask: Task<Void, Never>?
    private var closed = false
    private var terminalError: MeshSecureChannelError?
    private var nextSendSequence: UInt64 = 0
    private var nextReceiveSequence: UInt64 = 0
    private var sendBusy = false
    private var activeSendID: UUID?
    private var sendWaiters: [UUID: SendWaiter] = [:]
    private var sendWaiterOrder: [UUID] = []
    private var pendingSends: [UUID: Int] = [:]
    private var pendingSendBytes = 0

    private init(
        transport: any MeshByteConnection,
        remoteDevice: DeviceID,
        role: MeshSecureRole,
        route: ConnectionRoute,
        trustRepository: TrustRepository,
        handshake: HandshakeResult
    ) {
        self.transport = transport
        self.remoteDevice = remoteDevice
        localRole = role
        self.route = route
        self.trustRepository = trustRepository
        remotePublicKey = handshake.remotePublicKey
        agreementKey = handshake.agreementKey
        remoteAgreementKey = handshake.remoteAgreementKey
        transcriptHash = handshake.transcriptHash
        sendKey = handshake.sendKey
        receiveKey = handshake.receiveKey
        sendNoncePrefix = handshake.sendNoncePrefix
        receiveNoncePrefix = handshake.receiveNoncePrefix
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        frameStream = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(128)) { continuation = $0 }
        frameContinuation = continuation
    }

    public static func connect(
        over transport: any MeshByteConnection,
        identity: DeviceIdentity,
        remoteDevice: DeviceID,
        transferID: TransferID,
        role: MeshSecureRole,
        trustRepository: TrustRepository,
        route: ConnectionRoute
    ) async throws -> MeshSecureChannel {
        do {
            let handshake = try await withTaskCancellationHandler {
                try await performHandshake(
                    transport: transport,
                    identity: identity,
                    remoteDevice: remoteDevice,
                    transferID: transferID,
                    role: role,
                    trustRepository: trustRepository,
                    route: route
                )
            } onCancel: {
                Task { await transport.close() }
            }
            let channel = MeshSecureChannel(
                transport: transport,
                remoteDevice: remoteDevice,
                role: role,
                route: route,
                trustRepository: trustRepository,
                handshake: handshake
            )
            await channel.startReader()
            return channel
        } catch let error as MeshSecureChannelError {
            await transport.close()
            throw error
        } catch is CancellationError {
            await transport.close()
            throw CancellationError()
        } catch {
            await transport.close()
            throw MeshSecureChannelError.transportClosed
        }
    }

    public func send(_ frame: Data) async throws {
        guard frame.count <= Self.maximumMessageBytes else { throw MeshSecureChannelError.messageTooLarge }
        guard !closed else { throw terminalError ?? .transportClosed }
        let identifier = try reserveSend(bytes: frame.count)
        var beganTransport = false
        do {
            try await waitForSendTurn(identifier)
            guard !closed else { throw terminalError ?? .transportClosed }
            guard nextSendSequence < UInt64.max else { throw MeshSecureChannelError.sequenceViolation }
            let sequence = nextSendSequence
            nextSendSequence += 1
            let payload = try encrypt(frame, sequence: sequence)
            let wire = try MeshWireProtocol.encode(purpose: .transfer, payload: payload, limit: .encrypted)
            beganTransport = true
            try await withTaskCancellationHandler {
                try await transport.send(wire)
            } onCancel: {
                Task { await self.ambiguousSendCancelled(identifier) }
            }
            try Task.checkCancellation()
            finishSend(identifier)
        } catch let error as MeshSecureChannelError {
            finishSend(identifier)
            await fail(error)
            throw error
        } catch is CancellationError {
            finishSend(identifier)
            if beganTransport { await fail(.transportClosed) }
            throw CancellationError()
        } catch {
            finishSend(identifier)
            await fail(.transportClosed)
            throw MeshSecureChannelError.transportClosed
        }
    }

    public nonisolated func frames() -> AsyncThrowingStream<Data, Error> { frameStream }

    public func exportKey(label: String, context: Data, length: Int) async throws -> Data {
        guard !closed else { throw terminalError ?? .transportClosed }
        guard !label.isEmpty,
            label.utf8.count <= 255,
            !label.contains("\0"),
            context.count <= Self.maximumMessageBytes,
            (1...(255 * SHA256.byteCount)).contains(length)
        else { throw MeshSecureChannelError.invalidKeyRequest }
        guard await trustRepository.publicKey(for: remoteDevice) == remotePublicKey else {
            await fail(.untrustedPeer)
            throw MeshSecureChannelError.untrustedPeer
        }

        var salt = Data("macchannel-mesh-export-v1".utf8)
        salt.append(transcriptHash)
        var info = Data()
        info.appendUInt16(UInt16(label.utf8.count))
        info.append(Data(label.utf8))
        info.appendUInt32(UInt32(context.count))
        info.append(context)
        let sharedSecret = try agreementKey.sharedSecretFromKeyAgreement(with: remoteAgreementKey)
        let key = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: info,
            outputByteCount: length
        )
        return key.withUnsafeBytes { Data($0) }
    }

    public func close() async {
        if !closed { finish(nil) }
        let reader = readerTask
        reader?.cancel()
        let closeTask = beginTransportClose()
        await closeTask.value
        await reader?.value
    }

    func _testOnlyPendingSendCount() -> Int { pendingSends.count }
    func _testOnlyTerminalError() -> MeshSecureChannelError? { terminalError }

    private func startReader() {
        guard readerTask == nil else { return }
        readerTask = Task { [weak self] in await self?.readLoop() }
    }

    private func readLoop() async {
        let framed = MeshFramedConnection(transport: transport)
        do {
            while !closed {
                let frame = try await framed.receive(limit: .encrypted)
                guard frame.purpose == .transfer else { throw MeshSecureChannelError.protocolViolation }
                let plaintext = try decrypt(frame.payload)
                switch frameContinuation.yield(plaintext) {
                case .enqueued:
                    break
                case .dropped, .terminated:
                    throw MeshSecureChannelError.overloaded
                @unknown default:
                    throw MeshSecureChannelError.transportClosed
                }
            }
        } catch is CancellationError {
            return
        } catch let error as MeshSecureChannelError {
            await fail(error)
        } catch {
            if !closed { await fail(.transportClosed) }
        }
    }

    private func encrypt(_ plaintext: Data, sequence: UInt64) throws -> Data {
        var header = Data([1, localRole.rawValue])
        header.appendUInt64(sequence)
        var authenticatedData = transcriptHash
        authenticatedData.append(header)
        let nonce = try makeNonce(prefix: sendNoncePrefix, sequence: sequence)
        let sealed = try AES.GCM.seal(plaintext, using: sendKey, nonce: nonce, authenticating: authenticatedData)
        var payload = header
        payload.append(sealed.ciphertext)
        payload.append(sealed.tag)
        return payload
    }

    private func decrypt(_ payload: Data) throws -> Data {
        guard payload.count >= 26,
            payload.count <= Self.maximumMessageBytes + 26,
            payload[0] == 1,
            payload[1] == localRole.opposite.rawValue
        else { throw MeshSecureChannelError.protocolViolation }
        let sequence = payload.readUInt64(at: 2)
        guard sequence == nextReceiveSequence else { throw MeshSecureChannelError.sequenceViolation }
        guard nextReceiveSequence < UInt64.max else { throw MeshSecureChannelError.sequenceViolation }
        let header = Data(payload.prefix(10))
        let cipherAndTag = Data(payload.dropFirst(10))
        guard cipherAndTag.count >= 16 else { throw MeshSecureChannelError.protocolViolation }
        let ciphertext = Data(cipherAndTag.dropLast(16))
        let tag = Data(cipherAndTag.suffix(16))
        var authenticatedData = transcriptHash
        authenticatedData.append(header)
        do {
            let box = try AES.GCM.SealedBox(
                nonce: makeNonce(prefix: receiveNoncePrefix, sequence: sequence),
                ciphertext: ciphertext,
                tag: tag
            )
            let plaintext = try AES.GCM.open(box, using: receiveKey, authenticating: authenticatedData)
            guard plaintext.count <= Self.maximumMessageBytes else { throw MeshSecureChannelError.messageTooLarge }
            nextReceiveSequence += 1
            return plaintext
        } catch let error as MeshSecureChannelError {
            throw error
        } catch {
            throw MeshSecureChannelError.decryptionFailed
        }
    }

    private func reserveSend(bytes: Int) throws -> UUID {
        guard pendingSends.count < Self.maximumPendingSends,
            pendingSendBytes + bytes <= Self.maximumPendingSendBytes
        else { throw MeshSecureChannelError.overloaded }
        let identifier = UUID()
        pendingSends[identifier] = bytes
        pendingSendBytes += bytes
        return identifier
    }

    private func waitForSendTurn(_ identifier: UUID) async throws {
        if !sendBusy {
            sendBusy = true
            activeSendID = identifier
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    releaseReservation(identifier)
                    continuation.resume(throwing: CancellationError())
                } else {
                    sendWaiters[identifier] = SendWaiter(continuation: continuation)
                    sendWaiterOrder.append(identifier)
                }
            }
        } onCancel: {
            Task { await self.cancelSendWaiter(identifier) }
        }
    }

    private func cancelSendWaiter(_ identifier: UUID) {
        guard let waiter = sendWaiters.removeValue(forKey: identifier) else { return }
        sendWaiterOrder.removeAll { $0 == identifier }
        releaseReservation(identifier)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func ambiguousSendCancelled(_ identifier: UUID) async {
        guard activeSendID == identifier else { return }
        await fail(.transportClosed)
    }

    private func finishSend(_ identifier: UUID) {
        guard activeSendID == identifier || sendWaiters[identifier] != nil else { return }
        releaseReservation(identifier)
        activeSendID = nil
        if let next = sendWaiterOrder.first {
            sendWaiterOrder.removeFirst()
            let waiter = sendWaiters.removeValue(forKey: next)
            activeSendID = next
            waiter?.continuation.resume()
        } else {
            sendBusy = false
        }
    }

    private func releaseReservation(_ identifier: UUID) {
        guard let bytes = pendingSends.removeValue(forKey: identifier) else { return }
        pendingSendBytes -= bytes
    }

    private func fail(_ error: MeshSecureChannelError) async {
        guard !closed else { return }
        finish(error)
        let task = beginTransportClose()
        await task.value
    }

    private func finish(_ error: MeshSecureChannelError?) {
        guard !closed else { return }
        closed = true
        terminalError = error
        if let error {
            frameContinuation.finish(throwing: error)
        } else {
            frameContinuation.finish()
        }
        for waiter in sendWaiters.values {
            waiter.continuation.resume(throwing: error ?? MeshSecureChannelError.transportClosed)
        }
        sendWaiters.removeAll()
        sendWaiterOrder.removeAll()
        pendingSends.removeAll()
        pendingSendBytes = 0
        sendBusy = false
        activeSendID = nil
    }

    private func beginTransportClose() -> Task<Void, Never> {
        if let transportCloseTask { return transportCloseTask }
        let transport = self.transport
        let task = Task { await transport.close() }
        transportCloseTask = task
        return task
    }

    private static func performHandshake(
        transport: any MeshByteConnection,
        identity: DeviceIdentity,
        remoteDevice: DeviceID,
        transferID: TransferID,
        role: MeshSecureRole,
        trustRepository: TrustRepository,
        route: ConnectionRoute
    ) async throws -> HandshakeResult {
        guard identity.id != remoteDevice,
            let expectedRemoteKey = await trustRepository.publicKey(for: remoteDevice),
            DeviceIdentity.deviceID(for: expectedRemoteKey) == remoteDevice,
            (try? P256.Signing.PublicKey(rawRepresentation: expectedRemoteKey)) != nil
        else { throw MeshSecureChannelError.untrustedPeer }

        let agreementKey = P256.KeyAgreement.PrivateKey()
        let localHello = MeshHandshakeHello(
            role: role,
            route: route,
            device: identity.id,
            remoteDevice: remoteDevice,
            transferID: transferID,
            nonce: randomBytes(count: 32),
            signingPublicKey: identity.publicKey.rawRepresentation,
            agreementPublicKey: agreementKey.publicKey.rawRepresentation
        )
        let localHelloWire = try localHello.encode()
        let framed = MeshFramedConnection(transport: transport)
        try await framed.send(
            MeshWireFrame(purpose: .transfer, payload: localHelloWire),
            limit: .preauthentication
        )
        let remoteFrame = try await framed.receive(limit: .preauthentication)
        guard remoteFrame.purpose == .transfer else { throw MeshSecureChannelError.authenticationFailed }
        let remoteHello = try MeshHandshakeHello.decode(remoteFrame.payload)
        try remoteHello.validate(
            expectedRole: role.opposite,
            route: route,
            device: remoteDevice,
            remoteDevice: identity.id,
            transferID: transferID,
            publicKey: expectedRemoteKey
        )
        guard
            let remoteAgreementKey = try? P256.KeyAgreement.PublicKey(
                rawRepresentation: remoteHello.agreementPublicKey
            )
        else { throw MeshSecureChannelError.authenticationFailed }

        let transcript = try MeshHandshakeTranscript.make(
            route: route,
            transferID: transferID,
            localRole: role,
            localHello: localHelloWire,
            remoteHello: remoteFrame.payload
        )
        let transcriptHash = Data(SHA256.hash(data: transcript))
        let signature = try identity.sign(transcript).derRepresentation
        let proof = try MeshHandshakeProof(role: role, signature: signature).encode()
        try await framed.send(
            MeshWireFrame(purpose: .transfer, payload: proof),
            limit: .preauthentication
        )
        let remoteProofFrame = try await framed.receive(limit: .preauthentication)
        guard remoteProofFrame.purpose == .transfer else { throw MeshSecureChannelError.authenticationFailed }
        let remoteProof = try MeshHandshakeProof.decode(remoteProofFrame.payload)
        guard remoteProof.role == role.opposite,
            let signingKey = try? P256.Signing.PublicKey(rawRepresentation: expectedRemoteKey),
            let parsedSignature = try? P256.Signing.ECDSASignature(derRepresentation: remoteProof.signature),
            signingKey.isValidSignature(parsedSignature, for: transcript),
            await trustRepository.publicKey(for: remoteDevice) == expectedRemoteKey
        else { throw MeshSecureChannelError.authenticationFailed }

        let sharedSecret = try agreementKey.sharedSecretFromKeyAgreement(with: remoteAgreementKey)
        return HandshakeResult(
            remotePublicKey: expectedRemoteKey,
            agreementKey: agreementKey,
            remoteAgreementKey: remoteAgreementKey,
            transcriptHash: transcriptHash,
            sendKey: deriveKey(
                sharedSecret: sharedSecret,
                transcriptHash: transcriptHash,
                label: directionalLabel(sender: role, component: "key"),
                bytes: 32
            ),
            receiveKey: deriveKey(
                sharedSecret: sharedSecret,
                transcriptHash: transcriptHash,
                label: directionalLabel(sender: role.opposite, component: "key"),
                bytes: 32
            ),
            sendNoncePrefix: deriveData(
                sharedSecret: sharedSecret,
                transcriptHash: transcriptHash,
                label: directionalLabel(sender: role, component: "nonce"),
                bytes: 4
            ),
            receiveNoncePrefix: deriveData(
                sharedSecret: sharedSecret,
                transcriptHash: transcriptHash,
                label: directionalLabel(sender: role.opposite, component: "nonce"),
                bytes: 4
            )
        )
    }

    private static func deriveKey(
        sharedSecret: SharedSecret,
        transcriptHash: Data,
        label: String,
        bytes: Int
    ) -> SymmetricKey {
        sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: transcriptHash,
            sharedInfo: Data(label.utf8),
            outputByteCount: bytes
        )
    }

    private static func deriveData(
        sharedSecret: SharedSecret,
        transcriptHash: Data,
        label: String,
        bytes: Int
    ) -> Data {
        deriveKey(
            sharedSecret: sharedSecret,
            transcriptHash: transcriptHash,
            label: label,
            bytes: bytes
        ).withUnsafeBytes { Data($0) }
    }

    private static func directionalLabel(sender: MeshSecureRole, component: String) -> String {
        "macchannel-mesh-v1/\(sender == .initiator ? "initiator-to-responder" : "responder-to-initiator")/\(component)"
    }

    private static func randomBytes(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    private func makeNonce(prefix: Data, sequence: UInt64) throws -> AES.GCM.Nonce {
        guard prefix.count == 4 else { throw MeshSecureChannelError.protocolViolation }
        var bytes = prefix
        bytes.appendUInt64(sequence)
        return try AES.GCM.Nonce(data: bytes)
    }
}

private struct MeshHandshakeHello: Sendable {
    let role: MeshSecureRole
    let route: ConnectionRoute
    let device: DeviceID
    let remoteDevice: DeviceID
    let transferID: TransferID
    let nonce: Data
    let signingPublicKey: Data
    let agreementPublicKey: Data

    func encode() throws -> Data {
        guard nonce.count == 32,
            signingPublicKey.count <= UInt16.max,
            agreementPublicKey.count <= UInt16.max
        else { throw MeshSecureChannelError.authenticationFailed }
        var data = Data([1, 1, role.rawValue, route.meshRawValue])
        data.append(device.rawValue.meshBytes)
        data.append(remoteDevice.rawValue.meshBytes)
        data.append(transferID.rawValue.meshBytes)
        data.append(nonce)
        data.appendUInt16(UInt16(signingPublicKey.count))
        data.append(signingPublicKey)
        data.appendUInt16(UInt16(agreementPublicKey.count))
        data.append(agreementPublicKey)
        return data
    }

    static func decode(_ data: Data) throws -> MeshHandshakeHello {
        var reader = MeshBinaryReader(data)
        guard try reader.byte() == 1, try reader.byte() == 1,
            let role = MeshSecureRole(rawValue: try reader.byte()),
            let route = ConnectionRoute(meshRawValue: try reader.byte())
        else { throw MeshSecureChannelError.authenticationFailed }
        let device = DeviceID(rawValue: try reader.uuid())
        let remoteDevice = DeviceID(rawValue: try reader.uuid())
        let transferID = TransferID(rawValue: try reader.uuid())
        let nonce = try reader.data(count: 32)
        let signingKey = try reader.lengthPrefixedUInt16()
        let agreementKey = try reader.lengthPrefixedUInt16()
        guard reader.isAtEnd else { throw MeshSecureChannelError.authenticationFailed }
        return MeshHandshakeHello(
            role: role,
            route: route,
            device: device,
            remoteDevice: remoteDevice,
            transferID: transferID,
            nonce: nonce,
            signingPublicKey: signingKey,
            agreementPublicKey: agreementKey
        )
    }

    func validate(
        expectedRole: MeshSecureRole,
        route: ConnectionRoute,
        device: DeviceID,
        remoteDevice: DeviceID,
        transferID: TransferID,
        publicKey: Data
    ) throws {
        guard role == expectedRole,
            self.route == route,
            self.device == device,
            self.remoteDevice == remoteDevice,
            self.transferID == transferID,
            nonce.count == 32,
            signingPublicKey == publicKey,
            DeviceIdentity.deviceID(for: signingPublicKey) == device,
            (try? P256.Signing.PublicKey(rawRepresentation: signingPublicKey)) != nil,
            (try? P256.KeyAgreement.PublicKey(rawRepresentation: agreementPublicKey)) != nil
        else { throw MeshSecureChannelError.authenticationFailed }
    }
}

private struct MeshHandshakeProof {
    let role: MeshSecureRole
    let signature: Data

    func encode() throws -> Data {
        guard signature.count <= UInt16.max else { throw MeshSecureChannelError.authenticationFailed }
        var data = Data([2, 1, role.rawValue])
        data.appendUInt16(UInt16(signature.count))
        data.append(signature)
        return data
    }

    static func decode(_ data: Data) throws -> MeshHandshakeProof {
        var reader = MeshBinaryReader(data)
        guard try reader.byte() == 2, try reader.byte() == 1,
            let role = MeshSecureRole(rawValue: try reader.byte())
        else { throw MeshSecureChannelError.authenticationFailed }
        let signature = try reader.lengthPrefixedUInt16()
        guard reader.isAtEnd else { throw MeshSecureChannelError.authenticationFailed }
        return MeshHandshakeProof(role: role, signature: signature)
    }
}

private enum MeshHandshakeTranscript {
    static func make(
        route: ConnectionRoute,
        transferID: TransferID,
        localRole: MeshSecureRole,
        localHello: Data,
        remoteHello: Data
    ) throws -> Data {
        let domain = Data("MACCHANNEL-MESH-AUTH-V1".utf8)
        let initiator = localRole == .initiator ? localHello : remoteHello
        let responder = localRole == .responder ? localHello : remoteHello
        guard domain.count <= UInt16.max,
            initiator.count <= UInt32.max,
            responder.count <= UInt32.max
        else { throw MeshSecureChannelError.authenticationFailed }
        var data = Data()
        data.appendUInt16(UInt16(domain.count))
        data.append(domain)
        data.append(1)
        data.append(route.meshRawValue)
        data.append(transferID.rawValue.meshBytes)
        data.appendUInt32(UInt32(initiator.count))
        data.append(initiator)
        data.appendUInt32(UInt32(responder.count))
        data.append(responder)
        return data
    }
}

private struct MeshBinaryReader {
    private let bytes: Data
    private var offset = 0

    init(_ bytes: Data) { self.bytes = bytes }
    var isAtEnd: Bool { offset == bytes.count }

    mutating func byte() throws -> UInt8 {
        guard offset < bytes.count else { throw MeshSecureChannelError.authenticationFailed }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func data(count: Int) throws -> Data {
        guard count >= 0, offset <= bytes.count, count <= bytes.count - offset else {
            throw MeshSecureChannelError.authenticationFailed
        }
        defer { offset += count }
        return Data(bytes[offset..<(offset + count)])
    }

    mutating func uuid() throws -> UUID {
        let data = try data(count: 16)
        let array = Array(data)
        return UUID(
            uuid: (
                array[0], array[1], array[2], array[3], array[4], array[5], array[6], array[7],
                array[8], array[9], array[10], array[11], array[12], array[13], array[14], array[15]
            ))
    }

    mutating func lengthPrefixedUInt16() throws -> Data {
        let high = UInt16(try byte())
        let low = UInt16(try byte())
        return try data(count: Int((high << 8) | low))
    }
}

extension ConnectionRoute {
    fileprivate var meshRawValue: UInt8 {
        switch self {
        case .lan: 1
        case .directInternet: 2
        case .relay: 3
        }
    }

    fileprivate init?(meshRawValue: UInt8) {
        switch meshRawValue {
        case 1: self = .lan
        case 2: self = .directInternet
        case 3: self = .relay
        default: return nil
        }
    }
}

extension UUID {
    fileprivate var meshBytes: Data {
        var value = uuid
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}

extension Data {
    fileprivate mutating func appendUInt16(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    fileprivate mutating func appendUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    fileprivate mutating func appendUInt64(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }

    fileprivate func readUInt64(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for byte in self[offset..<(offset + 8)] { value = (value << 8) | UInt64(byte) }
        return value
    }
}
