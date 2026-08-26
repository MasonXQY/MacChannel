import CryptoKit
import Foundation
@preconcurrency import WebRTC

public enum WebRTCSecureChannelError: Error, Equatable, Sendable {
    case messageTooLarge
    case authenticationFailed
    case notAuthenticated
    case invalidKeyRequest
    case transportClosed
    case sendFailed
    case overloaded
}

struct WebRTCHandshakePublicMaterial: Sendable {
    let localAgreementPublicKey: Data
    let remoteAgreementPublicKey: Data
    let transcriptHash: Data
}

/// An authenticated application stream over one ordered, reliable WebRTC data
/// channel. Handshake frames never escape through `frames()`.
public final class WebRTCSecureChannel: NSObject, SecureChannel, RTCDataChannelDelegate, @unchecked Sendable {
    public static let maximumMessageBytes = 64 * 1024
    public static let bufferedAmountLowThreshold: UInt64 = 256 * 1024
    fileprivate static let bufferedAmountHighWaterMark: UInt64 = 1024 * 1024

    public let route: ConnectionRoute
    public let isOrderedReliable: Bool

    private let channel: RTCDataChannel
    private let state: State
    private let frameStream: AsyncThrowingStream<Data, Error>
    private let callbacks = OrderedDataChannelCallbacks()
    private let testOnlyGenerateLocalCandidate: @Sendable () async -> Void

    init(
        connectionID: UUID,
        role: WebRTCRole,
        route: ConnectionRoute,
        channel: RTCDataChannel,
        localIdentity: DeviceIdentity,
        remoteDevice: DeviceID,
        remotePublicKey: Data,
        closeTransport: @escaping @Sendable () async -> Void,
        testOnlyGenerateLocalCandidate: @escaping @Sendable () async -> Void
    ) {
        self.route = route
        self.channel = channel
        self.testOnlyGenerateLocalCandidate = testOnlyGenerateLocalCandidate
        isOrderedReliable = channel.isOrdered
            && channel.maxPacketLifeTime == UInt16.max
            && channel.maxRetransmits == UInt16.max

        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        frameStream = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(128)) {
            continuation = $0
        }
        state = State(
            channel: RTCDataChannelBox(channel),
            connectionID: connectionID,
            role: role,
            route: route,
            localIdentity: localIdentity,
            remoteDevice: remoteDevice,
            remotePublicKey: remotePublicKey,
            frames: continuation,
            closeTransport: closeTransport
        )
        super.init()
        channel.delegate = self
    }

    func authenticate() async throws {
        await state.channelStateChanged(channel.readyState)
        try await state.waitUntilAuthenticated()
    }

    public func send(_ frame: Data) async throws {
        guard frame.count <= Self.maximumMessageBytes else {
            throw WebRTCSecureChannelError.messageTooLarge
        }
        try await state.sendApplication(frame)
    }

    public func frames() -> AsyncThrowingStream<Data, Error> { frameStream }

    public func exportKey(label: String, context: Data, length: Int) async throws -> Data {
        try await state.exportKey(label: label, context: context, length: length)
    }

    public func close() async {
        await state.close()
    }

    /// Bypasses the public send cap only for adversarial transport tests.
    func _testOnlySendRawFrame(_ frame: Data) -> Bool {
        channel.sendData(RTCDataBuffer(data: frame, isBinary: true))
    }

    func _testOnlyHandshakePublicMaterial() async throws -> WebRTCHandshakePublicMaterial {
        try await state.handshakePublicMaterial()
    }

    func _testOnlyGenerateLocalCandidate() async {
        await testOnlyGenerateLocalCandidate()
    }

    func _testOnlyForceBackpressure(_ forced: Bool) async {
        await state._testOnlyForceBackpressure(forced)
    }

    func _testOnlyBackpressureWaiterCount() async -> Int {
        await state._testOnlyBackpressureWaiterCount()
    }

    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        let readyState = dataChannel.readyState.rawValue
        callbacks.enqueue(
            { [state] in await state.channelStateChanged(rawValue: readyState) },
            onOverflow: { [state] in await state.callbackQueueOverflowed() }
        )
    }

    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let data = buffer.data
        callbacks.enqueue(
            { [state] in await state.received(data) },
            onOverflow: { [state] in await state.callbackQueueOverflowed() }
        )
    }

    public func dataChannel(_ dataChannel: RTCDataChannel, didChangeBufferedAmount amount: UInt64) {
        let currentAmount = dataChannel.bufferedAmount
        callbacks.enqueue(
            { [state] in await state.bufferedAmountChanged(currentAmount) },
            onOverflow: { [state] in await state.callbackQueueOverflowed() }
        )
    }
}

