import Foundation

public struct AccountInvitationRequest: Equatable, Sendable {
    public let payload: Data
    public let sender: AccountInvitationEndpoint
    public let origin, requestID, grantID: String
    public let targetLinkHash: Data
    public let issuedAtMilliseconds, expiresAtMilliseconds: UInt64

    public init(sender: AccountInvitationEndpoint, origin: URL, requestID: String, grantID: String,
                targetLinkHash: Data, issuedAtMilliseconds: UInt64) throws {
        guard issuedAtMilliseconds <= UInt64(Int64.max) - 86_400_000 else { throw AccountInvitationError.invalidProof }
        let fields = ["purpose": "dropmesh.account.invitation.request.v1", "audience": sender.audience,
            "origin": origin.absoluteString, "requestID": requestID, "grantID": grantID,
            "issuedAtMilliseconds": String(issuedAtMilliseconds), "expiresAtMilliseconds": String(issuedAtMilliseconds + 86_400_000),
            "senderAudience": sender.audience, "senderAccountID": sender.accountID, "senderGroupID": sender.groupID,
            "senderGeneration": String(sender.generation), "senderDeviceID": sender.deviceID,
            "senderPublicKey": sender.publicKey.base64EncodedString(), "targetLinkHash": targetLinkHash.base64EncodedString()]
        try self.init(canonicalPayload: invitationEncode(fields))
    }
    public init(canonicalPayload: Data) throws {
        do {
            guard canonicalPayload.count <= 4096 else { throw AccountInvitationError.invalidProof }
            let f = try AccountGroupWireJSON.fields(canonicalPayload, keys: ["purpose", "audience", "origin", "requestID", "grantID",
                "issuedAtMilliseconds", "expiresAtMilliseconds", "senderAudience", "senderAccountID", "senderGroupID",
                "senderGeneration", "senderDeviceID", "senderPublicKey", "targetLinkHash"])
            guard f["purpose"] == "dropmesh.account.invitation.request.v1", f["audience"] == f["senderAudience"],
                  AccountInvitationPair.validOrigin(f["origin"]!), invitationUUID(f["requestID"]!), invitationUUID(f["grantID"]!),
                  f["requestID"] != f["grantID"] else { throw AccountInvitationError.invalidProof }
            let issued = try invitationNumber(f["issuedAtMilliseconds"]), expires = try invitationNumber(f["expiresAtMilliseconds"])
            guard issued <= UInt64(Int64.max) - 86_400_000, expires == issued + 86_400_000 else { throw AccountInvitationError.invalidProof }
            sender = try AccountInvitationEndpoint(audience: f["senderAudience"]!, accountID: f["senderAccountID"]!, groupID: f["senderGroupID"]!,
                generation: invitationNumber(f["senderGeneration"]), deviceID: f["senderDeviceID"]!, publicKey: invitationBase64(f["senderPublicKey"]!, maximum: 88))
            targetLinkHash = try invitationBase64(f["targetLinkHash"]!, maximum: 44)
            guard targetLinkHash.count == 32, try invitationEncode(f) == canonicalPayload else { throw AccountInvitationError.invalidProof }
            payload = canonicalPayload; origin = f["origin"]!; requestID = f["requestID"]!; grantID = f["grantID"]!
            issuedAtMilliseconds = issued; expiresAtMilliseconds = expires
        } catch { throw AccountInvitationError.invalidProof }
    }
    func matches(_ pair: AccountInvitationPair) -> Bool {
        pair.sender == sender && pair.origin == origin && pair.requestID == requestID && pair.grantID == grantID &&
        pair.targetLinkHash == targetLinkHash && pair.issuedAtMilliseconds == issuedAtMilliseconds && pair.expiresAtMilliseconds == expiresAtMilliseconds
    }
}

public struct AccountInvitationRequestProof: Equatable, Sendable {
    public let payload: Data
    public let signature: Data
    public let request: AccountInvitationRequest
    public init(payload: Data, signature: Data) throws {
        let request = try AccountInvitationRequest(canonicalPayload: payload)
        try invitationVerify(signature, key: request.sender.publicKey, payload: payload)
        self.payload = payload; self.signature = signature; self.request = request
    }
}

