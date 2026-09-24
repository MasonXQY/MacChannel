import Foundation

public struct AccountInvitationLinkState: Equatable, Sendable {
    public let version: UInt64
    public let hash: Data

    public init(version: UInt64, hash: Data) {
        self.version = version
        self.hash = hash
    }
}

public enum AccountInvitationTransition: String, Sendable { case reject, cancel, revoke }

public protocol AccountInvitationService: Sendable {
    func invitationLink(accessToken: String) async throws -> AccountInvitationLinkState
    func rotateInvitationLink(accessToken: String, link: AccountInvitationLink) async throws -> AccountInvitationLinkState
    func createInvitation(accessToken: String, request: AccountInvitationRequestProof) async throws -> AccountInvitationRecord
    func invitation(accessToken: String, accountID: String, requestID: String) async throws -> AccountInvitationRecord
    func invitations(accessToken: String, accountID: String, inbox: Bool, afterRequestID: String?, limit: Int) async throws -> [AccountInvitationRecord]
    func selectInvitation(accessToken: String, accountID: String, requestID: String, target: AccountInvitationEndpoint) async throws -> AccountInvitationRecord
    func countersignInvitation(accessToken: String, accountID: String, pair: AccountInvitationPair, signature: Data) async throws -> AccountInvitationRecord
    func commitInvitation(accessToken: String, accountID: String, pair: AccountInvitationPair) async throws -> AccountInvitationRecord
    func transitionInvitation(accessToken: String, accountID: String, checkpoint: AccountInvitationCheckpoint, action: AccountInvitationTransition) async throws -> AccountInvitationRecord
    func blockInvitations(accessToken: String, targetAccountID: String, disconnectExisting: Bool) async throws
}

