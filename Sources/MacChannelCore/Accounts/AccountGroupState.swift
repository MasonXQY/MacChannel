import Foundation

public struct AccountGroupMember: Equatable, Sendable {
    public let deviceID: String
    public let publicKey: Data
}
public struct AccountGroupSnapshot: Equatable, Sendable {
    public let accountID: String
    public let groupID: String
    public let generation: UInt64
    public let sequence: UInt64
    public let headHash: Data
    public let members: [AccountGroupMember]
}

/// Pure owned value state. Pins must come from independent owner confirmation,
/// never from the same untrusted response carrying the anchor.
public struct AccountGroupState: Sendable {
    private var current: AccountGroupSnapshot
    public var snapshot: AccountGroupSnapshot { current }
    public init(anchor: AccountGroupEvent, expectedAccountID: String, expectedGroupID: String,
                expectedGeneration: UInt64, expectedAnchorHash: Data) throws {
        guard anchor.action == "bootstrap", anchor.sequence == 1, anchor.accountID == expectedAccountID,
              anchor.groupID == expectedGroupID, anchor.generation == expectedGeneration,
              let digest = try? anchor.digest(), digest == expectedAnchorHash else {
            throw AccountGroupProofError.invalidTransition
        }
        current = AccountGroupSnapshot(accountID: anchor.accountID, groupID: anchor.groupID,
            generation: anchor.generation, sequence: anchor.sequence, headHash: expectedAnchorHash,
            members: [AccountGroupMember(deviceID: anchor.actorDeviceID, publicKey: anchor.actorPublicKey)])
    }
    public mutating func apply(_ event: AccountGroupEvent) throws {
        guard let digest = try? event.digest(), event.action != "bootstrap", current.sequence < UInt64(Int64.max),
              event.accountID == current.accountID, event.groupID == current.groupID,
              event.generation == current.generation, event.sequence == current.sequence + 1,
              event.previousHash == current.headHash,
              current.members.contains(AccountGroupMember(deviceID: event.actorDeviceID, publicKey: event.actorPublicKey)) else {
            throw AccountGroupProofError.invalidTransition
        }
        var members = current.members
        switch event.action {
        case "approve":
            guard members.count < 64, !members.contains(where: { $0.deviceID == event.subjectDeviceID }) else {
                throw AccountGroupProofError.invalidTransition
            }
            members.append(AccountGroupMember(deviceID: event.subjectDeviceID, publicKey: event.subjectPublicKey))
        case "remove":
            guard let index = members.firstIndex(of: AccountGroupMember(deviceID: event.subjectDeviceID, publicKey: event.subjectPublicKey)) else {
                throw AccountGroupProofError.invalidTransition
            }
            members.remove(at: index)
        default: throw AccountGroupProofError.invalidTransition
        }
        current = AccountGroupSnapshot(accountID: current.accountID, groupID: current.groupID,
            generation: current.generation, sequence: event.sequence, headHash: digest,
            members: members.sorted { $0.deviceID < $1.deviceID })
    }
}