/// Authenticated API metadata plus device consent proofs, not live authority.
public struct AccountInvitationRecord: Equatable, Sendable {
    public let checkpoint: AccountInvitationCheckpoint
    public let verifiedAtMilliseconds: UInt64
    public let request: AccountInvitationRequestProof
    public let pair: AccountInvitationPair?
    public let senderSignature: Data
    public let targetSignature: Data
    public init(data: Data) throws {
        do {
            guard data.count <= 16_384 else { throw AccountServiceError.invalidResponse }
            var parser = PageParser(data: data)
            self = try parser.invitationRecord()
            parser.whitespace(); guard parser.i == parser.bytes.count else { throw AccountServiceError.invalidResponse }
        } catch { throw AccountServiceError.invalidResponse }
    }
    init(checkpoint: AccountInvitationCheckpoint, verifiedAtMilliseconds: UInt64, request: AccountInvitationRequestProof,
         pair: AccountInvitationPair?, senderSignature: Data, targetSignature: Data) throws {
        guard checkpoint.requestID == request.request.requestID, checkpoint.grantID == request.request.grantID,
              verifiedAtMilliseconds > 0, verifiedAtMilliseconds <= UInt64(Int64.max) else { throw AccountServiceError.invalidResponse }
        if let pair {
            guard checkpoint.state != .requested, request.request.matches(pair), checkpoint.proofDigest == pair.digest else { throw AccountServiceError.invalidResponse }
            if !senderSignature.isEmpty { try invitationVerify(senderSignature, key: pair.sender.publicKey, payload: pair.payload) }
            if !targetSignature.isEmpty { try invitationVerify(targetSignature, key: pair.target.publicKey, payload: pair.payload) }
            if checkpoint.state == .active || checkpoint.state == .revoked {
                _ = try AccountInvitationPairProof(payload: pair.payload, senderSignature: senderSignature, targetSignature: targetSignature)
            }
        } else {
            guard checkpoint.proofDigest.isEmpty, senderSignature.isEmpty, targetSignature.isEmpty else { throw AccountServiceError.invalidResponse }
        }
        self.checkpoint = checkpoint; self.verifiedAtMilliseconds = verifiedAtMilliseconds; self.request = request
        self.pair = pair; self.senderSignature = senderSignature; self.targetSignature = targetSignature
    }
    static func list(data: Data) throws -> [Self] {
        do {
            guard data.count <= 65_536 else { throw AccountServiceError.invalidResponse }
            var parser = PageParser(data: data); try parser.token(123)
            guard try parser.string() == "records" else { throw AccountServiceError.invalidResponse }
            try parser.token(58); try parser.token(91); parser.whitespace()
            var records: [Self] = []
            if parser.i < parser.bytes.count, parser.bytes[parser.i] != 93 {
                while true {
                    guard records.count < 5 else { throw AccountServiceError.invalidResponse }
                    records.append(try parser.invitationRecord()); parser.whitespace()
                    if parser.i < parser.bytes.count, parser.bytes[parser.i] == 93 { break }
                    try parser.token(44)
                }
            }
            try parser.token(93); try parser.token(125); parser.whitespace()
            guard parser.i == parser.bytes.count else { throw AccountServiceError.invalidResponse }
            return records
        } catch { throw AccountServiceError.invalidResponse }
    }
}

private extension PageParser {
    mutating func invitationFields(_ keys: Set<String>) throws -> [String: String] {
        try token(123); var fields: [String: String] = [:]
        for n in 0..<keys.count {
            if n > 0 { try token(44) }
            let key = try string(); guard keys.contains(key), fields[key] == nil else { throw AccountServiceError.invalidResponse }
            try token(58); fields[key] = try string()
        }
        try token(125); return fields
    }
    mutating func invitationRecord() throws -> AccountInvitationRecord {
        let start = i
        try token(123); var seen = Set<String>(), fields: [String: String] = [:]
        var requestFields: [String: String]?, pairFields: [String: String]?
        for n in 0..<8 {
            if n > 0 { try token(44) }
            let key = try string(); guard seen.insert(key).inserted else { throw AccountServiceError.invalidResponse }
            try token(58)
            switch key {
            case "request": requestFields = try invitationFields(["payload", "signature"])
            case "pair":
                whitespace()
                if bytes[i...].starts(with: Array("null".utf8)) { i += 4 }
                else { pairFields = try invitationFields(["payload", "senderSignature", "targetSignature"]) }
            case "requestID", "grantID", "revision", "state", "proofDigest", "verifiedAtMilliseconds": fields[key] = try string()
            default: throw AccountServiceError.invalidResponse
            }
        }
        try token(125)
        guard i - start <= 16_384, let requestFields, let stateString = fields["state"], let state = AccountInvitationState(rawValue: stateString),
              let requestID = fields["requestID"], let grantID = fields["grantID"], let digest = fields["proofDigest"] else { throw AccountServiceError.invalidResponse }
        let request = try AccountInvitationRequestProof(payload: invitationBase64(requestFields["payload"]!, maximum: 5464),
            signature: invitationBase64(requestFields["signature"]!, maximum: 108))
        let pair = try pairFields.map { try AccountInvitationPair(canonicalPayload: invitationBase64($0["payload"]!, maximum: 5464)) }
        let checkpoint = try AccountInvitationCheckpoint(requestID: requestID, grantID: grantID, revision: invitationNumber(fields["revision"]),
            state: state, proofDigest: invitationBase64(digest, maximum: 44))
        return try AccountInvitationRecord(checkpoint: checkpoint, verifiedAtMilliseconds: invitationNumber(fields["verifiedAtMilliseconds"]),
            request: request, pair: pair, senderSignature: invitationBase64(pairFields?["senderSignature"] ?? "", maximum: 108),
            targetSignature: invitationBase64(pairFields?["targetSignature"] ?? "", maximum: 108))
    }
}
