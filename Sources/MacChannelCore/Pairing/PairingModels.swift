import Foundation

public enum PairingError: Error, Equatable, Sendable {
    case invalidCode
    case codeExpired
    case codeAlreadyUsed
    case rateLimited
    case fingerprintMismatch
    case noPendingConfirmation
    case invalidPeerIdentity
    case invalidHandshake
    case authorizationSequenceExhausted
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

public struct PairingJoinResult: Sendable {
    public let peer: DeviceSummary
    public let fingerprint: String
    public let hostEphemeralPublicKey: Data
    public let joiningEphemeralPublicKey: Data
    public let authorization: SignedTrustRecord

    public init(
        peer: DeviceSummary,
        fingerprint: String,
        hostEphemeralPublicKey: Data,
        joiningEphemeralPublicKey: Data,
        authorization: SignedTrustRecord
    ) {
        self.peer = peer
        self.fingerprint = fingerprint
        self.hostEphemeralPublicKey = hostEphemeralPublicKey
        self.joiningEphemeralPublicKey = joiningEphemeralPublicKey
        self.authorization = authorization
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
    public let hostIdentitySignature: Data
    public let channelTag: Data
    public let authorization: SignedTrustRecord

    public init(
        hostIdentitySignature: Data,
        channelTag: Data,
        authorization: SignedTrustRecord
    ) {
        self.hostIdentitySignature = hostIdentitySignature
        self.channelTag = channelTag
        self.authorization = authorization
    }
}
