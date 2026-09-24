import CryptoKit
import Foundation

public protocol AccountGroupPendingService: Sendable {
    func createGroupJoin(accessToken: String, accountID: String, requestID: String, groupID: String, generation: UInt64) async throws -> AccountGroupPendingRequest
    func groupJoin(accessToken: String, accountID: String, requestID: String) async throws -> AccountGroupPendingRequest
    func groupJoins(accessToken: String, accountID: String) async throws -> [AccountGroupPendingSummary]
    func proposeGroupJoin(accessToken: String, accountID: String, requestID: String, draft: AccountGroupApprovalDraft) async throws -> AccountGroupPendingRequest
    func countersignGroupJoin(accessToken: String, accountID: String, requestID: String, draftHash: Data, subjectSignature: Data) async throws -> AccountGroupPendingRequest
    func commitGroupJoin(accessToken: String, accountID: String, requestID: String, draftHash: Data) async throws -> AccountGroupPendingRequest
    func cancelGroupJoin(accessToken: String, accountID: String, requestID: String) async throws -> AccountGroupPendingRequest
    func rejectGroupJoin(accessToken: String, accountID: String, requestID: String) async throws -> AccountGroupPendingRequest
}

extension AccountServiceClient: AccountGroupPendingService {
    public func createGroupJoin(accessToken: String, accountID: String, requestID: String, groupID: String, generation: UInt64) async throws -> AccountGroupPendingRequest {
        try Task.checkCancellation()
        guard AccountGroupPage.validGroupID(groupID), generation > 0, generation <= UInt64(Int64.max) else { throw AccountServiceError.invalidRequest }
        let result = try await pendingRecord("create", accessToken, accountID, requestID, fields: [
            "groupID": groupID, "generation": String(generation), "publicKey": identity.publicKey.rawRepresentation.base64EncodedString()])
        guard result.summary.groupID == groupID, result.summary.generation == generation,
              pendingSubject(result) else { throw AccountServiceError.invalidResponse }
        return result
    }
    public func groupJoin(accessToken: String, accountID: String, requestID: String) async throws -> AccountGroupPendingRequest {
        try await pendingRecord("get", accessToken, accountID, requestID)
    }
    public func groupJoins(accessToken: String, accountID: String) async throws -> [AccountGroupPendingSummary] {
        let data = try await pendingSend("list", accessToken, accountID, nil, fields: [:])
        do {
            let result = try AccountGroupPendingSummary.decodeList(data)
            guard result.allSatisfy({ $0.accountID == accountID }) else { throw AccountServiceError.invalidResponse }
            try Task.checkCancellation(); return result
        } catch { try Task.checkCancellation(); throw error }
    }
    public func proposeGroupJoin(accessToken: String, accountID: String, requestID: String, draft: AccountGroupApprovalDraft) async throws -> AccountGroupPendingRequest {
        try Task.checkCancellation()
        let event = draft.event
        guard event.accountID == accountID, event.actorDeviceID == identity.id.rawValue.uuidString.lowercased(),
              event.actorPublicKey == identity.publicKey.rawRepresentation else { throw AccountServiceError.invalidRequest }
        let encoded: Data
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            encoded = try encoder.encode(draft.wireDraft())
        } catch { throw AccountServiceError.invalidRequest }
        guard (1...4096).contains(encoded.count) else { throw AccountServiceError.invalidRequest }
        let digest = Data(SHA256.hash(data: try event.canonicalPayload()))
        let result = try await pendingRecord("propose", accessToken, accountID, requestID,
            fields: ["draft": encoded.base64EncodedString()], digest: digest)
        guard result.summary.groupID == event.groupID, result.summary.generation == event.generation,
              result.summary.deviceID == event.subjectDeviceID, result.summary.publicKey == event.subjectPublicKey else { throw AccountServiceError.invalidResponse }
        return result
    }
    public func countersignGroupJoin(accessToken: String, accountID: String, requestID: String, draftHash: Data, subjectSignature: Data) async throws -> AccountGroupPendingRequest {
        try Task.checkCancellation()
        guard draftHash.count == 32, (1...80).contains(subjectSignature.count),
              (try? P256.Signing.ECDSASignature(derRepresentation: subjectSignature)) != nil else { throw AccountServiceError.invalidRequest }
        let result = try await pendingRecord("countersign", accessToken, accountID, requestID, fields: [
            "draftHash": draftHash.base64EncodedString(), "subjectSignature": subjectSignature.base64EncodedString()], digest: draftHash)
        guard pendingSubject(result) else { throw AccountServiceError.invalidResponse }
        return result
    }
    public func commitGroupJoin(accessToken: String, accountID: String, requestID: String, draftHash: Data) async throws -> AccountGroupPendingRequest {
        try Task.checkCancellation()
        guard draftHash.count == 32 else { throw AccountServiceError.invalidRequest }
        let result = try await pendingRecord("commit", accessToken, accountID, requestID,
            fields: ["draftHash": draftHash.base64EncodedString()], digest: draftHash)
        if let draft = result.draft {
            guard draft.event.actorDeviceID == identity.id.rawValue.uuidString.lowercased(),
                  draft.event.actorPublicKey == identity.publicKey.rawRepresentation else { throw AccountServiceError.invalidResponse }
        }
        return result
    }
    public func cancelGroupJoin(accessToken: String, accountID: String, requestID: String) async throws -> AccountGroupPendingRequest {
        let result = try await pendingRecord("cancel", accessToken, accountID, requestID)
        guard pendingSubject(result) else { throw AccountServiceError.invalidResponse }
        return result
    }
    public func rejectGroupJoin(accessToken: String, accountID: String, requestID: String) async throws -> AccountGroupPendingRequest {
        try await pendingRecord("reject", accessToken, accountID, requestID)
    }

    private func pendingSubject(_ result: AccountGroupPendingRequest) -> Bool {
        result.summary.deviceID == identity.id.rawValue.uuidString.lowercased() && result.summary.publicKey == identity.publicKey.rawRepresentation
    }
    private func pendingRecord(_ operation: String, _ token: String, _ account: String, _ request: String,
                               fields: [String: String] = [:], digest: Data? = nil) async throws -> AccountGroupPendingRequest {
        let data = try await pendingSend(operation, token, account, request, fields: fields)
        do {
            let result = try AccountGroupPendingRequest(data: data)
            guard result.summary.accountID == account, result.summary.requestID == request else { throw AccountServiceError.invalidResponse }
            let status = result.summary.status
            guard !(operation == "propose" && status == .requested),
                  !(operation == "countersign" && (status == .requested || status == .proposed)),
                  !(["commit", "cancel", "reject"].contains(operation) && status.active) else { throw AccountServiceError.invalidResponse }
            if let digest, let draft = result.draft {
                guard Data(SHA256.hash(data: try draft.event.canonicalPayload())) == digest else { throw AccountServiceError.invalidResponse }
            }
            try Task.checkCancellation(); return result
        } catch { try Task.checkCancellation(); throw error }
    }
    private func pendingSend(_ operation: String, _ token: String, _ account: String, _ request: String?, fields: [String: String]) async throws -> Data {
        try Task.checkCancellation()
        guard Self.validToken(token), AccountGroupPage.validGroupID(account),
              request.map(AccountGroupPage.validGroupID) ?? true else { throw AccountServiceError.invalidRequest }
        var fields = fields
        fields["purpose"] = "dropmesh.account.group.join.\(operation).v1"
        fields["audience"] = audience; fields["accessToken"] = token; fields["requestID"] = request
        do {
            let data = try await send(path: "/v1/account/group/join/\(operation)", fields: fields, requestDate: requestDate())
            try Task.checkCancellation(); return data
        } catch { try Task.checkCancellation(); throw error }
    }
}
