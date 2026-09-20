import Foundation

public protocol AccountDeletionService: Sendable {
    func beginDeletion(receipt: String, accessToken: String, challengeID: String, code: String,
                       identityToken: String, confirmation: Bool) async throws -> AccountDeletionStatus
    func deletionStatus(receipt: String) async throws -> AccountDeletionStatus
}

extension AccountServiceClient: AccountDeletionService {
    public func beginDeletion(receipt: String, accessToken: String, challengeID: String, code: String,
                              identityToken: String, confirmation: Bool) async throws -> AccountDeletionStatus {
        try Task.checkCancellation()
        guard confirmation, Self.validToken(receipt), Self.validToken(accessToken), Self.validToken(challengeID),
              Self.validCredential(code, maximumBytes: 4096), Self.validCredential(identityToken, maximumBytes: 16384) else {
            throw AccountServiceError.invalidRequest
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(DeletionBeginPayload(audience: audience, receipt: receipt, accessToken: accessToken,
            challengeID: challengeID, code: code, identityToken: identityToken, confirmation: true))
        let bytes = try await send(path: "/v1/account/deletion/begin", payload: payload, requestDate: requestDate())
        return try Self.parseDeletionStatus(bytes)
    }
    public func deletionStatus(receipt: String) async throws -> AccountDeletionStatus {
        try Task.checkCancellation()
        guard Self.validToken(receipt) else { throw AccountServiceError.invalidRequest }
        let bytes = try await send(path: "/v1/account/deletion/status", fields: [
            "purpose": "dropmesh.account.deletion.status.v1", "audience": audience, "receipt": receipt], requestDate: requestDate())
        return try Self.parseDeletionStatus(bytes)
    }

    private static func parseDeletionStatus(_ bytes: Data) throws -> AccountDeletionStatus {
        do {
            var parser = PageParser(data: bytes)
            try parser.token(123)
            guard try parser.string() == "status" else { throw AccountServiceError.invalidResponse }
            try parser.token(58)
            guard let status = try AccountDeletionStatus(rawValue: parser.string()), status != .submitting else { throw AccountServiceError.invalidResponse }
            try parser.token(125); parser.whitespace()
            guard parser.i == parser.bytes.count else { throw AccountServiceError.invalidResponse }
            return status
        } catch { throw AccountServiceError.invalidResponse }
    }
}

private struct DeletionBeginPayload: Encodable {
    let purpose = "dropmesh.account.deletion.begin.v1"
    let audience: String, receipt: String, accessToken: String, challengeID: String, code: String, identityToken: String
    let confirmation: Bool
}
