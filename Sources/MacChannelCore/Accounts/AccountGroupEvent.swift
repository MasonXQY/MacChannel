import Foundation
import CryptoKit

public enum AccountGroupProofError: Error, Equatable { case invalidEvent, invalidTransition }

public struct AccountGroupWireEvent: Codable, Equatable, Sendable {
    public let payload: String
    public let signature: String
    public let subjectSignature: String

    public init(payload: String, signature: String, subjectSignature: String) {
        self.payload = payload; self.signature = signature; self.subjectSignature = subjectSignature
    }
    private struct Key: CodingKey {
        let stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { return nil }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        guard Set(c.allKeys.map(\.stringValue)) == Set(["payload", "signature", "subjectSignature"]) else {
            throw AccountGroupProofError.invalidEvent
        }
        payload = try c.decode(String.self, forKey: Key(stringValue: "payload")!)
        signature = try c.decode(String.self, forKey: Key(stringValue: "signature")!)
        subjectSignature = try c.decode(String.self, forKey: Key(stringValue: "subjectSignature")!)
        guard payload.utf8.count <= 4096, signature.utf8.count <= 108, subjectSignature.utf8.count <= 108 else {
            throw AccountGroupProofError.invalidEvent
        }
    }

    /// Required at untrusted raw JSON boundaries. Foundation's keyed Decoder
    /// loses duplicate keys; Codable alone cannot enforce their absence.
    public static func decodeJSON(_ data: Data) throws -> Self {
        do {
            _ = try AccountGroupWireJSON.fields(data, keys: ["payload", "signature", "subjectSignature"])
            return try JSONDecoder().decode(Self.self, from: data)
        }
        catch { throw AccountGroupProofError.invalidEvent }
    }
}

enum AccountGroupWireJSON {
    static func fields(_ data: Data, keys: Set<String>) throws -> [String: String] {
        guard data.count <= 8192 else { throw AccountGroupProofError.invalidEvent }
        let bytes = Array(data)
        var i = 0
        func whitespace() { while i < bytes.count && [9, 10, 13, 32].contains(bytes[i]) { i += 1 } }
        func token(_ byte: UInt8) throws {
            whitespace()
            guard i < bytes.count, bytes[i] == byte else { throw AccountGroupProofError.invalidEvent }
            i += 1
        }
        func string() throws -> String {
            whitespace()
            let start = i
            try token(34)
            while i < bytes.count {
                if bytes[i] == 34 {
                    i += 1
                    return try JSONDecoder().decode(String.self, from: Data(bytes[start..<i]))
                }
                if bytes[i] == 92 { i += 1 }
                i += 1
            }
            throw AccountGroupProofError.invalidEvent
        }
        try token(123)
        var fields: [String: String] = [:]
        for index in 0..<keys.count {
            if index > 0 { try token(44) }
            let key = try string()
            guard keys.contains(key), fields[key] == nil else {
                throw AccountGroupProofError.invalidEvent
            }
            try token(58)
            fields[key] = try string()
        }
        try token(125)
        whitespace()
        guard i == bytes.count else { throw AccountGroupProofError.invalidEvent }
        return fields
    }
}

public struct AccountGroupEvent: Equatable, Sendable {
    public let accountID: String
    public let groupID: String
    public let generation: UInt64
    public let sequence: UInt64
    public let previousHash: Data
    public let action: String
    public let actorDeviceID: String
    public let actorPublicKey: Data
    public let subjectDeviceID: String
    public let subjectPublicKey: Data
    public let epochMilliseconds: Int64
    public let signature: Data
    public let subjectSignature: Data

