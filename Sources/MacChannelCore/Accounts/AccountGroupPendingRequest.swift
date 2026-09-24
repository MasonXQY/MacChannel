import Foundation

public enum AccountGroupPendingStatus: String, Sendable, CaseIterable {
    case requested, proposed, countersigned, committed, rejected, cancelled, expired, invalidated
    var active: Bool { self == .requested || self == .proposed || self == .countersigned }
}

/// Inbox metadata only. Neither a summary nor a proof receipt establishes membership.
public struct AccountGroupPendingSummary: Equatable, Sendable {
    public let requestID, accountID, groupID, deviceID: String
    public let generation: UInt64
    public let publicKey: Data
    public let status: AccountGroupPendingStatus
    public let createdAtMilliseconds, expiresAtMilliseconds: UInt64
    public var createdAt: Date { Date(timeIntervalSince1970: Double(createdAtMilliseconds) / 1000) }
    public var expiresAt: Date { Date(timeIntervalSince1970: Double(expiresAtMilliseconds) / 1000) }

    public init(requestID: String, accountID: String, groupID: String, generation: UInt64,
                deviceID: String, publicKey: Data, status: AccountGroupPendingStatus,
                createdAtMilliseconds: UInt64, expiresAtMilliseconds: UInt64) throws {
        guard [requestID, accountID, groupID, deviceID].allSatisfy(AccountGroupPage.validGroupID),
              generation > 0, generation <= UInt64(Int64.max),
              createdAtMilliseconds > 0, expiresAtMilliseconds <= 9_007_199_254_740_991,
              expiresAtMilliseconds > createdAtMilliseconds,
              expiresAtMilliseconds - createdAtMilliseconds == 300_000,
              (try? AccountGroupEvent.deviceID(publicKey: publicKey)) == deviceID else {
            throw AccountServiceError.invalidResponse
        }
        self.requestID = requestID; self.accountID = accountID; self.groupID = groupID
        self.generation = generation; self.deviceID = deviceID; self.publicKey = Data(Array(publicKey))
        self.status = status; self.createdAtMilliseconds = createdAtMilliseconds
        self.expiresAtMilliseconds = expiresAtMilliseconds
    }

    public static func decodeList(_ data: Data) throws -> [Self] {
        do { var parser = PageParser(data: data); return try parser.pendingList() }
        catch { throw AccountServiceError.invalidResponse }
    }
}

public struct AccountGroupPendingRequest: Equatable, Sendable {
    public let summary: AccountGroupPendingSummary
    public let draft: AccountGroupApprovalDraft?
    public let event: AccountGroupEvent?
    public let eventHash: Data?

    public init(summary: AccountGroupPendingSummary, draft: AccountGroupApprovalDraft?,
                event: AccountGroupEvent?, eventHash: Data?) throws {
        do {
            switch summary.status {
            case .requested: guard draft == nil, event == nil, eventHash == nil else { throw AccountServiceError.invalidResponse }
            case .proposed: guard draft != nil, event == nil, eventHash == nil else { throw AccountServiceError.invalidResponse }
            case .countersigned: guard draft != nil, event != nil, eventHash == nil else { throw AccountServiceError.invalidResponse }
            case .committed: guard draft != nil, event != nil, eventHash?.count == 32 else { throw AccountServiceError.invalidResponse }
            case .rejected, .cancelled, .expired, .invalidated:
                guard eventHash == nil else { throw AccountServiceError.invalidResponse }
            }
            func bound(_ e: AccountGroupEvent) -> Bool {
                e.action == "approve" && e.accountID == summary.accountID && e.groupID == summary.groupID &&
                e.generation == summary.generation && e.subjectDeviceID == summary.deviceID && e.subjectPublicKey == summary.publicKey
            }
            if let draft {
                _ = try AccountGroupApprovalDraft(event: draft.event)
                guard bound(draft.event) else { throw AccountServiceError.invalidResponse }
            }
            if let event {
                try event.validate()
                guard let draft, bound(event), try event.canonicalPayload() == draft.event.canonicalPayload(),
                      event.signature == draft.event.signature else { throw AccountServiceError.invalidResponse }
                if let eventHash { guard try event.digest() == eventHash else { throw AccountServiceError.invalidResponse } }
            }
        } catch { throw AccountServiceError.invalidResponse }
        self.summary = summary; self.draft = draft; self.event = event
        self.eventHash = eventHash.map { Data(Array($0)) }
    }

