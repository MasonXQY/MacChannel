import Foundation
@preconcurrency import WebRTC

public struct TURNServer: Equatable, Sendable {
    public let urls: [String]
    public let username: String
    public let credential: String

    public init(urls: [String], username: String, credential: String) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }
}

public struct ICEConfiguration: Equatable, Sendable {
    public let stunURLs: [String]
    public let turnServers: [TURNServer]

    public init(stunURLs: [String], turnServers: [TURNServer]) {
        self.stunURLs = stunURLs
        self.turnServers = turnServers
    }
}

struct WebRTCIceServerPlan: Equatable, Sendable {
    let urls: [String]
    let username: String?
    let credential: String?
}

struct WebRTCRoutePlan: Equatable, Sendable {
    let servers: [WebRTCIceServerPlan]
    let relayOnly: Bool
    let allowedCandidateKinds: Set<WebRTCCandidateKind>

    func allows(candidateSDP: String) -> Bool {
        let fields = candidateSDP.split(whereSeparator: { $0.isWhitespace })
        guard let typeIndex = fields.firstIndex(of: "typ"), fields.indices.contains(typeIndex + 1),
              let kind = WebRTCCandidateKind(rawValue: String(fields[typeIndex + 1]))
        else { return false }
        return allowedCandidateKinds.contains(kind)
    }

    func allowsRemoteDescription(_ sdp: String) -> Bool {
        sdp.split(whereSeparator: { $0.isNewline })
            .filter { $0.hasPrefix("a=candidate:") }
            .allSatisfy { allows(candidateSDP: String($0)) }
    }
}

enum WebRTCCandidateKind: String, Hashable, Sendable {
    case host
    case serverReflexive = "srflx"
    case relay
}

struct WebRTCDataChannelProperties: Equatable, Sendable {
    let label: String
    let protocolName: String
    let isOrdered: Bool
    let maxPacketLifeTime: UInt16
    let maxRetransmits: UInt16
    let isNegotiated: Bool
}

public enum WebRTCRole: String, Sendable { case offerer, answerer }

public enum WebRTCSignalMessage: Codable, Equatable, Sendable {
    case offer(sdp: String, route: ConnectionRoute)
    case answer(sdp: String)
    case candidate(sdp: String, sdpMLineIndex: Int32, sdpMid: String?)
}

public protocol WebRTCSignalTransport: Sendable {
    func messages(from remoteDevice: DeviceID, connectionID: UUID) async -> AsyncThrowingStream<WebRTCSignalMessage, Error>
    func send(_ message: WebRTCSignalMessage, to remoteDevice: DeviceID, connectionID: UUID) async throws
}

public enum WebRTCFactoryError: Error, Equatable, Sendable {
    case peerConnectionCreationFailed
    case dataChannelCreationFailed
    case sessionDescriptionFailed
    case iceFailed
    case signalingEnded
    case signalingOverflow
    case remoteCandidateOverflow
    case peerUnavailable
    case trustForbidden
    case timeout
}

public protocol WebRTCChannelFactory: Sendable {
    func connect(
        localIdentity: DeviceIdentity,
        remoteDevice: DeviceID,
        remotePublicKey: Data,
        connectionID: UUID,
        role: WebRTCRole,
        route: ConnectionRoute,
        ice: ICEConfiguration,
        signaling: any WebRTCSignalTransport
    ) async throws -> WebRTCSecureChannel
}

public final class WebRTCFactory: WebRTCChannelFactory, @unchecked Sendable {
    private static let didInitializeSSL: Bool = {
        RTCInitializeSSL()
    }()

    private let factory: RTCPeerConnectionFactory
    private let connectionTimeout: Duration

    public init(connectionTimeout: Duration = .seconds(12)) {
        _ = Self.didInitializeSSL
        factory = RTCPeerConnectionFactory()
        self.connectionTimeout = connectionTimeout
    }

