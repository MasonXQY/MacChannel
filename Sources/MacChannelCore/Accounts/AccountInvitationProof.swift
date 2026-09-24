import CryptoKit
import Foundation

public enum AccountInvitationError: Error, Equatable {
    case invalidProof, invalidContext, invalidTransition, rollback, conflict, capacity, secureStorage
}

public enum AccountInvitationRole: String, Codable, Sendable { case sender, target }

public struct AccountInvitationEndpoint: Equatable, Sendable {
    public let audience: String
    public let accountID: String
    public let groupID: String
    public let generation: UInt64
    public let deviceID: String
    public let publicKey: Data

    public init(audience: String, accountID: String, groupID: String, generation: UInt64, deviceID: String, publicKey: Data) throws {
        guard invitationAudience(audience), invitationUUID(accountID), invitationUUID(groupID), invitationUUID(deviceID),
              generation > 0, generation <= UInt64(Int64.max), (publicKey.count == 64 || (publicKey.count == 65 && publicKey.first == 4)),
              (try? AccountGroupEvent.deviceID(publicKey: publicKey)) == deviceID else { throw AccountInvitationError.invalidProof }
        self.audience = audience; self.accountID = accountID; self.groupID = groupID; self.generation = generation
        self.deviceID = deviceID; self.publicKey = publicKey
    }
}

/// Exact immutable bytes signed by both selected physical endpoints. Parsing or
/// signing this value alone does not prove current membership or grant freshness.
public struct AccountInvitationPair: Equatable, Sendable {
    public let payload: Data
    public let audience: String
    public let origin: String
    public let requestID: String
    public let grantID: String
    public let linkVersion: UInt64
    public let targetLinkHash: Data
    public let issuedAtMilliseconds: UInt64
    public let expiresAtMilliseconds: UInt64
    public let sender: AccountInvitationEndpoint
    public let target: AccountInvitationEndpoint
    public var digest: Data { Data(SHA256.hash(data: payload)) }

    public init(canonicalPayload: Data) throws {
        do {
            guard canonicalPayload.count <= 4096 else { throw AccountInvitationError.invalidProof }
            let fields = try AccountGroupWireJSON.fields(canonicalPayload, keys: Self.keys)
            guard fields["purpose"] == "dropmesh.account.invitation.pair.v1",
                  let audience = fields["audience"], invitationAudience(audience),
                  let origin = fields["origin"], Self.validOrigin(origin),
                  let request = fields["requestID"], invitationUUID(request),
                  let grant = fields["grantID"], invitationUUID(grant), grant != request else { throw AccountInvitationError.invalidProof }
            let link = try invitationNumber(fields["linkVersion"])
            let issued = try invitationNumber(fields["issuedAtMilliseconds"])
            let expires = try invitationNumber(fields["expiresAtMilliseconds"])
            guard issued <= UInt64(Int64.max) - 86_400_000, expires == issued + 86_400_000 else { throw AccountInvitationError.invalidProof }
            func endpoint(_ prefix: String) throws -> AccountInvitationEndpoint {
                try AccountInvitationEndpoint(audience: fields[prefix + "Audience"]!, accountID: fields[prefix + "AccountID"]!, groupID: fields[prefix + "GroupID"]!,
                    generation: invitationNumber(fields[prefix + "Generation"]), deviceID: fields[prefix + "DeviceID"]!,
                    publicKey: invitationBase64(fields[prefix + "PublicKey"]!, maximum: 88))
            }
            let sender = try endpoint("sender"), target = try endpoint("target")
            let linkHash = try invitationBase64(fields["targetLinkHash"]!, maximum: 44)
            guard linkHash.count == 32, audience == sender.audience, sender.accountID != target.accountID, sender.deviceID != target.deviceID,
                  try invitationEncode(fields) == canonicalPayload else { throw AccountInvitationError.invalidProof }
            self.payload = canonicalPayload; self.audience = audience; self.origin = origin
            requestID = request; grantID = grant; linkVersion = link
            targetLinkHash = linkHash
            issuedAtMilliseconds = issued; expiresAtMilliseconds = expires
            self.sender = sender; self.target = target
        } catch { throw AccountInvitationError.invalidProof }
    }

