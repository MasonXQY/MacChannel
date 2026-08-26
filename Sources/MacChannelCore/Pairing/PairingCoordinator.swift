import CryptoKit
import Foundation

public actor PairingCoordinator: PairingHostEndpoint {
    private struct HostedSession {
        let code: String
        let expiresAt: Date
        let ephemeralKey: P256.KeyAgreement.PrivateKey
        var used: Bool
    }

    private struct PendingConfirmation {
        let fingerprint: String
        let peer: DeviceSummary
        let authorization: SignedTrustRecord
    }

    private let identity: DeviceIdentity
    private let displayName: String
    private let transport: any PairingTransport
    private let clock: any PairingClock
    private var trustStore: TrustStore
    private var hostedSession: HostedSession?
    private var pendingConfirmation: PendingConfirmation?
    private var authorizationSequence: UInt64 = 0
    private var state: PairingState = .idle
    private let stateContinuation: AsyncStream<PairingState>.Continuation

    public nonisolated let states: AsyncStream<PairingState>

    public init(
        identity: DeviceIdentity,
        displayName: String = "Mac",
        transport: any PairingTransport,
        clock: any PairingClock = SystemPairingClock()
    ) {
        self.identity = identity
        self.displayName = displayName
        self.transport = transport
        self.clock = clock
        trustStore = TrustStore(owner: identity.id)
        let stream = AsyncStream<PairingState>.makeStream()
        states = stream.stream
        stateContinuation = stream.continuation
        stateContinuation.yield(.idle)
    }

    deinit {
        stateContinuation.finish()
    }

    public func createCode() async throws -> String {
        if let previous = hostedSession {
            await transport.remove(code: previous.code)
        }

        let code = String(format: "%06d", Int.random(in: 0..<1_000_000))
        let expiresAt = clock.now.addingTimeInterval(300)
        let ephemeralKey = P256.KeyAgreement.PrivateKey()
        let offer = PairingOffer(
            code: code,
            expiresAt: expiresAt,
            hostID: identity.id,
            hostIdentityPublicKey: identity.publicKey.rawRepresentation,
            hostEphemeralPublicKey: ephemeralKey.publicKey.rawRepresentation,
            hostDisplayName: displayName
        )
        do {
            try await transport.publish(offer, endpoint: self)
            hostedSession = HostedSession(
                code: code,
                expiresAt: expiresAt,
                ephemeralKey: ephemeralKey,
                used: false
            )
            transition(to: .displayingCode(expiresAt: expiresAt))
            return code
        } catch {
            transition(to: .failed(.connectionFailed))
            throw error
        }
    }

    @discardableResult
    public func accept(code: String) throws -> PairingCodeAcceptance {
        do {
            var session = try validatedSession(for: code)
            session.used = true
            hostedSession = session
            return PairingCodeAcceptance(expiresAt: session.expiresAt)
        } catch {
            transition(to: .failed(.connectionFailed))
            throw error
        }
    }

    public func join(
        code: String,
        source: String? = nil
    ) async throws -> PairingJoinResult {
        transition(to: .joining)
        let resolvedSource = source ?? identity.id.rawValue.uuidString.lowercased()
        do {
            let offer = try await transport.lookup(code: code, source: resolvedSource)
            let hostIdentityKey = try validatedIdentityKey(
                id: offer.hostID,
                rawRepresentation: offer.hostIdentityPublicKey
            )
            let hostEphemeralKey = try P256.KeyAgreement.PublicKey(
                rawRepresentation: offer.hostEphemeralPublicKey
            )
            let joiningEphemeralKey = P256.KeyAgreement.PrivateKey()
            let transcript = try PairingCryptography.transcript(
                offer: offer,
                joiningID: identity.id,
                joiningIdentityPublicKey: identity.publicKey.rawRepresentation,
                joiningEphemeralPublicKey: joiningEphemeralKey.publicKey.rawRepresentation,
                joiningDisplayName: displayName
            )
            let channelKey = try PairingCryptography.channelKey(
                privateKey: joiningEphemeralKey,
                remotePublicKey: hostEphemeralKey,
                transcript: transcript
            )
            let request = PairingJoinRequest(
                code: code,
                joiningID: identity.id,
                joiningIdentityPublicKey: identity.publicKey.rawRepresentation,
                joiningEphemeralPublicKey: joiningEphemeralKey.publicKey.rawRepresentation,
                joiningDisplayName: displayName,
                identitySignature: try identity.sign(transcript).derRepresentation,
                channelTag: PairingCryptography.channelTag(
                    label: "join-confirmation",
                    transcript: transcript,
                    key: channelKey
                )
            )
            let response = try await transport.submit(
                code: code,
                source: resolvedSource,
                request: request
            )
            try PairingCryptography.verifySignature(
                response.hostIdentitySignature,
                message: transcript,
                publicKey: hostIdentityKey
            )
            guard PairingCryptography.channelTag(
                label: "host-confirmation",
                transcript: transcript,
                key: channelKey
            ) == response.channelTag else {
                throw PairingError.invalidHandshake
            }
            try response.authorization.validated()
            guard response.authorization.issuer == offer.hostID,
                  response.authorization.issuerPublicKey == offer.hostIdentityPublicKey,
                  response.authorization.subject == identity.id,
                  response.authorization.subjectPublicKey == identity.publicKey.rawRepresentation,
                  response.authorization.action == .authorize
            else {
                throw PairingError.invalidHandshake
            }

            let sequence = try reserveAuthorizationSequence()
            let localAuthorization = try SignedTrustRecord.authorizing(
                subject: offer.hostID,
                subjectPublicKey: offer.hostIdentityPublicKey,
                signedBy: identity,
                sequence: sequence,
                timestamp: clock.now
            )
            let fingerprint = PairingCryptography.fingerprint(
                hostPublicKey: offer.hostEphemeralPublicKey,
                joiningPublicKey: joiningEphemeralKey.publicKey.rawRepresentation
            )
            let peer = DeviceSummary(
                id: offer.hostID,
                displayName: offer.hostDisplayName,
                availability: .internet
            )
            pendingConfirmation = PendingConfirmation(
                fingerprint: fingerprint,
                peer: peer,
                authorization: localAuthorization
            )
            transition(to: .awaitingFingerprint(local: fingerprint, remote: fingerprint))
            return PairingJoinResult(
                peer: peer,
                fingerprint: fingerprint,
                hostEphemeralPublicKey: offer.hostEphemeralPublicKey,
                joiningEphemeralPublicKey: joiningEphemeralKey.publicKey.rawRepresentation,
                authorization: response.authorization
            )
        } catch {
            transition(to: .failed(.connectionFailed))
            throw error
        }
    }

    public func accept(_ request: PairingJoinRequest) async throws -> PairingJoinResponse {
        do {
            var session = try validatedSession(for: request.code)
            let joiningIdentityKey = try validatedIdentityKey(
                id: request.joiningID,
                rawRepresentation: request.joiningIdentityPublicKey
            )
            let joiningEphemeralKey: P256.KeyAgreement.PublicKey
            do {
                joiningEphemeralKey = try P256.KeyAgreement.PublicKey(
                    rawRepresentation: request.joiningEphemeralPublicKey
                )
            } catch {
                throw PairingError.invalidHandshake
            }
            let offer = PairingOffer(
                code: session.code,
                expiresAt: session.expiresAt,
                hostID: identity.id,
                hostIdentityPublicKey: identity.publicKey.rawRepresentation,
                hostEphemeralPublicKey: session.ephemeralKey.publicKey.rawRepresentation,
                hostDisplayName: displayName
            )
            let transcript = try PairingCryptography.transcript(
                offer: offer,
                joiningID: request.joiningID,
                joiningIdentityPublicKey: request.joiningIdentityPublicKey,
                joiningEphemeralPublicKey: request.joiningEphemeralPublicKey,
                joiningDisplayName: request.joiningDisplayName
            )
            try PairingCryptography.verifySignature(
                request.identitySignature,
                message: transcript,
                publicKey: joiningIdentityKey
            )
            let channelKey = try PairingCryptography.channelKey(
                privateKey: session.ephemeralKey,
                remotePublicKey: joiningEphemeralKey,
                transcript: transcript
            )
            guard PairingCryptography.channelTag(
                label: "join-confirmation",
                transcript: transcript,
                key: channelKey
            ) == request.channelTag else {
                throw PairingError.invalidHandshake
            }

            session.used = true
            hostedSession = session
            let sequence = try reserveAuthorizationSequence()
            let authorization = try SignedTrustRecord.authorizing(
                subject: request.joiningID,
                subjectPublicKey: request.joiningIdentityPublicKey,
                signedBy: identity,
                sequence: sequence,
                timestamp: clock.now
            )
            let fingerprint = PairingCryptography.fingerprint(
                hostPublicKey: session.ephemeralKey.publicKey.rawRepresentation,
                joiningPublicKey: request.joiningEphemeralPublicKey
            )
            let peer = DeviceSummary(
                id: request.joiningID,
                displayName: request.joiningDisplayName,
                availability: .internet
            )
            pendingConfirmation = PendingConfirmation(
                fingerprint: fingerprint,
                peer: peer,
                authorization: authorization
            )
            transition(to: .awaitingFingerprint(local: fingerprint, remote: fingerprint))
            return PairingJoinResponse(
                hostIdentitySignature: try identity.sign(transcript).derRepresentation,
                channelTag: PairingCryptography.channelTag(
                    label: "host-confirmation",
                    transcript: transcript,
                    key: channelKey
                ),
                authorization: authorization
            )
        } catch {
            transition(to: .failed(.connectionFailed))
            throw error
        }
    }

    public func confirmFingerprint(_ fingerprint: String) throws {
        guard let pendingConfirmation else {
            throw PairingError.noPendingConfirmation
        }
        guard pendingConfirmation.fingerprint == fingerprint else {
            self.pendingConfirmation = nil
            transition(to: .failed(.connectionFailed))
            throw PairingError.fingerprintMismatch
        }
        do {
            try trustStore.authorize(pendingConfirmation.authorization)
            self.pendingConfirmation = nil
            transition(to: .confirmed(pendingConfirmation.peer))
        } catch {
            self.pendingConfirmation = nil
            transition(to: .failed(.connectionFailed))
            throw error
        }
    }

    public func currentState() -> PairingState {
        state
    }

    public func isTrusted(_ device: DeviceID) -> Bool {
        trustStore.isTrusted(device)
    }

    private func validatedSession(for code: String) throws -> HostedSession {
        guard code.count == 6,
              code.allSatisfy({ $0.isASCII && $0.isNumber }),
              let session = hostedSession,
              session.code == code
        else {
            throw PairingError.invalidCode
        }
        guard !session.used else {
            throw PairingError.codeAlreadyUsed
        }
        guard clock.now < session.expiresAt else {
            throw PairingError.codeExpired
        }
        return session
    }

    private func validatedIdentityKey(
        id: DeviceID,
        rawRepresentation: Data
    ) throws -> P256.Signing.PublicKey {
        guard DeviceIdentity.deviceID(for: rawRepresentation) == id,
              let key = try? P256.Signing.PublicKey(rawRepresentation: rawRepresentation)
        else {
            throw PairingError.invalidPeerIdentity
        }
        return key
    }

    private func reserveAuthorizationSequence() throws -> UInt64 {
        let next = authorizationSequence.addingReportingOverflow(1)
        guard !next.overflow else {
            throw PairingError.authorizationSequenceExhausted
        }
        authorizationSequence = next.partialValue
        return next.partialValue
    }

    private func transition(to newState: PairingState) {
        state = newState
        stateContinuation.yield(newState)
    }
}