    static func routePlan(for route: ConnectionRoute, ice: ICEConfiguration) -> WebRTCRoutePlan {
        switch route {
        case .lan:
            WebRTCRoutePlan(servers: [], relayOnly: false, allowedCandidateKinds: [.host])
        case .directInternet:
            WebRTCRoutePlan(
                servers: ice.stunURLs.map { .init(urls: [$0], username: nil, credential: nil) },
                relayOnly: false,
                allowedCandidateKinds: [.serverReflexive]
            )
        case .relay:
            WebRTCRoutePlan(
                servers: ice.turnServers.map { .init(
                    urls: $0.urls,
                    username: $0.username,
                    credential: $0.credential
                ) },
                relayOnly: true,
                allowedCandidateKinds: [.relay]
            )
        }
    }

    static func acceptsDataChannel(_ properties: WebRTCDataChannelProperties) -> Bool {
        properties.label == "macchannel"
            && properties.protocolName == "macchannel.secure.v1"
            && properties.isOrdered
            && properties.maxPacketLifeTime == UInt16.max
            && properties.maxRetransmits == UInt16.max
            && !properties.isNegotiated
    }

    public func connect(
        localIdentity: DeviceIdentity,
        remoteDevice: DeviceID,
        remotePublicKey: Data,
        connectionID: UUID,
        role: WebRTCRole,
        route: ConnectionRoute,
        ice: ICEConfiguration,
        signaling: any WebRTCSignalTransport
    ) async throws -> WebRTCSecureChannel {
        let driver = try WebRTCPeerDriver(
            factory: factory,
            localIdentity: localIdentity,
            remoteDevice: remoteDevice,
            remotePublicKey: remotePublicKey,
            connectionID: connectionID,
            role: role,
            route: route,
            ice: ice,
            signaling: signaling
        )
        await driver.retainForLifetime()
        do {
            return try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: WebRTCSecureChannel.self) { group in
                    group.addTask { try await driver.establish() }
                    group.addTask { [connectionTimeout] in
                        do {
                            try await Task.sleep(for: connectionTimeout)
                        } catch {
                            throw CancellationError()
                        }
                        await driver.timeout()
                        throw WebRTCFactoryError.timeout
                    }
                    defer { group.cancelAll() }
                    guard let result = try await group.next() else { throw WebRTCFactoryError.timeout }
                    return result
                }
            } onCancel: {
                Task { await driver.abort() }
            }
        } catch {
            await driver.abort()
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }
}

private final class PeerConnectionBox: @unchecked Sendable {
    let value: RTCPeerConnection
    init(_ value: RTCPeerConnection) { self.value = value }
}

private final class FactoryDataChannelBox: @unchecked Sendable {
    let value: RTCDataChannel
    init(_ value: RTCDataChannel) { self.value = value }
}

private final class WebRTCPeerDriver: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    // libwebrtc peer connections depend on the ObjC factory (and its worker
    // threads) remaining alive for their entire lifetime. The public factory
    // is commonly scoped only to connection setup, so the driver retains the
    // underlying factory until its secure channel closes.
    private let factoryOwner: RTCPeerConnectionFactory
    private let routePlan: WebRTCRoutePlan
    private let state: WebRTCPeerState

    init(
        factory: RTCPeerConnectionFactory,
        localIdentity: DeviceIdentity,
        remoteDevice: DeviceID,
        remotePublicKey: Data,
        connectionID: UUID,
        role: WebRTCRole,
        route: ConnectionRoute,
        ice: ICEConfiguration,
        signaling: any WebRTCSignalTransport
    ) throws {
        factoryOwner = factory
        let configuration = RTCConfiguration()
        let routePlan = WebRTCFactory.routePlan(for: route, ice: ice)
        self.routePlan = routePlan
        configuration.iceServers = routePlan.servers.map {
            RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
        }
        configuration.iceTransportPolicy = routePlan.relayOnly ? .relay : .all
        configuration.sdpSemantics = .unifiedPlan
        configuration.continualGatheringPolicy = .gatherOnce
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peer = factory.peerConnection(
            with: configuration,
            constraints: constraints,
            delegate: nil
        ) else {
            throw WebRTCFactoryError.peerConnectionCreationFailed
        }
        state = WebRTCPeerState(
            peer: PeerConnectionBox(peer),
            localIdentity: localIdentity,
            remoteDevice: remoteDevice,
            remotePublicKey: remotePublicKey,
            connectionID: connectionID,
            role: role,
            route: route,
            routePlan: routePlan,
            signaling: signaling
        )
        super.init()
        peer.delegate = self
    }

    func establish() async throws -> WebRTCSecureChannel { try await state.establish() }
    func timeout() async { await state.fail(.timeout) }
    func abort() async {
        await state.fail(.signalingEnded)
        await state.close()
    }
    func retainForLifetime() async { await state.retainDriver(self) }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if newState == .failed {
            Task { await state.fail(.iceFailed) }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        guard routePlan.allows(candidateSDP: candidate.sdp) else { return }
        Task {
            await state.generatedCandidate(
                sdp: candidate.sdp,
                lineIndex: candidate.sdpMLineIndex,
                mid: candidate.sdpMid
            )
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        Task { await state.openedRemoteDataChannel(FactoryDataChannelBox(dataChannel)) }
    }
}