    public init(accountID: String, groupID: String, generation: UInt64, sequence: UInt64,
                previousHash: Data, action: String, actorDeviceID: String, actorPublicKey: Data,
                subjectDeviceID: String, subjectPublicKey: Data, epochMilliseconds: Int64,
                signature: Data = Data(), subjectSignature: Data = Data()) throws {
        self.accountID = accountID; self.groupID = groupID
        self.generation = generation; self.sequence = sequence; self.previousHash = previousHash
        self.action = action; self.actorDeviceID = actorDeviceID; self.actorPublicKey = actorPublicKey
        self.subjectDeviceID = subjectDeviceID; self.subjectPublicKey = subjectPublicKey
        self.epochMilliseconds = epochMilliseconds; self.signature = signature; self.subjectSignature = subjectSignature
        try validateStructure()
    }
    public func canonicalPayload() throws -> Data {
        try validateStructure()
        // Every string is constrained to ASCII UUID/action/base64 constants, so
        // no escaping is required. Integer interpolation never passes via Double.
        return Data(("{\"accountID\":\"\(accountID)\",\"action\":\"\(action)\",\"actorDeviceID\":\"\(actorDeviceID)\",\"actorPublicKey\":\"\(actorPublicKey.base64EncodedString())\",\"epochMilliseconds\":\(epochMilliseconds),\"generation\":\(generation),\"groupID\":\"\(groupID)\",\"previousHash\":\"\(previousHash.base64EncodedString())\",\"purpose\":\"dropmesh.account.group.event.v1\",\"sequence\":\(sequence),\"subjectDeviceID\":\"\(subjectDeviceID)\",\"subjectPublicKey\":\"\(subjectPublicKey.base64EncodedString())\"}").utf8)
    }
    public func validate() throws {
        let payload = try validateActorProof()
        if action == "approve" { try Self.verify(subjectSignature, key: subjectPublicKey, payload: payload) }
        else if !subjectSignature.isEmpty { throw AccountGroupProofError.invalidEvent }
    }
    // Internal actor-only seam; finalized validation never skips joining proof.
    func validateActorProof() throws -> Data {
        let payload = try canonicalPayload()
        try Self.verify(signature, key: actorPublicKey, payload: payload)
        return payload
    }
    private static func verify(_ signature: Data, key: Data, payload: Data) throws {
        guard !signature.isEmpty, signature.count <= 80,
              let sig = try? P256.Signing.ECDSASignature(derRepresentation: signature),
              try Self.publicKey(key).isValidSignature(sig, for: payload) else {
            throw AccountGroupProofError.invalidEvent
        }
    }
    public func digest() throws -> Data {
        try validate()
        return Data(SHA256.hash(data: try canonicalPayload()))
    }
    public func wireEvent() throws -> AccountGroupWireEvent {
        try validate()
        return AccountGroupWireEvent(payload: try canonicalPayload().base64EncodedString(),
            signature: signature.base64EncodedString(), subjectSignature: subjectSignature.base64EncodedString())
    }
    public init(wire: AccountGroupWireEvent) throws {
        do {
            try self.init(canonicalPayload: Self.wireBase64(wire.payload, bound: 4096),
                signature: Self.wireBase64(wire.signature, bound: 108),
                subjectSignature: Self.wireBase64(wire.subjectSignature, bound: 108))
            try validate()
        } catch { throw AccountGroupProofError.invalidEvent }
    }
    static func wireBase64(_ value: String, bound: Int) throws -> Data {
        guard value.utf8.count <= bound, let result = Data(base64Encoded: value),
              result.base64EncodedString() == value else { throw AccountGroupProofError.invalidEvent }
        return result
    }
    // Exact canonical parser shared by separate draft and finalized envelopes.
    init(canonicalPayload bytes: Data, signature: Data, subjectSignature: Data) throws {
        struct Payload: Decodable {
            let accountID: String, action: String, actorDeviceID: String, actorPublicKey: String
            let epochMilliseconds: Int64, generation: UInt64, groupID: String, previousHash: String
            let purpose: String, sequence: UInt64, subjectDeviceID: String, subjectPublicKey: String
        }
        do {
            let p = try JSONDecoder().decode(Payload.self, from: bytes)
            guard p.purpose == "dropmesh.account.group.event.v1" else { throw AccountGroupProofError.invalidEvent }
            try self.init(accountID: p.accountID, groupID: p.groupID, generation: p.generation, sequence: p.sequence,
                previousHash: Self.wireBase64(p.previousHash, bound: 44), action: p.action, actorDeviceID: p.actorDeviceID,
                actorPublicKey: Self.wireBase64(p.actorPublicKey, bound: 88), subjectDeviceID: p.subjectDeviceID,
                subjectPublicKey: Self.wireBase64(p.subjectPublicKey, bound: 88), epochMilliseconds: p.epochMilliseconds,
                signature: signature, subjectSignature: subjectSignature)
            guard try canonicalPayload() == bytes else { throw AccountGroupProofError.invalidEvent }
        } catch { throw AccountGroupProofError.invalidEvent }
    }
    private static func publicKey(_ bytes: Data) throws -> P256.Signing.PublicKey {
        do {
            let encoded: Data
            if bytes.count == 64 { encoded = Data([4]) + bytes }
            else if bytes.count == 65, bytes.first == 4 { encoded = bytes }
            else { throw AccountGroupProofError.invalidEvent }
            // CryptoKit raw/x963 initialization alone can retain an off-curve
            // point. Compressed decoding reconstructs y on P256; require the
            // reconstructed full point to equal the original exact coordinates.
            let compressed = Data([2 | (encoded.last! & 1)]) + encoded.dropFirst().prefix(32)
            let key = try P256.Signing.PublicKey(compressedRepresentation: compressed)
            guard key.x963Representation == encoded else { throw AccountGroupProofError.invalidEvent }
            return key
        } catch { throw AccountGroupProofError.invalidEvent }
    }
    public static func deviceID(publicKey: Data) throws -> String {
        _ = try Self.publicKey(publicKey)
        let h = Array(SHA256.hash(data: publicKey).prefix(16).map { String(format: "%02x", $0) }.joined())
        return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(h[$0]) }.joined(separator: "-")
    }
    private func validateStructure() throws {
        func uuid(_ value: String) -> Bool {
            let b = Array(value.utf8)
            return b.count == 36 && b.enumerated().allSatisfy { i, c in
                [8, 13, 18, 23].contains(i) ? c == 45 : ((48...57).contains(c) || (97...102).contains(c))
            }
        }
        guard uuid(accountID), uuid(groupID), generation > 0, generation <= UInt64(Int64.max),
              sequence > 0, sequence <= UInt64(Int64.max), epochMilliseconds > 0,
              try Self.deviceID(publicKey: actorPublicKey) == actorDeviceID,
              try Self.deviceID(publicKey: subjectPublicKey) == subjectDeviceID else {
            throw AccountGroupProofError.invalidEvent
        }
        switch action {
        case "bootstrap":
            guard sequence == 1, previousHash.isEmpty, actorDeviceID == subjectDeviceID,
                  actorPublicKey == subjectPublicKey else { throw AccountGroupProofError.invalidEvent }
        case "approve":
            guard sequence >= 2, previousHash.count == 32, actorDeviceID != subjectDeviceID else { throw AccountGroupProofError.invalidEvent }
        case "remove":
            guard sequence >= 2, previousHash.count == 32,
                  actorDeviceID != subjectDeviceID || actorPublicKey == subjectPublicKey else { throw AccountGroupProofError.invalidEvent }
        default: throw AccountGroupProofError.invalidEvent
        }
    }
}
