import Foundation

public enum PairingError: Error, Equatable, Sendable {
    case invalidCode
    case codeExpired
    case codeAlreadyUsed
    case rateLimited
    case fingerprintMismatch
    case authorizationPending
    case noPendingConfirmation
    case invalidPeerIdentity
    case invalidHandshake
    case invalidTrustStore
    case sessionExpired
    case resourceExhausted
    case operationInProgress
    case staleOperation
}

extension PairingError {
    var stateError: MacChannelError {
        switch self {
        case .invalidCode:
            .pairingInvalidCode
        case .codeExpired:
            .pairingCodeExpired
        case .codeAlreadyUsed:
            .pairingCodeAlreadyUsed
        case .rateLimited:
            .pairingRateLimited
        case .fingerprintMismatch:
            .pairingFingerprintMismatch
        case .authorizationPending:
            .pairingAuthorizationPending
        case .invalidPeerIdentity, .invalidHandshake:
            .pairingHandshakeFailed
        case .noPendingConfirmation, .invalidTrustStore:
            .pairingTrustFailed
        case .sessionExpired:
            .pairingSessionExpired
        case .resourceExhausted:
            .pairingResourceExhausted
        case .operationInProgress:
            .pairingOperationInProgress
        case .staleOperation:
            .pairingStaleOperation
        }
    }
}

public enum PairingState: Equatable, Sendable {
    case idle
    case displayingCode(expiresAt: Date)
    case joining
    case awaitingFingerprint(local: String, remote: String)
    case confirmed(DeviceSummary)
    case failed(MacChannelError)
}

public struct PairingCodeAcceptance: Equatable, Sendable {
    public let expiresAt: Date

    public init(expiresAt: Date) {
        self.expiresAt = expiresAt
    }
}

public struct PairingSessionID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct PairingJoinResult: Sendable {
    public let sessionID: PairingSessionID
    public let peer: DeviceSummary
    public let fingerprint: String
    public let hostEphemeralPublicKey: Data
    public let joiningEphemeralPublicKey: Data

    public init(
        sessionID: PairingSessionID,
        peer: DeviceSummary,
        fingerprint: String,
        hostEphemeralPublicKey: Data,
        joiningEphemeralPublicKey: Data
    ) {
        self.sessionID = sessionID
        self.peer = peer
        self.fingerprint = fingerprint
        self.hostEphemeralPublicKey = hostEphemeralPublicKey
        self.joiningEphemeralPublicKey = joiningEphemeralPublicKey
    }
}

public protocol PairingClock: Sendable {
    var now: Date { get }
}

public struct SystemPairingClock: PairingClock {
    public init() {}
    public var now: Date { Date() }
}

public struct PairingOffer: Sendable {
    public let code: String
    public let expiresAt: Date
    public let hostID: DeviceID
    public let hostIdentityPublicKey: Data
    public let hostEphemeralPublicKey: Data
    public let hostDisplayName: String

    public init(
        code: String,
        expiresAt: Date,
        hostID: DeviceID,
        hostIdentityPublicKey: Data,
        hostEphemeralPublicKey: Data,
        hostDisplayName: String
    ) {
        self.code = code
        self.expiresAt = expiresAt
        self.hostID = hostID
        self.hostIdentityPublicKey = hostIdentityPublicKey
        self.hostEphemeralPublicKey = hostEphemeralPublicKey
        self.hostDisplayName = hostDisplayName
    }
}

public struct PairingJoinRequest: Sendable {
    public let code: String
    public let joiningID: DeviceID
    public let joiningIdentityPublicKey: Data
    public let joiningEphemeralPublicKey: Data
    public let joiningDisplayName: String
    public let identitySignature: Data
    public let channelTag: Data

    public init(
        code: String,
        joiningID: DeviceID,
        joiningIdentityPublicKey: Data,
        joiningEphemeralPublicKey: Data,
        joiningDisplayName: String,
        identitySignature: Data,
        channelTag: Data
    ) {
        self.code = code
        self.joiningID = joiningID
        self.joiningIdentityPublicKey = joiningIdentityPublicKey
        self.joiningEphemeralPublicKey = joiningEphemeralPublicKey
        self.joiningDisplayName = joiningDisplayName
        self.identitySignature = identitySignature
        self.channelTag = channelTag
    }
}

public struct PairingJoinResponse: Sendable {
    public let sessionID: PairingSessionID
    public let hostIdentitySignature: Data
    public let channelTag: Data

    public init(
        sessionID: PairingSessionID,
        hostIdentitySignature: Data,
        channelTag: Data
    ) {
        self.sessionID = sessionID
        self.hostIdentitySignature = hostIdentitySignature
        self.channelTag = channelTag
    }
}

public struct PairingAuthorizationEnvelope: Sendable {
    public let sessionID: PairingSessionID
    public let authorization: SignedTrustRecord
    public let channelTag: Data

    public init(
        sessionID: PairingSessionID,
        authorization: SignedTrustRecord,
        channelTag: Data
    ) {
        self.sessionID = sessionID
        self.authorization = authorization
        self.channelTag = channelTag
    }
}

public struct PairingDeliveryReservation: Hashable, Sendable {
    public let id: UUID
    public let sessionID: PairingSessionID

    init(id: UUID = UUID(), sessionID: PairingSessionID) {
        self.id = id
        self.sessionID = sessionID
    }
}

public enum PairingDeliveryStatus: Equatable, Sendable {
    case reserved
    case committed
}

public struct PairingSessionStorageCounts: Equatable, Sendable {
    public let routes: Int
    public let deliveries: Int
    public let reservations: Int

    public init(routes: Int, deliveries: Int, reservations: Int) {
        self.routes = routes
        self.deliveries = deliveries
        self.reservations = reservations
    }
}

public struct PairingLimiterStorageCounts: Equatable, Sendable {
    public let sources: Int
    public let codes: Int
    public let globalEvents: Int

    public init(sources: Int, codes: Int, globalEvents: Int) {
        self.sources = sources
        self.codes = codes
        self.globalEvents = globalEvents
    }
}
