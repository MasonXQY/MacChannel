import Foundation

public struct AccountDeviceApproval: Sendable {
    let identity: DeviceIdentity
    let intentStorage: any AccountGroupApprovalIntentStorage
    public init(identity: DeviceIdentity, intentStorage: any AccountGroupApprovalIntentStorage = KeychainAccountGroupApprovalIntentStorage()) {
        self.identity = identity; self.intentStorage = intentStorage
    }
}

public enum AccountDeviceApprovalError: Error, Equatable, Sendable {
    case unavailable, busy, invalidTicket, verificationMismatch, requestExpired
    case sessionChanged, requestConflict, invalidHistory, secureStorage
}

public struct AccountDeviceApprovalTicket: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public enum Operation: Sendable { case requestJoin, approveJoin, confirmJoin, verifyCommitted }
    public let id: UUID
    public let operation: Operation
    public let expiresAt: Date
    public let presentation: AccountDeviceApprovalPresentation
    public var description: String { "AccountDeviceApprovalTicket(<redacted>)" }
    public var debugDescription: String { description }
}

public struct AccountDeviceApprovalPresentation: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let requestID, groupID: String
    public let requestCode, fingerprint: String?
    public var description: String { "AccountDeviceApprovalPresentation(<redacted>)" }
    public var debugDescription: String { description }
}

public struct AccountDeviceApprovalView: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public enum Role: Sendable { case subject, actor, otherMember }
    public enum Phase: Sendable {
        case waitingForMember, needsMemberVerification, waitingForSubject, needsSubjectConfirmation
        case waitingForActor, verifyingHistory, joined, removed, rejected, cancelled, expired, invalidated
        case needsSignIn, retryableFailure
    }
    public let summary: AccountGroupPendingSummary
    public let role: Role
    public let phase: Phase
    public let requestCode, memberCode, fingerprint: String?
    public let snapshot: AccountGroupSnapshot?
    public var description: String { "AccountDeviceApprovalView(<redacted>)" }
    public var debugDescription: String { description }
}