private final class OrderedDataChannelCallbacks: @unchecked Sendable {
    typealias Operation = @Sendable () async -> Void

    private let lock = NSLock()
    private var queue: [Operation] = []
    private var draining = false
    private var overflowed = false

    func enqueue(_ operation: @escaping Operation, onOverflow: @escaping Operation) {
        var shouldStartDraining = false
        var shouldReportOverflow = false
        lock.withLock {
            guard !overflowed else { return }
            if queue.count >= 128 {
                overflowed = true
                queue.removeAll(keepingCapacity: false)
                shouldReportOverflow = true
            } else {
                queue.append(operation)
                if !draining {
                    draining = true
                    shouldStartDraining = true
                }
            }
        }
        if shouldReportOverflow { Task { await onOverflow() } }
        if shouldStartDraining { Task { await drain() } }
    }

    private func drain() async {
        while let operation = next() { await operation() }
    }

    private func next() -> Operation? {
        lock.withLock {
            guard !queue.isEmpty else {
                draining = false
                return nil
            }
            return queue.removeFirst()
        }
    }
}

private final class RTCDataChannelBox: @unchecked Sendable {
    let value: RTCDataChannel
    init(_ value: RTCDataChannel) { self.value = value }
}

private actor State {
    private static let handshakeMagic = Data("MACCHANNEL-HANDSHAKE-1\n".utf8)
    private static let hkdfSalt = Data("macchannel-webrtc-export-v1".utf8)
    private static let maximumBackpressureWaiters = 128
    private static let maximumSuspendedFrameBytes = 4 * 1024 * 1024

    private struct BackpressureWaiter {
        let frameBytes: Int
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct HandshakeMessage: Codable {
        let type: String
        let deviceID: String
        let publicKey: Data?
        let agreementPublicKey: Data?
        let nonce: Data?
        let signature: Data?
    }

    private struct TranscriptPeer: Codable {
        let deviceID: String
        let nonce: Data
        let publicKey: Data
        let agreementPublicKey: Data
        let role: String
    }

    private struct Transcript: Codable {
        let protocolName: String
        let connectionID: String
        let route: String
        let peers: [TranscriptPeer]
    }

    private let channel: RTCDataChannelBox
    private let connectionID: UUID
    private let role: WebRTCRole
    private let route: ConnectionRoute
    private let localIdentity: DeviceIdentity
    private let remoteDevice: DeviceID
    private let remotePublicKey: Data
    private let localNonce: Data
    private let localAgreementKey: P256.KeyAgreement.PrivateKey
    private let frameContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private let closeTransport: @Sendable () async -> Void
    private var transcript: Data?
    private var remoteAgreementPublicKey: P256.KeyAgreement.PublicKey?
    private var helloSent = false
    private var proofSent = false
    private var remoteProofVerified = false
    private var readySent = false
    private var remoteReady = false
    private var authenticated = false
    private var closed = false
    private var terminalError: WebRTCSecureChannelError?
    private var authenticationWaiters: [CheckedContinuation<Void, Error>] = []
    private var backpressureWaiters: [UUID: BackpressureWaiter] = [:]
    private var suspendedFrameBytes = 0
    private var transportCloseTask: Task<Void, Never>?
    private var testOnlyBackpressureForced = false

    init(
        channel: RTCDataChannelBox,
        connectionID: UUID,
        role: WebRTCRole,
        route: ConnectionRoute,
        localIdentity: DeviceIdentity,
        remoteDevice: DeviceID,
        remotePublicKey: Data,
        frames: AsyncThrowingStream<Data, Error>.Continuation,
        closeTransport: @escaping @Sendable () async -> Void
    ) {
        self.channel = channel
        self.connectionID = connectionID
        self.role = role
        self.route = route
        self.localIdentity = localIdentity
        self.remoteDevice = remoteDevice
        self.remotePublicKey = remotePublicKey
        localNonce = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        localAgreementKey = P256.KeyAgreement.PrivateKey()
        frameContinuation = frames
        self.closeTransport = closeTransport
    }

    func channelStateChanged(_ readyState: RTCDataChannelState) {
        switch readyState {
        case .open:
            // The answerer speaks first after its remotely opened channel has
            // a delegate. The offerer responds only after receiving that hello.
            if role == .answerer { sendHelloIfNeeded() }
        case .closing, .closed:
            fail(.transportClosed)
        case .connecting:
            break
        @unknown default:
            fail(.transportClosed)
        }
    }

    func channelStateChanged(rawValue: Int) {
        guard let readyState = RTCDataChannelState(rawValue: rawValue) else {
            fail(.transportClosed)
            return
        }
        channelStateChanged(readyState)
    }

    func waitUntilAuthenticated() async throws {
        if authenticated { return }
        if let terminalError { throw terminalError }
        try await withCheckedThrowingContinuation { continuation in
            authenticationWaiters.append(continuation)
        }
    }

    func received(_ data: Data) {
        guard !closed else { return }
        guard data.count <= WebRTCSecureChannel.maximumMessageBytes else {
            fail(.messageTooLarge)
            return
        }
        if authenticated {
            switch frameContinuation.yield(data) {
            case .enqueued:
                break
            case .dropped, .terminated:
                fail(.transportClosed)
            @unknown default:
                fail(.transportClosed)
            }
        } else if data.starts(with: Self.handshakeMagic) {
            handleHandshake(Data(data.dropFirst(Self.handshakeMagic.count)))
        } else {
            fail(.authenticationFailed)
        }
    }

    func bufferedAmountChanged(_ amount: UInt64) {
        guard amount <= WebRTCSecureChannel.bufferedAmountLowThreshold else { return }
        let waiters = backpressureWaiters.values
        backpressureWaiters.removeAll()
        suspendedFrameBytes = 0
        waiters.forEach { $0.continuation.resume() }
    }

    func callbackQueueOverflowed() {
        fail(.transportClosed)
    }

    func sendApplication(_ data: Data) async throws {
        guard authenticated else { throw terminalError ?? .notAuthenticated }
        guard !closed else { throw WebRTCSecureChannelError.transportClosed }
        while testOnlyBackpressureForced
                || channel.value.bufferedAmount > WebRTCSecureChannel.bufferedAmountHighWaterMark {
            try await waitForBackpressure(frameBytes: data.count)
            guard !closed else { throw WebRTCSecureChannelError.transportClosed }
        }
        guard channel.value.sendData(RTCDataBuffer(data: data, isBinary: true)) else {
            throw WebRTCSecureChannelError.sendFailed
        }
    }

    func exportKey(label: String, context: Data, length: Int) throws -> Data {
        guard authenticated, let transcript, let remoteAgreementPublicKey else {
            throw WebRTCSecureChannelError.notAuthenticated
        }
        guard !label.isEmpty, !label.contains("\0"),
              (1...(255 * SHA256.byteCount)).contains(length)
        else {
            throw WebRTCSecureChannelError.invalidKeyRequest
        }
        var info = Data(label.utf8)
        info.append(0)
        info.append(context)
        let transcriptHash = Data(SHA256.hash(data: transcript))
        var salt = Self.hkdfSalt
        salt.append(transcriptHash)
        let sharedSecret = try localAgreementKey.sharedSecretFromKeyAgreement(with: remoteAgreementPublicKey)
        let key = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: info,
            outputByteCount: length
        )
        return key.withUnsafeBytes { Data($0) }
    }

    func handshakePublicMaterial() throws -> WebRTCHandshakePublicMaterial {
        guard authenticated, let transcript, let remoteAgreementPublicKey else {
            throw WebRTCSecureChannelError.notAuthenticated
        }
        return WebRTCHandshakePublicMaterial(
            localAgreementPublicKey: localAgreementKey.publicKey.rawRepresentation,
            remoteAgreementPublicKey: remoteAgreementPublicKey.rawRepresentation,
            transcriptHash: Data(SHA256.hash(data: transcript))
        )
    }

    func _testOnlyForceBackpressure(_ forced: Bool) {
        testOnlyBackpressureForced = forced
    }

    func _testOnlyBackpressureWaiterCount() -> Int {
        backpressureWaiters.count
    }

    private func waitForBackpressure(frameBytes: Int) async throws {
        guard backpressureWaiters.count < Self.maximumBackpressureWaiters,
              suspendedFrameBytes + frameBytes <= Self.maximumSuspendedFrameBytes
        else {
            throw WebRTCSecureChannelError.overloaded
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if closed {
                    continuation.resume(throwing: WebRTCSecureChannelError.transportClosed)
                } else {
                    backpressureWaiters[id] = BackpressureWaiter(
                        frameBytes: frameBytes,
                        continuation: continuation
                    )
                    suspendedFrameBytes += frameBytes
                }
            }
        } onCancel: {
            Task { await self.cancelBackpressureWaiter(id) }
        }
    }

    private func cancelBackpressureWaiter(_ id: UUID) {
        guard let waiter = backpressureWaiters.removeValue(forKey: id) else { return }
        suspendedFrameBytes -= waiter.frameBytes
        waiter.continuation.resume(throwing: CancellationError())
    }

    func close() async {
        if !closed {
            closed = true
            channel.value.delegate = nil
            channel.value.close()
            finish(.transportClosed)
        }
        let closeTask = beginTransportClose()
        await closeTask.value
    }

    private func sendHelloIfNeeded() {
        guard !helloSent, !closed else { return }
        helloSent = true
        sendHandshake(HandshakeMessage(
            type: "hello",
            deviceID: localIdentity.id.rawValue.uuidString.lowercased(),
            publicKey: localIdentity.publicKey.rawRepresentation,
            agreementPublicKey: localAgreementKey.publicKey.rawRepresentation,
            nonce: localNonce,
            signature: nil
        ))
    }

    private func handleHandshake(_ payload: Data) {
        guard let message = try? JSONDecoder().decode(HandshakeMessage.self, from: payload) else {
            fail(.authenticationFailed)
            return
        }
        switch message.type {
        case "hello": handleHello(message)
        case "proof": handleProof(message)
        case "ready": handleReady(message)
        default: fail(.authenticationFailed)
        }
    }

    private func handleHello(_ message: HandshakeMessage) {
        guard transcript == nil,
              message.deviceID == remoteDevice.rawValue.uuidString.lowercased(),
              message.publicKey == remotePublicKey,
              let agreementPublicKeyData = message.agreementPublicKey,
              let agreementPublicKey = try? P256.KeyAgreement.PublicKey(rawRepresentation: agreementPublicKeyData),
              let nonce = message.nonce, nonce.count == 32,
              message.signature == nil,
              DeviceIdentity.deviceID(for: remotePublicKey) == remoteDevice,
              (try? P256.Signing.PublicKey(rawRepresentation: remotePublicKey)) != nil
        else {
            fail(.authenticationFailed)
            return
        }
        let remoteRole: WebRTCRole = role == .offerer ? .answerer : .offerer
        let peers = [
            TranscriptPeer(
                deviceID: localIdentity.id.rawValue.uuidString.lowercased(),
                nonce: localNonce,
                publicKey: localIdentity.publicKey.rawRepresentation,
                agreementPublicKey: localAgreementKey.publicKey.rawRepresentation,
                role: role.rawValue
            ),
            TranscriptPeer(
                deviceID: message.deviceID,
                nonce: nonce,
                publicKey: remotePublicKey,
                agreementPublicKey: agreementPublicKeyData,
                role: remoteRole.rawValue
            ),
        ].sorted { $0.deviceID < $1.deviceID }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let receivedTranscript = try? encoder.encode(Transcript(
            protocolName: "macchannel-data-auth-v2",
            connectionID: connectionID.uuidString.lowercased(),
            route: route.rawValue,
            peers: peers
        )),
              let signature = try? localIdentity.sign(receivedTranscript).derRepresentation
        else {
            fail(.authenticationFailed)
            return
        }
        transcript = receivedTranscript
        remoteAgreementPublicKey = agreementPublicKey
        sendHelloIfNeeded()
        proofSent = true
        sendHandshake(HandshakeMessage(
            type: "proof",
            deviceID: localIdentity.id.rawValue.uuidString.lowercased(),
            publicKey: nil,
            agreementPublicKey: nil,
            nonce: nil,
            signature: signature
        ))
    }

    private func handleProof(_ message: HandshakeMessage) {
        guard proofSent,
              !remoteProofVerified,
              message.deviceID == remoteDevice.rawValue.uuidString.lowercased(),
              message.publicKey == nil,
              message.agreementPublicKey == nil,
              message.nonce == nil,
              let signatureData = message.signature,
              let transcript,
              let publicKey = try? P256.Signing.PublicKey(rawRepresentation: remotePublicKey),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: signatureData),
              publicKey.isValidSignature(signature, for: transcript)
        else {
            fail(.authenticationFailed)
            return
        }
        remoteProofVerified = true
        readySent = true
        sendHandshake(HandshakeMessage(
            type: "ready",
            deviceID: localIdentity.id.rawValue.uuidString.lowercased(),
            publicKey: nil,
            agreementPublicKey: nil,
            nonce: nil,
            signature: nil
        ))
        completeAuthenticationIfReady()
    }

    private func handleReady(_ message: HandshakeMessage) {
        guard remoteProofVerified,
              message.deviceID == remoteDevice.rawValue.uuidString.lowercased(),
              message.publicKey == nil,
              message.agreementPublicKey == nil,
              message.nonce == nil,
              message.signature == nil
        else {
            fail(.authenticationFailed)
            return
        }
        remoteReady = true
        completeAuthenticationIfReady()
    }

    private func completeAuthenticationIfReady() {
        guard readySent, remoteReady, !authenticated, !closed else { return }
        authenticated = true
        let waiters = authenticationWaiters
        authenticationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func sendHandshake(_ message: HandshakeMessage) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let encoded = try? encoder.encode(message) else {
            fail(.authenticationFailed)
            return
        }
        var wire = Self.handshakeMagic
        wire.append(encoded)
        guard wire.count <= WebRTCSecureChannel.maximumMessageBytes,
              channel.value.sendData(RTCDataBuffer(data: wire, isBinary: true))
        else {
            fail(.sendFailed)
            return
        }
    }

    private func fail(_ error: WebRTCSecureChannelError) {
        guard terminalError == nil, !closed else { return }
        terminalError = error
        closed = true
        channel.value.delegate = nil
        channel.value.close()
        _ = beginTransportClose()
        finish(error)
    }

    private func beginTransportClose() -> Task<Void, Never> {
        if let transportCloseTask { return transportCloseTask }
        let closeTransport = self.closeTransport
        let task = Task { await closeTransport() }
        transportCloseTask = task
        return task
    }

    private func finish(_ error: WebRTCSecureChannelError) {
        let authWaiters = authenticationWaiters
        authenticationWaiters.removeAll()
        authWaiters.forEach { $0.resume(throwing: error) }
        let pressureWaiters = backpressureWaiters.values
        backpressureWaiters.removeAll()
        suspendedFrameBytes = 0
        pressureWaiters.forEach { $0.continuation.resume(throwing: error) }
        frameContinuation.finish(throwing: error)
    }
}
