import CryptoKit
import Foundation

public actor PairingCoordinator: RendezvousPairingHostEndpoint {
    private struct HostedSession {
        let code: String
        let expiresAt: Date
        let ephemeralKey: P256.KeyAgreement.PrivateKey
        var used: Bool
    }

    private enum PendingRole {
        case host
        case joiner
    }

    private struct PendingConfirmation {
        let role: PendingRole
        let sessionID: PairingSessionID
        let fingerprint: String
        let peer: DeviceSummary
        let peerIdentityPublicKey: Data
        let transcript: Data
        let channelKey: SymmetricKey
        let expiresAt: Date
        let generation: UInt64
        var localConfirmed: Bool
        var issuedAuthorization: SignedTrustRecord?
        var deliveryReservation: PairingDeliveryReservation?
    }

    private let identity: DeviceIdentity
    private let displayName: String
    private let transport: any PairingTransport
    private let clock: any PairingClock
    private let trustRepository: TrustRepository
    private var hostedSession: HostedSession?
    private var pendingConfirmation: PendingConfirmation?
    private var lifecycleGeneration: UInt64 = 0
    private var codeCreationInProgress = false
    private var joinInProgress = false
    private var confirmationInProgress = false
    private var commitInProgress = false
    private var state: PairingState = .idle
    private let stateContinuation: AsyncStream<PairingState>.Continuation

    public nonisolated let states: AsyncStream<PairingState>

    public init(
        identity: DeviceIdentity,
        displayName: String = "Mac",
        trustRepository: TrustRepository,
        transport: any PairingTransport,
        clock: any PairingClock = SystemPairingClock()
    ) throws {
        guard trustRepository.ownerID == identity.id else {
            throw PairingError.invalidTrustStore
        }
        self.identity = identity
        self.displayName = displayName
        self.trustRepository = trustRepository
        self.transport = transport
        self.clock = clock
        let stream = AsyncStream<PairingState>.makeStream()
        states = stream.stream
        stateContinuation = stream.continuation
        stateContinuation.yield(.idle)
    }

    deinit {
        stateContinuation.finish()
    }

    public func pendingPeerSummary() -> DeviceSummary? {
        pendingConfirmation?.peer
    }

    public func createCode() async throws -> String {
        guard !codeCreationInProgress, !joinInProgress, !commitInProgress else {
            throw PairingError.operationInProgress
        }
        guard pendingConfirmation?.issuedAuthorization == nil else {
            throw PairingError.operationInProgress
        }
        codeCreationInProgress = true
        defer { codeCreationInProgress = false }
        if let reservation = pendingConfirmation?.deliveryReservation {
            await transport.cancelAuthorizationDelivery(reservation)
            pendingConfirmation = nil
        }
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
            lifecycleGeneration = try nextGeneration()
            pendingConfirmation = nil
            hostedSession = HostedSession(
                code: code,
                expiresAt: expiresAt,
                ephemeralKey: ephemeralKey,
                used: false
            )
            transition(to: .displayingCode(expiresAt: expiresAt))
            return code
        } catch {
            transitionToFailure(error)
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
            transitionToFailure(error)
            throw error
        }
    }

    public func join(code: String) async throws -> PairingJoinResult {
        guard !joinInProgress, !codeCreationInProgress, !commitInProgress, pendingConfirmation == nil else {
            throw PairingError.operationInProgress
        }
        joinInProgress = true
        defer { joinInProgress = false }
        transition(to: .joining)
        do {
            let offer = try await transport.lookup(code: code)
            let hostIdentityKey = try validatedIdentityKey(
                id: offer.hostID,
                rawRepresentation: offer.hostIdentityPublicKey
            )
            guard let hostEphemeralKey = try? P256.KeyAgreement.PublicKey(
                rawRepresentation: offer.hostEphemeralPublicKey
            ) else {
                throw PairingError.invalidHandshake
            }
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
                    message: transcript,
                    key: channelKey
                )
            )
            let response = try await transport.submit(code: code, request: request)
            let responseTranscript = PairingCryptography.sessionBoundTranscript(
                transcript,
                sessionID: response.sessionID
            )
            try PairingCryptography.verifySignature(
                response.hostIdentitySignature,
                message: responseTranscript,
                publicKey: hostIdentityKey
            )
            guard PairingCryptography.isValidChannelTag(
                response.channelTag,
                label: "host-confirmation",
                message: responseTranscript,
                key: channelKey
            ) else {
                throw PairingError.invalidHandshake
            }

            let fingerprint = PairingCryptography.fingerprint(
                hostPublicKey: offer.hostEphemeralPublicKey,
                joiningPublicKey: joiningEphemeralKey.publicKey.rawRepresentation
            )
            let peer = DeviceSummary(
                id: offer.hostID,
                displayName: offer.hostDisplayName,
                availability: .internet
            )
            lifecycleGeneration = try nextGeneration()
            pendingConfirmation = PendingConfirmation(
                role: .joiner,
                sessionID: response.sessionID,
                fingerprint: fingerprint,
                peer: peer,
                peerIdentityPublicKey: offer.hostIdentityPublicKey,
                transcript: transcript,
                channelKey: channelKey,
                expiresAt: offer.expiresAt,
                generation: lifecycleGeneration,
                localConfirmed: false,
                issuedAuthorization: nil,
                deliveryReservation: nil
            )
            transition(to: .awaitingFingerprint(local: fingerprint, remote: fingerprint))
            return PairingJoinResult(
                sessionID: response.sessionID,
                peer: peer,
                fingerprint: fingerprint,
                hostEphemeralPublicKey: offer.hostEphemeralPublicKey,
                joiningEphemeralPublicKey: joiningEphemeralKey.publicKey.rawRepresentation
            )
        } catch {
            if pendingConfirmation == nil {
                transitionToFailure(error)
            }
            throw normalizedHandshakeError(error)
        }
    }

    public func accept(_ request: PairingJoinRequest) async throws -> PairingJoinResponse {
        try await accept(request, sessionID: PairingSessionID())
    }

    public func accept(
        _ request: PairingJoinRequest,
        sessionID: PairingSessionID
    ) async throws -> PairingJoinResponse {
        do {
            guard !codeCreationInProgress, !commitInProgress, pendingConfirmation == nil else {
                throw PairingError.operationInProgress
            }
            var session = try validatedSession(for: request.code)
            let joiningIdentityKey = try validatedIdentityKey(
                id: request.joiningID,
                rawRepresentation: request.joiningIdentityPublicKey
            )
            guard let joiningEphemeralKey = try? P256.KeyAgreement.PublicKey(
                rawRepresentation: request.joiningEphemeralPublicKey
            ) else {
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
            guard PairingCryptography.isValidChannelTag(
                request.channelTag,
                label: "join-confirmation",
                message: transcript,
                key: channelKey
            ) else {
                throw PairingError.invalidHandshake
            }

            session.used = true
            hostedSession = session
            let responseTranscript = PairingCryptography.sessionBoundTranscript(
                transcript,
                sessionID: sessionID
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
            lifecycleGeneration = try nextGeneration()
            pendingConfirmation = PendingConfirmation(
                role: .host,
                sessionID: sessionID,
                fingerprint: fingerprint,
                peer: peer,
                peerIdentityPublicKey: request.joiningIdentityPublicKey,
                transcript: transcript,
                channelKey: channelKey,
                expiresAt: session.expiresAt,
                generation: lifecycleGeneration,
                localConfirmed: false,
                issuedAuthorization: nil,
                deliveryReservation: nil
            )
            transition(to: .awaitingFingerprint(local: fingerprint, remote: fingerprint))
            return PairingJoinResponse(
                sessionID: sessionID,
                hostIdentitySignature: try identity.sign(responseTranscript).derRepresentation,
                channelTag: PairingCryptography.channelTag(
                    label: "host-confirmation",
                    message: responseTranscript,
                    key: channelKey
                )
            )
        } catch {
            if pendingConfirmation == nil {
                transitionToFailure(error)
            }
            throw normalizedHandshakeError(error)
        }
    }

    @discardableResult
    public func confirmFingerprint(_ fingerprint: String) async throws -> SignedTrustRecord {
        guard !confirmationInProgress, !codeCreationInProgress, !joinInProgress, !commitInProgress else {
            throw PairingError.operationInProgress
        }
        confirmationInProgress = true
        defer { confirmationInProgress = false }
        guard var pending = pendingConfirmation else {
            let error = PairingError.noPendingConfirmation
            transitionToFailure(error)
            throw error
        }
        guard pending.fingerprint == fingerprint else {
            if pending.issuedAuthorization != nil {
                let error = PairingError.fingerprintMismatch
                transitionToFailure(error)
                throw error
            }
            if let reservation = pending.deliveryReservation {
                await transport.cancelAuthorizationDelivery(reservation)
            }
            clearPendingIfMatching(pending)
            let error = PairingError.fingerprintMismatch
            transitionToFailure(error)
            throw error
        }

        pending.localConfirmed = true
        pendingConfirmation = pending
        do {
            switch pending.role {
            case .host:
                return try await confirmAsHost(pending)
            case .joiner:
                return try await confirmAsJoiner(pending)
            }
        } catch {
            if pendingMatches(pending) {
                transitionToFailure(error)
            }
            throw error
        }
    }

    public func currentState() -> PairingState {
        state
    }

    public func isTrusted(_ device: DeviceID) async -> Bool {
        await trustRepository.isTrusted(device)
    }

    public func cancelPendingPairing() async throws {
        guard !commitInProgress,
              !confirmationInProgress,
              !joinInProgress,
              !codeCreationInProgress
        else { throw PairingError.operationInProgress }
        guard let pending = pendingConfirmation else { return }
        guard pending.issuedAuthorization == nil else {
            throw PairingError.operationInProgress
        }
        commitInProgress = true
        defer { commitInProgress = false }
        clearPendingIfMatching(pending)
        transition(to: .idle)
        if let reservation = pending.deliveryReservation {
            await transport.cancelAuthorizationDelivery(reservation)
        }
    }

    private func confirmAsHost(
        _ suppliedPending: PendingConfirmation
    ) async throws -> SignedTrustRecord {
        var pending = suppliedPending
        let reservation: PairingDeliveryReservation
        if let existing = pending.deliveryReservation {
            reservation = existing
            guard pendingMatches(pending), !codeCreationInProgress else {
                throw PairingError.staleOperation
            }
        } else {
            try validatePendingIsCurrentAndLive(pending)
            let created = try await transport.reserveAuthorizationDelivery(for: pending.sessionID)
            guard pendingMatches(pending), !codeCreationInProgress else {
                await transport.cancelAuthorizationDelivery(created)
                throw PairingError.staleOperation
            }
            pending.deliveryReservation = created
            pendingConfirmation = pending
            reservation = created
        }
        commitInProgress = true
        defer { commitInProgress = false }
        let authorization: SignedTrustRecord
        do {
            if let existing = pending.issuedAuthorization {
                authorization = existing
            } else {
                authorization = try await trustRepository.issueAuthorization(
                    subject: pending.peer.id,
                    subjectPublicKey: pending.peerIdentityPublicKey,
                    timestamp: clock.now
                )
                guard pendingMatches(pending) else {
                    await transport.cancelAuthorizationDelivery(reservation)
                    throw PairingError.staleOperation
                }
                pending.issuedAuthorization = authorization
                pendingConfirmation = pending
            }
        } catch {
            await transport.cancelAuthorizationDelivery(reservation)
            if pendingMatches(pending) {
                pending.deliveryReservation = nil
                pendingConfirmation = pending
            }
            throw error
        }

        let message = try PairingCryptography.authorizationMessage(
            transcript: pending.transcript,
            sessionID: pending.sessionID,
            authorization: authorization
        )
        let envelope = PairingAuthorizationEnvelope(
            sessionID: pending.sessionID,
            authorization: authorization,
            channelTag: PairingCryptography.channelTag(
                label: "authorization",
                message: message,
                key: pending.channelKey
            )
        )
        try await transport.deliverAuthorization(envelope, reservation: reservation)
        guard pendingMatches(pending), !codeCreationInProgress else { throw PairingError.staleOperation }
        clearPendingIfMatching(pending)
        transition(to: .confirmed(pending.peer))
        return authorization
    }

    private func confirmAsJoiner(
        _ pending: PendingConfirmation
    ) async throws -> SignedTrustRecord {
        guard pendingMatches(pending) else { throw PairingError.staleOperation }
        guard !codeCreationInProgress else { throw PairingError.staleOperation }
        let envelope = try await transport.authorization(for: pending.sessionID)
        guard pendingMatches(pending), !codeCreationInProgress else {
            throw PairingError.staleOperation
        }
        guard envelope.sessionID == pending.sessionID else {
            throw PairingError.invalidHandshake
        }
        let message = try PairingCryptography.authorizationMessage(
            transcript: pending.transcript,
            sessionID: pending.sessionID,
            authorization: envelope.authorization
        )
        guard PairingCryptography.isValidChannelTag(
            envelope.channelTag,
            label: "authorization",
            message: message,
            key: pending.channelKey
        ) else {
            throw PairingError.invalidHandshake
        }
        try envelope.authorization.validated()
        guard envelope.authorization.action == .authorize,
              envelope.authorization.issuer == pending.peer.id,
              envelope.authorization.issuerPublicKey == pending.peerIdentityPublicKey,
              envelope.authorization.subject == identity.id,
              envelope.authorization.subjectPublicKey == identity.publicKey.rawRepresentation
        else {
            throw PairingError.invalidHandshake
        }
        guard pendingMatches(pending) else { throw PairingError.staleOperation }
        commitInProgress = true
        defer { commitInProgress = false }
        try await trustRepository.bootstrapFromConfirmedPairing(envelope.authorization)
        guard pendingMatches(pending) else { throw PairingError.staleOperation }
        clearPendingIfMatching(pending)
        transition(to: .confirmed(pending.peer))
        return envelope.authorization
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

    private func nextGeneration() throws -> UInt64 {
        let next = lifecycleGeneration.addingReportingOverflow(1)
        guard !next.overflow else { throw PairingError.resourceExhausted }
        return next.partialValue
    }

    private func pendingMatches(_ pending: PendingConfirmation) -> Bool {
        pendingConfirmation?.sessionID == pending.sessionID
            && pendingConfirmation?.generation == pending.generation
    }

    private func clearPendingIfMatching(_ pending: PendingConfirmation) {
        guard pendingMatches(pending) else { return }
        pendingConfirmation = nil
    }

    private func validatePendingIsCurrentAndLive(_ pending: PendingConfirmation) throws {
        guard pendingMatches(pending) else { throw PairingError.staleOperation }
        guard clock.now < pending.expiresAt else { throw PairingError.sessionExpired }
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

    private func transition(to newState: PairingState) {
        state = newState
        stateContinuation.yield(newState)
    }

    private func transitionToFailure(_ error: Error) {
        if let pairingError = error as? PairingError {
            transition(to: .failed(pairingError.stateError))
        } else if error is TrustStoreError || error is TrustRecordValidationError {
            transition(to: .failed(.pairingTrustFailed))
        } else {
            transition(to: .failed(.pairingHandshakeFailed))
        }
    }

    private func normalizedHandshakeError(_ error: Error) -> Error {
        if error is PairingError || error is TrustStoreError || error is TrustRecordValidationError {
            return error
        }
        return PairingError.invalidHandshake
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

    static func sessionBoundTranscript(
        _ transcript: Data,
        sessionID: PairingSessionID
    ) -> Data {
        transcript + Data(sessionID.rawValue.uuidString.lowercased().utf8)
    }

    static func authorizationMessage(
        transcript: Data,
        sessionID: PairingSessionID,
        authorization: SignedTrustRecord
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return sessionBoundTranscript(transcript, sessionID: sessionID)
            + (try encoder.encode(authorization))
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

    static func channelTag(label: String, message: Data, key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(
            for: Data(label.utf8) + message,
            using: key
        ))
    }

    static func isValidChannelTag(
        _ tag: Data,
        label: String,
        message: Data,
        key: SymmetricKey
    ) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(
            tag,
            authenticating: Data(label.utf8) + message,
            using: key
        )
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