    public init(data: Data) throws {
        do { var parser = PageParser(data: data); self = try parser.pendingRequest() }
        catch { throw AccountServiceError.invalidResponse }
    }
}

private extension PageParser {
    mutating func pendingNull() -> Bool {
        whitespace()
        if bytes[i...].starts(with: Array("null".utf8)) { i += 4; return true }
        return false
    }
    mutating func pendingData() throws -> Data {
        let value = try string()
        guard let data = Data(base64Encoded: value), data.base64EncodedString() == value else { throw AccountServiceError.invalidResponse }
        return data
    }
    mutating func pendingDraft() throws -> AccountGroupApprovalDraft {
        whitespace(); let start = i
        try token(123)
        for member in 0..<2 {
            if member > 0 { try token(44) }
            _ = try string(); try token(58); _ = try string()
        }
        try token(125)
        return try AccountGroupApprovalDraft(wire: AccountGroupWireApprovalDraft.decodeJSON(Data(bytes[start..<i])))
    }
    mutating func pendingRecord(full: Bool) throws -> (AccountGroupPendingSummary, AccountGroupApprovalDraft?, AccountGroupEvent?, Data?) {
        try token(123)
        var names = Set<String>()
        var request: String?, account: String?, group: String?, device: String?, status: AccountGroupPendingStatus?
        var generation: UInt64?, created: UInt64?, expires: UInt64?, key: Data?
        var draft: AccountGroupApprovalDraft?, final: AccountGroupEvent?, hash: Data?
        for member in 0..<(full ? 12 : 9) {
            if member > 0 { try token(44) }
            let name = try string()
            guard names.insert(name).inserted else { throw AccountServiceError.invalidResponse }
            try token(58)
            switch name {
            case "requestID": request = try string()
            case "accountID": account = try string()
            case "groupID": group = try string()
            case "deviceID": device = try string()
            case "generation": generation = try integer(maximum: UInt64(Int64.max), minimum: 1)
            case "publicKey": key = try pendingData()
            case "status": status = AccountGroupPendingStatus(rawValue: try string())
            case "createdAt": created = try integer(maximum: 9_007_199_254_740_991, minimum: 1)
            case "expiresAt": expires = try integer(maximum: 9_007_199_254_740_991, minimum: 1)
            case "draft" where full: if !pendingNull() { draft = try pendingDraft() }
            case "event" where full: if !pendingNull() { final = try event() }
            case "eventHash" where full: if !pendingNull() { hash = try pendingData() }
            default: throw AccountServiceError.invalidResponse
            }
        }
        try token(125)
        guard let request, let account, let group, let device, let status, let generation, let created, let expires, let key else { throw AccountServiceError.invalidResponse }
        let summary = try AccountGroupPendingSummary(requestID: request, accountID: account, groupID: group,
            generation: generation, deviceID: device, publicKey: key, status: status,
            createdAtMilliseconds: created, expiresAtMilliseconds: expires)
        return (summary, draft, final, hash)
    }
    mutating func pendingStart(_ name: String) throws {
        guard bytes.count <= 65_536 else { throw AccountServiceError.invalidResponse }
        try token(123)
        guard try string() == name else { throw AccountServiceError.invalidResponse }
        try token(58)
    }
    mutating func pendingEnd() throws {
        try token(125); whitespace()
        guard i == bytes.count else { throw AccountServiceError.invalidResponse }
    }
    mutating func pendingRequest() throws -> AccountGroupPendingRequest {
        try pendingStart("request")
        let (summary, draft, event, hash) = try pendingRecord(full: true)
        try pendingEnd()
        return try AccountGroupPendingRequest(summary: summary, draft: draft, event: event, eventHash: hash)
    }
    mutating func pendingList() throws -> [AccountGroupPendingSummary] {
        try pendingStart("requests"); try token(91); whitespace()
        var result: [AccountGroupPendingSummary] = [], ids = Set<String>()
        if i < bytes.count, bytes[i] != 93 {
            while true {
                guard result.count < 32 else { throw AccountServiceError.invalidResponse }
                let (summary, _, _, _) = try pendingRecord(full: false)
                guard summary.status.active, ids.insert(summary.requestID).inserted else { throw AccountServiceError.invalidResponse }
                result.append(summary); whitespace()
                if i < bytes.count, bytes[i] == 93 { break }
                try token(44)
            }
        }
        try token(93); try pendingEnd(); return result
    }
}
