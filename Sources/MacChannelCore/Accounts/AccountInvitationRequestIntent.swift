import Foundation

/// Initial consent journal. Loading it does not authorize a new session or send.
public struct AccountInvitationRequestIntent: Equatable, Sendable {
    public let binding: AccountSessionBinding
    public let accountID: String
    public let operationID, sessionID: UUID
    public let request: AccountInvitationRequest
    public let preparedAtMilliseconds: UInt64
    public private(set) var phase: AccountInvitationIntent.Phase = .prepared
    public private(set) var signature = Data()

    public init(binding: AccountSessionBinding, accountID: String, operationID: UUID, sessionID: UUID,
                request: AccountInvitationRequest, preparedAtMilliseconds: UInt64) throws {
        self.binding = binding; self.accountID = accountID; self.operationID = operationID; self.sessionID = sessionID
        self.request = request; self.preparedAtMilliseconds = preparedAtMilliseconds
        guard invitationUUID(accountID), invitationUUID(operationID.uuidString.lowercased()), invitationUUID(sessionID.uuidString.lowercased()),
              request.sender.accountID == accountID, request.origin == binding.origin.absoluteString,
              request.sender.audience == binding.audience, request.sender.deviceID == binding.deviceID.uuidString.lowercased(),
              preparedAtMilliseconds >= request.issuedAtMilliseconds, preparedAtMilliseconds < request.expiresAtMilliseconds else {
            throw AccountInvitationError.invalidContext
        }
    }
    public func signed(signature: Data, atMilliseconds: UInt64) throws -> Self {
        guard phase == .prepared, atMilliseconds >= preparedAtMilliseconds, atMilliseconds < request.expiresAtMilliseconds else {
            throw AccountInvitationError.invalidTransition
        }
        _ = try AccountInvitationRequestProof(payload: request.payload, signature: signature)
        var next = self; next.phase = .signed; next.signature = signature; return next
    }
    public func cancelled() -> Self { var value = self; value.phase = .cancelled; return value }
    public func signedProof() throws -> AccountInvitationRequestProof {
        guard phase == .signed else { throw AccountInvitationError.invalidTransition }
        return try AccountInvitationRequestProof(payload: request.payload, signature: signature)
    }
    func canReplace(with next: Self) -> Bool {
        guard binding == next.binding, accountID == next.accountID, operationID == next.operationID, sessionID == next.sessionID,
              request == next.request, preparedAtMilliseconds == next.preparedAtMilliseconds else { return false }
        if self == next { return true }
        switch (phase, next.phase) {
        case (.prepared, .signed): return true
        case (.prepared, .cancelled), (.signed, .cancelled): return signature == next.signature
        default: return false
        }
    }
}

struct InvitationRequestIntentDTO: Codable {
    let operationID, sessionID: UUID
    let payload: Data
    let preparedAtMilliseconds: UInt64
    let phase: AccountInvitationIntent.Phase
    let signature: Data
    init(_ intent: AccountInvitationRequestIntent) {
        operationID = intent.operationID; sessionID = intent.sessionID; payload = intent.request.payload
        preparedAtMilliseconds = intent.preparedAtMilliseconds; phase = intent.phase; signature = intent.signature
    }
    func intent(binding: AccountSessionBinding, accountID: String) throws -> AccountInvitationRequestIntent {
        var result = try AccountInvitationRequestIntent(binding: binding, accountID: accountID, operationID: operationID, sessionID: sessionID,
            request: AccountInvitationRequest(canonicalPayload: payload), preparedAtMilliseconds: preparedAtMilliseconds)
        if phase == .prepared { guard signature.isEmpty else { throw AccountInvitationError.secureStorage } }
        else if !signature.isEmpty { result = try result.signed(signature: signature, atMilliseconds: preparedAtMilliseconds) }
        else if phase == .signed { throw AccountInvitationError.secureStorage }
        if phase == .cancelled { result = result.cancelled() }
        return result
    }
}