extension AccountServiceClient: AccountInvitationService {
    public func createInvitation(accessToken: String, request: AccountInvitationRequestProof) async throws -> AccountInvitationRecord {
        let binding = try invitationBinding(), value = request.request
        guard value.origin == binding.origin.absoluteString, value.sender.audience == audience,
              value.sender.deviceID == identity.id.rawValue.uuidString.lowercased(), value.sender.publicKey == identity.publicKey.rawRepresentation else {
            throw AccountServiceError.invalidRequest
        }
        let data = try await invitationSend("request", accessToken: accessToken, fields: ["requestPayload": request.payload.base64EncodedString(), "requestSignature": request.signature.base64EncodedString()])
        let record = try AccountInvitationRecord(data: data)
        try validateInvitation(record, accountID: value.sender.accountID)
        guard record.request.payload == request.payload else { throw AccountServiceError.invalidResponse }; return record
    }
    public func invitation(accessToken: String, accountID: String, requestID: String) async throws -> AccountInvitationRecord {
        try await invitationRecordOperation("get", accessToken: accessToken, accountID: accountID, requestID: requestID)
    }
    public func invitations(accessToken: String, accountID: String, inbox: Bool, afterRequestID: String?, limit: Int) async throws -> [AccountInvitationRecord] {
        guard invitationUUID(accountID), (1...5).contains(limit), afterRequestID == nil || invitationUUID(afterRequestID!) else { throw AccountServiceError.invalidRequest }
        let data = try await invitationSend(inbox ? "inbox" : "outbox", accessToken: accessToken,
            fields: ["afterRequestID": afterRequestID ?? "", "limit": String(limit)])
        let records = try AccountInvitationRecord.list(data: data)
        guard records.count <= limit else { throw AccountServiceError.invalidResponse }
        var previous = afterRequestID ?? ""
        for record in records {
            try validateInvitation(record, accountID: accountID)
            guard record.checkpoint.requestID > previous, inbox == (record.request.request.sender.accountID != accountID) else { throw AccountServiceError.invalidResponse }
            previous = record.checkpoint.requestID
        }
        return records
    }
    public func selectInvitation(accessToken: String, accountID: String, requestID: String, target: AccountInvitationEndpoint) async throws -> AccountInvitationRecord {
        guard target.accountID == accountID else { throw AccountServiceError.invalidRequest }
        let record = try await invitationRecordOperation("select", accessToken: accessToken, accountID: accountID, requestID: requestID,
            fields: ["targetDeviceID": target.deviceID, "targetGroupID": target.groupID, "targetGeneration": String(target.generation),
                "targetPublicKey": target.publicKey.base64EncodedString(), "targetAudience": target.audience])
        guard record.pair?.target == target else { throw AccountServiceError.invalidResponse }; return record
    }
    public func countersignInvitation(accessToken: String, accountID: String, pair: AccountInvitationPair, signature: Data) async throws -> AccountInvitationRecord {
        let role = try localInvitationRole(pair, accountID: accountID)
        do { try invitationVerify(signature, key: pair.endpoint(role).publicKey, payload: pair.payload) }
        catch { throw AccountServiceError.invalidRequest }
        let record = try await invitationRecordOperation("countersign", accessToken: accessToken, accountID: accountID, requestID: pair.requestID,
            fields: ["signature": signature.base64EncodedString()], pair: pair)
        guard (role == .sender ? record.senderSignature : record.targetSignature) == signature else { throw AccountServiceError.invalidResponse }; return record
    }
    public func commitInvitation(accessToken: String, accountID: String, pair: AccountInvitationPair) async throws -> AccountInvitationRecord {
        _ = try localInvitationRole(pair, accountID: accountID)
        let record = try await invitationRecordOperation("commit", accessToken: accessToken, accountID: accountID, requestID: pair.requestID,
            fields: ["proofDigest": pair.digest.base64EncodedString()], pair: pair)
        guard record.checkpoint.state == .active else { throw AccountServiceError.invalidResponse }; return record
    }
    public func transitionInvitation(accessToken: String, accountID: String, checkpoint: AccountInvitationCheckpoint, action: AccountInvitationTransition) async throws -> AccountInvitationRecord {
        guard action != .revoke || checkpoint.proofDigest.count == 32 else { throw AccountServiceError.invalidRequest }
        let record = try await invitationRecordOperation(action.rawValue, accessToken: accessToken, accountID: accountID, requestID: checkpoint.requestID,
            fields: ["expectedRevision": String(checkpoint.revision), "proofDigest": checkpoint.proofDigest.base64EncodedString()])
        let state: AccountInvitationState = action == .revoke ? .revoked : (action == .cancel ? .cancelled : .rejected)
        guard record.checkpoint.grantID == checkpoint.grantID, record.checkpoint.state == state,
              checkpoint.canAdvance(to: record.checkpoint) else { throw AccountServiceError.invalidResponse }
        return record
    }
    public func blockInvitations(accessToken: String, targetAccountID: String, disconnectExisting: Bool) async throws {
        guard invitationUUID(targetAccountID) else { throw AccountServiceError.invalidRequest }
        let data = try await invitationSend("block", accessToken: accessToken,
            fields: ["targetAccountID": targetAccountID, "disconnectExisting": disconnectExisting ? "true" : "false"])
        var parser = PageParser(data: data); try parser.token(123)
        guard try parser.string() == "blocked" else { throw AccountServiceError.invalidResponse }; try parser.token(58)
        guard try parser.boolean() else { throw AccountServiceError.invalidResponse }; try parser.token(125); parser.whitespace()
        guard parser.i == parser.bytes.count else { throw AccountServiceError.invalidResponse }
    }
    public func invitationLink(accessToken: String) async throws -> AccountInvitationLinkState {
        try await invitationLinkOperation("link/get", accessToken: accessToken, fields: [:])
    }
    public func rotateInvitationLink(accessToken: String, link: AccountInvitationLink) async throws -> AccountInvitationLinkState {
        let result = try await invitationLinkOperation("link/rotate", accessToken: accessToken, fields: ["linkToken": link.token])
        guard result.hash == link.tokenHash else { throw AccountServiceError.invalidResponse }; return result
    }
    private func invitationLinkOperation(_ op: String, accessToken: String, fields: [String: String]) async throws -> AccountInvitationLinkState {
        let data = try await invitationSend(op, accessToken: accessToken, fields: fields)
        do {
            let values = try AccountGroupWireJSON.fields(data, keys: ["version", "hash"])
            let version = try invitationNumber(values["version"]), hash = try invitationBase64(values["hash"]!, maximum: 44)
            guard hash.count == 32 else { throw AccountServiceError.invalidResponse }
            return AccountInvitationLinkState(version: version, hash: hash)
        } catch { throw AccountServiceError.invalidResponse }
    }
    private func invitationSend(_ op: String, accessToken: String, fields: [String: String]) async throws -> Data {
        try Task.checkCancellation()
        guard Self.validToken(accessToken) else { throw AccountServiceError.invalidRequest }
        var fields = fields
        fields["purpose"] = "dropmesh.account.invitation." + op.replacingOccurrences(of: "/", with: ".") + ".v1"
        fields["audience"] = audience; fields["accessToken"] = accessToken
        let result = try await send(path: "/v1/account/invitation/" + op, fields: fields, requestDate: requestDate())
        try Task.checkCancellation(); return result
    }
    private func invitationRecordOperation(_ op: String, accessToken: String, accountID: String, requestID: String,
                                           fields: [String: String] = [:], pair: AccountInvitationPair? = nil) async throws -> AccountInvitationRecord {
        guard invitationUUID(accountID), invitationUUID(requestID) else { throw AccountServiceError.invalidRequest }
        var fields = fields; fields["requestID"] = requestID
        let record = try AccountInvitationRecord(data: await invitationSend(op, accessToken: accessToken, fields: fields))
        try validateInvitation(record, accountID: accountID)
        guard record.checkpoint.requestID == requestID, pair == nil || record.pair == pair else { throw AccountServiceError.invalidResponse }
        return record
    }
    private func validateInvitation(_ record: AccountInvitationRecord, accountID: String) throws {
        guard record.request.request.origin == (try invitationBinding()).origin.absoluteString,
              record.pair == nil || record.pair!.sender.accountID == accountID || record.pair!.target.accountID == accountID else { throw AccountServiceError.invalidResponse }
        // Before selection the recipient identity is intentionally absent. Its
        // authenticated inbox response remains metadata, never endpoint authority.
    }
    private func localInvitationRole(_ pair: AccountInvitationPair, accountID: String) throws -> AccountInvitationRole {
        let binding = try invitationBinding()
        guard pair.origin == binding.origin.absoluteString else { throw AccountServiceError.invalidRequest }
        for role in [AccountInvitationRole.sender, .target] {
            let endpoint = pair.endpoint(role)
            if endpoint.accountID == accountID, endpoint.deviceID == identity.id.rawValue.uuidString.lowercased(),
               endpoint.audience == audience, endpoint.publicKey == identity.publicKey.rawRepresentation { return role }
        }
        throw AccountServiceError.invalidRequest
    }
}
