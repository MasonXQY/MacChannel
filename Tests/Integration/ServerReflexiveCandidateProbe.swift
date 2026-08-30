import Foundation
@preconcurrency import WebRTC
@testable import MacChannelCore

enum ServerReflexiveCandidateProbeError: Error, Equatable {
    case peerConnectionCreationFailed
    case offerFailed
    case localDescriptionFailed
    case noServerReflexiveCandidate
    case timedOut
}

enum ServerReflexiveCandidateProbe {
    static func gather(
        using configuration: ICEConfiguration,
        timeout: Duration
    ) async throws -> String {
        RTCInitializeSSL()
        let factory = RTCPeerConnectionFactory()
        let recorder = ICECandidateRecorder()
        let rtcConfiguration = RTCConfiguration()
        rtcConfiguration.iceServers = configuration.stunURLs.map {
            RTCIceServer(urlStrings: [$0])
        }
        rtcConfiguration.iceTransportPolicy = .all
        rtcConfiguration.sdpSemantics = .unifiedPlan
        rtcConfiguration.continualGatheringPolicy = .gatherOnce
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peer = factory.peerConnection(
            with: rtcConfiguration,
            constraints: constraints,
            delegate: recorder
        ) else {
            throw ServerReflexiveCandidateProbeError.peerConnectionCreationFailed
        }
        defer { peer.close() }
        let dataChannelConfiguration = RTCDataChannelConfiguration()
        dataChannelConfiguration.isOrdered = true
        dataChannelConfiguration.maxPacketLifeTime = -1
        dataChannelConfiguration.maxRetransmits = -1
        _ = peer.dataChannel(forLabel: "macchannel-probe", configuration: dataChannelConfiguration)
        let offer = try await createOffer(peer)
        try await setLocalDescription(offer, on: peer)
        let candidates = recorder.candidates()

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                for await candidate in candidates where candidate.contains(" typ srflx") {
                    return candidate
                }
                throw ServerReflexiveCandidateProbeError.noServerReflexiveCandidate
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ServerReflexiveCandidateProbeError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw ServerReflexiveCandidateProbeError.noServerReflexiveCandidate
            }
            return first
        }
    }

    private static func createOffer(_ peer: RTCPeerConnection) async throws
        -> RTCSessionDescription
    {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        return try await withCheckedThrowingContinuation { continuation in
            peer.offer(for: constraints) { description, error in
                guard let description, error == nil else {
                    continuation.resume(
                        throwing: ServerReflexiveCandidateProbeError.offerFailed)
                    return
                }
                continuation.resume(returning: description)
            }
        }
    }

    private static func setLocalDescription(
        _ description: RTCSessionDescription,
        on peer: RTCPeerConnection
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            peer.setLocalDescription(description) { error in
                if error == nil {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: ServerReflexiveCandidateProbeError.localDescriptionFailed)
                }
            }
        }
    }
}

private final class ICECandidateRecorder: NSObject, RTCPeerConnectionDelegate,
    @unchecked Sendable
{
    private let stream: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation

    override init() {
        var continuation: AsyncStream<String>.Continuation!
        stream = AsyncStream(bufferingPolicy: .bufferingNewest(128)) {
            continuation = $0
        }
        self.continuation = continuation
        super.init()
    }

    func candidates() -> AsyncStream<String> { stream }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete { continuation.finish() }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        continuation.yield(candidate.sdp)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