private enum PairingCryptography {
    static func transcript(
        offer: PairingOffer,
        joiningID: DeviceID,
        joiningIdentityPublicKey: Data,
        joiningEphemeralPublicKey: Data,
        joiningDisplayName: String
    ) throws -> Data {
        struct Transcript: Encodable {
            let code: String
            let expiresAtMilliseconds: Int64
            let hostDisplayName: String
            let hostEphemeralPublicKey: String
            let hostID: String
            let hostIdentityPublicKey: String
            let joiningDisplayName: String
            let joiningEphemeralPublicKey: String
            let joiningID: String
            let joiningIdentityPublicKey: String
        }
        let milliseconds = offer.expiresAt.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              milliseconds > Double(Int64.min),
              milliseconds < Double(Int64.max)
        else {
            throw PairingError.invalidHandshake
        }
        let value = Transcript(
            code: offer.code,
            expiresAtMilliseconds: Int64(milliseconds.rounded(.down)),
            hostDisplayName: offer.hostDisplayName,
            hostEphemeralPublicKey: offer.hostEphemeralPublicKey.base64EncodedString(),
            hostID: offer.hostID.rawValue.uuidString.lowercased(),
            hostIdentityPublicKey: offer.hostIdentityPublicKey.base64EncodedString(),
            joiningDisplayName: joiningDisplayName,
            joiningEphemeralPublicKey: joiningEphemeralPublicKey.base64EncodedString(),
            joiningID: joiningID.rawValue.uuidString.lowercased(),
            joiningIdentityPublicKey: joiningIdentityPublicKey.base64EncodedString()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func channelKey(
        privateKey: P256.KeyAgreement.PrivateKey,
        remotePublicKey: P256.KeyAgreement.PublicKey,
        transcript: Data
    ) throws -> SymmetricKey {
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: remotePublicKey)
        return secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("MacChannel pairing v1".utf8),
            sharedInfo: transcript,
            outputByteCount: 32
        )
    }

    static func channelTag(label: String, transcript: Data, key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(
            for: Data(label.utf8) + transcript,
            using: key
        ))
    }

    static func verifySignature(
        _ signature: Data,
        message: Data,
        publicKey: P256.Signing.PublicKey
    ) throws {
        guard let parsed = try? P256.Signing.ECDSASignature(derRepresentation: signature),
              publicKey.isValidSignature(parsed, for: message)
        else {
            throw PairingError.invalidHandshake
        }
    }

    static func fingerprint(hostPublicKey: Data, joiningPublicKey: Data) -> String {
        SHA256.hash(data: hostPublicKey + joiningPublicKey)
            .prefix(6)
            .map { String(format: "%02x", $0) }
            .joined()
    }

}
