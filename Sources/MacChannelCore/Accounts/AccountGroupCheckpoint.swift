import Foundation

public enum AccountGroupCheckpointError: Error, Equatable, Sendable {
    case invalidCheckpoint, secureStorage, missingCheckpoint, invalidHistory, operationInProgress
}

/// Anti-replay knowledge only. A checkpoint is never a cached membership grant.
public struct AccountGroupCheckpoint: Equatable, Sendable {
    public let binding: AccountSessionBinding
    public let accountID: String
    public let groupID: String
    public let generation: UInt64
    public let anchorHash: Data
    public let sequence: UInt64
    public let headHash: Data

    public init(binding: AccountSessionBinding, accountID: String, groupID: String,
                generation: UInt64, anchorHash: Data, sequence: UInt64, headHash: Data) throws {
        guard Self.canonicalUUID(accountID), Self.canonicalUUID(groupID),
              generation > 0, generation <= UInt64(Int64.max),
              sequence > 0, sequence <= UInt64(Int64.max),
              anchorHash.count == 32, headHash.count == 32,
              sequence != 1 || headHash == anchorHash else {
            throw AccountGroupCheckpointError.invalidCheckpoint
        }
        self.binding = binding
        self.accountID = accountID
        self.groupID = groupID
        self.generation = generation
        self.anchorHash = anchorHash
        self.sequence = sequence
        self.headHash = headHash
    }

    static func canonicalUUID(_ value: String) -> Bool {
        value.utf8.count == 36 && UUID(uuidString: value)?.uuidString.lowercased() == value
    }
}
