import Foundation

/// An actor-signed proposal only. It conveys neither membership nor user consent.
public struct AccountGroupApprovalDraft: Equatable, Sendable {
    public let event: AccountGroupEvent

    public init(event: AccountGroupEvent) throws {
        guard event.action == "approve", event.subjectSignature.isEmpty else {
            throw AccountGroupProofError.invalidEvent
        }
        _ = try event.validateActorProof()
        self.event = event
    }

    public init(wire: AccountGroupWireApprovalDraft) throws {
        try self.init(event: AccountGroupEvent(
            canonicalPayload: AccountGroupEvent.wireBase64(wire.payload, bound: 4096),
            signature: AccountGroupEvent.wireBase64(wire.signature, bound: 108), subjectSignature: Data()))
    }

    public func wireDraft() throws -> AccountGroupWireApprovalDraft {
        let payload = try event.canonicalPayload().base64EncodedString()
        guard payload.utf8.count <= 4096 else { throw AccountGroupProofError.invalidEvent }
        return AccountGroupWireApprovalDraft(payload: payload, signature: event.signature.base64EncodedString())
    }

    /// Adds only the joining proof; freshness, sessions, membership and explicit
    /// confirmations still belong to the authenticated transactional workflow.
    public func finalize(subjectSignature: Data) throws -> AccountGroupEvent {
        let result = try AccountGroupEvent(canonicalPayload: event.canonicalPayload(),
            signature: event.signature, subjectSignature: subjectSignature)
        try result.validate()
        return result
    }
}

public struct AccountGroupWireApprovalDraft: Codable, Equatable, Sendable {
    public let payload: String
    public let signature: String

    public init(payload: String, signature: String) {
        self.payload = payload; self.signature = signature
    }

    private struct Key: CodingKey {
        let stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { return nil }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        guard Set(c.allKeys.map(\.stringValue)) == Set(["payload", "signature"]) else {
            throw AccountGroupProofError.invalidEvent
        }
        payload = try c.decode(String.self, forKey: Key(stringValue: "payload")!)
        signature = try c.decode(String.self, forKey: Key(stringValue: "signature")!)
        _ = try AccountGroupEvent.wireBase64(payload, bound: 4096)
        _ = try AccountGroupEvent.wireBase64(signature, bound: 108)
    }

    /// Use at raw untrusted boundaries: keyed Codable alone loses duplicates.
    public static func decodeJSON(_ data: Data) throws -> Self {
        do {
            _ = try AccountGroupWireJSON.fields(data, keys: ["payload", "signature"])
            return try JSONDecoder().decode(Self.self, from: data)
        } catch { throw AccountGroupProofError.invalidEvent }
    }
}
