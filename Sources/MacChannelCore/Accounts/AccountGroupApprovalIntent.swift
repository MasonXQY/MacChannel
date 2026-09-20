import CryptoKit
import Foundation

/// Durable consent material. No tokens, private keys, signing, transport or trust mutations.
public struct AccountGroupApprovalIntent: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public enum Role: String, Sendable, Codable { case subject, actor }
    public struct Scope: Equatable, Sendable {
        public let binding: AccountSessionBinding
        public let accountID, requestID: String
        public let role: Role
        public init(binding: AccountSessionBinding, accountID: String, requestID: String, role: Role) throws {
            guard [accountID, requestID].allSatisfy(AccountGroupCheckpoint.canonicalUUID) else { throw AccountDeviceApprovalValueError.invalidValue }
            self.binding = binding; self.accountID = accountID; self.requestID = requestID; self.role = role
        }
    }
    public struct Acknowledgment: Equatable, Sendable, Codable {
        public let createdAtMilliseconds, expiresAtMilliseconds: UInt64
        public init(createdAtMilliseconds: UInt64, expiresAtMilliseconds: UInt64) throws {
            guard createdAtMilliseconds > 0, expiresAtMilliseconds <= 9_007_199_254_740_991,
                  expiresAtMilliseconds > createdAtMilliseconds, expiresAtMilliseconds - createdAtMilliseconds == 300_000 else {
                throw AccountDeviceApprovalValueError.invalidValue
            }
            self.createdAtMilliseconds = createdAtMilliseconds; self.expiresAtMilliseconds = expiresAtMilliseconds
        }
    }
    public struct Proof: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        public let draft: AccountGroupApprovalDraft
        public let capsule: AccountDeviceApprovalCapsule
        public let canonicalPayloadDigest, requestComparisonDigest: Data
        public init(request: AccountDeviceApprovalRequestContext, draft: AccountGroupApprovalDraft, capsule: AccountDeviceApprovalCapsule) throws {
            guard try AccountDeviceApprovalCapsule.parse(capsule.code, expectedRequest: request, expectedDraft: draft) == capsule else {
                throw AccountDeviceApprovalValueError.verificationMismatch
            }
            self.draft = draft; self.capsule = capsule
            canonicalPayloadDigest = Data(SHA256.hash(data: try draft.event.canonicalPayload()))
            requestComparisonDigest = request.requestDigest
        }
        public var description: String { "AccountGroupApprovalIntent.Proof(<redacted>)" }
        public var debugDescription: String { description }
    }
    /// Nonrecursive: terminal stores exactly one active predecessor, never another terminal.
    public enum ActivePhase: Equatable, Sendable {
        case subjectRequested
        case actorProposed(Proof)
        case subjectCountersigned(Proof, AccountGroupEvent)
    }
    public enum TerminalOutcome: Equatable, Sendable {
        case locallyAbandoned
        case acknowledged(AccountGroupPendingStatus)
    }
    public enum Phase: Equatable, Sendable {
        case active(ActivePhase)
        case terminal(ActivePhase, TerminalOutcome)
    }
    public let version = 1
    public let intentID: UUID
    public let scope: Scope
    public let originalSessionIdentity: AccountSessionIdentity
    public let localPublicKey: Data
    public let request: AccountDeviceApprovalRequestContext
    public let preparedAtMilliseconds, originalAccessExpiresAtMilliseconds: UInt64
    public let acknowledgment: Acknowledgment?
    public let phase: Phase
    public var groupID: String { request.groupID }
    public var generation: UInt64 { request.generation }
    public var confirmationDeadlineMilliseconds: UInt64 {
        min(preparedAtMilliseconds + 300_000, originalAccessExpiresAtMilliseconds, acknowledgment?.expiresAtMilliseconds ?? UInt64.max)
    }
    public var confirmationDeadline: Date { Date(timeIntervalSince1970: Double(confirmationDeadlineMilliseconds) / 1000) }
    public var activePredecessor: ActivePhase {
        switch phase { case .active(let value), .terminal(let value, _): return value }
    }
    public var isAcknowledgedTerminal: Bool {
        if case .terminal(_, .acknowledged) = phase { return true }; return false
    }

    public init(scope: Scope, intentID: UUID, originalSessionIdentity: AccountSessionIdentity, localPublicKey: Data,
                request: AccountDeviceApprovalRequestContext, preparedAtMilliseconds: UInt64,
                originalAccessExpiresAtMilliseconds: UInt64, acknowledgment: Acknowledgment? = nil, phase: Phase) throws {
        let identity = originalSessionIdentity
        guard identity.accountID.uuidString.lowercased() == scope.accountID,
              identity.accountID.uuidString != "00000000-0000-0000-0000-000000000000",
              identity.sessionID.uuidString != "00000000-0000-0000-0000-000000000000",
              identity.deviceID == scope.binding.deviceID, identity.audience == scope.binding.audience,
              (try? AccountGroupEvent.deviceID(publicKey: localPublicKey)) == scope.binding.deviceID.uuidString.lowercased(),
              request.origin == scope.binding.origin, request.accountID == scope.accountID, request.requestID == scope.requestID,
              preparedAtMilliseconds > 0, preparedAtMilliseconds <= 9_007_199_254_440_991,
              originalAccessExpiresAtMilliseconds > preparedAtMilliseconds, originalAccessExpiresAtMilliseconds <= 9_007_199_254_740_991 else {
            throw AccountDeviceApprovalValueError.invalidValue
        }
        if let acknowledgment {
            _ = try Acknowledgment(createdAtMilliseconds: acknowledgment.createdAtMilliseconds, expiresAtMilliseconds: acknowledgment.expiresAtMilliseconds)
        }
        self.scope = scope; self.intentID = intentID; self.originalSessionIdentity = identity
        self.localPublicKey = Data(Array(localPublicKey)); self.request = request
        self.preparedAtMilliseconds = preparedAtMilliseconds; self.originalAccessExpiresAtMilliseconds = originalAccessExpiresAtMilliseconds
        self.acknowledgment = acknowledgment; self.phase = phase
        switch activePredecessor {
        case .subjectRequested:
            guard scope.role == .subject, request.subjectPublicKey == localPublicKey,
                  request.subjectDeviceID == scope.binding.deviceID.uuidString.lowercased() else { throw AccountDeviceApprovalValueError.invalidValue }
        case .actorProposed(let proof):
            try validate(proof)
            guard scope.role == .actor, proof.draft.event.actorPublicKey == localPublicKey,
                  proof.draft.event.actorDeviceID == scope.binding.deviceID.uuidString.lowercased() else { throw AccountDeviceApprovalValueError.invalidValue }
        case .subjectCountersigned(let proof, let event):
            try validate(proof); try event.validate()
            guard scope.role == .subject, request.subjectPublicKey == localPublicKey,
                  try event.canonicalPayload() == proof.draft.event.canonicalPayload(), event.signature == proof.draft.event.signature else {
                throw AccountDeviceApprovalValueError.invalidValue
            }
        }
        if case .terminal(let predecessor, .acknowledged(let status)) = phase {
            guard !status.active else { throw AccountDeviceApprovalValueError.invalidValue }
            if status == .committed, case .subjectRequested = predecessor { throw AccountDeviceApprovalValueError.invalidValue }
        }
    }
    private func validate(_ proof: Proof) throws {
        guard try Proof(request: request, draft: proof.draft, capsule: proof.capsule) == proof else { throw AccountDeviceApprovalValueError.invalidValue }
    }

    /// Creates a candidate; storage additionally enforces full-record CAS and monotonicity.
    public func replacing(phase: Phase, acknowledgment: Acknowledgment? = nil) throws -> Self {
        try Self(scope: scope, intentID: intentID, originalSessionIdentity: originalSessionIdentity, localPublicKey: localPublicKey,
            request: request, preparedAtMilliseconds: preparedAtMilliseconds, originalAccessExpiresAtMilliseconds: originalAccessExpiresAtMilliseconds,
            acknowledgment: acknowledgment ?? self.acknowledgment, phase: phase)
    }

    public func canReplace(with next: Self) -> Bool {
        guard scope == next.scope, intentID == next.intentID, originalSessionIdentity == next.originalSessionIdentity,
              localPublicKey == next.localPublicKey, request == next.request, preparedAtMilliseconds == next.preparedAtMilliseconds,
              originalAccessExpiresAtMilliseconds == next.originalAccessExpiresAtMilliseconds,
              acknowledgment == nil || acknowledgment == next.acknowledgment else { return false }
        if phase == next.phase { return true }
        switch (phase, next.phase) {
        case (.active(.subjectRequested), .active(.subjectCountersigned)): return true
        case (.active(let old), .terminal(let retained, _)): return old == retained
        case (.terminal(let old, .locallyAbandoned), .terminal(let retained, .acknowledged)): return old == retained
        default: return false
        }
    }
    public var description: String { "AccountGroupApprovalIntent(<redacted>)" }
    public var debugDescription: String { description }
}