    public func endpoint(_ role: AccountInvitationRole) -> AccountInvitationEndpoint { role == .sender ? sender : target }

    /// Call only with independently verified local account/group/key context.
    /// Expiry applies to signing/commit, never to an already committed grant.
    public func validateForCommit(binding: AccountSessionBinding, local: AccountInvitationEndpoint,
                                  role: AccountInvitationRole, atMilliseconds: UInt64) throws {
        guard binding.origin.absoluteString == origin, binding.audience == endpoint(role).audience,
              binding.deviceID.uuidString.lowercased() == local.deviceID, endpoint(role) == local,
              atMilliseconds >= issuedAtMilliseconds, atMilliseconds < expiresAtMilliseconds else {
            throw AccountInvitationError.invalidContext
        }
    }

    private static let keys: Set<String> = ["purpose", "audience", "origin", "requestID", "grantID", "linkVersion",
        "issuedAtMilliseconds", "expiresAtMilliseconds", "senderAccountID", "senderGroupID", "senderGeneration",
        "senderDeviceID", "senderPublicKey", "targetAccountID", "targetGroupID", "targetGeneration", "targetDeviceID", "targetPublicKey",
        "senderAudience", "targetAudience", "targetLinkHash"]
    static func validOrigin(_ value: String) -> Bool {
        guard value.utf8.count <= 255, value.hasPrefix("https://"), let url = URL(string: value), AccountServiceClient.validOrigin(url) else { return false }
        let host = value.dropFirst(8)
        return !host.isEmpty && host.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }
    }
}

/// Cryptographic pair consent only; never a live connection authorization.
public struct AccountInvitationPairProof: Equatable, Sendable {
    public let payload: Data
    public let senderSignature: Data
    public let targetSignature: Data
    public let pair: AccountInvitationPair
    public init(payload: Data, senderSignature: Data, targetSignature: Data) throws {
        let pair = try AccountInvitationPair(canonicalPayload: payload)
        try invitationVerify(senderSignature, key: pair.sender.publicKey, payload: payload)
        try invitationVerify(targetSignature, key: pair.target.publicKey, payload: payload)
        self.payload = payload; self.senderSignature = senderSignature; self.targetSignature = targetSignature; self.pair = pair
    }
    public init(wireJSON: Data) throws {
        do {
            let fields = try AccountGroupWireJSON.fields(wireJSON, keys: ["payload", "senderSignature", "targetSignature"])
            try self.init(payload: invitationBase64(fields["payload"]!, maximum: 5464),
                senderSignature: invitationBase64(fields["senderSignature"]!, maximum: 108),
                targetSignature: invitationBase64(fields["targetSignature"]!, maximum: 108))
        } catch { throw AccountInvitationError.invalidProof }
    }
    public func wireJSON() throws -> Data {
        try invitationEncode(["payload": payload.base64EncodedString(), "senderSignature": senderSignature.base64EncodedString(),
            "targetSignature": targetSignature.base64EncodedString()])
    }
}

func invitationUUID(_ value: String) -> Bool {
    AccountGroupCheckpoint.canonicalUUID(value) && value != "00000000-0000-0000-0000-000000000000"
}
func invitationAudience(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 255 && value.utf8.allSatisfy {
        (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
    }
}
func invitationNumber(_ value: String?) throws -> UInt64 {
    guard let value, let number = UInt64(value), number > 0, number <= UInt64(Int64.max), String(number) == value else {
        throw AccountInvitationError.invalidProof
    }
    return number
}
func invitationBase64(_ value: String, maximum: Int) throws -> Data {
    guard value.utf8.count <= maximum, let data = Data(base64Encoded: value), data.base64EncodedString() == value else {
        throw AccountInvitationError.invalidProof
    }
    return data
}
func invitationEncode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}
func invitationVerify(_ signature: Data, key: Data, payload: Data) throws {
    let encoded = key.count == 64 ? Data([4]) + key : key
    guard signature.count <= 80, let parsed = try? P256.Signing.ECDSASignature(derRepresentation: signature),
          parsed.derRepresentation == signature, let publicKey = try? P256.Signing.PublicKey(x963Representation: encoded),
          publicKey.isValidSignature(parsed, for: payload) else { throw AccountInvitationError.invalidProof }
}
