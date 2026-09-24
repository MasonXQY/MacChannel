import Foundation

/// Persist before sending a local endpoint signature. No bearer tokens are kept.
public struct AccountInvitationIntent: Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case prepared, signed, cancelled }
    public let binding: AccountSessionBinding
    public let accountID: String
    public let operationID: UUID
    public let sessionID: UUID
    public let role: AccountInvitationRole
    public let pair: AccountInvitationPair
    public let preparedAtMilliseconds: UInt64
    public let observedRevision: UInt64
    public private(set) var phase: Phase = .prepared
    public private(set) var signature = Data()

    public init(binding: AccountSessionBinding, accountID: String, operationID: UUID, sessionID: UUID,
                role: AccountInvitationRole, pair: AccountInvitationPair, preparedAtMilliseconds: UInt64, observedRevision: UInt64) throws {
        guard invitationUUID(accountID), invitationUUID(operationID.uuidString.lowercased()), invitationUUID(sessionID.uuidString.lowercased()),
              pair.endpoint(role).accountID == accountID, observedRevision > 0, observedRevision <= UInt64(Int64.max) else { throw AccountInvitationError.invalidContext }
        try pair.validateForCommit(binding: binding, local: pair.endpoint(role), role: role, atMilliseconds: preparedAtMilliseconds)
        self.binding = binding; self.accountID = accountID; self.operationID = operationID; self.sessionID = sessionID
        self.role = role; self.pair = pair; self.preparedAtMilliseconds = preparedAtMilliseconds
        self.observedRevision = observedRevision
    }
    public func signed(signature: Data, atMilliseconds: UInt64) throws -> Self {
        guard phase == .prepared else { throw AccountInvitationError.invalidTransition }
        try pair.validateForCommit(binding: binding, local: pair.endpoint(role), role: role, atMilliseconds: atMilliseconds)
        try invitationVerify(signature, key: pair.endpoint(role).publicKey, payload: pair.payload)
        var next = self; next.phase = .signed; next.signature = signature; return next
    }
    public func cancelled() -> Self { var next = self; next.phase = .cancelled; return next }
    func canReplace(with next: Self) -> Bool {
        guard binding == next.binding, accountID == next.accountID, operationID == next.operationID, sessionID == next.sessionID,
              role == next.role, pair == next.pair, preparedAtMilliseconds == next.preparedAtMilliseconds,
              observedRevision == next.observedRevision else { return false }
        if self == next { return true }
        switch (phase, next.phase) {
        case (.prepared, .signed): return true
        case (.prepared, .cancelled), (.signed, .cancelled): return signature == next.signature
        default: return false
        }
    }
}

public enum AccountInvitationState: String, Codable, Sendable {
    case requested, selected, active, rejected, cancelled, expired, revoked
    public var isTerminal: Bool { self == .rejected || self == .cancelled || self == .expired || self == .revoked }
}

/// Durable high-water/tombstone only. It is not authenticated freshness evidence
/// and never grants connection authority when loaded from disk.
public struct AccountInvitationCheckpoint: Codable, Equatable, Sendable {
    public let requestID: String
    public let grantID: String
    public let revision: UInt64
    public let state: AccountInvitationState
    public let proofDigest: Data
    public init(requestID: String, grantID: String, revision: UInt64, state: AccountInvitationState, proofDigest: Data) throws {
        guard invitationUUID(requestID), invitationUUID(grantID), requestID != grantID, revision > 0, revision <= UInt64(Int64.max),
              proofDigest.isEmpty || proofDigest.count == 32,
              state != .requested || proofDigest.isEmpty,
              (state != .selected && state != .active && state != .revoked) || proofDigest.count == 32 else {
            throw AccountInvitationError.invalidContext
        }
        self.requestID = requestID; self.grantID = grantID; self.revision = revision; self.state = state; self.proofDigest = proofDigest
    }
    func canAdvance(to next: Self) -> Bool {
        guard requestID == next.requestID, grantID == next.grantID, next.revision >= revision,
              proofDigest.isEmpty || proofDigest == next.proofDigest else { return false }
        if next.revision == revision { return self == next }
        if state.isTerminal { return state == next.state && proofDigest == next.proofDigest }
        if state == .active { return next.state == .active || next.state == .revoked }
        if state == .selected { return next.state != .requested }
        return true
    }
}