private actor WebRTCPeerState {
    private static let maximumPendingRemoteCandidates = 128
    private static let maximumPendingRemoteCandidateBytes = 512 * 1024

    private let peer: PeerConnectionBox
    private let localIdentity: DeviceIdentity
    private let remoteDevice: DeviceID
    private let remotePublicKey: Data
    private let connectionID: UUID
    private let role: WebRTCRole
    private let route: ConnectionRoute
    private let routePlan: WebRTCRoutePlan
    private let signaling: any WebRTCSignalTransport
    private var secureChannel: WebRTCSecureChannel?
    private var channelWaiters: [CheckedContinuation<WebRTCSecureChannel, Error>] = []
    private var pendingRemoteCandidates: [RTCIceCandidate] = []
    private var pendingRemoteCandidateBytes = 0
    private var remoteDescriptionSet = false
    private var signalTask: Task<Void, Never>?
    private var candidateSendTasks: [UUID: Task<Void, Never>] = [:]
    private var teardownTask: Task<Void, Never>?
    private var driverOwner: WebRTCPeerDriver?
    private var terminalError: WebRTCFactoryError?
    private var closed = false

    init(
        peer: PeerConnectionBox,
        localIdentity: DeviceIdentity,
        remoteDevice: DeviceID,
        remotePublicKey: Data,
        connectionID: UUID,
        role: WebRTCRole,
        route: ConnectionRoute,
        routePlan: WebRTCRoutePlan,
        signaling: any WebRTCSignalTransport
    ) {
        self.peer = peer
        self.localIdentity = localIdentity
        self.remoteDevice = remoteDevice
        self.remotePublicKey = remotePublicKey
        self.connectionID = connectionID
        self.role = role
        self.route = route
        self.routePlan = routePlan
        self.signaling = signaling
    }

    func establish() async throws -> WebRTCSecureChannel {
        let messages = await signaling.messages(from: remoteDevice, connectionID: connectionID)
        signalTask = Task { [weak self] in
            do {
                for try await message in messages {
                    guard !Task.isCancelled else { return }
                    await self?.receivedSignal(message)
                }
                await self?.signalEnded()
            } catch let error as WebRTCFactoryError {
                await self?.signalFailed(error)
            } catch {
                await self?.signalEnded()
            }
        }

        if role == .offerer {
            let configuration = RTCDataChannelConfiguration()
            configuration.isOrdered = true
            configuration.maxPacketLifeTime = -1
            configuration.maxRetransmits = -1
            configuration.isNegotiated = false
            configuration.protocol = "macchannel.secure.v1"
            guard let dataChannel = peer.value.dataChannel(forLabel: "macchannel", configuration: configuration) else {
                throw WebRTCFactoryError.dataChannelCreationFailed
            }
            openedDataChannel(FactoryDataChannelBox(dataChannel))
            let offer = try await createOffer()
            try await setLocalDescription(offer)
            try await signaling.send(.offer(sdp: offer.sdp, route: route), to: remoteDevice, connectionID: connectionID)
        }

        let channel = try await waitForChannel()
        do {
            try await channel.authenticate()
            return channel
        } catch {
            await close()
            throw error
        }
    }

    func retainDriver(_ driver: WebRTCPeerDriver) {
        driverOwner = driver
    }

    func generatedCandidate(sdp: String, lineIndex: Int32, mid: String?) {
        guard !closed else { return }
        let taskID = UUID()
        let task = Task { [weak self, signaling, remoteDevice, connectionID] in
            guard !Task.isCancelled else { return }
            try? await signaling.send(
                .candidate(sdp: sdp, sdpMLineIndex: lineIndex, sdpMid: mid),
                to: remoteDevice,
                connectionID: connectionID
            )
            await self?.candidateSendFinished(taskID)
        }
        candidateSendTasks[taskID] = task
    }

    func openedRemoteDataChannel(_ dataChannel: FactoryDataChannelBox) {
        guard role == .answerer else { return }
        openedDataChannel(dataChannel)
    }

    func fail(_ error: WebRTCFactoryError) {
        guard terminalError == nil, !closed else { return }
        terminalError = error
        let waiters = channelWaiters
        channelWaiters.removeAll()
        waiters.forEach { $0.resume(throwing: error) }
        if let secureChannel {
            Task { await secureChannel.close() }
        } else {
            Task { await close() }
        }
    }

    private func openedDataChannel(_ dataChannel: FactoryDataChannelBox) {
        guard secureChannel == nil, terminalError == nil, !closed else {
            dataChannel.value.close()
            return
        }
        let properties = WebRTCDataChannelProperties(
            label: dataChannel.value.label,
            protocolName: dataChannel.value.`protocol`,
            isOrdered: dataChannel.value.isOrdered,
            maxPacketLifeTime: dataChannel.value.maxPacketLifeTime,
            maxRetransmits: dataChannel.value.maxRetransmits,
            isNegotiated: dataChannel.value.isNegotiated
        )
        guard WebRTCFactory.acceptsDataChannel(properties) else {
            dataChannel.value.close()
            fail(.dataChannelCreationFailed)
            return
        }
        let channel = WebRTCSecureChannel(
            connectionID: connectionID,
            role: role,
            route: route,
            channel: dataChannel.value,
            localIdentity: localIdentity,
            remoteDevice: remoteDevice,
            remotePublicKey: remotePublicKey,
            closeTransport: { await self.close() },
            testOnlyGenerateLocalCandidate: {
                await self.generatedCandidate(
                    sdp: "candidate:test 1 udp 1 192.168.1.20 7000 typ host",
                    lineIndex: 0,
                    mid: "0"
                )
            }
        )
        secureChannel = channel
        let waiters = channelWaiters
        channelWaiters.removeAll()
        waiters.forEach { $0.resume(returning: channel) }
    }

    private func waitForChannel() async throws -> WebRTCSecureChannel {
        if let secureChannel { return secureChannel }
        if let terminalError { throw terminalError }
        return try await withCheckedThrowingContinuation { continuation in
            channelWaiters.append(continuation)
        }
    }

    private func receivedSignal(_ message: WebRTCSignalMessage) async {
        guard terminalError == nil, !closed else { return }
        do {
            switch message {
            case let .offer(sdp, offeredRoute):
                guard role == .answerer, offeredRoute == route,
                      routePlan.allowsRemoteDescription(sdp)
                else {
                    fail(.sessionDescriptionFailed)
                    return
                }
                let offer = RTCSessionDescription(type: .offer, sdp: sdp)
                try await setRemoteDescription(offer)
                remoteDescriptionSet = true
                try await flushRemoteCandidates()
                let answer = try await createAnswer()
                try await setLocalDescription(answer)
                try await signaling.send(.answer(sdp: answer.sdp), to: remoteDevice, connectionID: connectionID)

            case let .answer(sdp):
                guard role == .offerer, routePlan.allowsRemoteDescription(sdp) else {
                    fail(.sessionDescriptionFailed)
                    return
                }
                try await setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp))
                remoteDescriptionSet = true
                try await flushRemoteCandidates()

            case let .candidate(sdp, lineIndex, mid):
                guard routePlan.allows(candidateSDP: sdp) else {
                    fail(.iceFailed)
                    return
                }
                let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: lineIndex, sdpMid: mid)
                if remoteDescriptionSet {
                    try await addRemoteCandidate(candidate)
                } else {
                    let candidateBytes = sdp.utf8.count + (mid?.utf8.count ?? 0) + 32
                    guard pendingRemoteCandidates.count < Self.maximumPendingRemoteCandidates,
                          pendingRemoteCandidateBytes + candidateBytes <= Self.maximumPendingRemoteCandidateBytes
                    else {
                        pendingRemoteCandidates.removeAll(keepingCapacity: false)
                        pendingRemoteCandidateBytes = 0
                        fail(.remoteCandidateOverflow)
                        return
                    }
                    pendingRemoteCandidates.append(candidate)
                    pendingRemoteCandidateBytes += candidateBytes
                }
            }
        } catch {
            fail(.sessionDescriptionFailed)
        }
    }

    private func signalEnded() {
        if secureChannel == nil { fail(.signalingEnded) }
    }

    private func signalFailed(_ error: WebRTCFactoryError) {
        if error == .signalingOverflow || secureChannel == nil { fail(error) }
    }

    private func createOffer() async throws -> RTCSessionDescription {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        return try await withCheckedThrowingContinuation { continuation in
            peer.value.offer(for: constraints) { description, error in
                guard let description, error == nil else {
                    continuation.resume(throwing: WebRTCFactoryError.sessionDescriptionFailed)
                    return
                }
                continuation.resume(returning: description)
            }
        }
    }

    private func createAnswer() async throws -> RTCSessionDescription {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        return try await withCheckedThrowingContinuation { continuation in
            peer.value.answer(for: constraints) { description, error in
                guard let description, error == nil else {
                    continuation.resume(throwing: WebRTCFactoryError.sessionDescriptionFailed)
                    return
                }
                continuation.resume(returning: description)
            }
        }
    }

    private func setLocalDescription(_ description: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.value.setLocalDescription(description) { error in
                if error == nil { continuation.resume() }
                else { continuation.resume(throwing: WebRTCFactoryError.sessionDescriptionFailed) }
            }
        }
    }

    private func setRemoteDescription(_ description: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.value.setRemoteDescription(description) { error in
                if error == nil { continuation.resume() }
                else { continuation.resume(throwing: WebRTCFactoryError.sessionDescriptionFailed) }
            }
        }
    }

    private func addRemoteCandidate(_ candidate: RTCIceCandidate) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.value.add(candidate) { error in
                if error == nil { continuation.resume() }
                else { continuation.resume(throwing: WebRTCFactoryError.iceFailed) }
            }
        }
    }

    private func flushRemoteCandidates() async throws {
        let candidates = pendingRemoteCandidates
        pendingRemoteCandidates.removeAll()
        pendingRemoteCandidateBytes = 0
        for candidate in candidates { try await addRemoteCandidate(candidate) }
    }

    fileprivate func close() async {
        let teardown = beginTeardown()
        await teardown.value
        secureChannel = nil
        driverOwner = nil
    }

    private func beginTeardown() -> Task<Void, Never> {
        if let teardownTask { return teardownTask }
        closed = true
        var tasks: [Task<Void, Never>] = []
        if let signalTask { tasks.append(signalTask) }
        tasks.append(contentsOf: candidateSendTasks.values)
        tasks.forEach { $0.cancel() }
        signalTask = nil
        candidateSendTasks.removeAll()
        pendingRemoteCandidates.removeAll(keepingCapacity: false)
        pendingRemoteCandidateBytes = 0
        peer.value.delegate = nil
        peer.value.close()
        finishChannelWaiters()
        let teardown = Task {
            for task in tasks { await task.value }
        }
        teardownTask = teardown
        return teardown
    }

    private func candidateSendFinished(_ taskID: UUID) {
        candidateSendTasks.removeValue(forKey: taskID)
    }

    private func finishChannelWaiters() {
        let waiters = channelWaiters
        channelWaiters.removeAll()
        waiters.forEach { $0.resume(throwing: terminalError ?? WebRTCFactoryError.signalingEnded) }
    }
}
