import Foundation

public protocol AccountGroupEnrollmentService: Sendable {
    func discoverGroup(accessToken: String, accountID: String) async throws -> AccountGroupDiscovery
    func recordGroupBootstrap(accessToken: String, event: AccountGroupEvent) async throws
}

/// Untrusted discovery metadata, never a membership snapshot or an authorized trust anchor.
public enum AccountGroupDiscovery: Equatable, Sendable {
    case absent
    case present(AccountGroupDiscoveryMetadata)
}

/// Even a valid anchor signature does not authorize adoption of the discovered group.
public struct AccountGroupDiscoveryMetadata: Equatable, Sendable {
    public let groupID: String
    public let generation: UInt64
    public let anchor: AccountGroupEvent
    public let anchorHash: Data
    public let headSequence: UInt64
    public let headHash: Data

    /// Constructs metadata only. Callers must validate account/revision bindings
    /// and independently authorize trust before using any discovered anchor.
    public init(groupID: String, generation: UInt64, anchor: AccountGroupEvent,
                anchorHash: Data, headSequence: UInt64, headHash: Data) {
        self.groupID = groupID; self.generation = generation; self.anchor = anchor
        self.anchorHash = anchorHash; self.headSequence = headSequence; self.headHash = headHash
    }
}

public enum AccountGroupEnrollmentError: Error, Equatable, Sendable { case conflict }

extension AccountServiceClient: AccountGroupEnrollmentService {
    public func discoverGroup(accessToken: String, accountID: String) async throws -> AccountGroupDiscovery {
        try Task.checkCancellation()
        guard Self.validToken(accessToken), AccountGroupPage.validGroupID(accountID) else {
            throw AccountServiceError.invalidRequest
        }
        let data = try await sendEnrollment(path: "/v1/account/group/discover", fields: [
            "purpose": "dropmesh.account.group.discover.v1", "audience": audience, "accessToken": accessToken,
        ])
        do {
            var parser = PageParser(data: data)
            let discovery = try parser.discovery(accountID: accountID)
            try Task.checkCancellation()
            return discovery
        } catch {
            try Task.checkCancellation()
            throw AccountServiceError.invalidResponse
        }
    }

    /// Transmits an already signed, explicitly consented bootstrap intent. This
    /// method neither creates that intent nor confirms membership or local trust.
    public func recordGroupBootstrap(accessToken: String, event: AccountGroupEvent) async throws {
        try Task.checkCancellation()
        guard Self.validToken(accessToken), event.action == "bootstrap",
              event.actorDeviceID == identity.id.rawValue.uuidString.lowercased(),
              event.actorPublicKey == identity.publicKey.rawRepresentation else {
            throw AccountServiceError.invalidRequest
        }
        let encoded: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            encoded = try encoder.encode(event.wireEvent())
        } catch { throw AccountServiceError.invalidRequest }
        guard (1...4096).contains(encoded.count) else { throw AccountServiceError.invalidRequest }
        let data = try await sendEnrollment(path: "/v1/account/group/bootstrap", fields: [
            "purpose": "dropmesh.account.group.bootstrap.v1", "audience": audience, "accessToken": accessToken,
            "confirmation": "join_this_device", "event": encoded.base64EncodedString(),
        ])
        do {
            var parser = PageParser(data: data)
            try parser.bootstrapAcknowledgment(event: event)
            try Task.checkCancellation()
        } catch {
            try Task.checkCancellation()
            throw AccountServiceError.invalidResponse
        }
    }

    private func sendEnrollment(path: String, fields: [String: String]) async throws -> Data {
        try Task.checkCancellation()
        do {
            let data = try await send(path: path, fields: fields, requestDate: requestDate())
            try Task.checkCancellation()
            return data
        } catch {
            // A noncooperative transport may return either a result or an error
            // after cancellation. Never deliver that stale outcome to the caller.
            try Task.checkCancellation()
            throw error
        }
    }
}

private extension PageParser {
    mutating func hash() throws -> Data {
        let value = try string()
        guard let decoded = Data(base64Encoded: value), decoded.count == 32,
              decoded.base64EncodedString() == value else { throw AccountServiceError.invalidResponse }
        return decoded
    }

    mutating func discovery(accountID: String) throws -> AccountGroupDiscovery {
        guard bytes.count <= 65_536 else { throw AccountServiceError.invalidResponse }
        try token(123)
        var names = Set<String>()
        var status: String?, group: String?, generation: UInt64?, anchor: AccountGroupEvent?
        var anchorHash: Data?, head: UInt64?, headHash: Data?
        while true {
            guard names.count < 7 else { throw AccountServiceError.invalidResponse }
            if !names.isEmpty { try token(44) }
            let key = try string()
            guard names.insert(key).inserted else { throw AccountServiceError.invalidResponse }
            try token(58)
            switch key {
            case "status": status = try string()
            case "groupID": group = try string()
            case "generation": generation = try integer(maximum: UInt64(Int64.max), minimum: 1)
            case "anchor": anchor = try event()
            case "anchorHash": anchorHash = try hash()
            case "headSequence": head = try integer(maximum: 8192, minimum: 1)
            case "headHash": headHash = try hash()
            default: throw AccountServiceError.invalidResponse
            }
            whitespace()
            if i < bytes.count, bytes[i] == 125 { break }
        }
        try token(125); whitespace()
        guard i == bytes.count else { throw AccountServiceError.invalidResponse }
        if status == "absent", names == ["status"] { return .absent }
        guard status == "present", names.count == 7, let group, AccountGroupPage.validGroupID(group),
              let generation, let anchor, let anchorHash, let head, let headHash,
              anchor.action == "bootstrap", anchor.accountID == accountID, anchor.groupID == group,
              anchor.generation == generation, try anchor.digest() == anchorHash,
              head != 1 || headHash == anchorHash else { throw AccountServiceError.invalidResponse }
        // A later head is informational. Only complete history plus independently
        // confirmed trust can establish current membership.
        return .present(.init(groupID: group, generation: generation, anchor: anchor,
                              anchorHash: anchorHash, headSequence: head, headHash: headHash))
    }

    mutating func bootstrapAcknowledgment(event: AccountGroupEvent) throws {
        guard bytes.count <= 65_536 else { throw AccountServiceError.invalidResponse }
        try token(123)
        var names = Set<String>()
        var status: String?, group: String?, generation: UInt64?, eventHash: Data?
        for member in 0..<4 {
            if member > 0 { try token(44) }
            let key = try string()
            guard names.insert(key).inserted else { throw AccountServiceError.invalidResponse }
            try token(58)
            switch key {
            case "status": status = try string()
            case "groupID": group = try string()
            case "generation": generation = try integer(maximum: UInt64(Int64.max), minimum: 1)
            case "eventHash": eventHash = try hash()
            default: throw AccountServiceError.invalidResponse
            }
        }
        try token(125); whitespace()
        guard i == bytes.count, status == "recorded", group == event.groupID,
              generation == event.generation, try eventHash == event.digest() else {
            throw AccountServiceError.invalidResponse
        }
    }
}
