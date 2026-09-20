import Foundation

/// Bounded, schema-specific JSON boundary. In particular, keyed Decodable alone
/// would discard duplicate names (including escaped aliases).
struct AccountGroupPage {
    let groupID: String
    let generation: UInt64
    let headSequence: UInt64
    let headHash: Data
    let afterSequence: UInt64
    let nextSequence: UInt64
    let hasMore: Bool
    let events: [AccountGroupEvent]

    static func validGroupID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    init(data: Data) throws {
        do {
            var parser = PageParser(data: data)
            self = try parser.parse()
        } catch { throw AccountServiceError.invalidResponse }
    }

    fileprivate init(groupID: String, generation: UInt64, headSequence: UInt64, headHash: Data,
                     afterSequence: UInt64, nextSequence: UInt64, hasMore: Bool, events: [AccountGroupEvent]) {
        self.groupID = groupID; self.generation = generation; self.headSequence = headSequence
        self.headHash = headHash; self.afterSequence = afterSequence; self.nextSequence = nextSequence
        self.hasMore = hasMore; self.events = events
    }
}

private struct PageParser {
    let bytes: [UInt8]
    var i = 0
    init(data: Data) { bytes = Array(data) }
    mutating func whitespace() { while i < bytes.count && [9, 10, 13, 32].contains(bytes[i]) { i += 1 } }
    mutating func token(_ byte: UInt8) throws {
        whitespace()
        guard i < bytes.count, bytes[i] == byte else { throw AccountServiceError.invalidResponse }
        i += 1
    }
    mutating func string() throws -> String {
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
        throw AccountServiceError.invalidResponse
    }
    mutating func integer(maximum: UInt64, minimum: UInt64 = 0) throws -> UInt64 {
        whitespace()
        let start = i
        while i < bytes.count && (48...57).contains(bytes[i]) { i += 1 }
        guard i > start, i - start <= 19, i - start == 1 || bytes[start] != 48,
              let value = UInt64(String(decoding: bytes[start..<i], as: UTF8.self)),
              value >= minimum, value <= maximum else { throw AccountServiceError.invalidResponse }
        // The next schema delimiter must immediately follow; decimals/exponents
        // cannot be consumed as part of another field.
        return value
    }
    mutating func boolean() throws -> Bool {
        whitespace()
        for (literal, value) in [(Array("true".utf8), true), (Array("false".utf8), false)] {
            if bytes[i...].starts(with: literal) { i += literal.count; return value }
        }
        throw AccountServiceError.invalidResponse
    }
    mutating func events() throws -> [AccountGroupEvent] {
        try token(91)
        whitespace()
        var values: [AccountGroupEvent] = []
        if i < bytes.count, bytes[i] == 93 { i += 1; return values }
        while true {
            guard values.count < 16 else { throw AccountServiceError.invalidResponse }
            whitespace()
            let start = i
            try token(123)
            // Wire events have exactly three string members. The existing raw
            // codec validates their names, uniqueness, bounds and proofs.
            for member in 0..<3 {
                if member > 0 { try token(44) }
                _ = try string(); try token(58); _ = try string()
            }
            try token(125)
            let wire = try AccountGroupWireEvent.decodeJSON(Data(bytes[start..<i]))
            values.append(try AccountGroupEvent(wire: wire))
            whitespace()
            guard i < bytes.count else { throw AccountServiceError.invalidResponse }
            if bytes[i] == 93 { i += 1; return values }
            try token(44)
        }
    }
    mutating func parse() throws -> AccountGroupPage {
        guard bytes.count <= 65_536 else { throw AccountServiceError.invalidResponse }
        try token(123)
        var names = Set<String>()
        var group: String?, generation: UInt64?, head: UInt64?, hash: Data?
        var after: UInt64?, next: UInt64?, more: Bool?, records: [AccountGroupEvent]?
        for member in 0..<8 {
            if member > 0 { try token(44) }
            let key = try string()
            guard names.insert(key).inserted else { throw AccountServiceError.invalidResponse }
            try token(58)
            switch key {
            case "groupID":
                let value = try string()
                guard AccountGroupPage.validGroupID(value) else { throw AccountServiceError.invalidResponse }
                group = value
            case "generation": generation = try integer(maximum: UInt64(Int64.max), minimum: 1)
            case "headSequence": head = try integer(maximum: 8192, minimum: 1)
            case "headHash":
                let value = try string()
                guard let decoded = Data(base64Encoded: value), decoded.count == 32,
                      decoded.base64EncodedString() == value else { throw AccountServiceError.invalidResponse }
                hash = decoded
            case "afterSequence": after = try integer(maximum: 8192)
            case "nextSequence": next = try integer(maximum: 8192)
            case "hasMore": more = try boolean()
            case "events": records = try events()
            default: throw AccountServiceError.invalidResponse
            }
        }
        try token(125); whitespace()
        guard i == bytes.count, let group, let generation, let head, let hash,
              let after, let next, let more, let records else { throw AccountServiceError.invalidResponse }
        return AccountGroupPage(groupID: group, generation: generation, headSequence: head,
            headHash: hash, afterSequence: after, nextSequence: next, hasMore: more, events: records)
    }
}
